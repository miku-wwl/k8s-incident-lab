[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [string]$Image = "k8s-incident-lab/coach-sandbox:local"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $repoRoot "scripts\LabVersions.psd1")
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

    Invoke-DockerChecked @("build", "--tag", $Image, (Join-Path $repoRoot "platform\coach")) `
        "The isolated Coach image could not be built." | Out-Null
    $imageId = ((Invoke-DockerChecked @("image", "inspect", "--format", "{{.Id}}", $Image) `
        "The immutable Coach image ID could not be resolved.") -join "").Trim()
    if ($imageId -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "The Coach image ID is not an immutable SHA-256 identity."
    }
    Write-Output "coach_image_id = $imageId"

    $null = & (Join-Path $repoRoot "scripts\New-LearnerKubeconfig.ps1") `
        -Context $Context -OutputPath $kubeconfigPath -DurationMinutes 30

    $runArguments = @(& (Join-Path $repoRoot "scripts\Get-CoachDockerArguments.ps1") `
        -BundlePath $bundlePath `
        -KubeconfigPath $kubeconfigPath `
        -Image $imageId `
        -ContainerCommand @("pwsh", "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 300") `
        -ContainerName $containerName `
        -Detach)
    Invoke-DockerChecked $runArguments "The isolated Coach test process could not start." | Out-Null
    $containerCreated = $true

    $inspect = ((Invoke-DockerChecked @("inspect", $containerName) `
        "The isolated Coach test process could not be inspected.") -join "`n" | ConvertFrom-Json)[0]
    if ([string]$inspect.Image -ne $imageId) {
        throw "Coach process did not start from the freshly built immutable image ID."
    }
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
    foreach ($destination in @('/workspace', '/run/learner/kubeconfig')) {
        $mount = @($bindMounts | Where-Object { $_.Destination -eq $destination })[0]
        if (-not $mount -or $mount.RW) {
            throw "Coach bind mount '$destination' is not read-only."
        }
    }
    if (@($inspect.Mounts | Where-Object { $_.Destination -eq '/var/run/docker.sock' }).Count -ne 0) {
        throw "Docker socket is mounted inside the Coach process."
    }
    if (-not $inspect.HostConfig.ReadonlyRootfs -or
        $inspect.HostConfig.CapDrop -notcontains "ALL" -or
        @($inspect.HostConfig.SecurityOpt | Where-Object { $_ -like "no-new-privileges*" }).Count -ne 1 -or
        $inspect.Config.WorkingDir -ne "/workspace" -or
        $inspect.Config.User -ne "10001:10001") {
        throw "Coach process hardening settings are incomplete."
    }
    Write-Output "PASS immutable_image_identity"
    Write-Output "PASS non_root_uid_configured"
    Write-Output "PASS root_filesystem_readonly"
    Write-Output "PASS workspace_mount_readonly"
    Write-Output "PASS kubeconfig_mount_readonly"
    Write-Output "PASS owner_repository_root_inaccessible"

    $readCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "if (-not (Test-Path -LiteralPath '/workspace/incident-brief.md') -or -not (Test-Path -LiteralPath '/workspace/README.md')) { exit 11 }"
    )
    Invoke-DockerChecked $readCommand "Learner brief or runbook was not readable." | Out-Null
    Write-Output "PASS learner_brief_readable"
    Write-Output "PASS learner_runbook_readable"

    $workspaceWriteCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "`$path='/workspace/should-not-write'; try { [IO.File]::WriteAllText(`$path,'denied'); exit 21 } catch { if (Test-Path -LiteralPath `$path) { exit 22 }; exit 0 }"
    )
    Invoke-DockerChecked $workspaceWriteCommand "Learner Bundle write was not denied." | Out-Null
    Write-Output "PASS workspace_write_denied"

    $kubeconfigWriteCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "`$path='/run/learner/kubeconfig'; try { [IO.File]::AppendAllText(`$path,'denied'); exit 23 } catch { exit 0 }"
    )
    Invoke-DockerChecked $kubeconfigWriteCommand "Sanitized kubeconfig write was not denied." | Out-Null
    Write-Output "PASS kubeconfig_write_denied"

    $temporaryWriteCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "`$path='/tmp/coach-write-test'; [IO.File]::WriteAllText(`$path,'allowed'); if ([IO.File]::ReadAllText(`$path) -ne 'allowed') { exit 24 }; Remove-Item -LiteralPath `$path"
    )
    Invoke-DockerChecked $temporaryWriteCommand "Coach /tmp was not writable." | Out-Null
    Write-Output "PASS tmp_writable"

    $dockerSocketCommand = @(
        "exec", $containerName, "pwsh", "-NoLogo", "-NoProfile", "-Command",
        "if (Test-Path -LiteralPath '/var/run/docker.sock') { exit 25 }"
    )
    Invoke-DockerChecked $dockerSocketCommand "Docker socket is accessible inside the Coach boundary." | Out-Null
    Write-Output "PASS docker_socket_absent"

    $kubectlVersionCommand = @(
        "exec", $containerName, "kubectl", "version", "--client", "-o", "json"
    )
    $kubectlVersionRaw = (Invoke-DockerChecked $kubectlVersionCommand `
        "kubectl client version could not be inspected inside the Coach boundary.") -join "`n"
    $kubectlVersion = ($kubectlVersionRaw | ConvertFrom-Json).clientVersion.gitVersion
    if ($kubectlVersion -ne $versions.Kubectl) {
        throw "Coach kubectl is $kubectlVersion; expected $($versions.Kubectl)."
    }
    Write-Output "PASS kubectl_client_version=$kubectlVersion"

    $runtimeUid = ((Invoke-DockerChecked @("exec", $containerName, "id", "-u") `
        "Coach runtime UID could not be inspected.") -join "").Trim()
    if ($runtimeUid -ne "10001") { throw "Coach runtime UID is $runtimeUid, not 10001." }
    Write-Output "PASS non_root_uid=$runtimeUid"

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
