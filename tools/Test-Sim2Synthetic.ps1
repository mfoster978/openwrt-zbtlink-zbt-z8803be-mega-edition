$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$id = [Guid]::NewGuid().ToString('N')
$artifacts = Join-Path $root 'artifacts'
$stagePath = Join-Path $artifacts "sim2-fixture-stage-$id.json"
$bundlePath = Join-Path $artifacts "sim2-fixture-bundle-$id.sh"
$state = [ordered]@{ stage = 'local_started'; credential_present = $false }
$encoding = [Text.UTF8Encoding]::new($false)
$temporaryCredential = $false
function Save-Stage([string]$stage) {
    $state.stage = $stage
    $state.utc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json), $encoding)
    Write-Output "FixtureStage=$stage"
}
try {
    # Check source snapshots without reading any configuration or credential value.
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'staged-sim2\manifest.json')) | ConvertFrom-Json
    foreach ($entry in $manifest.PSObject.Properties) {
        foreach ($pair in @(@('original', 'original_sha256'), @('staged-sim2', 'staged_sha256'))) {
            $path = Join-Path (Join-Path $root $pair[0]) $entry.Name
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $entry.Value.($pair[1])) { throw 'Local source drift: fixture refused.' }
        }
    }
    $fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sim2-synthetic-fixtures.sh')).Replace("`r", '')
    $marker = "SIM2_FIXTURE_$id"
    $bundle = "#!/bin/sh`ntimeout -s TERM -k 3 40 sh <<'$marker'`n$fixture`n$marker`n"
    $bundle += 'result=$?' + "`n" + 'exit "$result"' + "`n"
    [IO.File]::WriteAllText($bundlePath, $bundle, $encoding)
    Save-Stage 'local_verified'
    if (-not (Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD)) {
        Save-Stage 'awaiting_secure_credential'
        $credential = Get-Credential -UserName root -Message 'Pinned router SSH: isolated SIM2 mock fixtures only. Enter password here, not in chat.'
        if ($null -eq $credential -or $credential.Password.Length -eq 0) {
            throw 'Secure prompt cancelled or empty; fixture not started.'
        }
        try {
            $env:ZBT_DIAG_PASSWORD = $credential.GetNetworkCredential().Password
            $temporaryCredential = $true
        }
        finally {
            $credential.Password.Dispose()
            $credential = $null
        }
    }
    $state.credential_present = Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD
    Save-Stage 'syntax_dispatched'
    & (Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1') -ScriptPath (Join-Path $PSScriptRoot 'sim2-synthetic-fixtures.sh') -ArtifactName sim2-fixture-syntax -TimeoutSeconds 15 -SyntaxOnly
    Save-Stage 'syntax_passed'
    & (Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1') -ScriptPath $bundlePath -ArtifactName sim2-synthetic-fixture -TimeoutSeconds 50
    Save-Stage 'fixture_passed'
}
catch {
    $state.failure_type = $_.Exception.GetType().FullName
    Save-Stage 'stopped'
    throw
}
finally {
    if ($temporaryCredential) {
        [Environment]::SetEnvironmentVariable('ZBT_DIAG_PASSWORD', $null, 'Process')
        $state.temporary_credential_cleared = -not (Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD)
    }
    $state.credential_present = Test-Path -LiteralPath Env:\ZBT_DIAG_PASSWORD
    [IO.File]::WriteAllText($stagePath, ($state | ConvertTo-Json), $encoding)
    Write-Output "FixtureStageArtifact=$stagePath"
}
