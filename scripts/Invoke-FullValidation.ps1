[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [ValidateSet("BaselineOnly", "SingleScenario", "FullMatrix")]
    [string]$Mode = "FullMatrix",

    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [ValidateRange(0, 90)]
    [int]$WarmupSeconds = 30,

    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "LabVersions.psd1")
$scenarioIds = @("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")
$currentIncident = $null
$currentStep = "initialization"
$scenarioStopwatch = $null

if ($Mode -eq "SingleScenario" -and -not $Incident) {
    throw "-Incident is required when -Mode SingleScenario is used."
}
if ($Mode -ne "SingleScenario" -and $Incident) {
    throw "-Incident is only valid with -Mode SingleScenario."
}

$defaultName = switch ($Mode) {
    "BaselineOnly" { "validation-baseline.json" }
    "SingleScenario" { "validation-$Incident.json" }
    "FullMatrix" { "validation-summary.json" }
}
if (-not $OutputPath) {
    $OutputPath = Join-Path (Join-Path $repoRoot "evidence") $defaultName
}
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFull

function Write-EvidenceAtomic([object]$Document, [string]$Path) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString("N"))
    try {
        $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-DeploymentImageVersion([string]$Namespace, [string]$Deployment) {
    $image = & kubectl --context $Context -n $Namespace get "deployment/$Deployment" `
        -o jsonpath='{.spec.template.spec.containers[0].image}'
    if ($LASTEXITCODE -ne 0 -or -not $image) {
        throw "Could not determine image version for $Namespace/$Deployment."
    }
    $taggedReference = ($image -split '@')[0]
    return ($taggedReference -split ':')[-1]
}

function Get-WorkloadImage([string]$Namespace, [string]$Resource) {
    $image = & kubectl --context $Context -n $Namespace get $Resource `
        -o jsonpath='{.spec.template.spec.containers[0].image}'
    if ($LASTEXITCODE -ne 0 -or -not $image) {
        throw "Could not determine runtime image for $Namespace/$Resource."
    }
    return [string]$image
}

function Get-ExecutionEnvironment {
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $dockerInfoRaw = (& docker info --format '{{json .}}') -join "`n"
    $dockerVersionRaw = (& docker version --format '{{json .Server}}') -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $dockerInfoRaw -or -not $dockerVersionRaw) {
        throw "Docker execution envelope could not be determined."
    }
    $dockerInfo = $dockerInfoRaw | ConvertFrom-Json
    $dockerVersion = $dockerVersionRaw | ConvertFrom-Json

    return [ordered]@{
        host = [ordered]@{
            logical_cpu_count = [int]$computerSystem.NumberOfLogicalProcessors
            memory_gb = [Math]::Round([double]$computerSystem.TotalPhysicalMemory / 1GB, 2)
        }
        container_runtime = [ordered]@{
            name = "docker"
            version = [string]$dockerVersion.Version
            platform = [string]$dockerVersion.Platform.Name
            allocated_cpu = [int]$dockerInfo.NCPU
            allocated_memory_gb = [Math]::Round([double]$dockerInfo.MemTotal / 1GB, 2)
        }
    }
}

function Get-EnvironmentMetadata {
    & (Join-Path $PSScriptRoot "Assert-LabCluster.ps1") `
        -Context $Context -RequireNamespaceMarker

    $kindOutput = & (Join-Path $repoRoot ".tools\kind.exe") version
    if ($LASTEXITCODE -ne 0 -or ($kindOutput -join " ") -notmatch 'kind\s+(v[^\s]+)') {
        throw "Could not determine kind version."
    }
    $kindVersion = $Matches[1]

    $versionSkew = & (Join-Path $PSScriptRoot "Assert-KubectlVersionSkew.ps1") `
        -Context $Context -PassThru

    $nodeJson = ((& kubectl --context $Context get nodes -o json) -join "`n") | ConvertFrom-Json
    $controlPlaneCount = @($nodeJson.items | Where-Object {
        $null -ne $_.metadata.labels.'node-role.kubernetes.io/control-plane'
    }).Count
    $workerCount = @($nodeJson.items | Where-Object {
        $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
    }).Count

    $helmRaw = (& helm list -A --kube-context $Context -o json) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect Helm releases." }
    $helmReleases = @($helmRaw | ConvertFrom-Json)
    $keda = @($helmReleases | Where-Object { $_.name -eq "keda" })[0]
    $metricsServer = @($helmReleases | Where-Object { $_.name -eq "metrics-server" })[0]
    if (-not $keda -or -not $metricsServer) { throw "Pinned Helm releases are not installed." }

    $kedaChart = $keda.chart -replace '^keda-', ''
    $metricsServerChart = $metricsServer.chart -replace '^metrics-server-', ''
    $pythonOutput = (& kubectl --context $Context -n incident-lab exec deployment/gateway -- python --version) -join " "
    if ($LASTEXITCODE -ne 0 -or $pythonOutput -notmatch 'Python\s+([^\s]+)') {
        throw "Could not determine application Python version."
    }
    $pythonVersion = $Matches[1]

    $clusterName = $Context -replace '^kind-', ''
    $nodeImageId = (& docker inspect "$clusterName-control-plane" --format '{{.Image}}') -join ""
    $nodeRepoDigestsRaw = (& docker image inspect $nodeImageId --format '{{json .RepoDigests}}') -join ""
    if ($LASTEXITCODE -ne 0 -or -not $nodeRepoDigestsRaw) {
        throw "Could not determine the running kind node image digest."
    }
    $nodeRepoDigests = @($nodeRepoDigestsRaw | ConvertFrom-Json)
    $expectedNodeRepoDigest = "kindest/node@$($versions.KindNodeImageDigest)"
    if ($nodeRepoDigests -notcontains $expectedNodeRepoDigest) {
        throw "kind node digest mismatch: expected $expectedNodeRepoDigest."
    }

    $expectedImages = [ordered]@{
        runtime_inspector = "python:$($versions.Python)-slim@$($versions.PythonBaseDigest)"
        storage_inspector = "redis:$($versions.Redis)@$($versions.RedisDigest)"
        redis = "redis:$($versions.Redis)@$($versions.RedisDigest)"
        prometheus = "prom/prometheus:$($versions.Prometheus)@$($versions.PrometheusDigest)"
        grafana = "grafana/grafana:$($versions.Grafana)@$($versions.GrafanaDigest)"
        kube_state_metrics = "registry.k8s.io/kube-state-metrics/kube-state-metrics:$($versions.KubeStateMetrics)@$($versions.KubeStateMetricsDigest)"
        metrics_server = "registry.k8s.io/metrics-server/metrics-server:v$($versions.MetricsServerApp)@$($versions.MetricsServerDigest)"
        keda_operator = "ghcr.io/kedacore/keda:$($versions.KedaApp)@$($versions.KedaOperatorDigest)"
        keda_metrics_api = "ghcr.io/kedacore/keda-metrics-apiserver:$($versions.KedaApp)@$($versions.KedaMetricsDigest)"
        keda_webhooks = "ghcr.io/kedacore/keda-admission-webhooks:$($versions.KedaApp)@$($versions.KedaWebhooksDigest)"
    }
    $runtimeImages = [ordered]@{
        kind_node = "$($versions.KindNodeImage)@$($versions.KindNodeImageDigest)"
        runtime_inspector = Get-WorkloadImage "incident-lab" "statefulset/runtime-inspector"
        storage_inspector = Get-WorkloadImage "incident-lab" "statefulset/storage-inspector"
        redis = Get-WorkloadImage "incident-lab" "statefulset/redis"
        prometheus = Get-WorkloadImage "lab-observability" "deployment/prometheus"
        grafana = Get-WorkloadImage "lab-observability" "deployment/grafana"
        kube_state_metrics = Get-WorkloadImage "lab-observability" "deployment/kube-state-metrics"
        metrics_server = Get-WorkloadImage "kube-system" "deployment/metrics-server"
        keda_operator = Get-WorkloadImage "keda" "deployment/keda-operator"
        keda_metrics_api = Get-WorkloadImage "keda" "deployment/keda-operator-metrics-apiserver"
        keda_webhooks = Get-WorkloadImage "keda" "deployment/keda-admission-webhooks"
    }
    foreach ($key in $expectedImages.Keys) {
        if ($runtimeImages[$key] -ne $expectedImages[$key]) {
            throw "Runtime image mismatch for ${key}: expected $($expectedImages[$key]), observed $($runtimeImages[$key])."
        }
    }

    $metadata = [ordered]@{
        kind_version = $kindVersion
        kubectl_client_version = $versionSkew.kubectl_client_version
        kubernetes_server_version = $versionSkew.kubernetes_server_version
        kubectl_server_minor_skew = $versionSkew.minor_skew
        control_plane_nodes = $controlPlaneCount
        worker_nodes = $workerCount
        keda_chart_version = $kedaChart
        keda_app_version = $keda.app_version
        metrics_server_chart_version = $metricsServerChart
        metrics_server_app_version = $metricsServer.app_version
        prometheus_version = Get-DeploymentImageVersion "lab-observability" "prometheus"
        grafana_version = Get-DeploymentImageVersion "lab-observability" "grafana"
        kube_state_metrics_version = Get-DeploymentImageVersion "lab-observability" "kube-state-metrics"
        python_version = $pythonVersion
        runtime_images = $runtimeImages
    }

    $expected = [ordered]@{
        kind_version = $versions.Kind
        kubectl_client_version = $versions.Kubectl
        kubernetes_server_version = $versions.Kubernetes
        keda_chart_version = $versions.KedaChart
        keda_app_version = $versions.KedaApp
        metrics_server_chart_version = $versions.MetricsServerChart
        metrics_server_app_version = $versions.MetricsServerApp
        prometheus_version = $versions.Prometheus
        grafana_version = $versions.Grafana
        kube_state_metrics_version = $versions.KubeStateMetrics
        python_version = $versions.Python
    }
    foreach ($key in $expected.Keys) {
        if ([string]$metadata[$key] -ne [string]$expected[$key]) {
            throw "Runtime version mismatch for ${key}: expected $($expected[$key]), observed $($metadata[$key])."
        }
    }
    return $metadata
}

$scenarioResults = [ordered]@{}
foreach ($scenarioId in $scenarioIds) {
    $scenarioResults[$scenarioId] = [ordered]@{
        pre_activation_baseline = "NOT_RUN"
        activation = "NOT_RUN"
        symptom_validation = "NOT_RUN"
        runtime_evidence = "NOT_RUN"
        reset = "NOT_RUN"
        recovery = "NOT_RUN"
        warmup_seconds = $null
        duration_seconds = $null
    }
}

$gitStatus = @(& git -C $repoRoot status --porcelain)
$summary = [ordered]@{
    schema_version = 2
    generated_at = [DateTime]::UtcNow.ToString('o')
    validation_mode = $Mode
    overall_status = "NOT_RUN"
    repository = [ordered]@{
        branch = (& git -C $repoRoot branch --show-current).Trim()
        commit = (& git -C $repoRoot rev-parse HEAD).Trim()
        working_tree_dirty = ($gitStatus.Count -gt 0)
    }
    environment = $null
    execution_environment = $null
    repository_checks = [ordered]@{ status = "NOT_RUN" }
    baseline = [ordered]@{ status = "NOT_RUN" }
    scenarios = $scenarioResults
    final_recovery = [ordered]@{ status = "NOT_RUN" }
}

$evidenceAreas = @{
    "INC-01" = "changes"
    "INC-02" = "capacity"
    "INC-03" = "changes"
    "INC-04" = "service-path"
    "INC-05" = "service-path"
    "INC-06" = "queue"
    "INC-07" = "storage"
    "INC-08" = "dns"
}

try {
    $currentStep = "environment_metadata"
    $summary.environment = Get-EnvironmentMetadata
    $summary.execution_environment = Get-ExecutionEnvironment

    $currentStep = "repository_checks"
    & (Join-Path $repoRoot "tests\Validate-Repository.ps1")
    $summary.repository_checks.status = "PASS"

    $currentStep = "baseline"
    & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
    $summary.baseline.status = "PASS"

    $selectedScenarios = switch ($Mode) {
        "BaselineOnly" { @() }
        "SingleScenario" { @($Incident) }
        "FullMatrix" { $scenarioIds }
    }

    foreach ($scenarioId in $selectedScenarios) {
        $currentIncident = $scenarioId
        $result = $summary.scenarios[$scenarioId]
        $scenarioStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $effectiveWarmupSeconds = if ($scenarioId -eq "INC-08") {
            [Math]::Max($WarmupSeconds, 60)
        } else {
            $WarmupSeconds
        }
        $result.warmup_seconds = $effectiveWarmupSeconds

        $currentStep = "pre_activation_baseline"
        & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
        $result.pre_activation_baseline = "PASS"

        $currentStep = "activation"
        & (Join-Path $repoRoot "scenario-builder\Start-Scenario.ps1") `
            -Incident $scenarioId -Context $Context
        $result.activation = "PASS"

        $currentStep = "symptom_validation"
        & (Join-Path $repoRoot "scenario-builder\Test-Scenario.ps1") `
            -Incident $scenarioId -Context $Context -WarmupSeconds $effectiveWarmupSeconds
        $result.symptom_validation = "PASS"

        $currentStep = "runtime_evidence"
        $runtimeEvidenceOutput = @(& (Join-Path $repoRoot "learner\Get-RuntimeEvidence.ps1") `
            -Context $Context -Area $evidenceAreas[$scenarioId])
        if ($runtimeEvidenceOutput.Count -eq 0) {
            throw "Runtime evidence helper returned no evidence for $scenarioId."
        }
        Write-Output "RUNTIME_EVIDENCE_PASS incident=$scenarioId area=$($evidenceAreas[$scenarioId]) lines=$($runtimeEvidenceOutput.Count)"
        $result.runtime_evidence = "PASS"

        $currentStep = "reset"
        & (Join-Path $repoRoot "scenario-builder\Reset-Scenario.ps1") -Context $Context
        $result.reset = "PASS"

        $currentStep = "recovery"
        & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
        $result.recovery = "PASS"
        $scenarioStopwatch.Stop()
        $result.duration_seconds = [Math]::Round($scenarioStopwatch.Elapsed.TotalSeconds, 2)
        $scenarioStopwatch = $null
    }

    $currentIncident = $null
    $currentStep = "final_recovery"
    & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
    $summary.final_recovery.status = "PASS"
    $summary.overall_status = "PASS"
    $summary.generated_at = [DateTime]::UtcNow.ToString('o')

    Write-EvidenceAtomic $summary $outputFull
    Write-Output "VALIDATION_EVIDENCE_PASS mode=$Mode path=$outputFull"
}
catch {
    $originalError = $_
    if ($scenarioStopwatch -and $scenarioStopwatch.IsRunning -and $currentIncident) {
        $scenarioStopwatch.Stop()
        $summary.scenarios[$currentIncident].duration_seconds = [Math]::Round($scenarioStopwatch.Elapsed.TotalSeconds, 2)
    }
    $summary.overall_status = "FAIL"
    $summary.generated_at = [DateTime]::UtcNow.ToString('o')
    if ($currentIncident -and $summary.scenarios[$currentIncident][$currentStep] -eq "NOT_RUN") {
        $summary.scenarios[$currentIncident][$currentStep] = "FAIL"
    } elseif (-not $currentIncident -and $summary.Contains($currentStep) -and
        $summary[$currentStep] -is [System.Collections.IDictionary]) {
        $summary[$currentStep].status = "FAIL"
    }
    $summary["failure"] = [ordered]@{
        incident = $currentIncident
        step = $currentStep
        message = "Validation command failed; inspect Owner console logs."
    }

    $active = & kubectl --context $Context -n incident-lab get configmap scenario-state `
        -o jsonpath='{.data.incident}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $active) {
        try {
            & (Join-Path $repoRoot "scenario-builder\Reset-Scenario.ps1") -Context $Context
            & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
        }
        catch {
            Write-Warning "Automatic recovery after validation failure did not complete."
        }
    }

    $failureName = "validation-failed-{0}.json" -f ([DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"))
    $failurePath = Join-Path $outputDirectory $failureName
    Write-EvidenceAtomic $summary $failurePath
    Write-Error "Validation failed at step '$currentStep'. Failure evidence: $failurePath. $($originalError.Exception.Message)"
    throw $originalError
}
