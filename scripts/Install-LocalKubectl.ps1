[CmdletBinding()]
param(
    [string]$Version
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "LabVersions.psd1")
if (-not $Version) { $Version = $versions.Kubectl }
if ($Version -ne $versions.Kubectl) {
    throw "kubectl must use the repository-pinned version $($versions.Kubectl)."
}

$toolsDirectory = Join-Path $repoRoot ".tools"
$kubectlPath = Join-Path $toolsDirectory "kubectl.exe"

if (Test-Path -LiteralPath $kubectlPath -PathType Leaf) {
    $installedRaw = (& $kubectlPath version --client -o json) -join "`n"
    if ($LASTEXITCODE -eq 0 -and
        ($installedRaw | ConvertFrom-Json).clientVersion.gitVersion -eq $Version) {
        Write-Output $kubectlPath
        exit 0
    }
}

New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
$downloadPath = Join-Path $toolsDirectory "kubectl.exe.download"
$baseUrl = "https://dl.k8s.io/release/$Version/bin/windows/amd64"

try {
    Invoke-WebRequest -Uri "$baseUrl/kubectl.exe" -OutFile $downloadPath
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
    if ($actual -ne $versions.KubectlWindowsSha256) {
        throw "kubectl checksum verification failed for $Version."
    }
    Move-Item -LiteralPath $downloadPath -Destination $kubectlPath -Force
}
finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
}

Write-Output $kubectlPath
