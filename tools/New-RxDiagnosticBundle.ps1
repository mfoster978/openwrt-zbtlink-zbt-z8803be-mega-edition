param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Baseline', 'Recorder', 'Fixtures')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) {
    throw 'Refusing to overwrite an existing diagnostic bundle.'
}
$common = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-rx-common.sh')).Replace("`r", '')
$baseline = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-rx-baseline.sh')).Replace("`r", '')
$body = $common
$seconds = 70
switch ($Mode) {
    'Baseline' {
        $body += "`n" + $baseline + "`nrx_defaults`nrx_baseline`n"
    }
    'Recorder' {
        $seconds = 3605
        $body += "`nrx_defaults`nrx_record`n"
    }
    'Fixtures' {
        $seconds = 90
        $body += "`n" + $baseline + "`n"
        $body += @'
umask 077
FX_ROOT="$(mktemp -d /tmp/cellular-rx-fixtures-XXXXXX)" || exit 1
fixture_cleanup() {
    case "$FX_ROOT" in /tmp/cellular-rx-fixtures-??????)
        [ ! -L "$FX_ROOT" ] && rm -rf "$FX_ROOT"
        ;;
    esac
}
trap fixture_cleanup EXIT
trap 'exit 124' TERM INT HUP
'@
        $body += "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-rx-fixtures.sh')).Replace("`r", '')
        $body += "`nrx_fixture_main`n"
    }
}
$marker = 'RX_BUNDLE_' + [Guid]::NewGuid().ToString('N')
$bundle = "#!/bin/sh`n# Generated $Mode bundle; no modem recovery actions.`n"
$bundle += "timeout -s TERM -k 3 $seconds sh <<'$marker'`n" + $body + "`n$marker`n"
$bundle += 'result=$?' + "`n" + 'exit "$result"' + "`n"
$absolutePath = [IO.Path]::GetFullPath($OutputPath)
[IO.File]::WriteAllText($absolutePath, $bundle, [Text.UTF8Encoding]::new($false))
Write-Output $absolutePath
