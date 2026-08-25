[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateRange(10, 480)]
    [int]$DurationMinutes = 240
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$kubectlPath = & (Join-Path $PSScriptRoot "Use-LabKubectl.ps1")
& (Join-Path $PSScriptRoot "Assert-LabCluster.ps1") `
    -Context $Context -RequireNamespaceMarker

& $kubectlPath --context $Context apply `
    -f (Join-Path $repoRoot "platform\addons\learner-access.yaml") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Learner runtime RBAC could not be applied." }

$credentialValue = (& $kubectlPath --context $Context -n incident-lab create token `
    learner-investigator --duration "${DurationMinutes}m") -join ""
if ($LASTEXITCODE -ne 0 -or -not $credentialValue) {
    throw "A short-lived learner credential could not be issued."
}

$sourceRaw = (& $kubectlPath config view --raw -o json) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "The source kubeconfig could not be inspected." }
$source = $sourceRaw | ConvertFrom-Json
$sourceContext = @($source.contexts | Where-Object { $_.name -eq $Context })[0]
if (-not $sourceContext) { throw "Kubernetes context '$Context' was not found in kubeconfig." }
$sourceCluster = @($source.clusters | Where-Object { $_.name -eq $sourceContext.context.cluster })[0]
if (-not $sourceCluster) { throw "Cluster data for '$Context' was not found in kubeconfig." }

$serverUri = [Uri]$sourceCluster.cluster.server
if ($serverUri.Host -in @("127.0.0.1", "localhost", "::1")) {
    $builder = [UriBuilder]$serverUri
    $builder.Host = "host.docker.internal"
    $server = $builder.Uri.AbsoluteUri.TrimEnd('/')
} else {
    $server = $serverUri.AbsoluteUri.TrimEnd('/')
}

$userData = [ordered]@{}
$userData['token'] = $credentialValue
$document = [ordered]@{
    apiVersion = "v1"
    kind = "Config"
    clusters = @([ordered]@{
        name = "learner-cluster"
        cluster = [ordered]@{
            server = $server
            'certificate-authority-data' = $sourceCluster.cluster.'certificate-authority-data'
            'tls-server-name' = "localhost"
        }
    })
    contexts = @([ordered]@{
        name = $Context
        context = [ordered]@{
            cluster = "learner-cluster"
            namespace = "incident-lab"
            user = "learner-investigator"
        }
    })
    'current-context' = $Context
    users = @([ordered]@{
        name = "learner-investigator"
        user = $userData
    })
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFull
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputFull -Encoding utf8
Write-Output $outputFull
