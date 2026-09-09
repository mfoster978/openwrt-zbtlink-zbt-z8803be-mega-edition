param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stage', 'apply', 'power', 'observe', 'status', 'finish', 'abort', 'wait')]
    [string]$Action,
    [switch]$SyntaxOnly
)

$ErrorActionPreference = 'Stop'
$state = '/root/cellular-mtu-trial-20260908-141830'
$runner = Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1'
$trial = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-mtu-trial.sh')).Replace("`r", '')
$xhci = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-xhci-evidence.sh')).Replace("`r", '')
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('zbt-mtu-' + [Guid]::NewGuid().ToString('N') + '.sh')
$utf8 = [Text.UTF8Encoding]::new($false)

try {
    if ($Action -eq 'stage') {
        $delimiter = 'ZBT_SCRIPT_' + [Guid]::NewGuid().ToString('N')
        $payload = "umask 077`n[ ! -e '$state' ] || exit 1`nmkdir '$state' || exit 1`n"
        $payload += "cat > '$state/trial.sh' <<'$delimiter'`n$trial`n$delimiter`n"
        $payload += "cat > '$state/xhci.sh' <<'$delimiter'`n$xhci`n$delimiter`n"
        $payload += "sh -n '$state/trial.sh' && sh -n '$state/xhci.sh' || exit 1`n"
        $payload += "sh '$state/trial.sh' arm`n"
        if ($SyntaxOnly) {
            [IO.File]::WriteAllText($temporary, $trial, $utf8)
            & $runner -ScriptPath $temporary -ArtifactName mtu-trial-syntax -SyntaxOnly -TimeoutSeconds 25
            [IO.File]::WriteAllText($temporary, $xhci, $utf8)
            & $runner -ScriptPath $temporary -ArtifactName mtu-xhci-syntax -SyntaxOnly -TimeoutSeconds 25
        }
        else {
            [IO.File]::WriteAllText($temporary, $payload, $utf8)
            & $runner -ScriptPath $temporary -ArtifactName mtu-trial-stage -TimeoutSeconds 40
        }
    }
    elseif ($Action -eq 'wait') {
        if ($SyntaxOnly) { throw 'SyntaxOnly does not apply to wait.' }
        [IO.File]::WriteAllText($temporary, "sh '$state/trial.sh' status`n", $utf8)
        for ($round = 0; $round -lt 49; $round++) {
            $result = @(& $runner -ScriptPath $temporary -ArtifactName mtu-observation-status -TimeoutSeconds 30)
            $text = $result -join "`n"
            Write-Output $text
            if ($text -match '(?m)^phase=ready-to-finalize\r?$') {
                Write-Output 'Observation finished; explicit final verification is still required.'
                break
            }
            if ($text -notmatch '(?m)^phase=observing\r?$') {
                throw 'The trial is no longer observing; inspect its recorded phase and failure reason.'
            }
            Start-Sleep -Seconds 60
        }
    }
    else {
        [IO.File]::WriteAllText($temporary, "sh '$state/trial.sh' $Action`n", $utf8)
        $limit = 45
        if ($Action -eq 'power') { $limit = 260 }
        & $runner -ScriptPath $temporary -ArtifactName ("mtu-trial-" + $Action) -TimeoutSeconds $limit -SyntaxOnly:$SyntaxOnly
    }
}
finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
