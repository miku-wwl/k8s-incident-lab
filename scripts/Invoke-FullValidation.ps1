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
    return ($image -split ':')[-1]
}

function Get-EnvironmentMetadata {
    & (Join-Path $PSScriptRoot "Assert-LabCluster.ps1") `
        -Context $Context -RequireNamespaceMarker

    $kindOutput = & (Join-Path $repoRoot ".tools\kind.exe") version
    if ($LASTEXITCODE -ne 0 -or ($kindOutput -join " ") -notmatch 'kind\s+(v[^\s]+)') {
        throw "Could not determine kind version."
    }
    $kindVersion = $Matches[1]

    $kubectlVersionRaw = (& kubectl --context $Context version -o json) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not determine Kubernetes server version." }
    $kubernetesVersion = ($kubectlVersionRaw | ConvertFrom-Json).serverVersion.gitVersion

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

    $metadata = [ordered]@{
        kind_version = $kindVersion
        kubernetes_version = $kubernetesVersion
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
    }

    $expected = [ordered]@{
        kind_version = $versions.Kind
        kubernetes_version = $versions.Kubernetes
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
    }
}

$gitStatus = @(& git -C $repoRoot status --porcelain)
$summary = [ordered]@{
    schema_version = 1
    generated_at = [DateTime]::UtcNow.ToString('o')
    validation_mode = $Mode
    overall_status = "NOT_RUN"
    repository = [ordered]@{
        branch = (& git -C $repoRoot branch --show-current).Trim()
        commit = (& git -C $repoRoot rev-parse HEAD).Trim()
        working_tree_dirty = ($gitStatus.Count -gt 0)
    }
    environment = $null
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

        $currentStep = "pre_activation_baseline"
        & (Join-Path $PSScriptRoot "Test-Lab.ps1") -Context $Context
        $result.pre_activation_baseline = "PASS"

        $currentStep = "activation"
        & (Join-Path $repoRoot "scenario-builder\Start-Scenario.ps1") `
            -Incident $scenarioId -Context $Context
        $result.activation = "PASS"

        $currentStep = "symptom_validation"
        $effectiveWarmupSeconds = if ($scenarioId -eq "INC-08") {
            [Math]::Max($WarmupSeconds, 60)
        } else {
            $WarmupSeconds
        }
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
