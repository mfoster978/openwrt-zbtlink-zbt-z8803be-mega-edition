$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-mtu-trial.sh')).Replace("`r", '')
$boundary = $source.IndexOf("`ncase `"`$1`" in`n")
if ($boundary -lt 0) { throw 'Trial function boundary was not found.' }
$functionsOnly = $source.Substring(0, $boundary)
$tests = @'

# All mutations below target unique test files; network commands are mocked.
fixture="$(mktemp -d /tmp/cellular-mtu-fixture.XXXXXX)" || exit 1
resolve_device() { printf 'fixture-device\n'; }
value() { cat "$STATE/current"; }
now() { printf '100\n'; }
ip() {
	[ "$*" = 'link set dev fixture-device mtu 1472' ] || return 1
	printf 'called\n' > "$STATE/ip-called"
	printf '1472\n' > "$STATE/current"
}
fixture_state() {
	STATE="$fixture/$1"
	mkdir "$STATE" || exit 1
	printf '1472\n' > "$STATE/original-mtu"
	printf '%s\n' "$2" > "$STATE/current"
	[ "$3" = unowned ] || printf '1500\n' > "$STATE/mtu-owned"
}
fixture_state restore 1500
restore || exit 1
[ -f "$STATE/ip-called" ] && [ "$(cat "$STATE/current")" = 1472 ] || exit 1
printf 'fixture_expected_restore=pass\n'
fixture_state operator 1600
restore || exit 1
[ ! -f "$STATE/ip-called" ] && [ "$(cat "$STATE/current")" = 1600 ] || exit 1
printf 'fixture_operator_value_preserved=pass\n'
fixture_state cancelled 1500
printf 'cancelled\n' > "$STATE/cancelled"
restore || exit 1
[ ! -f "$STATE/ip-called" ] && [ "$(cat "$STATE/current")" = 1500 ] || exit 1
printf 'fixture_cancelled_does_not_restore=pass\n'
fixture_state unowned 1500 unowned
restore || exit 1
[ ! -f "$STATE/ip-called" ] && [ "$(cat "$STATE/current")" = 1500 ] || exit 1
printf 'fixture_unowned_mtu_preserved=pass\n'
fixture_state absent 1500
resolve_device() { return 1; }
if restore; then exit 1; fi
[ ! -f "$STATE/rollback-complete" ] && [ ! -d "$STATE/decision.lock" ] || exit 1
printf 'fixture_absent_device_does_not_complete=pass\n'
fixture_state failed-write 1500
resolve_device() { printf 'fixture-device\n'; }
ip() { return 1; }
if restore; then exit 1; fi
[ ! -f "$STATE/rollback-complete" ] && [ ! -d "$STATE/decision.lock" ] || exit 1
printf 'fixture_failed_write_remains_retryable=pass\n'
printf 'ROLLBACK_FIXTURES_PASSED=6\n'
exit 0
'@
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('zbt-mtu-fixtures-' + [Guid]::NewGuid().ToString('N') + '.sh')
try {
    [IO.File]::WriteAllText($temporary, $functionsOnly + $tests, [Text.UTF8Encoding]::new($false))
    & $runner -ScriptPath $temporary -ArtifactName mtu-rollback-fixtures -TimeoutSeconds 25
}
finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
