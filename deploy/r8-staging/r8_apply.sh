#!/usr/bin/env bash
# Adds ONLY the jp.granda-jp.com vhost to the existing Nginx: backup, nginx -t gate,
# graceful reload, fingerprint health diff, AUTOMATIC ROLLBACK on any regression or error.
# Never restarts Nginx, never edits another vhost, never touches DNS or www.
# Usage: sudo R7_PORT=<port> [R7_ADMIN_LOGIN_PATH=/..] [R7_HEALTH_PATH=/..] \
#             [R7_ROUTE_MANIFEST=file] [R8_HEALTH_URLS=file] [SERVER_PUBLIC_IP=ip] ./r8_apply.sh
set -euo pipefail
umask 077
. "$(dirname "$0")/r8_lib.sh"
need_root
: "${R7_PORT:?set R7_PORT to the existing R7 localhost port}"
validate_inputs
mkdir -p "$STATE_ROOT"; chmod 700 "$STATE_ROOT"
exec 9>"$STATE_ROOT/.lock"; flock -n 9 || die "another r8 run holds $STATE_ROOT/.lock"

# ---- guards (read-only) ----
load_nginx || die "existing nginx config fails nginx -T/-t; not touching it"
r7_socks="$(ss -ltnH "sport = :$R7_PORT" | awk '{print $4}')"
[ -n "$r7_socks" ] || die "nothing listening on :$R7_PORT"
grep -qvE '^(127\.0\.0\.1|\[::1\]):' <<<"$r7_socks" && die "R7 port $R7_PORT is bound publicly ($(tr '\n' ' ' <<<"$r7_socks")); rebind to 127.0.0.1 first"
if [ -n "$R7_HEALTH_PATH" ]; then
  c="$(curl --noproxy '*' -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1:$R7_PORT$R7_HEALTH_PATH" || true)"
  [ "$c" = 200 ] || die "R7 health $R7_HEALTH_PATH -> $c (want 200)"
else
  c="$(curl --noproxy '*' -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1:$R7_PORT/" || true)"
  [[ "$c" =~ ^[1-4] ]] || die "R7 / -> $c"
  log "R7_HEALTH_PATH not set: R7 health UNVERIFIED (only / -> $c checked)"
fi
names="$(all_server_names)"; grep -qxF -- "$DOMAIN" <<<"$names" && die "$DOMAIN already present in nginx config (re-run? use r8_rollback.sh first)"
case "$(nginx_vhost_dir)" in
  sites-enabled) VHOST="$NGINX_DIR/sites-available/$DOMAIN.conf"; LINK="$NGINX_DIR/sites-enabled/$DOMAIN.conf" ;;
  conf.d)        VHOST="$NGINX_DIR/conf.d/$DOMAIN.conf"; LINK="" ;;
  *) die "cannot detect vhost include dir under $NGINX_DIR" ;;
esac
SNIPPET="$NGINX_DIR/granda-r8-proxy.inc"
HOOK="$RENEW_HOOK_DIR/granda-r8-nginx-reload.sh"
for f in "$VHOST" "$SNIPPET" "$HOOK" ${LINK:+"$LINK"}; do [ ! -e "$f" ] || die "$f already exists; refusing to overwrite"; done
conf="$(manifest_blocklist_conflicts)"; [ -z "$conf" ] || die "R7 routes would be blocked by staging blocklist: $(tr '\n' ' ' <<<"$conf")"
[ -n "$R7_ROUTE_MANIFEST" ] || log "R7_ROUTE_MANIFEST not set: blocklist/route compatibility UNVERIFIED"
[ -n "$R7_ADMIN_LOGIN_PATH" ] || log "R7_ADMIN_LOGIN_PATH not set: login rate limit NOT configured (UNVERIFIED)"
if ! plan_listen_policy; then
  printf '%s\n' "$POLICY_REPORT"
  die "default_server not explicit on a shared socket: $DOMAIN could become the bare-IP/unknown-host site. Mark the intended existing site default_server (ops decision), then re-run."
fi
printf '%s\n' "$POLICY_REPORT"
if [ -n "$R_SINKS" ]; then
  ver="$(nginx -v 2>&1)"; grep -qE 'nginx/(1\.(19\.([4-9]|[1-9][0-9])|[2-9][0-9])|[2-9])' <<<"$ver" || die "default sink needs nginx >= 1.19.4 (ssl_reject_handshake)"
fi

# ---- backup + manifest ----
RUN="$STATE_ROOT/apply-$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$RUN"
tar -C "$(dirname "$NGINX_DIR")" -czf "$RUN/nginx.before.tgz" "$(basename "$NGINX_DIR")"
printf '%s\n' "$NGINX_T_RAW" > "$RUN/nginx-T.before.txt"
resources > "$RUN/resources.before.txt" 2>&1 || true
existing_server_names > "$RUN/targets.txt"
health_snapshot "$RUN/targets.txt" > "$RUN/health.before.txt"; sleep 1
health_snapshot "$RUN/targets.txt" > "$RUN/health.before2.txt"
printf '%s\n' "$VHOST" "$SNIPPET" ${LINK:+"$LINK"} > "$RUN/manifest.txt"
ln -sfn "$RUN" "$STATE_ROOT/last-apply"
MASTER_PID="$(nginx_master_pid)"
log "backup + manifest in $RUN"

INSTALLED=0; DONE=0
rollback() { DONE=1; log "ROLLBACK: $1"; r8_restore "$RUN" || true; die "rolled back ($1); see $RUN"; }
on_exit() { local rc=$?; if [ "$rc" != 0 ] && [ "$INSTALLED" = 1 ] && [ "$DONE" = 0 ]; then DONE=1; log "unexpected failure (rc=$rc): rolling back"; r8_restore "$RUN" || true; fi; }
trap on_exit EXIT
trap 'exit 130' INT TERM HUP   # interrupted mid-change => EXIT trap rolls back

install_and_reload() {  # $1 = http | full
  INSTALLED=1
  render_vhost "$1" > "$VHOST"; render_proxy_snippet > "$SNIPPET"; chmod 644 "$VHOST" "$SNIPPET"
  [ -z "$LINK" ] || ln -sfn "$VHOST" "$LINK"
  cp -- "$VHOST" "$RUN/vhost.$1.conf"
  if ! nginx_cmd -t > "$RUN/nginx-t.$1.txt" 2>&1; then cat "$RUN/nginx-t.$1.txt"; rollback "nginx -t failed ($1)"; fi
  nginx_cmd -s reload; sleep "$RELOAD_WAIT"
  [ "$(nginx_master_pid)" = "$MASTER_PID" ] || rollback "nginx master PID changed (not a graceful reload)"
  health_snapshot "$RUN/targets.txt" > "$RUN/health.after.$1.txt"
  local reg; reg="$(health_regressions "$RUN/health.before.txt" "$RUN/health.before2.txt" "$RUN/health.after.$1.txt")"
  [ -z "$reg" ] || { printf '%s\n' "$reg"; rollback "existing site/service regression after $1"; }
  local c
  if [ "$1" = http ]; then
    c="$(curl --noproxy '*' -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$DOMAIN:$HTTP_PORT:127.0.0.1" "http://$DOMAIN:$HTTP_PORT/" || true)"
    [ "$c" = 301 ] || rollback "$DOMAIN http -> $c (want 301)"
  else
    c="$(curl --noproxy '*' -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" "https://$DOMAIN:$HTTPS_PORT/" || true)"
    [[ "$c" =~ ^[1-4] ]] || rollback "$DOMAIN https -> $c"
  fi
  log "$1 phase live; existing sites/bare-IP/unknown-host/services unchanged"
}

# ---- phase 1: HTTP vhost + certificate (only if no valid cert for this exact host) ----
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1 \
   || ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -qF "DNS:$DOMAIN"; then
  command -v certbot >/dev/null || die "certbot missing (apt-get install -y certbot), then re-run"
  mkdir -p "$ACME_ROOT"; chmod 755 "$ACME_ROOT"
  install_and_reload http
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN" \
      --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
    || rollback "certificate issuance failed (check DNS points here and port $HTTP_PORT is reachable)"
  mkdir -p "$RENEW_HOOK_DIR"
  printf '#!/bin/sh\nnginx%s -t && nginx%s -s reload\n' "${NGINX_CONF:+ -c $NGINX_CONF}" "${NGINX_CONF:+ -c $NGINX_CONF}" > "$HOOK"
  chmod 755 "$HOOK"; echo "$HOOK" >> "$RUN/manifest.txt"
fi

# ---- phase 2: full HTTPS staging vhost ----
install_and_reload full
nginx_cmd -T > "$RUN/nginx-T.after.txt" 2>&1
resources > "$RUN/resources.after.txt" 2>&1 || true
cert_renewal_status | sed 's/^/  /'
DONE=1
log "R8 vhost live. Rollback: sudo $KIT_DIR/r8_rollback.sh   (manifest: $RUN/manifest.txt)"
log "Next: run r8_verify.sh from an EXTERNAL device."
