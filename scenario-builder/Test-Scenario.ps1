[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [Parameter(Mandatory)]
    [string]$Context,

    [ValidateRange(0, 60)]
    [int]$WarmupSeconds = 25
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
        $raw = & kubectl --context $Context -n $namespace get endpointslice `
            -l kubernetes.io/service-name=gateway -o json
        $slices = ($raw -join "`n") | ConvertFrom-Json
        $addresses = @($slices.items | ForEach-Object { $_.endpoints.addresses } | Where-Object { $_ }).Count
        if ($addresses -ne 0) { throw "Gateway still has $addresses endpoint addresses." }
        Write-Output "PASS gateway_endpoint_addresses=0"
        $value = Get-PrometheusValue 'sum(rate(lab_load_requests_total{target=~".*gateway.*",result!="200"}[15s]))'
        Assert-GreaterThan "failed_customer_requests_per_second" $value 0.2
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
        $value = Get-PrometheusValue 'sum(rate(lab_storage_errors_total[15s]))'
        Assert-GreaterThan "storage_errors_per_second" $value 0.1
    }
    "INC-08" {
        $ready = & kubectl --context $Context -n $namespace get deployment/dns-client `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$ready -lt 1) { throw "DNS client workload is not Running." }
        Write-Output "PASS dns_client_ready_replicas=$ready"
        $coreDnsReady = & kubectl --context $Context -n kube-system get deployment/coredns `
            -o jsonpath='{.status.readyReplicas}'
        if ([int]$coreDnsReady -lt 1) { throw "CoreDNS is not Ready; scenario is too destructive." }
        Write-Output "PASS coredns_ready_replicas=$coreDnsReady"
        $value = Get-PrometheusValue 'count(sum by (target) (rate(lab_load_requests_total{target!="cluster-dns",result!~"2.."}[15s])) > 0)'
        Assert-GreaterThan "failed_service_paths" $value 2
    }
}

Write-Output "SCENARIO_REPRODUCTION_PASS incident=$Incident context=$Context"
