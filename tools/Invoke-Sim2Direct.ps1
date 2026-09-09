param([Parameter(Mandatory = $true)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$id = [Guid]::NewGuid().ToString('N')
$stagePath = Join-Path $root "artifacts\sim2-direct-stage-$id.json"
$encoding = [Text.UTF8Encoding]::new($false)
$temporary = $false
$state = [ordered]@{ stage = 'local_started'; backup_requested = $false; rollback_requested = $false }
function Save-Stage([string]$name) {
    $state.stage = $name
    $state.utc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json), $encoding)
    Write-Output "DeploymentStage=$name"
}
try {
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw 'Missing deployment bundle.' }
    if (-not (Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD)) {
        Save-Stage 'awaiting_secure_credential'
        $credential = Get-Credential -UserName root -Message 'Apply approved offline SIM2 configuration without backup or rollback. Enter password here, not in chat.'
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
    Save-Stage 'deployment_dispatched'
    & (Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1') -ScriptPath $ScriptPath -ArtifactName sim2-direct-deployment -TimeoutSeconds 90
    Save-Stage 'deployment_complete'
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
    Write-Output "DeploymentStageArtifact=$stagePath"
}
