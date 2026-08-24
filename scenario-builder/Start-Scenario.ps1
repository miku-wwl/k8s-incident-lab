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
$stateDirectory = Join-Path $repoRoot ".scenario-state"
$safeContext = $Context -replace '[^A-Za-z0-9_.-]', '_'
$statePath = Join-Path $stateDirectory "$safeContext.json"

function Invoke-Kubectl {
    $output = & kubectl --context $Context @args
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed: $($args -join ' ')"
    }
    return $output
}

function Assert-DisposableLabContext {
    if ($Context -notlike "kind-*") {
        throw "Scenario mutation is restricted to a kind context; received '$Context'."
    }
    $knownContext = & kubectl config get-contexts $Context -o name 2>$null
    if ($LASTEXITCODE -ne 0 -or $knownContext -ne $Context) {
        throw "Kubernetes context '$Context' does not exist."
    }
    Invoke-Kubectl cluster-info | Out-Null
    $labId = Invoke-Kubectl get namespace $namespace `
        -o jsonpath='{.metadata.labels.training\.example\.com/lab-id}'
    $disposable = Invoke-Kubectl get namespace $namespace `
        -o jsonpath='{.metadata.labels.training\.example\.com/disposable}'
    if ($labId -ne "k8s-incident-lab" -or $disposable -ne "true") {
        throw "Namespace '$namespace' is not marked as the disposable incident lab."
    }
    $nodeJson = (Invoke-Kubectl get nodes -o json) -join "`n"
    $nodes = ($nodeJson | ConvertFrom-Json).items
    $controlPlanes = @($nodes | Where-Object {
        $null -ne $_.metadata.labels.'node-role.kubernetes.io/control-plane'
    })
    $workers = @($nodes | Where-Object {
        $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
    })
    if ($controlPlanes.Count -ne 1 -or $workers.Count -lt 3) {
        throw "The shared lab topology requires one control-plane and at least three workers."
    }
}

Assert-DisposableLabContext

$active = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -eq 0 -and $active) {
    throw "Scenario $active is already active. Reset it before starting another incident."
}
if (Test-Path -LiteralPath $statePath) {
    throw "Builder state already exists at '$statePath'. Resolve or reset it before continuing."
}

$startedAt = [DateTime]::UtcNow.ToString('o')
$builderState = [ordered]@{
    incident = $Incident
    context = $Context
    startedAt = $startedAt
}

if ($Incident -eq "INC-08") {
    $coreDnsRaw = (Invoke-Kubectl -n kube-system get deployment coredns -o json) -join "`n"
    $coreDns = $coreDnsRaw | ConvertFrom-Json
    $builderState["coreDns"] = [ordered]@{
        replicas = $coreDns.spec.replicas
        resources = $coreDns.spec.template.spec.containers[0].resources
    }
}

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$builderState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8

& kubectl --context $Context -n $namespace create configmap scenario-state `
    --from-literal="incident=$Incident" `
    --from-literal="startedAt=$startedAt" `
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
        $nodeJson = (Invoke-Kubectl get nodes -o json) -join "`n"
        $nodes = ($nodeJson | ConvertFrom-Json).items | Where-Object {
            -not $_.spec.unschedulable -and
            $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
        }
        if (@($nodes).Count -lt 3) {
            throw "INC-03 requires three schedulable worker nodes. Recreate the provided kind cluster."
        }
        $target = @($nodes | Where-Object {
            $_.metadata.labels.'training.example.com/tier' -eq 'primary'
        })[0].metadata.name
        if (-not $target) { throw "The primary maintenance target was not found." }
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
        Invoke-Kubectl apply -f (Join-Path $PSScriptRoot "change-505.yaml")
        Invoke-Kubectl -n $namespace annotate deployment/gateway-rollout `
            kubernetes.io/change-cause="Progressive delivery 1.1.0" --overwrite
        Invoke-Kubectl -n $namespace rollout status deployment/gateway-rollout --timeout=3m
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
        Invoke-Kubectl -n $namespace delete job storage-maintenance storage-recovery --ignore-not-found
        Invoke-Kubectl apply -f (Join-Path $PSScriptRoot "change-707.yaml")
        Invoke-Kubectl -n $namespace wait --for=condition=Complete job/storage-maintenance --timeout=2m
    }
    "INC-08" {
        Invoke-Kubectl -n kube-system set resources deployment/coredns -c coredns `
            "--requests=cpu=75m,memory=70Mi" "--limits=cpu=200m,memory=170Mi"
        Invoke-Kubectl -n kube-system annotate deployment/coredns `
            training.example.com/change="Resolver capacity rollout" --overwrite
        Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=3m
        Invoke-Kubectl apply -f (Join-Path $PSScriptRoot "change-818.yaml")
        Invoke-Kubectl -n $namespace rollout status deployment/discovery-probe --timeout=3m
    }
}

$brief = Join-Path $repoRoot "learner\briefs\$Incident.md"
Write-Output "SCENARIO_READY incident=$Incident context=$Context"
Write-Output "Learner brief: $brief"
Write-Output "Use runtime evidence only. Do not share this builder session with the Coach session."
