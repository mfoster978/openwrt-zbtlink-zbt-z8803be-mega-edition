#!/usr/bin/env bash
set -euo pipefail
updater_root="$(cd "$(dirname "$0")/../.." && pwd)"
updater_tmp="$(mktemp -d /tmp/zbt-firmware-updater-check.XXXXXX)"
trap '[[ "$updater_tmp" == /tmp/zbt-firmware-updater-check.* ]] && rm -rf -- "$updater_tmp"' EXIT
cd "$updater_root/firmware/feeds/zbt-firmware-updater/src"
# All network interactions use a local httptest TLS fixture and every router
# command is dependency-injected. This never downloads or flashes real firmware.
go test -race -count=1 -v ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$updater_tmp/zbt-firmware-updater-arm64" .
file "$updater_tmp/zbt-firmware-updater-arm64"
CGO_ENABLED=0 go build -buildvcs=false -o "$updater_tmp/zbt-firmware-updater-host" .
"$updater_tmp/zbt-firmware-updater-host" list | jq -e '.flash.keep_settings == false and .prepare.release_id == 1 and .info == {}'
printf '%s\n' '{"id":"../../etc/passwd","ubus_rpc_session":"fixture-session-not-a-secret"}' | "$updater_tmp/zbt-firmware-updater-host" call status | jq -e '.ok == false and (.error | contains("Invalid update ID")) and (tostring | contains("fixture-session") | not)'
echo 'Mega updater tests and static ARM64 build passed; no firmware was flashed.'
