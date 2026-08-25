[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [string]$KubectlPath,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "LabVersions.psd1")
if (-not $KubectlPath) {
    $KubectlPath = & (Join-Path $PSScriptRoot "Use-LabKubectl.ps1")
}

$versionRaw = (& $KubectlPath --context $Context version -o json) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "Could not query kubectl client and Kubernetes server versions for '$Context'."
}
$version = $versionRaw | ConvertFrom-Json
$clientVersion = [string]$version.clientVersion.gitVersion
$serverVersion = [string]$version.serverVersion.gitVersion

if ($clientVersion -ne $versions.Kubectl) {
    throw "The lab requires pinned kubectl $($versions.Kubectl); observed $clientVersion."
}
$clientMatch = [regex]::Match($clientVersion, '^v(?<major>\d+)\.(?<minor>\d+)')
$serverMatch = [regex]::Match($serverVersion, '^v(?<major>\d+)\.(?<minor>\d+)')
if (-not $clientMatch.Success -or -not $serverMatch.Success) {
    throw "Could not parse kubectl/server versions: client=$clientVersion server=$serverVersion."
}

$clientMajor = [int]$clientMatch.Groups['major'].Value
$clientMinor = [int]$clientMatch.Groups['minor'].Value
$serverMajor = [int]$serverMatch.Groups['major'].Value
$serverMinor = [int]$serverMatch.Groups['minor'].Value
$minorSkew = [Math]::Abs($clientMinor - $serverMinor)

if ($clientMajor -ne $serverMajor -or $minorSkew -gt 1) {
    throw "Unsupported kubectl/server version skew: client=$clientVersion server=$serverVersion supported skew is +/-1 minor."
}

$result = [pscustomobject]@{
    kubectl_client_version = $clientVersion
    kubernetes_server_version = $serverVersion
    minor_skew = $minorSkew
}
Write-Verbose "kubectl version skew validated: client=$clientVersion server=$serverVersion skew=$minorSkew."
if ($PassThru) { $result }
