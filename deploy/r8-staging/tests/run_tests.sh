#!/usr/bin/env bash
# Repeatable regression tests for the R8 staging kit.
# Drives a THROWAWAY nginx (own prefix/config/pid under a mktemp dir, high ports) with stub
# docker/systemctl/certbot. Never touches /etc/nginx, ports 80/443, Tencent, DNS or the network.
# Requires root (nginx master), nginx >= 1.19.4, openssl, curl, python3, ss, flock.
# Usage: sudo deploy/r8-staging/tests/run_tests.sh [name-filter]
# shellcheck disable=SC2034,SC2046  # vars are read inside check()'s eval strings; jp()/www() emit curl args by design
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${1:-}"
P_HTTP=28080 P_HTTPS=28443 P_R7=28090 P_PUB=28091 P_NONE=28099
DOM=jp.granda-jp.com

[ "$(id -u)" = 0 ] || { echo "run as root (throwaway nginx master)"; exit 1; }
for b in nginx openssl curl python3 ss flock; do command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }; done
for p in $P_HTTP $P_HTTPS $P_R7 $P_PUB $P_NONE; do
  [ -z "$(ss -ltnH "sport = :$p")" ] || { echo "port $p already in use; refusing to run"; exit 1; }
done
ROOT="$(mktemp -d /tmp/r8-tests.XXXXXX)"
trap '[ -n "${KEEP:-}" ] || rm -rf -- "$ROOT"' EXIT

# ---------------- fixture ----------------
mkcert() {  # dir cn days
  mkdir -p "$1"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$3" -subj "/CN=$2" \
    -addext "subjectAltName=DNS:$2" -keyout "$1/privkey.pem" -out "$1/fullchain.pem" 2>/dev/null
}
wait_port() { local i; for i in $(seq 50); do [ -n "$(ss -ltnH "sport = :$1")" ] && return 0; sleep 0.1; done; return 1; }

# setup [default=1] [http2=0] [https=1] [jpcert=1]
setup() {
  local def="${1:-1}" h2="${2:-0}" https="${3:-1}" jpcert="${4:-1}" D="" H=""
  [ "$def" = 1 ] && D=" default_server"; [ "$h2" = 1 ] && H=" http2"
  mkdir -p "$T"/{nginx/sites-available,nginx/sites-enabled,nginx/conf.d,state,le/live,acme,bin,www,tmp,cron}
  mkcert "$T/wwwcert" www.example.test 30
  [ "$jpcert" = 1 ] && mkcert "$T/le/live/$DOM" "$DOM" 30
  cat > "$T/nginx/nginx.conf" <<EOF
user root;
worker_processes 1;
pid $T/nginx.pid;
error_log $T/error.log;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $T/tmp/body; proxy_temp_path $T/tmp/proxy; fastcgi_temp_path $T/tmp/fcgi;
    uwsgi_temp_path $T/tmp/uwsgi; scgi_temp_path $T/tmp/scgi;
    include $T/nginx/conf.d/*.conf;
    include $T/nginx/sites-enabled/*;
}
EOF
  # www.conf / meishi.conf sort AFTER jp.granda-jp.com.conf: the worst case for implicit defaults.
  {
    echo "server { listen $P_HTTP$D; server_name www.example.test; add_header X-Site www always; return 200 \"<html><title>WWW home</title></html>\n\"; }"
    [ "$https" = 1 ] && echo "server { listen $P_HTTPS ssl$D$H; server_name www.example.test; ssl_certificate $T/wwwcert/fullchain.pem; ssl_certificate_key $T/wwwcert/privkey.pem; add_header X-Site www always; return 200 \"<html><title>WWW home</title></html>\n\"; }"
  } > "$T/nginx/sites-available/www.conf"
  {
    echo "server { listen $P_HTTP; server_name meishi.example.test static.*; return 200 \"<title>Meishi</title>\n\"; }"
    [ "$https" = 1 ] && echo "server { listen $P_HTTPS ssl; server_name meishi.example.test; ssl_certificate $T/wwwcert/fullchain.pem; ssl_certificate_key $T/wwwcert/privkey.pem; return 200 \"<title>Meishi</title>\n\"; }"
  } > "$T/nginx/sites-available/meishi.conf"
  ln -s ../sites-available/www.conf "$T/nginx/sites-enabled/www.conf"
  ln -s ../sites-available/meishi.conf "$T/nginx/sites-enabled/meishi.conf"
  echo '<html><title>R7 staging</title></html>' > "$T/www/index.html"
  nginx -c "$T/nginx/nginx.conf" || return 1
  python3 -m http.server "$P_R7" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 & echo $! >> "$T/pids"
  wait_port "$P_HTTP" && wait_port "$P_R7" || return 1
  export DOMAIN="$DOM" NGINX_DIR="$T/nginx" NGINX_CONF="$T/nginx/nginx.conf" HTTP_PORT=$P_HTTP HTTPS_PORT=$P_HTTPS \
         STATE_ROOT="$T/state" CERT_DIR="$T/le/live/$DOM" ACME_ROOT="$T/acme" RENEW_HOOK_DIR="$T/le/hooks" \
         RELOAD_WAIT=1 SYSTEMD_RUN_DIR="$T/no-systemd" R8_CRON_PATHS="$T/cron" SERVER_PUBLIC_IP=127.0.0.1 \
         R7_PORT=$P_R7 PATH="$T/bin:$PATH"
  unset R7_ADMIN_LOGIN_PATH R7_HEALTH_PATH R7_ROUTE_MANIFEST R8_HEALTH_URLS
}
teardown() {
  [ -f "$T/nginx.pid" ] && kill -QUIT "$(cat "$T/nginx.pid")" 2>/dev/null   # works even if the test broke the config
  [ -f "$T/pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$T/pids"
  sleep 0.3
}

# ---------------- helpers ----------------
FAILS=0
check() { if eval "$2"; then :; else echo "    FAIL: $1"; FAILS=$((FAILS+1)); fi; }
c() { curl --noproxy '*' -sk -m 5 "$@"; }
title() { c "$@" | grep -o '<title>[^<]*' | head -1 | sed 's/<title>//'; }
proto() { c -o /dev/null -w '%{http_version}' "$@"; }
status() { c -o /dev/null -w '%{http_code}' "$@"; }
jp()  { echo --resolve "$DOM:$P_HTTPS:127.0.0.1" "https://$DOM:$P_HTTPS$1"; }
www() { echo --resolve "www.example.test:$P_HTTPS:127.0.0.1" "https://www.example.test:$P_HTTPS/"; }
apply() { OUT="$("${KIT_RUN:-$KIT}/r8_apply.sh" 2>&1)"; RC=$?; }
jp_files() { ls "$T/nginx/sites-enabled/$DOM.conf" "$T/nginx/sites-available/$DOM.conf" "$T/nginx/granda-r8-proxy.inc" 2>/dev/null | wc -l; }
nginx_T() { nginx -c "$T/nginx/nginx.conf" -T 2>/dev/null; }
vhost() { cat "$T/nginx/sites-available/$DOM.conf"; }
lib() { ( . "$KIT/r8_lib.sh"; "$@" ); }

# ---------------- tests ----------------
t01_existing_healthy_vhost() {
  setup
  check "www https title" '[ "$(title $(www))" = "WWW home" ]'
  check "meishi http" '[ "$(title --resolve meishi.example.test:$P_HTTP:127.0.0.1 http://meishi.example.test:$P_HTTP/)" = Meishi ]'
}
t02_jp_apply() {
  setup; apply
  check "apply rc=0 ($OUT)" '[ $RC = 0 ]'
  check "jp https serves R7" '[ "$(title $(jp /))" = "R7 staging" ]'
  check "jp noindex header" 'c -D - -o /dev/null $(jp /) | grep -qi "^x-robots-tag: noindex"'
  check "jp http 301 -> https" '[ "$(c -o /dev/null -w "%{http_code} %{redirect_url}" --resolve $DOM:$P_HTTP:127.0.0.1 http://$DOM:$P_HTTP/x)" = "301 https://$DOM/x" ]'
  check "jp never default_server" '! vhost | grep -B3 "server_name $DOM" | grep -q default_server'
  check "no rate limit without login path" '! vhost | grep -q limit_req'
}
t03_existing_vhost_unchanged() {
  setup; local before; before="$(nginx_T)"; apply
  local run; run="$(readlink -f "$T/state/last-apply")"
  lib health_snapshot "$run/targets.txt" > "$T/after.txt"
  check "fingerprint regressions empty" '[ -z "$(lib health_regressions "$run/health.before.txt" "$run/health.before2.txt" "$T/after.txt")" ]'
  check "nginx -T: no pre-existing line removed/changed" '[ -z "$(diff <(echo "$before") <(nginx_T) | grep "^<")" ]'
  check "www still WWW" '[ "$(title $(www))" = "WWW home" ]'
}
t04_http2_isolation() {
  setup 1 0; apply
  check "apply ok" '[ $RC = 0 ]'
  check "existing www stays HTTP/1.1" '[ "$(proto $(www))" = 1.1 ]'
  check "jp does not enable h2" '[ "$(proto $(jp /))" = 1.1 ]'
  check "no http2 listen param/directive in jp vhost" '! vhost | grep -Eq "^ *listen [^;]*http2|^ *http2 on"'
}
t05_http2_mirror_existing() {
  setup 1 1; apply
  check "apply ok" '[ $RC = 0 ]'
  check "existing www h2 unchanged" '[ "$(proto $(www))" = 2 ]'
  check "jp mirrors port-level h2" '[ "$(proto $(jp /))" = 2 ]'
  check "report says listen-level" 'grep -q "HTTP2 mirror: listen-level" <<<"$OUT"'
}
t06_default_server_missing_blocks() {
  setup 0; local before; before="$(nginx_T)"; apply
  check "apply refused" '[ $RC != 0 ]'
  check "reason names default_server" 'grep -q "default_server not explicit" <<<"$OUT"'
  check "no jp files installed" '[ "$(jp_files)" = 0 ]'
  check "config untouched" '[ "$before" = "$(nginx_T)" ]'
}
t07_bare_ip_unknown_known_jp_hosts() {
  setup; apply
  check "bare IP https -> existing default" '[ "$(title https://127.0.0.1:$P_HTTPS/)" = "WWW home" ]'
  check "bare IP http -> existing default" '[ "$(title -H "Host: 127.0.0.1" http://127.0.0.1:$P_HTTP/)" = "WWW home" ]'
  check "unknown host https -> existing default" '[ "$(title --resolve x.invalid:$P_HTTPS:127.0.0.1 https://x.invalid:$P_HTTPS/)" = "WWW home" ]'
  check "unknown host http -> existing default" '[ "$(title -H "Host: x.invalid" http://127.0.0.1:$P_HTTP/)" = "WWW home" ]'
  check "known meishi unchanged" '[ "$(title --resolve meishi.example.test:$P_HTTPS:127.0.0.1 https://meishi.example.test:$P_HTTPS/)" = Meishi ]'
  check "jp host -> R7" '[ "$(title $(jp /))" = "R7 staging" ]'
}
t08_sink_on_socket_with_no_listener() {
  setup 1 0 0; apply
  check "apply ok" '[ $RC = 0 ]'
  check "sink rendered" 'vhost | grep -q ssl_reject_handshake'
  check "bare IP https rejected (not jp)" '[ "$(status https://127.0.0.1:$P_HTTPS/)" = 000 ]'
  check "jp https -> R7" '[ "$(title $(jp /))" = "R7 staging" ]'
  check "www http unchanged" '[ "$(title -H "Host: www.example.test" http://127.0.0.1:$P_HTTP/)" = "WWW home" ]'
}
t09_r7_not_listening_refused() {
  setup; R7_PORT=$P_NONE apply
  check "refused" '[ $RC != 0 ] && grep -q "nothing listening" <<<"$OUT"'
  check "no files" '[ "$(jp_files)" = 0 ]'
}
t10_r7_public_bind_refused() {
  setup
  python3 -m http.server "$P_PUB" --bind 0.0.0.0 --directory "$T/www" >/dev/null 2>&1 & echo $! >> "$T/pids"; wait_port "$P_PUB"
  R7_PORT=$P_PUB apply
  check "refused" '[ $RC != 0 ] && grep -q "bound publicly" <<<"$OUT"'
  check "no files" '[ "$(jp_files)" = 0 ]'
}
t11_invalid_nginx_config_refused() {
  setup; echo "bogus_r8_directive on;" >> "$T/nginx/sites-available/meishi.conf"; apply
  check "refused" '[ $RC != 0 ] && grep -q "fails nginx" <<<"$OUT"'
  check "no files" '[ "$(jp_files)" = 0 ]'
}
t12_graceful_reload_same_master() {
  setup; local pid; pid="$(cat "$T/nginx.pid")"; apply
  check "apply ok" '[ $RC = 0 ]'
  check "master pid unchanged" '[ "$(cat "$T/nginx.pid")" = "$pid" ]'
}
t13_forced_regression_http2_auto_rollback() {
  setup; cp -r "$KIT" "$T/kit"
  sed -i "s/__LISTEN_HTTPS__/listen $P_HTTPS ssl http2;/" "$T/kit/jp.granda-jp.com.conf.tmpl"   # re-inject the P0-2 bug
  KIT_RUN="$T/kit" apply
  check "apply failed" '[ $RC != 0 ]'
  check "detected www protocol change" 'grep -q "site:www.example.test:https.proto.1.1 -> 2" <<<"$OUT"'
  check "auto rollback ran + verified" 'grep -q "ROLLBACK" <<<"$OUT" && grep -q "rollback verified" <<<"$OUT"'
  check "jp files removed" '[ "$(jp_files)" = 0 ]'
  check "www back to 1.1" '[ "$(proto $(www))" = 1.1 ]'
}
t14_forced_regression_unhealthy_container_auto_rollback() {
  setup
  cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
[ "$1" = ps ] || exit 0
if [ -e "$NGINX_DIR/sites-enabled/jp.granda-jp.com.conf" ]; then echo "meishi-web|Up 9 minutes (unhealthy)"; else echo "meishi-web|Up 9 minutes (healthy)"; fi
EOF
  chmod +x "$T/bin/docker"; apply
  check "apply failed" '[ $RC != 0 ]'
  check "container health change detected" 'grep -q "ctr:meishi-web.state.running:healthy -> running:unhealthy" <<<"$OUT"'
  check "jp files removed" '[ "$(jp_files)" = 0 ]'
}
t15_manual_rollback_idempotent() {
  setup; local before; before="$(nginx_T)"; apply
  local out rc; out="$("$KIT/r8_rollback.sh" 2>&1)"; rc=$?
  check "rollback rc=0 ($out)" '[ $rc = 0 ] && grep -q "rollback verified" <<<"$out"'
  check "config identical to pre-apply" '[ "$before" = "$(nginx_T)" ]'
  check "jp gone" '[ "$(jp_files)" = 0 ]'
  out="$("$KIT/r8_rollback.sh" 2>&1)"; rc=$?
  check "second rollback harmless" '[ $rc = 0 ]'
}
t16_missing_systemd() {
  setup; mkdir -p "$T/fake-systemd"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
  SYSTEMD_RUN_DIR="$T/fake-systemd" apply
  check "apply ok with broken systemctl" '[ $RC = 0 ]'
}
t17_ipv6_mirroring() {
  setup; apply
  check "no [::] when server has none" '! vhost | grep -q "\[::\]"'
  local v6; v6="$( . "$KIT/r8_lib.sh"
    NGINX_STMTS="$(printf 'listen %s default_server;\nlisten [::]:%s default_server;\nlisten %s ssl default_server;\nlisten [::]:%s ssl default_server;\n' $P_HTTP $P_HTTP $P_HTTPS $P_HTTPS)"
    plan_listen_policy >/dev/null && printf '%s\n' "$R_LISTEN_HTTP" "$R_LISTEN_HTTPS" )"
  check "unit: [::] mirrored when present" '[ "$(grep -c "\[::\]" <<<"$v6")" = 2 ]'
  local blk; blk="$( . "$KIT/r8_lib.sh"
    NGINX_STMTS="$(printf 'listen %s default_server;\nlisten [::]:%s;\nlisten %s ssl default_server;\n' $P_HTTP $P_HTTP $P_HTTPS)"
    plan_listen_policy >/dev/null && echo OK || echo BLOCK )"
  check "unit: [::] socket without default blocks" '[ "$blk" = BLOCK ]'
}
t18_route_manifest_missing_is_unverified() {
  setup; apply
  local out rc; out="$(CONNECT_IP=127.0.0.1 CACERT="$CERT_DIR/fullchain.pem" "$KIT/r8_verify.sh" 2>&1)"; rc=$?
  check "exit 2 (unverified, no fail) [$rc]" '[ $rc = 2 ]'
  check "routes UNVERIFIED" 'grep -q "UNVERIFIED  R7 routes" <<<"$out"'
  check "admin UNVERIFIED" 'grep -q "UNVERIFIED  admin login form" <<<"$out"'
  check "no FAIL lines" '! grep -q "^FAIL" <<<"$out"'
}
t19_route_manifest_supplied() {
  setup; apply
  printf '/ 200\n/index.html 200\n# comment\n/nope 404\n' > "$T/routes.txt"
  local out rc; out="$(R7_ROUTE_MANIFEST="$T/routes.txt" CONNECT_IP=127.0.0.1 CACERT="$CERT_DIR/fullchain.pem" "$KIT/r8_verify.sh" 2>&1)"; rc=$?
  check "routes PASS" 'grep -q "PASS        route /index.html (200)" <<<"$out" && grep -q "PASS        route /nope (404)" <<<"$out"'
  check "no FAIL" '! grep -q "^FAIL" <<<"$out"'
  printf '/missing-page 200\n' > "$T/routes2.txt"
  out="$(R7_ROUTE_MANIFEST="$T/routes2.txt" CONNECT_IP=127.0.0.1 CACERT="$CERT_DIR/fullchain.pem" "$KIT/r8_verify.sh" 2>&1)"; rc=$?
  check "broken route FAILs, exit 1" '[ $rc = 1 ] && grep -q "FAIL        route /missing-page" <<<"$out"'
}
t20_manifest_blocklist_conflict_refused() {
  setup; printf '/\n/downloads/brochure.zip\n/company/\n' > "$T/routes.txt"
  R7_ROUTE_MANIFEST="$T/routes.txt" apply
  check "refused" '[ $RC != 0 ] && grep -q "blocked by staging blocklist: /downloads/brochure.zip" <<<"$OUT"'
  check "no files" '[ "$(jp_files)" = 0 ]'
}
t21_login_rate_limit_config() {
  setup; mkdir -p "$T/www/admin"; echo '<form><input type="password"></form>' > "$T/www/admin/login"
  R7_ADMIN_LOGIN_PATH=/admin/login apply
  check "apply ok" '[ $RC = 0 ]'
  check "exact login location rendered" 'vhost | grep -q "location = /admin/login {" && vhost | grep -q "limit_req zone=granda_r8_login"'
  local out; out="$(R7_ADMIN_LOGIN_PATH=/admin/login CONNECT_IP=127.0.0.1 CACERT="$CERT_DIR/fullchain.pem" "$KIT/r8_verify.sh" 2>&1)"
  check "verify: login form + rate limit PASS" 'grep -q "PASS        login form" <<<"$out" && grep -q "PASS        login rate limited" <<<"$out"'
  local codes; codes="$(for i in $(seq 12); do status -X POST $(jp /admin/login); echo; done)"
  check "direct: 429 after burst" 'grep -q 429 <<<"$codes"'
  check "rate limit scoped to login path" '[ "$(status $(jp /))" = 200 ]'
}
t22_cert_renewal_states() {
  setup
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/certbot"; chmod +x "$T/bin/certbot"
  check "no mechanism + cert -> FAIL" '[ "$(lib cert_renewal_status | tail -1)" = "CERT_RENEWAL = FAIL" ]'
  echo "0 */12 * * * root certbot -q renew" > "$T/cron/certbot"
  check "cron + 30d cert -> PASS" '[ "$(lib cert_renewal_status | tail -1)" = "CERT_RENEWAL = PASS" ]'
  mkcert "$T/le/live/$DOM" "$DOM" 5
  check "cron + 5d cert -> GAPS" '[ "$(lib cert_renewal_status | tail -1)" = "CERT_RENEWAL = GAPS" ]'
  echo '0 */12 * * * root test -x /usr/bin/certbot -a \! -d /run/systemd/system && certbot -q renew' > "$T/cron/certbot"
  mkdir -p "$T/fake-systemd"; printf '#!/bin/sh\nexit 3\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
  check "systemd host, timer inactive, guarded cron -> FAIL" '[ "$(SYSTEMD_RUN_DIR=$T/fake-systemd lib cert_renewal_status | tail -1)" = "CERT_RENEWAL = FAIL" ]'
  rm -rf "$T/le/live/$DOM"; rm -f "$T/cron/certbot"
  check "no cert yet, no mechanism -> GAPS" '[ "$(lib cert_renewal_status | tail -1)" = "CERT_RENEWAL = GAPS" ]'
}
t23_two_phase_certbot_issue() {
  setup 1 0 1 0
  cat > "$T/bin/certbot" <<'EOF'
#!/bin/sh
[ "$1" = certonly ] || exit 0
mkdir -p "$CERT_DIR" && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN" -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" 2>/dev/null
EOF
  chmod +x "$T/bin/certbot"; apply
  check "apply ok ($OUT)" '[ $RC = 0 ] && grep -q "http phase live" <<<"$OUT" && grep -q "full phase live" <<<"$OUT"'
  check "renewal hook in manifest" 'grep -q granda-r8-nginx-reload.sh "$(readlink -f $T/state/last-apply)/manifest.txt" && [ -x "$T/le/hooks/granda-r8-nginx-reload.sh" ]'
  "$KIT/r8_rollback.sh" >/dev/null 2>&1
  check "rollback removes hook" '[ ! -e "$T/le/hooks/granda-r8-nginx-reload.sh" ]'
}
t24_certbot_failure_rolls_back() {
  setup 1 0 1 0; printf '#!/bin/sh\nexit 1\n' > "$T/bin/certbot"; chmod +x "$T/bin/certbot"
  local before; before="$(nginx_T)"; apply
  check "apply failed" '[ $RC != 0 ] && grep -q "certificate issuance failed" <<<"$OUT"'
  check "config restored" '[ "$before" = "$(nginx_T)" ]'
}
t25_second_apply_refused() {
  setup; apply; local sum; sum="$(vhost | sha1sum)"; apply
  check "second apply refused" '[ $RC != 0 ] && grep -q "already present" <<<"$OUT"'
  check "vhost unchanged" '[ "$(vhost | sha1sum)" = "$sum" ]'
}
t26_input_validation() {
  setup
  DOMAIN='jp.granda-jp.com;evil' apply;            check "bad DOMAIN" '[ $RC != 0 ] && grep -q "invalid DOMAIN" <<<"$OUT"'
  R7_ADMIN_LOGIN_PATH='/a;b' apply;                 check "bad login path" '[ $RC != 0 ] && grep -q "invalid R7_ADMIN_LOGIN_PATH" <<<"$OUT"'
  R7_ADMIN_LOGIN_PATH='/admin/../x' apply;          check "traversal login path" '[ $RC != 0 ] && grep -q "invalid R7_ADMIN_LOGIN_PATH" <<<"$OUT"'
  R7_ROUTE_MANIFEST="$T/does-not-exist" apply;     check "missing manifest file" '[ $RC != 0 ] && grep -q "R7_ROUTE_MANIFEST file not readable" <<<"$OUT"'
  R7_PORT='80 -o x' apply;                          check "bad R7_PORT" '[ $RC != 0 ] && grep -q "invalid R7_PORT" <<<"$OUT"'
  check "nothing installed" '[ "$(jp_files)" = 0 ]'
}
t27_glob_and_wildcard_safety() {
  setup; mkdir -p "$T/cwd"; touch "$T/cwd/static.txt" "$T/cwd/www.example.test.bak"
  (cd "$T/cwd" && "$KIT/r8_apply.sh" >/dev/null 2>&1)
  local run; run="$(readlink -f "$T/state/last-apply")"
  check "targets are exactly the concrete hostnames" '[ "$(tr "\n" " " < "$run/targets.txt")" = "meishi.example.test www.example.test " ]'
}
t28_concurrent_run_locked() {
  setup; mkdir -p "$T/state"; flock "$T/state/.lock" sleep 4 & local holder=$!; sleep 0.5; apply
  check "refused while locked" '[ $RC != 0 ] && grep -q "holds" <<<"$OUT"'
  wait "$holder"
}
t29_interrupt_mid_apply_rolls_back() {
  setup 1 0 1 0; printf '#!/bin/sh\nsleep 3\nexit 0\n' > "$T/bin/certbot"; chmod +x "$T/bin/certbot"
  local before; before="$(nginx_T)"
  "$KIT/r8_apply.sh" > "$T/apply.log" 2>&1 & local ap=$!
  local i; for i in $(seq 50); do grep -q "http phase live" "$T/apply.log" && break; sleep 0.2; done
  kill -TERM "$ap"; wait "$ap"; local rc=$?
  check "apply interrupted (rc=$rc)" '[ $rc != 0 ]'
  check "trap rolled back" 'grep -q "unexpected failure" "$T/apply.log" && grep -q "rollback verified" "$T/apply.log"'
  check "config restored" '[ "$before" = "$(nginx_T)" ]'
}

# ---------------- runner ----------------
pass=0; fail=0; failed=()
for t in $(declare -F | awk '{print $3}' | grep -E '^t[0-9]+_' | sort); do
  [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]] && continue
  T="$ROOT/$t"; mkdir -p "$T"
  ( trap teardown EXIT; FAILS=0; "$t"; exit "$FAILS" ); rc=$?
  if [ "$rc" = 0 ]; then echo "ok    $t"; pass=$((pass+1)); else echo "FAIL  $t"; fail=$((fail+1)); failed+=("$t"); fi
done
echo; echo "TESTS: $((pass+fail))  PASS: $pass  FAIL: $fail ${failed[*]:+(${failed[*]})}"
[ "$fail" = 0 ]
