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
    "INC-07 storage mechanism" = '(storage-maintenance|SQLite.{0,12}(lock|锁)|文件系统.{0,12}(权限|只读)|chmod|chown)'
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
