#!/usr/bin/env bash
set -euo pipefail
speedtest_root="$(cd "$(dirname "$0")/../.." && pwd)"
speedtest_tmp="$(mktemp -d /tmp/zbt-speedtest-check.XXXXXX)"
trap '[[ "$speedtest_tmp" == /tmp/zbt-speedtest-check.* ]] && rm -rf -- "$speedtest_tmp"' EXIT
curl --fail --silent --show-error --location --max-time 60 \
  'https://codeload.github.com/showwin/speedtest-go/tar.gz/v1.7.10' -o "$speedtest_tmp/source.tar.gz"
printf '%s  %s\n' 70a2937d0759820fe7ee8f61b960d60c07b34c0d783ed11c0065b68fe2964aea "$speedtest_tmp/source.tar.gz" | sha256sum -c -
mkdir "$speedtest_tmp/source"
tar -xzf "$speedtest_tmp/source.tar.gz" -C "$speedtest_tmp/source" --strip-components=1
mkdir -p "$speedtest_tmp/source/cmd/zbt-speedtest"
cp "$speedtest_root"/firmware/feeds/zbt-speedtest/src/*.go "$speedtest_tmp/source/cmd/zbt-speedtest/"
cd "$speedtest_tmp/source"
go test -v ./cmd/zbt-speedtest
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$speedtest_tmp/zbt-speedtest-arm64" ./cmd/zbt-speedtest
file "$speedtest_tmp/zbt-speedtest-arm64"
CGO_ENABLED=0 go build -o "$speedtest_tmp/zbt-speedtest-host" ./cmd/zbt-speedtest
"$speedtest_tmp/zbt-speedtest-host" list | jq -e '.start.consent == false and .cancel.id == "" and .status == {}'
printf '%s\n' '{"interface":"default","consent":false,"ubus_rpc_session":"fixture-only-not-a-real-session"}' | "$speedtest_tmp/zbt-speedtest-host" call start | jq -e '.ok == false and (.error | contains("data-usage")) and (tostring | contains("fixture-only") | not)'
echo 'Pinned speedtest engine tests and static ARM64 build passed; no public bandwidth test was run.'
