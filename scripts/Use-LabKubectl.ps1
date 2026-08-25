$labKubectlPath = & (Join-Path $PSScriptRoot "Install-LocalKubectl.ps1")
if (-not $labKubectlPath) { throw "The pinned kubectl executable was not resolved." }

$labToolsDirectory = Split-Path -Parent $labKubectlPath
$pathEntries = @($env:PATH -split [IO.Path]::PathSeparator)
if ($pathEntries.Count -eq 0 -or
    -not $pathEntries[0].Equals($labToolsDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    $env:PATH = $labToolsDirectory + [IO.Path]::PathSeparator + $env:PATH
}

$labKubectlPath
