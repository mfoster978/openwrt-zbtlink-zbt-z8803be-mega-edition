#!/bin/sh
# Run only inside a disposable container with the pinned Speedify UI APK
# extracted at /usr/share/luci-app-speedify and its proxy mounted in /opt.
set -eu
auth_script="${SFY_AUTH_SCRIPT:-/opt/sfy-ws-auth.py}"
nginx_config="${NGINX_CONFIG:-/opt/nginx-speedify.conf}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -keyout /tmp/speedify-test.key -out /tmp/speedify-test.crt >/dev/null 2>&1
python3 -u "$auth_script" >/tmp/proxy-test.log 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; nginx -c "$nginx_config" -s quit 2>/dev/null || true' EXIT
nginx -t -c "$nginx_config"
nginx -c "$nginx_config"
i=0
until curl -fsS http://127.0.0.1:8080/cgi-bin/luci/ >/dev/null; do
  i=$((i+1)); [ "$i" -lt 20 ]; sleep 0.2
done
# Wait for Python to bind its socket, not just for nginx to accept requests.
i=0
while :; do
  code=$(curl -ks -o /tmp/test-response -w '%{http_code}' https://127.0.0.1:8443/luci-app-speedify/view/index.html)
  [ "$code" != 502 ] && break
  i=$((i+1)); [ "$i" -lt 20 ]; sleep 0.2
done
[ "$code" = 401 ]

# HTTP LuCI remains usable, but every Speedify entry point moves to HTTPS.
code=$(curl -s -D /tmp/test-headers -o /tmp/test-response -w '%{http_code}' \
  http://127.0.0.1:8080/cgi-bin/luci/admin/speedify)
[ "$code" = 307 ]
grep -qi '^Location: https://127.0.0.1/cgi-bin/luci/admin/speedify' /tmp/test-headers
code=$(curl -s -D /tmp/test-headers -o /tmp/test-response -w '%{http_code}' \
  http://127.0.0.1:8080/luci-app-speedify/view/index.html)
[ "$code" = 307 ]
grep -qi '^Location: https://127.0.0.1/luci-app-speedify/view/index.html' /tmp/test-headers
code=$(curl -s -o /tmp/test-response -w '%{http_code}' http://127.0.0.1:8080/cgi-bin/luci/admin/system)
[ "$code" = 200 ]

base=https://127.0.0.1:8443
curl_flags='-ks'
code=$(curl $curl_flags -o /tmp/test-response -w '%{http_code}' "$base/cgi-bin/luci/admin/speedify")
[ "$code" = 200 ]
for token in missing valid invalid; do
  cookie=''
  [ "$token" = valid ] && cookie='sfy-session=zbtTestAdminSession'
  [ "$token" = invalid ] && cookie='sfy-session=invalidSession'
  if [ -n "$cookie" ]; then
    code=$(curl $curl_flags -o /tmp/test-response -w '%{http_code}' -H "Cookie: $cookie" "$base/luci-app-speedify/view/index.html")
  else
    code=$(curl $curl_flags -o /tmp/test-response -w '%{http_code}' "$base/luci-app-speedify/view/index.html")
  fi
  if [ "$token" = valid ]; then
    [ "$code" = 200 ]
    grep -qi '<html' /tmp/test-response
  else
    [ "$code" = 401 ]
  fi
done
printf '%s\n' 'Speedify nginx/proxy integration: HTTP Speedify=307 to HTTPS; HTTPS auth and ordinary HTTP LuCI remain healthy'
