[CmdletBinding()]
param(
    [string]$Context,
    [switch]$CreateKindCluster,
    [switch]$SkipBuild,
    [switch]$SkipAddons
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$namespace = "incident-lab"
$clusterName = "incident-lab"

foreach ($command in @("docker", "kubectl", "helm")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

if ($CreateKindCluster) {
    $kindPath = & (Join-Path $PSScriptRoot "Install-LocalKind.ps1")
    $existing = & $kindPath get clusters
    if ($existing -notcontains $clusterName) {
        & $kindPath create cluster --name $clusterName --config (Join-Path $repoRoot "platform\cluster\kind-config.yaml")
        if ($LASTEXITCODE -ne 0) { throw "kind cluster creation failed." }
    }
    $Context = "kind-$clusterName"
}

if (-not $Context) {
    throw "Pass -Context explicitly, or use -CreateKindCluster for the disposable local cluster."
}

& kubectl --context $Context cluster-info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Kubernetes context '$Context' is not reachable." }

if ($Context -notlike "kind-*") {
    throw "This lab is restricted to disposable kind contexts; received '$Context'."
}
$nodeJson = (& kubectl --context $Context get nodes -o json) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "Could not inspect kind cluster topology." }
$nodes = ($nodeJson | ConvertFrom-Json).items
$controlPlaneCount = @($nodes | Where-Object {
    $null -ne $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count
$workerCount = @($nodes | Where-Object {
    $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count
if ($controlPlaneCount -ne 1 -or $workerCount -ne 3) {
    throw "Expected one control-plane and three workers; found $controlPlaneCount control-plane and $workerCount workers. Recreate the disposable kind cluster."
}

if (-not $SkipBuild) {
    foreach ($release in @("1.0.0", "1.1.0", "2.0.0")) {
        & docker build --build-arg "APP_RELEASE=$release" --tag "k8s-incident-lab/service:$release" (Join-Path $repoRoot "apps\lab-service")
        if ($LASTEXITCODE -ne 0) { throw "Image build failed for release $release." }
    }

    if ($Context -eq "kind-$clusterName") {
        $kindPath = Join-Path $repoRoot ".tools\kind.exe"
        foreach ($release in @("1.0.0", "1.1.0", "2.0.0")) {
            & $kindPath load docker-image "k8s-incident-lab/service:$release" --name $clusterName
            if ($LASTEXITCODE -ne 0) { throw "Loading release $release into kind failed." }
        }
    }
}

if (-not $SkipAddons) {
    & helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update | Out-Null
    & helm repo add kedacore https://kedacore.github.io/charts --force-update | Out-Null
    & helm repo update | Out-Null
    & helm upgrade --install metrics-server metrics-server/metrics-server `
        --kube-context $Context --namespace kube-system `
        --values (Join-Path $repoRoot "platform\addons\metrics-server-values.yaml") `
        --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "metrics-server installation failed." }
    & helm upgrade --install keda kedacore/keda `
        --kube-context $Context --namespace keda --create-namespace `
        --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "KEDA installation failed." }
}

& kubectl --context $Context apply -k (Join-Path $repoRoot "platform\base")
if ($LASTEXITCODE -ne 0) { throw "Base platform apply failed." }
& kubectl --context $Context apply -k (Join-Path $repoRoot "platform\observability")
if ($LASTEXITCODE -ne 0) { throw "Observability apply failed." }

if (& kubectl --context $Context get crd scaledobjects.keda.sh --ignore-not-found -o name) {
    & kubectl --context $Context apply -f (Join-Path $repoRoot "platform\addons\queue-scaling.yaml")
    if ($LASTEXITCODE -ne 0) { throw "Queue autoscaling apply failed." }
} elseif (-not $SkipAddons) {
    throw "KEDA CRDs were not available after installation."
} else {
    Write-Warning "KEDA is absent; INC-06 will be unavailable until queue-scaling.yaml can be applied."
}

& kubectl --context $Context -n $namespace wait --for=condition=Available deployment --all --timeout=5m
if ($LASTEXITCODE -ne 0) { throw "Not all deployments became Available." }
& kubectl --context $Context -n $namespace rollout status statefulset/redis --timeout=3m
if ($LASTEXITCODE -ne 0) { throw "Redis did not become ready." }
& kubectl --context $Context -n $namespace rollout status statefulset/storage --timeout=3m
if ($LASTEXITCODE -ne 0) { throw "Storage did not become ready." }
& kubectl --context $Context -n lab-observability wait --for=condition=Available deployment --all --timeout=5m
if ($LASTEXITCODE -ne 0) { throw "Observability did not become ready." }

Write-Output "LAB_READY context=$Context namespace=$namespace"
Write-Output "Run .\scripts\Test-Lab.ps1 -Context '$Context' before starting a scenario."
