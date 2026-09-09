param(
    [switch]$Capture,
    [switch]$PromptForCredential
)

# Run with powershell.exe -NoProfile -File so this preference stays inside the
# child process. Use -NonInteractive only when a credential prompt is not needed.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $workspace 'artifacts'
$runId = [Guid]::NewGuid().ToString('N')
$stagePath = Join-Path $artifacts ("terminal-exec-stages-$runId.json")
$lockPath = Join-Path $artifacts 'rx-baseline-once-f2c39652.json'
$builder = Join-Path $PSScriptRoot 'New-RxDiagnosticBundle.ps1'
$runner = Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1'
$encoding = [Text.UTF8Encoding]::new($false)
$temporaryCredential = $false
$state = [ordered]@{
    run_id = $runId
    process_id = $PID
    powershell_version = $PSVersionTable.PSVersion.ToString()
    capture_requested = [bool]$Capture
    stage = 'local_started'
    utc = [DateTime]::UtcNow.ToString('o')
}

function Write-Stage([string]$Name) {
    $state.stage = $Name
    $state.utc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json -Depth 3), $encoding)
    Write-Output ("ExecutionStage=" + $Name)
}

New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
Write-Stage 'local_started'
try {
    # Presence only: the credential is never written to either state file.
    $state.credential_present = Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD
    $processes = [Diagnostics.Process]::GetProcessesByName('plink')
    $state.existing_plink_processes = $processes.Length
    foreach ($process in $processes) { $process.Dispose() }
    $state.existing_capture_guard = [IO.File]::Exists($lockPath)
    $state.prior_baseline_bundles = @(
        [IO.Directory]::GetFiles($artifacts, 'rx-baseline-bundle-*.sh')
    ).Count
    $state.prior_baseline_results = @(
        [IO.Directory]::GetFiles($artifacts, 'rx-bounded-baseline-*.txt')
    ).Count
    foreach ($path in @($builder, $runner)) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -ne 0) {
            throw 'A required PowerShell helper failed syntax validation.'
        }
    }
    Write-Stage 'local_checks_complete'
    if (-not $Capture) {
        Write-Output ($state | ConvertTo-Json -Depth 3)
        return
    }
    if ($state.existing_plink_processes -ne 0) {
        throw 'An existing SSH process must be assessed before starting the baseline.'
    }
    if ($state.existing_capture_guard -or $state.prior_baseline_results -ne 0 -or
        $state.prior_baseline_bundles -ne 0) {
        throw 'Prior baseline state exists; inspect it before any new capture.'
    }
    if (-not $state.credential_present) {
        if (-not $PromptForCredential) {
            throw 'The process-only router credential is unavailable; SSH was not started.'
        }
        Write-Stage 'awaiting_secure_credential'
        $credential = Get-Credential -UserName root `
            -Message 'Router root@192.168.1.1: one pinned-SSH, read-only USB baseline. Do not enter this password in chat.'
        if ($null -eq $credential -or $credential.Password.Length -eq 0) {
            throw 'Credential input was cancelled or empty; SSH was not started.'
        }
        try {
            # Assign in this process before invoking SSH; never pass a password
            # literal/argument, serialize it, or print the credential object.
            $env:ZBT_DIAG_PASSWORD = $credential.GetNetworkCredential().Password
            $temporaryCredential = $true
        }
        finally {
            $credential.Password.Dispose()
            $credential = $null
        }
        $state.credential_present = Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD
        Write-Stage 'credential_ready'
    }

    # Keep this guard even after failure: an interrupted capture is not retried
    # automatically. FileMode.CreateNew also prevents concurrent dispatch.
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes(($state | ConvertTo-Json -Depth 3))
        $lock.Write($bytes, 0, $bytes.Length)
    }
    finally { $lock.Dispose() }

    $baseline = Join-Path $artifacts ("rx-baseline-bundle-$runId.sh")
    $recorder = Join-Path $artifacts ("rx-recorder-prepared-$runId.sh")
    & $builder -Mode Baseline -OutputPath $baseline | Out-Null
    & $builder -Mode Recorder -OutputPath $recorder | Out-Null
    $state.baseline_bundle = $baseline
    $state.recorder_bundle = $recorder
    Write-Stage 'bundles_prepared'

    foreach ($name in @('router-rx-common.sh', 'router-rx-baseline.sh')) {
        & $runner -ScriptPath (Join-Path $PSScriptRoot $name) `
            -ArtifactName ($name.Replace('.sh', '') + '-syntax') `
            -TimeoutSeconds 15 -SyntaxOnly
    }
    Write-Stage 'syntax_checks_complete'

    # Checking only existing evidence directories does not query modem state.
    # This guard executes immediately before the already-bounded baseline body.
    $body = [IO.File]::ReadAllText($baseline)
    $guard = @'
for prior in /root/cellular-rx-baseline-*; do
    [ ! -d "$prior" ] || {
        printf 'baseline_refused=prior_remote_capture_exists\n'
        exit 27
    }
done
'@
    $entry = "`nrx_defaults`nrx_baseline`n"
    if (-not $body.Contains($entry)) {
        throw 'Expected baseline entry point was not found; SSH capture was not started.'
    }
    $body = $body.Replace($entry, "`n" + $guard.Replace("`r", '') + $entry)
    [IO.File]::WriteAllText($baseline, $body, $encoding)
    Write-Stage 'capture_dispatched'
    & $runner -ScriptPath $baseline -ArtifactName rx-bounded-baseline -TimeoutSeconds 85
    Write-Stage 'capture_complete'
}
catch {
    $state.failure_type = $_.Exception.GetType().FullName
    Write-Stage 'stopped'
    throw
}
finally {
    if ($temporaryCredential) {
        [Environment]::SetEnvironmentVariable('ZBT_DIAG_PASSWORD', $null, 'Process')
        $state.credential_present = $false
        $state.temporary_credential_cleared = $true
        [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json -Depth 3), $encoding)
    }
    Write-Output ("ExecutionStageArtifact=" + $stagePath)
}
