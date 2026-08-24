[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $failures.Add($Message)
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Add-Failure "kubectl is required for Kustomize rendering."
} else {
    foreach ($path in @("platform\base", "platform\observability")) {
        & kubectl kustomize (Join-Path $repoRoot $path) | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-Failure "Kustomize rendering failed: $path" }
    }
    $scenarioManifests = Get-ChildItem -LiteralPath (Join-Path $repoRoot "scenario-builder") `
        -Filter "change-*.yaml" -File
    foreach ($manifest in $scenarioManifests) {
        & kubectl apply --dry-run=client -f $manifest.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-Failure "Scenario manifest dry-run failed: $($manifest.Name)" }
    }
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Add-Failure "python is required for application syntax validation."
} else {
    & python -m py_compile (Join-Path $repoRoot "apps\lab-service\app.py")
    if ($LASTEXITCODE -ne 0) { Add-Failure "Python syntax validation failed." }
}

$powerShellFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.tools[\\/]' }
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        Add-Failure "$($file.FullName): $($parseError.Message)"
    }
}

foreach ($incidentNumber in 1..8) {
    $incident = "INC-{0:d2}" -f $incidentNumber
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "learner\briefs\$incident.md"))) {
        Add-Failure "Missing learner brief for $incident."
    }
}
foreach ($template in @("timeline.md", "investigation.md", "postmortem.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "learner\templates\$template"))) {
        Add-Failure "Missing learner template: $template"
    }
}
foreach ($learnerFile in @("COACH-PROMPT.md", "BUNDLE-README.md", "scorecard.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "learner\$learnerFile"))) {
        Add-Failure "Missing learner boundary file: $learnerFile"
    }
}

$unsafePublicNames = Get-ChildItem -LiteralPath (Join-Path $repoRoot "learner") -Recurse -File |
    Where-Object { $_.Name -match '(broken|fault|inject|solution|answer|root.?cause)' }
foreach ($file in $unsafePublicNames) {
    Add-Failure "Learner-visible filename is not neutral: $($file.FullName)"
}

$publicFiles = @(
    Get-Item -LiteralPath (Join-Path $repoRoot "README.md")
    Get-ChildItem -LiteralPath (Join-Path $repoRoot "docs") -Recurse -File
    Get-ChildItem -LiteralPath (Join-Path $repoRoot "learner") -Recurse -File
)
$spoilerPatterns = [ordered]@{
    "INC-05 listener/routing mechanism" = '(gateway-rollout|端口.{0,12}不一致|selector mismatch|选择器不匹配|零个端点|EndpointSlice 地址数为零)'
    "INC-07 storage mechanism" = '(storage-maintenance|SQLite.{0,12}(lock|锁)|文件系统.{0,12}(写权限|变为只读|只读挂载)|chmod|chown)'
    "INC-08 resolver mechanism" = '(discovery-probe|Resolver capacity rollout|CoreDNS.{0,12}(配置错误|CPU|限流)|SERVFAIL|查询放大)'
    "scenario answer language" = '(intentionally broken|expected fix|incident cause)'
}
foreach ($file in $publicFiles) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($entry in $spoilerPatterns.GetEnumerator()) {
        if ($content -match $entry.Value) {
            Add-Failure "Learner-visible spoiler ($($entry.Key)): $($file.FullName)"
        }
    }
}

$kindConfig = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "platform\cluster\kind-config.yaml")
$controlPlaneCount = [regex]::Matches($kindConfig, '(?m)^\s*- role: control-plane\s*$').Count
$workerCount = [regex]::Matches($kindConfig, '(?m)^\s*- role: worker\s*$').Count
if ($controlPlaneCount -ne 1 -or $workerCount -ne 3) {
    Add-Failure "kind topology must contain one control-plane and three workers."
}

$topologyGuard = Join-Path $repoRoot "scripts\Assert-LabCluster.ps1"
if (-not (Test-Path -LiteralPath $topologyGuard -PathType Leaf)) {
    Add-Failure "Missing shared kind topology guard."
} else {
    $guardContent = Get-Content -Raw -LiteralPath $topologyGuard
    if ($guardContent -notmatch '\$controlPlaneCount\s+-ne\s+1' -or
        $guardContent -notmatch '\$workerCount\s+-ne\s+3') {
        Add-Failure "Shared topology guard must require exactly one control-plane and three workers."
    }
}

$guardedWorkflows = @(
    "scripts\Start-Lab.ps1",
    "scripts\Test-Lab.ps1",
    "scripts\Open-Dashboards.ps1",
    "scenario-builder\Start-Scenario.ps1",
    "scenario-builder\Reset-Scenario.ps1",
    "scenario-builder\Test-Scenario.ps1",
    "scripts\Invoke-FullValidation.ps1"
)
foreach ($relativePath in $guardedWorkflows) {
    $workflowPath = Join-Path $repoRoot $relativePath
    $workflowContent = Get-Content -Raw -LiteralPath $workflowPath
    if ($workflowContent -notmatch 'Assert-LabCluster\.ps1') {
        Add-Failure "Cluster workflow does not use the shared exact-topology guard: $relativePath"
    }
}
$scenarioStartContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scenario-builder\Start-Scenario.ps1")
if ($scenarioStartContent -match 'workers\.Count\s+-lt\s+3|at least three workers|至少三个工作节点') {
    Add-Failure "Scenario start still accepts more than the exact three-worker topology."
}

$versionFile = Join-Path $repoRoot "scripts\LabVersions.psd1"
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    Add-Failure "Missing validated runtime version manifest."
} else {
    $versions = Import-PowerShellDataFile $versionFile
    foreach ($key in @("Kind", "Kubernetes", "MetricsServerChart", "MetricsServerApp", "KedaChart", "KedaApp", "Prometheus", "Grafana", "KubeStateMetrics", "Python")) {
        if (-not $versions[$key]) { Add-Failure "Missing pinned version value: $key" }
    }
    $startLabContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts\Start-Lab.ps1")
    if ($startLabContent -notmatch '--version\s+\$MetricsServerChartVersion') {
        Add-Failure "metrics-server Helm install is not explicitly version-pinned."
    }
    if ($startLabContent -notmatch '--version\s+\$KedaChartVersion') {
        Add-Failure "KEDA Helm install is not explicitly version-pinned."
    }
}

$scorecardPath = Join-Path $repoRoot "learner\scorecard.md"
if (Test-Path -LiteralPath $scorecardPath) {
    $scorecardLines = Get-Content -LiteralPath $scorecardPath |
        Where-Object { $_ -match '^\|.+\|\s*\d+\s*\|' -and $_ -notmatch '总分' }
    $scoreTotal = 0
    foreach ($line in $scorecardLines) {
        if ($line -match '^\|[^|]+\|\s*(\d+)\s*\|') { $scoreTotal += [int]$Matches[1] }
    }
    if ($scoreTotal -ne 100) { Add-Failure "Incident scorecard weights total $scoreTotal, not 100." }
}

foreach ($incidentNumber in 1..8) {
    $incident = "INC-{0:d2}" -f $incidentNumber
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "evaluator\rubrics\$incident.md"))) {
        Add-Failure "Missing owner-only evaluator rubric for $incident."
    }
}
foreach ($evaluatorFile in @("README.md", "evaluation-template.md", "New-EvaluationPackage.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "evaluator\$evaluatorFile"))) {
        Add-Failure "Missing evaluator control-plane file: $evaluatorFile"
    }
}

$boundaryScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scenario-builder\New-LearnerBundle.ps1")
foreach ($forbiddenCopy in @("apps", "platform", "scenario-builder", "evaluator", ".git")) {
    if ($boundaryScript -match "Copy-Item[^`n]+$([regex]::Escape($forbiddenCopy))") {
        Add-Failure "Learner bundle script may copy owner-only material: $forbiddenCopy"
    }
}
if ($boundaryScript -notmatch 'Test-LearnerBundleIsolation\.ps1') {
    Add-Failure "Learner bundle generator does not enforce the structural isolation test."
}

$bundleTestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("k8s-incident-lab-bundle-test-{0}" -f [guid]::NewGuid().ToString("N"))
try {
    & (Join-Path $repoRoot "scenario-builder\New-LearnerBundle.ps1") `
        -Incident INC-01 -OutputPath $bundleTestRoot | Out-Null
    & (Join-Path $repoRoot "tests\Test-LearnerBundleIsolation.ps1") `
        -BundlePath $bundleTestRoot -OwnerRepositoryRoot $repoRoot | Out-Null
}
catch {
    Add-Failure "Dynamic learner bundle isolation validation failed: $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $bundleTestRoot) {
        $resolvedBundleTest = (Resolve-Path -LiteralPath $bundleTestRoot).Path
        $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedBundleTest.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Add-Failure "Refused to clean bundle test path outside the system temporary directory."
        } else {
            Remove-Item -LiteralPath $resolvedBundleTest -Recurse -Force
        }
    }
}

$schemaPath = Join-Path $repoRoot "evidence\validation-summary.schema.json"
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    Add-Failure "Missing validation evidence schema."
} else {
    try { $null = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json }
    catch { Add-Failure "Validation evidence schema is not valid JSON." }
}

$evidencePath = Join-Path $repoRoot "evidence\validation-summary.json"
if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    try {
        if (-not (Test-Json -LiteralPath $evidencePath -SchemaFile $schemaPath -ErrorAction Stop)) {
            Add-Failure "Validation evidence does not conform to its JSON schema."
        }
        $evidenceRaw = Get-Content -Raw -LiteralPath $evidencePath
        $evidence = $evidenceRaw | ConvertFrom-Json
        $requiredEvidenceFields = @(
            "schema_version", "generated_at", "validation_mode", "overall_status", "repository",
            "environment", "repository_checks", "baseline", "scenarios", "final_recovery"
        )
        foreach ($field in $requiredEvidenceFields) {
            if ($evidence.PSObject.Properties.Name -notcontains $field) {
                Add-Failure "Validation evidence is missing field: $field"
            }
        }
        if ($evidence.schema_version -ne 1) { Add-Failure "Validation evidence schema_version must be 1." }
        if ($evidence.environment.control_plane_nodes -ne 1 -or $evidence.environment.worker_nodes -ne 3) {
            Add-Failure "Validation evidence topology must be exactly 1+3."
        }
        $scenarioNames = @($evidence.scenarios.PSObject.Properties.Name | Sort-Object)
        $expectedScenarioNames = @(1..8 | ForEach-Object { "INC-{0:d2}" -f $_ })
        if (@(Compare-Object $expectedScenarioNames $scenarioNames).Count -ne 0) {
            Add-Failure "Validation evidence must contain exactly INC-01 through INC-08."
        }
        $allowedStatuses = @("PASS", "FAIL", "NOT_RUN")
        foreach ($scenarioName in $scenarioNames) {
            $scenarioResult = $evidence.scenarios.$scenarioName
            foreach ($field in @("pre_activation_baseline", "activation", "symptom_validation", "runtime_evidence", "reset", "recovery")) {
                if ($allowedStatuses -notcontains $scenarioResult.$field) {
                    Add-Failure "Invalid evidence status for $scenarioName/$field."
                }
            }
        }
        $evidenceSpoilers = @(
            'selector mismatch', 'SQLite lock', 'CoreDNS.{0,12}(CPU|限流|配置错误)',
            '文件系统.{0,12}(权限|只读)', 'expected solution', 'root cause'
        )
        foreach ($pattern in $evidenceSpoilers) {
            if ($evidenceRaw -match $pattern) {
                Add-Failure "Validation evidence contains scenario-answer material."
            }
        }
    }
    catch {
        Add-Failure "Validation evidence is not structurally valid JSON: $($_.Exception.Message)"
    }
}

$applicationSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "apps\lab-service\app.py")
if ($applicationSource -match 'INCIDENT_MODE') {
    Add-Failure "Application contains forbidden INCIDENT_MODE fault switching."
}

$secretPattern = '(?i)(api[_-]?key|client[_-]?secret|private[_-]?key|password\s*[:=]|token\s*[:=]|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY)'
$secretFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]\.tools[\\/]' -and
        $_.Extension -notin @('.pyc', '.png', '.jpg', '.gif')
    }
foreach ($file in $secretFiles) {
    if ((Get-Content -Raw -LiteralPath $file.FullName) -match $secretPattern) {
        Add-Failure "Potential sensitive value pattern found: $($file.FullName)"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "REPOSITORY_VALIDATION_FAIL count=$($failures.Count)"
}

Write-Output "REPOSITORY_VALIDATION_PASS"
