[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot "Assert-LabCluster.ps1") -Context $Context -RequireNamespaceMarker
$kubectl = (Get-Command kubectl).Source
$workingDirectory = (Get-Location).Path

$grafanaArgs = @("--context", $Context, "-n", "lab-observability", "port-forward", "service/grafana", "3000:3000")
$prometheusArgs = @("--context", $Context, "-n", "lab-observability", "port-forward", "service/prometheus", "9090:9090")

$grafana = Start-Process -FilePath $kubectl -ArgumentList $grafanaArgs -WorkingDirectory $workingDirectory -WindowStyle Hidden -PassThru
$prometheus = Start-Process -FilePath $kubectl -ArgumentList $prometheusArgs -WorkingDirectory $workingDirectory -WindowStyle Hidden -PassThru

Write-Output "Grafana:    http://localhost:3000 (PID $($grafana.Id))"
Write-Output "Prometheus: http://localhost:9090 (PID $($prometheus.Id))"
Write-Output "Stop with: Stop-Process -Id $($grafana.Id),$($prometheus.Id)"
