[CmdletBinding()]
param(
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

$incident = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $incident) {
    throw "No active scenario state was found in context '$Context'."
}

if ($incident -eq "INC-03") {
    $targets = & kubectl --context $Context get nodes `
        -l training.example.com/tier=primary -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    foreach ($target in @($targets)) {
        if ($target) { Invoke-Kubectl uncordon $target }
    }
    $removePlacement = '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
    Invoke-Kubectl -n $namespace patch deployment gateway --type merge --patch $removePlacement
}

if ($incident -eq "INC-05") {
    $selectorPatch = '[{"op":"replace","path":"/spec/selector","value":{"app.kubernetes.io/name":"gateway"}}]'
    Invoke-Kubectl -n $namespace patch service gateway --type json --patch $selectorPatch
}

if ($incident -eq "INC-08") {
    Invoke-Kubectl -n $namespace delete deployment dns-client --ignore-not-found
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
    if ($corefile.Contains($dnsRuleBlock)) {
        $updatedCorefile = $corefile.Replace($dnsRuleBlock, "")
        $configPatch = @{ data = @{ Corefile = $updatedCorefile } } | ConvertTo-Json -Compress
        Invoke-Kubectl -n kube-system patch configmap coredns --type merge --patch $configPatch
        Invoke-Kubectl -n kube-system rollout restart deployment/coredns
        Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=3m
    }
    & kubectl --context $Context -n kube-system annotate configmap/coredns `
        training.example.com/change- --overwrite 2>$null | Out-Null
}

Invoke-Kubectl apply -k (Join-Path $repoRoot "platform\base")
if (& kubectl --context $Context get crd scaledobjects.keda.sh --ignore-not-found -o name) {
    Invoke-Kubectl apply -f (Join-Path $repoRoot "platform\addons\queue-scaling.yaml")
}

if ($incident -eq "INC-06") {
    Invoke-Kubectl -n $namespace exec statefulset/redis '--' redis-cli DEL orders | Out-Null
}

Invoke-Kubectl -n $namespace wait --for=condition=Available deployment --all --timeout=5m
$deployments = & kubectl --context $Context -n $namespace get deployment `
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
foreach ($deployment in @($deployments)) {
    if ($deployment) {
        Invoke-Kubectl -n $namespace rollout status "deployment/$deployment" --timeout=3m
    }
}
Invoke-Kubectl -n $namespace rollout status statefulset/storage --timeout=3m
Invoke-Kubectl -n $namespace delete configmap scenario-state

Write-Output "SCENARIO_RESET incident=$incident context=$Context"
Write-Output "Run .\scripts\Test-Lab.ps1 -Context '$Context' to establish fresh recovery evidence."
