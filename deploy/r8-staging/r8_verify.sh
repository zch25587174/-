#!/usr/bin/env bash
# Run from an EXTERNAL device (not the server). Read-only HTTP probes; no credentials.
# Anything that needs R7 facts not supplied is reported UNVERIFIED, never PASS.
# Usage: [R7_ROUTE_MANIFEST=file] [R7_ADMIN_LOGIN_PATH=/..] [R7_HEALTH_PATH=/..]
#        [EXPECTED_IP=ip] [R7_PORT=port] ./r8_verify.sh [domain]
# Test-only pinning: CONNECT_IP (use instead of DNS), CACERT, HTTP_PORT, HTTPS_PORT.
# Exit: 0 all PASS, 1 any FAIL, 2 no FAIL but something UNVERIFIED.
set -uo pipefail
. "$(dirname "$0")/r8_lib.sh"
DOMAIN="${1:-$DOMAIN}"; validate_inputs
EXPECTED_IP="${EXPECTED_IP:-}"; CONNECT_IP="${CONNECT_IP:-}"; CACERT="${CACERT:-}"
for v in "$EXPECTED_IP" "$CONNECT_IP"; do [ -z "$v" ] || [[ "$v" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid IP: $v"; done
hp=""; [ "$HTTPS_PORT" = 443 ] || hp=":$HTTPS_PORT"
B="https://$DOMAIN$hp"; H="http://$DOMAIN$( [ "$HTTP_PORT" = 80 ] || echo ":$HTTP_PORT")"
CURL=(curl -s -m 15)
[ -z "$CONNECT_IP" ] || CURL+=(--noproxy '*' --resolve "$DOMAIN:$HTTPS_PORT:$CONNECT_IP" --resolve "$DOMAIN:$HTTP_PORT:$CONNECT_IP")
[ -z "$CACERT" ]     || CURL+=(--cacert "$CACERT")
pass=0; fail=0; unv=0
ok()  { echo "PASS        $*"; pass=$((pass+1)); }
bad() { echo "FAIL        $*"; fail=$((fail+1)); }
unk() { echo "UNVERIFIED  $*"; unv=$((unv+1)); }
code() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@"; }
hdrs() { "${CURL[@]}" -o /dev/null -D - "$@" | tr -d '\r'; }
expect() { local want="$1" label="$2" c; shift 2; c="$(code "$@")"; [[ "$c" =~ ^($want)$ ]] && ok "$label ($c)" || bad "$label (got $c, want $want)"; }

echo "== DNS"
if [ -n "$CONNECT_IP" ]; then unk "DNS (pinned to $CONNECT_IP for testing)"
else
  got="$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ')"; echo "$DOMAIN -> ${got:-?}"
  if [ -z "$EXPECTED_IP" ]; then unk "DNS target (set EXPECTED_IP to the Tencent public IP)"
  elif [ "$(echo "$got" | xargs)" = "$EXPECTED_IP" ]; then ok "DNS -> $EXPECTED_IP"; else bad "DNS -> '$got' (want $EXPECTED_IP)"; fi
fi

echo "== TLS / REDIRECT"
"${CURL[@]}" -o /dev/null "$B/" && ok "certificate valid + hostname match" || bad "TLS verification"
end="$(echo | openssl s_client -connect "${CONNECT_IP:-$DOMAIN}:$HTTPS_PORT" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
if [ -n "$end" ]; then d=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 )); [ "$d" -ge 14 ] && ok "certificate valid $d more days" || bad "certificate expires in $d days"
else bad "could not read certificate"; fi
expect '301|308' "HTTP -> HTTPS redirect" "$H/"
grep -qi "^location: https://$DOMAIN" <<<"$(hdrs "$H/")" && ok "redirect target https://$DOMAIN" || bad "redirect target"

echo "== NOINDEX / HEADERS"
h="$(hdrs "$B/")"
grep -qi '^x-robots-tag:.*noindex' <<<"$h" && ok "X-Robots-Tag noindex" || bad "X-Robots-Tag missing"
grep -q 'Disallow: /' <<<"$("${CURL[@]}" "$B/robots.txt")" && ok "robots.txt disallows all" || bad "robots.txt"
grep -qi '^strict-transport-security:.*includesubdomains' <<<"$h" && bad "HSTS includeSubDomains (would affect other hosts)" || ok "HSTS scoped to host"

echo "== R7 ROUTES"
if [ -n "$R7_ROUTE_MANIFEST" ] && [ -f "$R7_ROUTE_MANIFEST" ]; then
  while read -r p want; do
    [[ "$p" == /* ]] || { bad "manifest line not a path: $p"; continue; }
    expect "$want" "route $p" "$B$p"
  done < <(manifest_routes)
else unk "R7 routes (set R7_ROUTE_MANIFEST from R7 source; no route list is guessed)"; fi
if [ -n "$R7_HEALTH_PATH" ]; then expect 200 "R7 health $R7_HEALTH_PATH" "$B$R7_HEALTH_PATH"; else unk "R7 health (set R7_HEALTH_PATH)"; fi
expect 404 "unknown route -> 404" "$B/r8-nonexistent-$RANDOM$RANDOM"

echo "== ADMIN"
if [ -n "$R7_ADMIN_LOGIN_PATH" ]; then
  grep -qiE 'type="?password' <<<"$("${CURL[@]}" -L "$B$R7_ADMIN_LOGIN_PATH")" && ok "login form at $R7_ADMIN_LOGIN_PATH" || bad "no password field at $R7_ADMIN_LOGIN_PATH"
  sc="$(hdrs -L "$B$R7_ADMIN_LOGIN_PATH" | grep -i '^set-cookie' || true)"
  if [ -z "$sc" ]; then unk "cookie flags (no cookie set before login)"
  elif grep -qvi 'secure' <<<"$sc"; then bad "cookie without Secure flag"; else ok "cookies Secure"; fi
  got429=no; for _ in $(seq 12); do [ "$(code -X POST -d 'username=r8probe&password=wrong' "$B$R7_ADMIN_LOGIN_PATH")" = 429 ] && got429=yes; done
  [ "$got429" = yes ] && ok "login rate limited (429)" || bad "no 429 on $R7_ADMIN_LOGIN_PATH"
else unk "admin login form, cookie flags, rate limit (set R7_ADMIN_LOGIN_PATH)"; fi

echo "== SENSITIVE PATHS (expect 403/404)"
for p in "${SENSITIVE_PROBES[@]}"; do expect '403|404' "GET $p" "$B$p"; done
expect '400|403|404' "path traversal"    --path-as-is "$B/../../etc/passwd"
expect '400|403|404' "encoded traversal" "$B/%2e%2e/%2e%2e/etc/passwd"
grep -q '<script>alert(1)</script>' <<<"$("${CURL[@]}" "$B/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")" && bad "reflected XSS in ?q" || ok "no reflected XSS in /?q"
c="$(code "$B/?id=1'%20OR%20'1'='1")"; [[ "$c" =~ ^5 ]] && bad "SQLi probe -> $c" || ok "SQLi probe -> $c (no 5xx)"

echo "== EXPOSURE"
ip="${EXPECTED_IP:-$CONNECT_IP}"
if [[ "$ip" =~ ^(127\.|::1$) ]]; then unk "port exposure (target is loopback; run from an external device)"
elif [ -n "$ip" ] && [ -n "${R7_PORT:-}" ]; then
  timeout 5 bash -c "echo > /dev/tcp/$ip/$R7_PORT" 2>/dev/null && bad "R7 port $R7_PORT reachable on $ip" || ok "R7 port $R7_PORT not reachable"
  for dbp in 3306 5432 6379 27017; do timeout 5 bash -c "echo > /dev/tcp/$ip/$dbp" 2>/dev/null && bad "DB port $dbp open on $ip" || ok "DB port $dbp closed"; done
else unk "port exposure (set EXPECTED_IP and R7_PORT)"; fi

echo; echo "RESULT: $pass PASS, $fail FAIL, $unv UNVERIFIED"
[ "$fail" = 0 ] || exit 1
[ "$unv" = 0 ] || exit 2
