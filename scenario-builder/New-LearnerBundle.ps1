[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$learnerRoot = Join-Path $repoRoot "learner"
$repoFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$outputFull = [IO.Path]::GetFullPath($OutputPath)

if ($outputFull.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Learner bundles must be generated outside the owner repository."
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Output path already exists: $outputFull"
}

New-Item -ItemType Directory -Path $outputFull | Out-Null
Copy-Item -LiteralPath (Join-Path $learnerRoot "briefs\$Incident.md") `
    -Destination (Join-Path $outputFull "incident-brief.md")
Copy-Item -LiteralPath (Join-Path $learnerRoot "templates\timeline.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "templates\investigation.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "templates\postmortem.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "Get-RuntimeEvidence.ps1") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "COACH-PROMPT.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "scorecard.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $learnerRoot "BUNDLE-README.md") `
    -Destination (Join-Path $outputFull "README.md")

$contents = @(
    "BUNDLE-CONTENTS.txt",
    "COACH-PROMPT.md",
    "Get-RuntimeEvidence.ps1",
    "incident-brief.md",
    "investigation.md",
    "postmortem.md",
    "README.md",
    "scorecard.md",
    "timeline.md"
) | Sort-Object
$contents | Set-Content -LiteralPath (Join-Path $outputFull "BUNDLE-CONTENTS.txt") -Encoding utf8

& (Join-Path $repoRoot "tests\Test-LearnerBundleIsolation.ps1") `
    -BundlePath $outputFull -OwnerRepositoryRoot $repoRoot

Write-Output "LEARNER_BUNDLE_READY incident=$Incident path=$outputFull"
Write-Output "The bundle excludes source, Builder scripts, evaluator rubrics and ground truth."
Write-Output "Start the Coach through scripts\Start-CoachSandbox.ps1; a host process is not filesystem-isolated."
