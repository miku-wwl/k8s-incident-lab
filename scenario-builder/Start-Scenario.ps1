[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [Parameter(Mandatory)]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$namespace = "incident-lab"

function Invoke-Kubectl {
    & kubectl --context $Context @args
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed: $($args -join ' ')"
    }
}

Invoke-Kubectl cluster-info | Out-Null
$active = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -eq 0 -and $active) {
    throw "Scenario $active is already active. Reset it before starting another incident."
}

& kubectl --context $Context -n $namespace create configmap scenario-state `
    --from-literal="incident=$Incident" `
    --from-literal="startedAt=$([DateTime]::UtcNow.ToString('o'))" `
    --dry-run=client -o yaml | & kubectl --context $Context apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create scenario state." }

switch ($Incident) {
    "INC-01" {
        Invoke-Kubectl -n $namespace set image deployment/gateway app=k8s-incident-lab/service:2.0.0
        Invoke-Kubectl -n $namespace annotate deployment/gateway `
            kubernetes.io/change-cause="Routine release 2.0.0" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/gateway --timeout=3m
    }
    "INC-02" {
        Invoke-Kubectl -n $namespace set env deployment/traffic-gateway `
            CONCURRENCY=48 REQUEST_INTERVAL_SECONDS=0.02 REQUEST_TIMEOUT_SECONDS=0.8
        Invoke-Kubectl -n $namespace scale deployment/traffic-gateway --replicas=4
        Invoke-Kubectl -n $namespace annotate deployment/traffic-gateway `
            kubernetes.io/change-cause="Representative demand window" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/traffic-gateway --timeout=3m
    }
    "INC-03" {
        $nodes = (Invoke-Kubectl get nodes -o json | ConvertFrom-Json).items |
            Where-Object {
                -not $_.spec.unschedulable -and
                $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
            }
        if (@($nodes).Count -lt 2) {
            throw "INC-03 requires at least two schedulable worker nodes. Use -CreateKindCluster."
        }
        $target = @($nodes)[0].metadata.name
        Invoke-Kubectl label node $target training.example.com/tier=primary --overwrite
        $placementPatch = '{"spec":{"template":{"spec":{"nodeSelector":{"training.example.com/tier":"primary"}}}}}'
        $budgetPatch = '{"spec":{"minAvailable":0}}'
        Invoke-Kubectl -n $namespace patch deployment gateway --type merge --patch $placementPatch
        Invoke-Kubectl -n $namespace patch poddisruptionbudget gateway --type merge --patch $budgetPatch
        Invoke-Kubectl -n $namespace annotate deployment/gateway `
            kubernetes.io/change-cause="Workload placement update" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/gateway --timeout=3m
        Invoke-Kubectl drain $target --pod-selector=app.kubernetes.io/name=gateway `
            --ignore-daemonsets --delete-emptydir-data --timeout=2m
    }
    "INC-04" {
        Invoke-Kubectl -n $namespace set env deployment/traffic-shared `
            CONCURRENCY=80 REQUEST_INTERVAL_SECONDS=0.01 REQUEST_TIMEOUT_SECONDS=0.8
        Invoke-Kubectl -n $namespace scale deployment/traffic-shared --replicas=4
        Invoke-Kubectl -n $namespace annotate deployment/traffic-shared `
            kubernetes.io/change-cause="Shared workload demand window" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/traffic-shared --timeout=3m
    }
    "INC-05" {
        $servicePatch = '{"spec":{"selector":{"app.kubernetes.io/name":"gateway","app.kubernetes.io/role":"candidate"}}}'
        Invoke-Kubectl -n $namespace patch service gateway --type merge --patch $servicePatch
        Invoke-Kubectl -n $namespace annotate service/gateway `
            training.example.com/change="routing update" --overwrite
    }
    "INC-06" {
        if (-not (& kubectl --context $Context get crd scaledobjects.keda.sh --ignore-not-found -o name)) {
            throw "INC-06 requires KEDA. Re-run Start-Lab.ps1 without -SkipAddons."
        }
        $scalingPatch = '{"spec":{"maxReplicaCount":2,"triggers":[{"type":"redis","metadata":{"address":"redis.incident-lab.svc.cluster.local:6379","listName":"orders","listLength":"100000","enableTLS":"false"}}]}}'
        Invoke-Kubectl -n $namespace patch scaledobject worker --type merge --patch $scalingPatch
        Invoke-Kubectl -n $namespace set env deployment/traffic-orders `
            CONCURRENCY=12 REQUEST_INTERVAL_SECONDS=0.05
        Invoke-Kubectl -n $namespace annotate deployment/traffic-orders `
            kubernetes.io/change-cause="Order demand window" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/traffic-orders --timeout=3m
    }
    "INC-07" {
        Invoke-Kubectl -n $namespace set env statefulset/storage --containers=maintenance `
            MAINTENANCE_INTERVAL_SECONDS=0.2 MAINTENANCE_HOLD_SECONDS=2.5
        Invoke-Kubectl -n $namespace annotate statefulset/storage `
            kubernetes.io/change-cause="Scheduled data maintenance" --overwrite
        Invoke-Kubectl -n $namespace rollout status statefulset/storage --timeout=3m
    }
    "INC-08" {
        $coreDns = & kubectl --context $Context -n kube-system get deployment coredns -o name 2>$null
        if (-not $coreDns) { throw "INC-08 requires kube-system deployment/coredns." }
        $dnsRuleBlock = @'
    template IN A incident-lab.svc.cluster.local {
        rcode SERVFAIL
    }
    template IN AAAA incident-lab.svc.cluster.local {
        rcode SERVFAIL
    }
'@ + "`n"
        $config = (Invoke-Kubectl -n kube-system get configmap coredns -o json | ConvertFrom-Json)
        $corefile = $config.data.Corefile
        if ($corefile.Contains($dnsRuleBlock)) { throw "Scenario DNS rules are already present." }
        $updatedCorefile = [regex]::Replace(
            $corefile,
            '(?m)^(\s*ready\s*\r?\n)',
            { param($match) $match.Value + $dnsRuleBlock },
            1
        )
        if ($updatedCorefile -eq $corefile) { throw "CoreDNS ready directive was not found." }
        $configPatch = @{ data = @{ Corefile = $updatedCorefile } } | ConvertTo-Json -Compress
        Invoke-Kubectl -n kube-system patch configmap coredns --type merge --patch $configPatch
        Invoke-Kubectl -n kube-system annotate configmap/coredns `
            training.example.com/change="resolver configuration update" --overwrite
        Invoke-Kubectl -n kube-system rollout restart deployment/coredns
        Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=3m
        Invoke-Kubectl apply -f (Join-Path $PSScriptRoot "change-818.yaml")
        Invoke-Kubectl -n $namespace rollout status deployment/dns-client --timeout=3m
    }
}

$brief = Join-Path $repoRoot "learner\briefs\$Incident.md"
Write-Output "SCENARIO_READY incident=$Incident context=$Context"
Write-Output "Learner brief: $brief"
Write-Output "Use runtime evidence only. Do not share this builder session with the Coach session."
