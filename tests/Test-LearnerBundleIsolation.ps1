[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [string]$OwnerRepositoryRoot
)

$ErrorActionPreference = "Stop"
$bundleFull = [IO.Path]::GetFullPath($BundlePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
$ownerFull = [IO.Path]::GetFullPath($OwnerRepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$ownerPrefix = $ownerFull + [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath $bundleFull -PathType Container)) {
    throw "Learner bundle directory was not found: $bundleFull"
}
if ($bundleFull -eq $ownerFull -or $bundleFull.StartsWith($ownerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Learner bundle must be outside the Owner repository."
}

$expectedFiles = @(
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

$items = @(Get-ChildItem -LiteralPath $bundleFull -Recurse -Force)
$directories = @($items | Where-Object { $_.PSIsContainer })
if ($directories.Count -ne 0) {
    throw "Learner bundle must be flat; unexpected directories: $($directories.Name -join ', ')"
}

$reparsePoints = @($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
if ($reparsePoints.Count -ne 0) {
    throw "Learner bundle must not contain links or reparse points."
}

$actualFiles = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    [IO.Path]::GetRelativePath($bundleFull, $_.FullName).Replace('\', '/')
}) | Sort-Object

$difference = @(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles)
if ($difference.Count -ne 0) {
    throw "Learner bundle contents differ from the nine-file allowlist: $($difference.InputObject -join ', ')"
}

$forbiddenSegments = @(
    ".git", "apps", "scenario-builder", "evaluator", "rubrics", "ground-truth",
    "solution", "answer", "inject", "builder-only", "owner-only"
)
foreach ($relativePath in $actualFiles) {
    $segments = @($relativePath -split '[/\\]')
    foreach ($segment in $segments) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($segment)
        if ($forbiddenSegments -contains $segment.ToLowerInvariant() -or
            $forbiddenSegments -contains $stem.ToLowerInvariant()) {
            throw "Forbidden structural name in learner bundle: $relativePath"
        }
    }
}

$manifestPath = Join-Path $bundleFull "BUNDLE-CONTENTS.txt"
$manifestFiles = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ }) | Sort-Object
if (@(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $manifestFiles).Count -ne 0) {
    throw "BUNDLE-CONTENTS.txt does not match the learner bundle allowlist."
}

Write-Output "LEARNER_BUNDLE_ISOLATION_PASS path=$bundleFull files=$($actualFiles.Count)"
