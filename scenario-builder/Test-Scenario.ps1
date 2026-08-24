[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [Parameter(Mandatory)]
    [string]$Context,

    [ValidateRange(0, 90)]
    [int]$WarmupSeconds = 30
)

$ErrorActionPreference = "Stop"
$namespace = "incident-lab"

function Get-PrometheusValue([string]$Expression) {
    $encoded = [Uri]::EscapeDataString($Expression)
    $url = "http://localhost:9090/api/v1/query?query=$encoded"
    $raw = & kubectl --context $Context -n lab-observability exec deployment/prometheus -- `
        wget -qO- $url
    if ($LASTEXITCODE -ne 0) { throw "Prometheus query failed: $Expression" }
    $response = ($raw -join "`n") | ConvertFrom-Json
    if ($response.status -ne "success" -or @($response.data.result).Count -eq 0) { return 0.0 }
    return [double]$response.data.result[0].value[1]
}

function Assert-GreaterThan([string]$Name, [double]$Actual, [double]$Threshold) {
    if ($Actual -le $Threshold) {
        throw "$Name was $Actual; expected greater than $Threshold."
    }
    Write-Output "PASS $Name=$Actual"
}

if ($Context -notlike "kind-*") {
    throw "Scenario verification is restricted to a kind context; received '$Context'."
}

$active = & kubectl --context $Context -n $namespace get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -ne 0 -or $active -ne $Incident) {
    throw "Active scenario is '$active', not '$Incident'."
}

if ($WarmupSeconds -gt 0) { Start-Sleep -Seconds $WarmupSeconds }

switch ($Incident) {
    "INC-01" {
        $image = & kubectl --context $Context -n $namespace get deployment/gateway `
            -o jsonpath='{.spec.template.spec.containers[0].image}'
        if ($image -ne "k8s-incident-lab/service:2.0.0") { throw "Release 2.0.0 is not active." }
        $value = Get-PrometheusValue 'sum(rate(lab_http_requests_total{service="gateway",status=~"5.."}[15s]))'
        Assert-GreaterThan "gateway_5xx_per_second" $value 0.2
    }
    "INC-02" {
        $value = Get-PrometheusValue 'sum(rate(lab_http_requests_total{service="gateway",status=~"5.."}[15s]))'
        Assert-GreaterThan "gateway_5xx_per_second" $value 0.2
    }
    "INC-03" {
        $available = & kubectl --context $Context -n $namespace get deployment/gateway `
            -o jsonpath='{.status.availableReplicas}'
        $availableCount = if ($available) { [int]$available } else { 0 }
        if ($availableCount -ge 3) { throw "Gateway still has $availableCount available replicas." }
        $pending = (& kubectl --context $Context -n $namespace get pods `
            -l app.kubernetes.io/name=gateway --field-selector=status.phase=Pending -o name).Count
        Assert-GreaterThan "pending_gateway_pods" $pending 0
    }
    "INC-04" {
        $value = Get-PrometheusValue 'sum(rate(lab_dependency_requests_total{result!="success"}[15s]))'
        Assert-GreaterThan "failed_dependency_calls_per_second" $value 0.2
    }
    "INC-05" {
        $stableReady = & kubectl --context $Context -n $namespace get deployment/gateway `
            -o jsonpath='{.status.readyReplicas}'
        $rolloutReady = & kubectl --context $Context -n $namespace get deployment/gateway-rollout `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$stableReady -lt 3 -or [int]$rolloutReady -lt 2) {
            throw "Gateway workloads are not predominantly healthy."
        }
        Write-Output "PASS gateway_ready_replicas=$stableReady rollout_ready_replicas=$rolloutReady"

        $raw = & kubectl --context $Context -n $namespace get endpointslice `
            -l kubernetes.io/service-name=gateway -o json
        $slices = (($raw -join "`n") | ConvertFrom-Json).items
        $endpoints = @($slices | ForEach-Object { $_.endpoints })
        $readyEndpoints = @($endpoints | Where-Object { $_.conditions.ready -ne $false }).Count
        if ($readyEndpoints -lt 5) { throw "Expected at least five apparently ready gateway endpoints; observed $readyEndpoints." }
        Write-Output "PASS gateway_ready_endpoints=$readyEndpoints"

        $failed = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*gateway.*",result!="200"}[15s]))'
        $succeeded = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*gateway.*",result="200"}[15s]))'
        $catalogSucceeded = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*catalog.*",result="200"}[15s]))'
        Assert-GreaterThan "failed_customer_requests_per_second" $failed 0.2
        Assert-GreaterThan "successful_customer_requests_per_second" $succeeded 0.2
        Assert-GreaterThan "successful_direct_catalog_requests_per_second" $catalogSucceeded 0.2
    }
    "INC-06" {
        $depth = Get-PrometheusValue 'max(lab_queue_depth)'
        $age = Get-PrometheusValue 'max(lab_oldest_message_age_seconds)'
        Assert-GreaterThan "queue_depth" $depth 30
        Assert-GreaterThan "oldest_message_age_seconds" $age 3
        $replicas = & kubectl --context $Context -n $namespace get deployment/worker `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$replicas -ne 2) { throw "Expected two Running workers; observed $replicas." }
        Write-Output "PASS ready_workers=$replicas"
    }
    "INC-07" {
        $ready = & kubectl --context $Context -n $namespace get statefulset/storage `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$ready -ne 1) { throw "Storage StatefulSet is not Ready." }
        Write-Output "PASS storage_ready_replicas=$ready"
        $phase = & kubectl --context $Context -n $namespace get pvc/data-storage-0 `
            -o jsonpath='{.status.phase}'
        if ($phase -ne "Bound") { throw "Storage PVC is not Bound." }
        Write-Output "PASS storage_pvc_phase=$phase"
        $job = & kubectl --context $Context -n $namespace get job/storage-maintenance `
            -o jsonpath='{.status.succeeded}'
        if ([int]$job -ne 1) { throw "The maintenance operation did not complete." }
        Write-Output "PASS storage_maintenance_completed=$job"
        $errors = Get-PrometheusValue 'sum(rate(lab_storage_errors_total{operation="write"}[15s]))'
        $writeFailures = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*storage.*write",result!~"2.."}[15s]))'
        $readSuccess = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*storage.*read",result="200"}[15s]))'
        Assert-GreaterThan "storage_write_errors_per_second" $errors 0.1
        Assert-GreaterThan "failed_storage_writes_per_second" $writeFailures 0.1
        Assert-GreaterThan "successful_storage_reads_per_second" $readSuccess 0.1
    }
    "INC-08" {
        $ready = & kubectl --context $Context -n $namespace get deployment/discovery-probe `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$ready -lt 3) { throw "Discovery probe workload is not Ready." }
        Write-Output "PASS discovery_probe_ready_replicas=$ready"
        $coreDnsReady = & kubectl --context $Context -n kube-system get deployment/coredns `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$coreDnsReady -lt 1) { throw "CoreDNS is not Ready; scenario is too destructive." }
        Write-Output "PASS coredns_ready_replicas=$coreDnsReady"
        $dnsTimeouts = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target="cluster-dns",result="timeout"}[1m]))'
        $dnsP95 = Get-PrometheusValue 'histogram_quantile(0.95,sum by (le) (rate(lab_dns_query_duration_seconds_bucket[1m])))'
        $failedPaths = Get-PrometheusValue 'count(sum by (target) (rate(lab_load_requests_total{target!="cluster-dns",result!~"2.."}[1m])) > 0)'
        $successfulPaths = Get-PrometheusValue 'count(sum by (target) (rate(lab_load_requests_total{target!="cluster-dns",result=~"2.."}[1m])) > 0)'
        Assert-GreaterThan "dns_timeouts_per_second" $dnsTimeouts 1
        Assert-GreaterThan "dns_query_p95_seconds" $dnsP95 0.05
        Assert-GreaterThan "degraded_service_paths" $failedPaths 1
        Assert-GreaterThan "still_successful_service_paths" $successfulPaths 1
    }
}

Write-Output "SCENARIO_REPRODUCTION_PASS incident=$Incident context=$Context"
