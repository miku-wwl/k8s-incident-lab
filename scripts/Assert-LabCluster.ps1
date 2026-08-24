[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [switch]$RequireNamespaceMarker,

    [string]$Namespace = "incident-lab"
)

$ErrorActionPreference = "Stop"

if ($Context -notlike "kind-*") {
    throw "The lab is restricted to a disposable kind context; received '$Context'."
}

$knownContext = & kubectl config get-contexts $Context -o name 2>$null
if ($LASTEXITCODE -ne 0 -or $knownContext -ne $Context) {
    throw "Kubernetes context '$Context' does not exist."
}

& kubectl --context $Context cluster-info | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Kubernetes context '$Context' is not reachable."
}

$nodeJson = (& kubectl --context $Context get nodes -o json) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect kind cluster topology."
}
$nodes = ($nodeJson | ConvertFrom-Json).items
$controlPlaneCount = @($nodes | Where-Object {
    $null -ne $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count
$workerCount = @($nodes | Where-Object {
    $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count

if ($controlPlaneCount -ne 1 -or $workerCount -ne 3) {
    throw "The shared lab requires exactly one control-plane and three workers; found $controlPlaneCount control-plane and $workerCount workers."
}

if ($RequireNamespaceMarker) {
    $labId = & kubectl --context $Context get namespace $Namespace `
        -o jsonpath='{.metadata.labels.training\.example\.com/lab-id}'
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect namespace '$Namespace'."
    }
    $disposable = & kubectl --context $Context get namespace $Namespace `
        -o jsonpath='{.metadata.labels.training\.example\.com/disposable}'
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect namespace '$Namespace'."
    }
    if ($labId -ne "k8s-incident-lab" -or $disposable -ne "true") {
        throw "Namespace '$Namespace' is not marked as the disposable incident lab."
    }
}

Write-Verbose "Validated disposable lab context '$Context': 1 control-plane + 3 workers."
