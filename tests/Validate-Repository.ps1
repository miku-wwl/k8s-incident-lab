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

$unsafePublicNames = Get-ChildItem -LiteralPath (Join-Path $repoRoot "learner") -Recurse -File |
    Where-Object { $_.Name -match '(broken|fault|inject|solution|answer|root.?cause)' }
foreach ($file in $unsafePublicNames) {
    Add-Failure "Learner-visible filename is not neutral: $($file.FullName)"
}

$applicationSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "apps\lab-service\app.py")
if ($applicationSource -match 'INCIDENT_MODE') {
    Add-Failure "Application contains forbidden INCIDENT_MODE fault switching."
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "REPOSITORY_VALIDATION_FAIL count=$($failures.Count)"
}

Write-Output "REPOSITORY_VALIDATION_PASS"
