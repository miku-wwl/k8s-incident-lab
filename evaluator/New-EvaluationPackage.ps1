[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [Parameter(Mandatory)]
    [string]$Context,

    [Parameter(Mandatory)]
    [string]$SubmissionPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [switch]$InvestigationClosed
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$repoFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$submissionFull = [IO.Path]::GetFullPath($SubmissionPath)

if (-not $InvestigationClosed) {
    throw "Pass -InvestigationClosed only after the learner submitted RCA and investigation ended."
}
if ($Context -notlike "kind-*") {
    throw "Evaluation lifecycle verification is restricted to a kind context."
}
if (-not (Test-Path -LiteralPath $submissionFull -PathType Leaf)) {
    throw "Learner submission was not found: $submissionFull"
}
if ($outputFull.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Evaluator packages must be generated outside the owner repository."
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Output path already exists: $outputFull"
}

$active = & kubectl --context $Context -n incident-lab get configmap scenario-state `
    -o jsonpath='{.data.incident}' 2>$null
if ($LASTEXITCODE -eq 0 -and $active) {
    throw "Scenario $active is still active. Reset and verify recovery before revealing Ground Truth."
}

$baselineVerifier = Join-Path $repoRoot "scripts\Test-Lab.ps1"
Write-Output "Verifying the recovered customer and platform baseline before Ground Truth reveal..."
& $baselineVerifier -Context $Context
if ($LASTEXITCODE -ne 0) {
    throw "Recovered baseline verification failed; the evaluation package was not created."
}

$rubric = Join-Path $PSScriptRoot "rubrics\$Incident.md"
if (-not (Test-Path -LiteralPath $rubric -PathType Leaf)) {
    throw "Owner rubric was not found for $Incident."
}

New-Item -ItemType Directory -Path $outputFull | Out-Null
Copy-Item -LiteralPath $submissionFull -Destination (Join-Path $outputFull "learner-submission.md")
Copy-Item -LiteralPath (Join-Path $repoRoot "learner\scorecard.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "evaluation-template.md") -Destination $outputFull
Copy-Item -LiteralPath $rubric -Destination (Join-Path $outputFull "ground-truth-rubric.md")

$metadata = [ordered]@{
    incident = $Incident
    context = $Context
    investigationClosed = $true
    generatedAt = [DateTime]::UtcNow.ToString('o')
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputFull "evaluation-metadata.json") -Encoding utf8

Write-Output "EVALUATION_PACKAGE_READY incident=$Incident path=$outputFull"
Write-Output "Ground Truth is now revealed to the Evaluator only."
