#!/bin/sh
# Run only inside a disposable container with the pinned Speedify UI APK
# extracted at /usr/share/luci-app-speedify and its proxy mounted in /opt.
set -eu
python3 -u /opt/sfy-ws-auth.py >/tmp/proxy-test.log 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; nginx -c /opt/nginx-speedify.conf -s quit 2>/dev/null || true' EXIT
nginx -t -c /opt/nginx-speedify.conf
nginx -c /opt/nginx-speedify.conf
i=0
until curl -fsS http://127.0.0.1:8080/cgi-bin/luci/ >/dev/null; do
  i=$((i+1)); [ "$i" -lt 20 ]; sleep 0.2
done
# Wait for Python to bind its socket, not just for nginx to accept requests.
i=0
while :; do
  code=$(curl -s -o /tmp/test-response -w '%{http_code}' http://127.0.0.1:8080/luci-app-speedify/view/index.html)
  [ "$code" != 502 ] && break
  i=$((i+1)); [ "$i" -lt 20 ]; sleep 0.2
done
[ "$code" = 401 ]
code=$(curl -s -o /tmp/test-response -w '%{http_code}' -H 'Cookie: sfy-session=zbtTestAdminSession' http://127.0.0.1:8080/luci-app-speedify/view/index.html)
[ "$code" = 200 ]
grep -qi '<html' /tmp/test-response
code=$(curl -s -o /tmp/test-response -w '%{http_code}' -H 'Cookie: sfy-session=invalidSession' http://127.0.0.1:8080/luci-app-speedify/view/index.html)
[ "$code" = 401 ]
printf '%s\n' 'Speedify nginx/proxy integration: authenticated index=200; missing/invalid session=401; LuCI fixture remains reachable'
