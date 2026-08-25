[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [string]$KubeconfigPath,

    [Parameter(Mandatory)]
    [string]$Image,

    [string[]]$ContainerCommand = @("pwsh", "-NoLogo", "-NoProfile"),

    [string]$ContainerName,

    [switch]$Detach,

    [switch]$Interactive,

    [switch]$AutoRemove
)

$bundleFull = [IO.Path]::GetFullPath($BundlePath)
$kubeconfigFull = [IO.Path]::GetFullPath($KubeconfigPath)
if (-not (Test-Path -LiteralPath $bundleFull -PathType Container)) {
    throw "Learner bundle was not found: $bundleFull"
}
if (-not (Test-Path -LiteralPath $kubeconfigFull -PathType Leaf)) {
    throw "Sanitized kubeconfig was not found."
}

$arguments = @("run")
if ($AutoRemove) { $arguments += "--rm" }
if ($Detach) { $arguments += "--detach" }
if ($Interactive) { $arguments += @("--interactive", "--tty") }
if ($ContainerName) { $arguments += @("--name", $ContainerName) }
$arguments += @(
    "--cap-drop", "ALL",
    "--security-opt", "no-new-privileges",
    "--read-only",
    "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
    "--user", "10001:10001",
    "--workdir", "/workspace",
    "--env", "HOME=/tmp",
    "--env", "KUBECONFIG=/run/learner/kubeconfig",
    "--mount", "type=bind,source=$bundleFull,target=/workspace",
    "--mount", "type=bind,source=$kubeconfigFull,target=/run/learner/kubeconfig,readonly",
    $Image
)
$arguments += $ContainerCommand
$arguments
