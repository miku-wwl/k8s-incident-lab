[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [string]$Image = "k8s-incident-lab/coach-sandbox:local"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$ownerFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("k8s-incident-lab-process-isolation-{0}" -f [guid]::NewGuid().ToString("N"))
$bundlePath = Join-Path $temporaryRoot "learner-bundle"
$credentialDirectory = Join-Path $temporaryRoot "runtime"
$kubeconfigPath = Join-Path $credentialDirectory "kubeconfig.json"
$containerName = "incident-lab-coach-test-{0}" -f [guid]::NewGuid().ToString("N").Substring(0, 12)
$containerCreated = $false

function Invoke-DockerChecked([string[]]$DockerArguments, [string]$FailureMessage) {
    $output = @(& docker @DockerArguments)
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
    return $output
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    & (Join-Path $repoRoot "scenario-builder\New-LearnerBundle.ps1") `
        -Incident INC-01 -OutputPath $bundlePath | Out-Null
    & (Join-Path $repoRoot "tests\Test-LearnerBundleIsolation.ps1") `
        -BundlePath $bundlePath -OwnerRepositoryRoot $repoRoot | Out-Null
    Write-Output "PASS bundle_isolation"

    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-DockerChecked @("build", "--tag", $Image, (Join-Path $repoRoot "platform\coach")) `
            "The isolated Coach image could not be built." | Out-Null
    }

    $null = & (Join-Path $repoRoot "scripts\New-LearnerKubeconfig.ps1") `
        -Context $Context -OutputPath $kubeconfigPath -DurationMinutes 30

    $runArguments = @(& (Join-Path $repoRoot "scripts\Get-CoachDockerArguments.ps1") `
        -BundlePath $bundlePath `
        -KubeconfigPath $kubeconfigPath `
        -Image $Image `
        -ContainerCommand @("pwsh", "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 300") `
        -ContainerName $containerName `
        -Detach)
    Invoke-DockerChecked $runArguments "The isolated Coach test process could not start." | Out-Null
    $containerCreated = $true

    $inspect = ((Invoke-DockerChecked @("inspect", $containerName) `
        "The isolated Coach test process could not be inspected.") -join "`n" | ConvertFrom-Json)[0]
    $bindMounts = @($inspect.Mounts | Where-Object { $_.Type -eq "bind" })
    if ($bindMounts.Count -ne 2) { throw "Coach process must have exactly two bind mounts." }
    foreach ($mount in $bindMounts) {
        $sourceFull = [IO.Path]::GetFullPath([string]$mount.Source)
        if ($sourceFull -eq $ownerFull -or
            $sourceFull.StartsWith($ownerFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Owner repository is mounted into the Coach process."
        }
    }
    if (@($bindMounts.Destination | Sort-Object) -join ',' -ne '/run/learner/kubeconfig,/workspace') {
        throw "Coach process bind mounts differ from the workspace/kubeconfig allowlist."
    }
    if (-not $inspect.HostConfig.ReadonlyRootfs -or
        $inspect.HostConfig.CapDrop -notcontains "ALL" -or
        @($inspect.HostConfig.SecurityOpt | Where-Object { $_ -like "no-new-privileges*" }).Count -ne 1 -or
        $inspect.Config.WorkingDir -ne "/workspace" -or
        $inspect.Config.User -ne "10001:10001") {
        throw "Coach process hardening settings are incomplete."
    }
    Write-Output "PASS owner_repository_root_inaccessible"

    $readCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "if (-not (Test-Path -LiteralPath '/workspace/incident-brief.md') -or -not (Test-Path -LiteralPath '/workspace/README.md')) { exit 11 }"
    )
    Invoke-DockerChecked $readCommand "Learner brief or runbook was not readable." | Out-Null
    Write-Output "PASS learner_brief_readable"
    Write-Output "PASS learner_runbook_readable"

    Invoke-DockerChecked @("exec", $containerName, "kubectl", "--context", $Context, "-n", "incident-lab", "get", "pods", "-o", "name") `
        "kubectl get pods failed inside the Coach boundary." | Out-Null
    Write-Output "PASS kubectl_get_pods"
    Invoke-DockerChecked @("exec", $containerName, "kubectl", "--context", $Context, "-n", "incident-lab", "logs", "deployment/gateway", "--tail=1") `
        "kubectl logs failed inside the Coach boundary." | Out-Null
    Write-Output "PASS kubectl_logs"
    Invoke-DockerChecked @("exec", $containerName, "kubectl", "--context", $Context, "-n", "incident-lab", "describe", "deployment/gateway") `
        "kubectl describe failed inside the Coach boundary." | Out-Null
    Write-Output "PASS kubectl_describe"

    $evidenceCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-File",
        "/workspace/Get-RuntimeEvidence.ps1", "-Context", $Context, "-Area", "summary"
    )
    Invoke-DockerChecked $evidenceCommand "The learner runtime evidence helper failed inside the Coach boundary." | Out-Null
    Write-Output "PASS learner_runtime_evidence"
    foreach ($area in @("storage", "dns")) {
        $areaCommand = @(
            "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-File",
            "/workspace/Get-RuntimeEvidence.ps1", "-Context", $Context, "-Area", $area
        )
        Invoke-DockerChecked $areaCommand "Learner runtime evidence area '$area' failed inside the Coach boundary." | Out-Null
    }
    Write-Output "PASS restricted_diagnostic_exec"

    $deniedCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "`$forbidden=@('/owner-repository','/workspace/.git','/workspace/apps','/workspace/scenario-builder','/workspace/evaluator','/workspace/rubrics','/workspace/ground-truth','/workspace/solution','/workspace/answer'); if (`$forbidden | Where-Object { Test-Path -LiteralPath `$_ }) { exit 12 }"
    )
    Invoke-DockerChecked $deniedCommand "Owner-only material is visible inside the Coach boundary." | Out-Null
    foreach ($label in @("git", "scenario_builder", "evaluator", "apps_source", "ground_truth", "solution_answer_rubric")) {
        Write-Output "PASS ${label}_inaccessible"
    }

    & docker exec $containerName kubectl --context $Context -n incident-lab `
        exec deployment/gateway -- true *> $null
    if ($LASTEXITCODE -eq 0) { throw "Learner credential can exec into an application container." }
    Write-Output "PASS application_container_exec_denied"
    & docker exec $containerName kubectl --context $Context -n lab-observability `
        exec deployment/prometheus -- true *> $null
    if ($LASTEXITCODE -eq 0) { throw "Learner credential can exec into the Prometheus container." }
    Write-Output "PASS prometheus_container_exec_denied"

    $secretAccess = (@(& docker exec $containerName kubectl --context $Context `
        auth can-i get secrets -n incident-lab 2>$null)) -join ""
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Kubernetes authorization could not be checked." }
    if ($secretAccess.Trim() -ne "no") { throw "Learner credential can read Kubernetes Secrets." }
    Write-Output "PASS kubernetes_secrets_denied"
    Write-Output "COACH_PROCESS_ISOLATION_PASS"
}
finally {
    if ($containerCreated) {
        & docker rm --force $containerName *> $null
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($resolvedTemporary.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}
