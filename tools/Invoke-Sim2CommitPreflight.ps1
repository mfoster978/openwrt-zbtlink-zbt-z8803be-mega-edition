$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$id = [Guid]::NewGuid().ToString('N')
$stagePath = Join-Path $root "artifacts\sim2-commit-preflight-stage-$id.json"
$bundlePath = Join-Path $root "artifacts\sim2-commit-preflight-bundle-$id.sh"
$encoding = [Text.UTF8Encoding]::new($false)
$temporary = $false
$state = [ordered]@{ stage = 'local_started' }
function Save-Stage([string]$name) {
    $state.stage = $name
    $state.utc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json), $encoding)
    Write-Output "PreflightStage=$name"
}
try {
    $body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sim2-commit-preflight.sh')).Replace("`r", '')
    $marker = "SIM2_PREFLIGHT_$id"
    $bundle = "#!/bin/sh`ntimeout -s TERM -k 3 35 sh <<'$marker'`n$body`n$marker`n"
    $bundle += 'result=$?' + "`n" + 'exit "$result"' + "`n"
    [IO.File]::WriteAllText($bundlePath, $bundle, $encoding)
    if (-not (Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD)) {
        Save-Stage 'awaiting_secure_credential'
        $credential = Get-Credential -UserName root -Message 'Router read-only SIM2 deployment safety check. Enter password here, not in chat.'
        if ($null -eq $credential -or $credential.Password.Length -eq 0) { throw 'Credential prompt cancelled or empty.' }
        try {
            $env:ZBT_DIAG_PASSWORD = $credential.GetNetworkCredential().Password
            $temporary = $true
        }
        finally {
            $credential.Password.Dispose()
            $credential = $null
        }
    }
    Save-Stage 'readonly_preflight_dispatched'
    & (Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1') -ScriptPath $bundlePath -ArtifactName sim2-commit-preflight -TimeoutSeconds 45
    Save-Stage 'readonly_preflight_complete'
}
catch {
    $state.failure_type = $_.Exception.GetType().FullName
    Save-Stage 'stopped'
    throw
}
finally {
    if ($temporary) {
        [Environment]::SetEnvironmentVariable('ZBT_DIAG_PASSWORD', $null, 'Process')
        $state.temporary_credential_cleared = -not (Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD)
    }
    $state.credential_present = Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json), $encoding)
    Write-Output "PreflightStageArtifact=$stagePath"
}
