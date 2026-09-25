#!/usr/bin/env bash
# Adds ONLY the jp.granda-jp.com vhost to the existing Nginx, with backup, nginx -t gate,
# graceful reload, post-reload health diff, and AUTOMATIC ROLLBACK on any regression.
# Never restarts Nginx, never edits another vhost, never touches DNS or www.
# Usage: sudo R7_PORT=<port> ./r8_apply.sh
set -euo pipefail
. "$(dirname "$0")/r8_lib.sh"
need_root
: "${R7_PORT:?set R7_PORT to the existing R7 localhost port}"
[[ "$R7_PORT" =~ ^[0-9]+$ ]] || die "R7_PORT must be numeric"

# ---- guards (no changes yet) ----
nginx -t >/dev/null 2>&1 || die "existing nginx config already fails nginx -t; not touching it"
ss -ltnH "sport = :$R7_PORT" | grep -q . || die "nothing listening on :$R7_PORT"
ss -ltnH "sport = :$R7_PORT" | awk '{print $4}' | grep -qvE '^(127\.0\.0\.1|\[::1\]):' && die "R7 port $R7_PORT is bound publicly; rebind to 127.0.0.1 first"
nginx -T 2>/dev/null | grep -qE "server_name[^;]*\b${DOMAIN//./\\.}\b" && die "$DOMAIN already present in nginx config; inspect manually"

case "$(nginx_vhost_dir)" in
  sites-enabled) VHOST=/etc/nginx/sites-available/$DOMAIN.conf; LINK=/etc/nginx/sites-enabled/$DOMAIN.conf ;;
  conf.d)        VHOST=/etc/nginx/conf.d/$DOMAIN.conf; LINK="" ;;
  *) die "cannot detect vhost include dir" ;;
esac
SNIPPET=/etc/nginx/granda-r8-proxy.inc

# ---- backup + manifest ----
TS="$(date +%Y%m%d-%H%M%S)"; RUN="$STATE_ROOT/apply-$TS"; mkdir -p "$RUN"; chmod 700 "$STATE_ROOT"
tar -C / -czf "$RUN/etc-nginx.before.tgz" etc/nginx
nginx -T > "$RUN/nginx-T.before.txt" 2>&1
resources > "$RUN/resources.before.txt"
health_snapshot > "$RUN/health.before.txt"
MANIFEST="$RUN/manifest.txt"
printf '%s\n' "$VHOST" "$SNIPPET" ${LINK:+"$LINK"} > "$MANIFEST"
ln -sfn "$RUN" "$STATE_ROOT/last-apply"
log "backup + manifest in $RUN"

rollback() {
  log "ROLLBACK: $1"
  while read -r f; do rm -f -- "$f"; done < "$MANIFEST"
  if nginx -t >/dev/null 2>&1; then nginx -s reload; sleep 2; else
    log "nginx -t fails after removing R8 files; restoring full /etc/nginx backup"
    tar -C / -xzf "$RUN/etc-nginx.before.tgz"; nginx -t && nginx -s reload; sleep 2
  fi
  health_snapshot > "$RUN/health.after-rollback.txt"
  health_regressions "$RUN/health.before.txt" "$RUN/health.after-rollback.txt" || true
  die "rolled back ($1). Original state restored; see $RUN"
}

# Mirror the server: emit IPv6 listeners only if existing vhosts already listen on [::].
IPV6=no; nginx -T 2>/dev/null | grep -qE '^\s*listen\s+\[::\]' && IPV6=yes
render() { { [ "$IPV6" = yes ] && cat "$KIT_DIR/$1" || grep -vE '^\s*listen\s+\[::\]' "$KIT_DIR/$1"; } | sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__R7_PORT__#$R7_PORT#g" -e "s#__ACME_ROOT__#$ACME_ROOT#g" \
               -e "s#__CERT_DIR__#$CERT_DIR#g" -e "s#__PROXY_SNIPPET__#$SNIPPET#g"; }

install_and_reload() {  # $1 = template name
  render "$1" > "$VHOST"; render granda-r8-proxy.inc.tmpl > "$SNIPPET"
  [ -n "$LINK" ] && ln -sfn "$VHOST" "$LINK"
  if ! nginx -t > "$RUN/nginx-t.$1.txt" 2>&1; then cat "$RUN/nginx-t.$1.txt"; rollback "nginx -t failed for $1"; fi
  nginx -s reload; sleep 3
  health_snapshot > "$RUN/health.after.$1.txt"
  local reg; reg="$(health_regressions "$RUN/health.before.txt" "$RUN/health.after.$1.txt")"
  [ -z "$reg" ] || { echo "$reg"; rollback "existing service regression after $1"; }
  log "$1 live; existing services unchanged"
}

# ---- phase 1: HTTP vhost + certificate (only if no valid cert for this exact host) ----
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1 \
   || ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$DOMAIN"; then
  command -v certbot >/dev/null || die "certbot missing. Install it (apt-get install -y certbot) - installs a package only, no service changes - then re-run"
  mkdir -p "$ACME_ROOT"
  install_and_reload jp.granda-jp.com.http.conf.tmpl
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN" \
      --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
    || rollback "certificate issuance failed (check DNS points here and port 80 is open)"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nnginx -t && nginx -s reload\n' > /etc/letsencrypt/renewal-hooks/deploy/granda-r8-nginx-reload.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/granda-r8-nginx-reload.sh
  echo /etc/letsencrypt/renewal-hooks/deploy/granda-r8-nginx-reload.sh >> "$MANIFEST"
fi

# ---- phase 2: full HTTPS staging vhost ----
install_and_reload jp.granda-jp.com.conf.tmpl
nginx -T > "$RUN/nginx-T.after.txt" 2>&1
diff <(grep -v "$DOMAIN" "$RUN/nginx-T.before.txt") <(grep -v "$DOMAIN" "$RUN/nginx-T.after.txt") > "$RUN/nginx-T.diff" || true
resources > "$RUN/resources.after.txt"
log "R8 vhost live. Rollback path: sudo $KIT_DIR/r8_rollback.sh   (manifest: $MANIFEST)"
log "Next: run r8_verify.sh from an EXTERNAL machine."
