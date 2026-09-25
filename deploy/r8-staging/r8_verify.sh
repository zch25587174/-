#!/usr/bin/env bash
# Run from an EXTERNAL machine (not the server). Read-only HTTP probes; no credentials used.
# Usage: ./r8_verify.sh [domain] [r7_port] [server_ip]
set -uo pipefail
D="${1:-jp.granda-jp.com}"; P="${2:-}"; IP="${3:-}"; B="https://$D"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@"; }
expect() { local want="$1" label="$2"; shift 2; local c; c="$(code "$@")"; [[ "$c" =~ ^($want)$ ]] && ok "$label ($c)" || bad "$label (got $c, want $want)"; }

echo "== DNS";   echo "$D -> $(dig +short A "$D" @1.1.1.1 | tr '\n' ' ')"
echo "== TLS"
curl -sS -m 15 -o /dev/null "$B/" && ok "certificate valid + hostname match" || bad "TLS verification"
echo | openssl s_client -connect "$D:443" -servername "$D" 2>/dev/null | openssl x509 -noout -subject -enddate -ext subjectAltName 2>/dev/null
expect '301|308' "HTTP -> HTTPS redirect" "http://$D/"
curl -sI -m 15 "http://$D/" | grep -qi "^location: https://$D" && ok "redirect target is https://$D" || bad "redirect target"

echo "== NOINDEX"
curl -sI -m 15 "$B/" | grep -qi '^x-robots-tag:.*noindex' && ok "X-Robots-Tag noindex header" || bad "X-Robots-Tag missing"
curl -s -m 15 "$B/robots.txt" | grep -q 'Disallow: /' && ok "robots.txt disallows all" || bad "robots.txt"
curl -sI -m 15 "$B/" | grep -qi '^strict-transport-security:.*includesubdomains' && bad "HSTS includeSubDomains (would affect other hosts)" || ok "HSTS scoped to host"

echo "== PAGES (expect 200)"
for p in / /service/ /cases/ /news/ /company/ /contact/ /legal/; do expect '200' "GET $p" "$B$p"; done
expect '404' "unknown route -> 404" "$B/r8-nonexistent-$(date +%s)"

echo "== ADMIN AUTH"
c="$(code "$B/admin/")"; [[ "$c" =~ ^(200|301|302|303|401|403)$ ]] && echo "INFO  /admin/ -> $c (inspect: must show login, not content)"
curl -s -m 15 -L "$B/admin/" | grep -qiE 'type="password"|login|ログイン' && ok "/admin/ shows login form" || bad "/admin/ login form not detected"
for p in /admin/api/news /admin/news /admin/media; do c="$(code "$B$p")"; [[ "$c" =~ ^(301|302|303|401|403|404)$ ]] && ok "unauth $p -> $c" || bad "unauth $p -> $c"; done
curl -sI -m 15 -L "$B/admin/" | grep -i '^set-cookie' | grep -qvi 'secure' && bad "cookie without Secure flag" || ok "admin cookies Secure (or none set pre-login)"

echo "== SENSITIVE PATHS (expect 403/404)"
for p in /.env /.git/HEAD /.git/config /backup.sql /db.sqlite /dump.sql /backups/ /logs/ /app.log /config.bak /.DS_Store /package.json.bak; do
  expect '403|404' "GET $p" "$B$p"; done
expect '400|403|404' "path traversal" --path-as-is "$B/../../etc/passwd"
expect '400|403|404' "encoded traversal" "$B/%2e%2e/%2e%2e/etc/passwd"
x="$(curl -s -m 15 "$B/news/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")"; grep -q '<script>alert(1)</script>' <<<"$x" && bad "reflected XSS in ?q" || ok "no reflected XSS in ?q"
s="$(code "$B/news/1'%20OR%20'1'='1")"; [[ "$s" =~ ^5 ]] && bad "SQLi probe caused $s" || ok "SQLi probe -> $s (no 5xx)"

echo "== EXPOSURE"
if [ -n "$P" ] && [ -n "$IP" ]; then
  timeout 5 bash -c "echo > /dev/tcp/$IP/$P" 2>/dev/null && bad "R7 port $P reachable publicly" || ok "R7 port $P not public"
  for dbp in 3306 5432 6379 27017; do timeout 5 bash -c "echo > /dev/tcp/$IP/$dbp" 2>/dev/null && bad "DB port $dbp public" || ok "DB port $dbp closed"; done
else echo "SKIP  port exposure (pass r7_port and server_ip)"; fi

echo "== LOGIN RATE LIMIT (12 rapid bad POSTs, expect a 429)"
got429=no; for i in $(seq 12); do [ "$(code -X POST -d 'username=r8probe&password=wrong' "$B/admin/login")" = 429 ] && got429=yes; done
[ "$got429" = yes ] && ok "login rate limited" || bad "no 429 seen on /admin/login (check actual login path)"

echo; echo "RESULT: $pass pass, $fail fail"; [ "$fail" = 0 ]
