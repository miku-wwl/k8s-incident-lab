[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$namespace = "incident-lab"
$safeContext = $Context -replace '[^A-Za-z0-9_.-]', '_'
$statePath = Join-Path (Join-Path $repoRoot ".scenario-state") "$safeContext.json"

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
}

Assert-DisposableLabContext

$incident = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $incident) {
    throw "No active scenario state was found in context '$Context'."
}

$builderState = $null
if (Test-Path -LiteralPath $statePath) {
    $builderState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($builderState.incident -ne $incident -or $builderState.context -ne $Context) {
        throw "Builder state does not match the active cluster scenario."
    }
} elseif ($incident -eq "INC-08") {
    throw "INC-08 reset requires the private Builder state at '$statePath'."
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
    Invoke-Kubectl -n $namespace delete deployment gateway-rollout --ignore-not-found
}

if ($incident -eq "INC-07") {
    Invoke-Kubectl -n $namespace delete job storage-maintenance storage-recovery --ignore-not-found
    Invoke-Kubectl apply -f (Join-Path $PSScriptRoot "change-707-reset.yaml")
    Invoke-Kubectl -n $namespace wait --for=condition=Complete job/storage-recovery --timeout=2m
    Invoke-Kubectl -n $namespace delete job storage-recovery --ignore-not-found
}

if ($incident -eq "INC-08") {
    Invoke-Kubectl -n $namespace delete deployment discovery-probe --ignore-not-found
    $resourcePatch = @(
        [ordered]@{
            op = "replace"
            path = "/spec/template/spec/containers/0/resources"
            value = $builderState.coreDns.resources
        }
    ) | ConvertTo-Json -Depth 20 -Compress -AsArray
    Invoke-Kubectl -n kube-system patch deployment coredns --type json --patch $resourcePatch
    Invoke-Kubectl -n kube-system scale deployment/coredns --replicas=$($builderState.coreDns.replicas)
    & kubectl --context $Context -n kube-system annotate deployment/coredns `
        training.example.com/change- 2>$null | Out-Null
    Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=3m
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

if (Test-Path -LiteralPath $statePath) {
    Remove-Item -LiteralPath $statePath -Force
}

Write-Output "SCENARIO_RESET incident=$incident context=$Context"
Write-Output "Run .\scripts\Test-Lab.ps1 -Context '$Context' to establish fresh recovery evidence."
