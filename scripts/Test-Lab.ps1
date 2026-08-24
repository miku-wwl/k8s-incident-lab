[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$namespace = "incident-lab"

if ($Context -notlike "kind-*") {
    throw "Baseline verification is restricted to a disposable kind context; received '$Context'."
}
& kubectl --context $Context cluster-info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Kubernetes context '$Context' is not reachable." }

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
    throw "Baseline topology is not one control-plane plus three workers."
}
Write-Output "kind topology: 1 control-plane + 3 workers"

$activeScenario = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -eq 0 -and $activeScenario) {
    throw "Scenario $activeScenario is still active; this is not a baseline state."
}

$podsRaw = & kubectl --context $Context -n $namespace get pods `
    -l app.kubernetes.io/part-of=k8s-incident-lab -o json
if ($LASTEXITCODE -ne 0) { throw "Could not inspect lab pods." }
$pods = (($podsRaw -join "`n") | ConvertFrom-Json).items
$unready = @($pods | Where-Object {
    $_.status.phase -ne "Running" -or
    @($_.status.containerStatuses | Where-Object { -not $_.ready }).Count -gt 0
} | ForEach-Object { $_.metadata.name })
if ($unready.Count -gt 0) {
    throw "Baseline has unready pods: $($unready -join ', ')"
}

$pvcRaw = (& kubectl --context $Context -n $namespace get pvc -o json) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "Could not inspect PVC state." }
$unboundClaims = @(($pvcRaw | ConvertFrom-Json).items | Where-Object {
    $_.status.phase -ne "Bound"
} | ForEach-Object { $_.metadata.name })
if ($unboundClaims.Count -gt 0) {
    throw "Baseline has unbound PVCs: $($unboundClaims -join ', ')"
}
Write-Output "PVCs: all Bound"

$gatewaySlicesRaw = & kubectl --context $Context -n $namespace get endpointslice `
    -l kubernetes.io/service-name=gateway -o json
if ($LASTEXITCODE -ne 0) { throw "Could not inspect gateway EndpointSlices." }
$gatewaySlices = ($gatewaySlicesRaw -join "`n") | ConvertFrom-Json
$gatewayAddresses = @(
    $gatewaySlices.items | ForEach-Object { $_.endpoints.addresses } | Where-Object { $_ }
).Count
if ($gatewayAddresses -lt 1) { throw "Gateway has no viable EndpointSlice addresses." }
Write-Output "gateway endpoints: $gatewayAddresses"

$probe = @'
import time
import urllib.request

checks = [
    ("gateway", "GET", "http://gateway:8080/api"),
    ("catalog", "GET", "http://catalog:8080/data"),
    ("orders", "POST", "http://orders:8080/orders"),
    ("storage", "POST", "http://storage:8080/write"),
    ("storage-read", "GET", "http://storage:8080/read"),
]
for name, method, url in checks:
    consecutive = 0
    last_error = "not attempted"
    for attempt in range(30):
        try:
            request = urllib.request.Request(url, method=method)
            with urllib.request.urlopen(request, timeout=2) as response:
                if response.status >= 300:
                    raise RuntimeError(f"HTTP {response.status}")
                consecutive += 1
                last_error = ""
                if consecutive == 3:
                    print(f"{name}: 3 consecutive HTTP {response.status}")
                    break
        except Exception as exc:
            consecutive = 0
            last_error = f"{type(exc).__name__}: {exc}"
        time.sleep(1)
    if consecutive < 3:
        raise SystemExit(f"{name}: did not stabilize: {last_error}")
'@

& kubectl --context $Context -n $namespace exec deployment/traffic-gateway -- python -c $probe
if ($LASTEXITCODE -ne 0) { throw "Service-path baseline checks failed." }

$dnsProbe = @'
import socket
import time

names = ["gateway", "catalog", "orders", "storage", "redis"]
for name in names:
    durations = []
    for _ in range(5):
        started = time.monotonic()
        socket.getaddrinfo(name, None)
        durations.append((time.monotonic() - started) * 1000)
    print(f"{name}: resolved 5/5, max_ms={max(durations):.1f}")
'@
& kubectl --context $Context -n $namespace exec deployment/traffic-gateway -- python -c $dnsProbe
if ($LASTEXITCODE -ne 0) { throw "DNS baseline checks failed." }

$coreDnsReady = & kubectl --context $Context -n kube-system get deployment/coredns `
    -o jsonpath='{.status.readyReplicas}'
if ($LASTEXITCODE -ne 0 -or [int]$coreDnsReady -lt 2) {
    throw "CoreDNS baseline is not fully Ready."
}
Write-Output "CoreDNS: $coreDnsReady replicas Ready"

$scaledObjectReady = & kubectl --context $Context -n $namespace get scaledobject/worker `
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>$null
if ($LASTEXITCODE -ne 0 -or $scaledObjectReady -ne "True") {
    throw "KEDA worker ScaledObject is not Ready."
}
Write-Output "KEDA worker ScaledObject: Ready"

& kubectl --context $Context -n lab-observability exec deployment/prometheus -- `
    wget -qO- http://localhost:9090/-/ready
if ($LASTEXITCODE -ne 0) { throw "Prometheus is not ready." }

$downTargetCount = -1
foreach ($attempt in 1..12) {
    $downTargetsRaw = & kubectl --context $Context -n lab-observability exec deployment/prometheus -- `
        wget -qO- 'http://localhost:9090/api/v1/query?query=count%28up%20%3D%3D%200%29'
    if ($LASTEXITCODE -ne 0) { throw "Could not query Prometheus target health." }
    $downTargetsResult = (($downTargetsRaw -join "`n") | ConvertFrom-Json).data.result
    $downTargetCount = if (@($downTargetsResult).Count -eq 0) {
        0
    } else {
        [int][double]$downTargetsResult[0].value[1]
    }
    if ($downTargetCount -eq 0) { break }
    if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
}
if ($downTargetCount -ne 0) { throw "Prometheus has $downTargetCount down targets." }
Write-Output "Prometheus targets: all up"

Write-Output "BASELINE_PASS context=$Context"
