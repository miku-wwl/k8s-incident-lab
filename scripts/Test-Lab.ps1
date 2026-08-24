[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$namespace = "incident-lab"

& kubectl --context $Context cluster-info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Kubernetes context '$Context' is not reachable." }

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
]
for name, method, url in checks:
    consecutive = 0
    last_error = "not attempted"
    for attempt in range(12):
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
        time.sleep(0.5)
    if consecutive < 3:
        raise SystemExit(f"{name}: did not stabilize: {last_error}")
'@

& kubectl --context $Context -n $namespace exec deployment/traffic-gateway -- python -c $probe
if ($LASTEXITCODE -ne 0) { throw "Service-path baseline checks failed." }

& kubectl --context $Context -n lab-observability exec deployment/prometheus -- `
    wget -qO- http://localhost:9090/-/ready
if ($LASTEXITCODE -ne 0) { throw "Prometheus is not ready." }

$downTargetsRaw = & kubectl --context $Context -n lab-observability exec deployment/prometheus -- `
    wget -qO- 'http://localhost:9090/api/v1/query?query=count%28up%20%3D%3D%200%29'
if ($LASTEXITCODE -ne 0) { throw "Could not query Prometheus target health." }
$downTargetsResult = (($downTargetsRaw -join "`n") | ConvertFrom-Json).data.result
$downTargetCount = if (@($downTargetsResult).Count -eq 0) {
    0
} else {
    [int][double]$downTargetsResult[0].value[1]
}
if ($downTargetCount -ne 0) { throw "Prometheus has $downTargetCount down targets." }
Write-Output "Prometheus targets: all up"

Write-Output "BASELINE_PASS context=$Context"
