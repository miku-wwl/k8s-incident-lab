[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("INC-01", "INC-02", "INC-03", "INC-04", "INC-05", "INC-06", "INC-07", "INC-08")]
    [string]$Incident,

    [string]$Destination = (Join-Path (Get-Location) "incident-room")
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if (Test-Path -LiteralPath $Destination) {
    throw "Destination already exists: $Destination"
}

New-Item -ItemType Directory -Path $Destination | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "briefs\$Incident.md") `
    -Destination (Join-Path $Destination "incident-brief.md")
foreach ($name in @("timeline.md", "investigation.md", "postmortem.md")) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "templates\$name") `
        -Destination (Join-Path $Destination $name)
}

Write-Output "INCIDENT_ROOM_READY incident=$Incident path=$Destination"
