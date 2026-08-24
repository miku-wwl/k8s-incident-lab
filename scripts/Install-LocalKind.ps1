[CmdletBinding()]
param(
    [string]$Version
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "LabVersions.psd1")
if (-not $Version) { $Version = $versions.Kind }
$toolsDirectory = Join-Path $repoRoot ".tools"
$kindPath = Join-Path $toolsDirectory "kind.exe"

if (Test-Path -LiteralPath $kindPath) {
    Write-Output $kindPath
    exit 0
}

New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
$baseUrl = "https://github.com/kubernetes-sigs/kind/releases/download/$Version"
$downloadPath = Join-Path $toolsDirectory "kind.exe.download"
$checksumsPath = Join-Path $toolsDirectory "kind-windows-amd64.sha256sum"

try {
    Invoke-WebRequest -Uri "$baseUrl/kind-windows-amd64" -OutFile $downloadPath
    Invoke-WebRequest -Uri "$baseUrl/kind-windows-amd64.sha256sum" -OutFile $checksumsPath
    $checksumLine = Get-Content -LiteralPath $checksumsPath | Select-Object -First 1
    if (-not $checksumLine) {
        throw "The release checksum file did not contain kind-windows-amd64."
    }
    $expected = ($checksumLine -split "\s+")[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "kind checksum verification failed."
    }
    Move-Item -LiteralPath $downloadPath -Destination $kindPath
}
finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumsPath -Force -ErrorAction SilentlyContinue
}

Write-Output $kindPath
