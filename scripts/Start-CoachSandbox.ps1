[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [string]$Context,

    [string]$Image = "k8s-incident-lab/coach-sandbox:local",

    [string[]]$ContainerCommand = @("pwsh", "-NoLogo", "-NoProfile"),

    [switch]$Interactive
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$bundleFull = [IO.Path]::GetFullPath($BundlePath)

& (Join-Path $repoRoot "tests\Test-LearnerBundleIsolation.ps1") `
    -BundlePath $bundleFull -OwnerRepositoryRoot $repoRoot | Out-Null
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the isolated Coach boundary."
}

& docker build --tag $Image (Join-Path $repoRoot "platform\coach")
if ($LASTEXITCODE -ne 0) { throw "The isolated Coach image could not be built." }
$imageId = ((& docker image inspect --format '{{.Id}}' $Image) -join "").Trim()
if ($LASTEXITCODE -ne 0 -or $imageId -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "The immutable Coach image ID could not be resolved."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("k8s-incident-lab-coach-{0}" -f [guid]::NewGuid().ToString("N"))
$kubeconfigPath = Join-Path $temporaryRoot "kubeconfig.json"

try {
    $null = & (Join-Path $PSScriptRoot "New-LearnerKubeconfig.ps1") `
        -Context $Context -OutputPath $kubeconfigPath

    $arguments = @(& (Join-Path $PSScriptRoot "Get-CoachDockerArguments.ps1") `
        -BundlePath $bundleFull `
        -KubeconfigPath $kubeconfigPath `
        -Image $imageId `
        -ContainerCommand $ContainerCommand `
        -Interactive:$Interactive `
        -AutoRemove)
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "The isolated Coach process exited unsuccessfully." }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($resolvedTemporary.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}
