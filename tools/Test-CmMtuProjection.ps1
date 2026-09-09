$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1'
$cases = @('router-mtu-owner.sh', 'router-mtu-evidence.sh')
$harness = "#!/bin/sh`nfile=/dev/stdin`n"
$fixture = @'
[09-08_14:33:52:060] change mtu 1500 -> 1472
[09-08_14:34:00:000] change mtu 1472 -> 1500
[09-08_14:34:00:001] requestGetIPAddress ipv4 mtu = 1472
[09-08_14:34:00:002] requestGetIPAddress ipv6 mtu = 1500
password=DO_NOT_EXPORT_SENTINEL
change mtu 1500 ->
requestGetProfile subscriber=DO_NOT_EXPORT_SENTINEL
unrecognized mtu text 1600 DO_NOT_EXPORT_SENTINEL
'@
$assertions = @'
)"
case "$actual" in *'change mtu 1500 -> 1472'*) ;; *) exit 1 ;; esac
case "$actual" in *'change mtu 1472 -> 1500'*) ;; *) exit 1 ;; esac
case "$actual" in *'ipv4 mtu = 1472'*) ;; *) exit 1 ;; esac
case "$actual" in *'ipv6 mtu = 1500'*) ;; *) exit 1 ;; esac
case "$actual" in *DO_NOT_EXPORT_SENTINEL*) exit 1 ;; esac
[ "$(printf '%s\n' "$actual" | wc -l)" -eq 4 ] || exit 1
'@
foreach ($name in $cases) {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r", '')
    $match = [regex]::Match($source, '(?s)# MTU_LOG_PROJECTOR_BEGIN\n(.*?)\n[ \t]*# MTU_LOG_PROJECTOR_END')
    if (-not $match.Success) { throw "Projection block not found in $name." }
    $harness += 'actual="$(' + "`n" + $match.Groups[1].Value.Trim()
    $harness += " <<'CM_MTU_FIXTURE'`n" + $fixture.Replace("`r", '') + "`nCM_MTU_FIXTURE`n"
    $harness += $assertions.Replace("`r", '') + "`n"
    $harness += "printf 'projection_fixture=${name}:pass\n'`n"
}
$harness += "printf 'CM_MTU_PROJECTION_FIXTURES_PASSED=2\n'`nexit 0`n"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('zbt-cm-projection-' + [Guid]::NewGuid().ToString('N') + '.sh')
try {
    [IO.File]::WriteAllText($temporary, $harness, [Text.UTF8Encoding]::new($false))
    & $runner -ScriptPath $temporary -ArtifactName cm-mtu-projection-fixtures -TimeoutSeconds 20
}
finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
