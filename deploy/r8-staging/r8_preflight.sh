#!/usr/bin/env bash
# READ-ONLY. Records the baseline required before any R8 change and says whether apply
# would be allowed. Changes nothing except writing its report under $STATE_ROOT.
# Usage: sudo [R7_PORT=..] [R7_HEALTH_PATH=..] [R7_ROUTE_MANIFEST=..] ./r8_preflight.sh
set -euo pipefail
umask 077
. "$(dirname "$0")/r8_lib.sh"
need_root
R7_PORT="${1:-${R7_PORT:-}}"
validate_inputs
mkdir -p "$STATE_ROOT"; chmod 700 "$STATE_ROOT"
OUT="$STATE_ROOT/preflight-$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$OUT"
exec > >(tee "$OUT/report.txt") 2>&1
log "preflight -> $OUT"
echo "### RESOURCES";          resources || true
echo "### LISTENING SOCKETS";  ss -ltnpH | sort -k4 || true
echo "### PUBLIC LISTENERS (0.0.0.0 / [::] / *)"; ss -ltnH | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/ {print $4}' | sort -u || true
echo "### NGINX"; nginx -v 2>&1 || true
if ! load_nginx; then echo "NGINX CONFIG INVALID (nginx -T failed) -> apply would ABORT"; exit 0; fi
printf '%s\n' "$NGINX_T_RAW" > "$OUT/nginx-T.txt"
echo "vhost dir: $(nginx_vhost_dir)"
echo "existing concrete server_names:"; existing_server_names | sed 's/^/  /'
names="$(all_server_names)"
if grep -qxF -- "$DOMAIN" <<<"$names"; then echo "$DOMAIN ALREADY CONFIGURED -> apply would ABORT"; else echo "$DOMAIN not configured (expected)"; fi
echo "### LISTEN / DEFAULT_SERVER POLICY"
if plan_listen_policy; then printf '%s\n' "$POLICY_REPORT"; echo "LISTEN_POLICY = OK"
else printf '%s\n' "$POLICY_REPORT"; echo "LISTEN_POLICY = BLOCK (apply would refuse: jp could become the default site)"; fi
echo "### DNS"
PUB_IP="${SERVER_PUBLIC_IP:-$(curl -s -m 5 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 2>/dev/null || true)}"
echo "server public IP: ${PUB_IP:-UNKNOWN}"
dns=""; if command -v dig >/dev/null; then for r in 1.1.1.1 8.8.8.8 119.29.29.29; do a="$(dig +short A "$DOMAIN" @"$r" 2>/dev/null | tr '\n' ' ')"; echo "$DOMAIN @$r: $a"; dns+="$a"; done; fi
if [ -n "$PUB_IP" ] && [ -n "$dns" ] && ! tr ' ' '\n' <<<"$dns" | grep -v '^$' | grep -qvxF -- "$PUB_IP"; then echo "DNS = VERIFIED (all resolvers -> $PUB_IP)"
else echo "DNS = UNVERIFIED (resolvers and server IP do not all agree, or unknown)"; fi
echo "### TLS / RENEWAL"
if [ -f "$CERT_DIR/fullchain.pem" ]; then openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -enddate -ext subjectAltName || true; else echo "no cert at $CERT_DIR"; fi
cert_renewal_status
echo "### R7"
if [ -n "$R7_PORT" ]; then
  r7_socks="$(ss -ltnH "sport = :$R7_PORT" | awk '{print $4}')"; echo "listening: ${r7_socks:-NOTHING}"
  if [ -z "$r7_socks" ]; then echo "R7 BIND: NOT LISTENING"
  elif grep -qvE '^(127\.0\.0\.1|\[::1\]):' <<<"$r7_socks"; then echo "R7 BIND: PUBLIC - apply would refuse"
  else echo "R7 BIND: localhost only (ok)"; fi
  hp="${R7_HEALTH_PATH:-/}"
  echo "GET $hp -> $(curl --noproxy '*' -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1:$R7_PORT$hp" || true)${R7_HEALTH_PATH:+ (health path)}${R7_HEALTH_PATH:- (R7_HEALTH_PATH unset: UNVERIFIED)}"
else
  echo "R7_PORT not given: identify it from LISTENING SOCKETS (127.0.0.1 listener owned by R7)."
fi
if [ -n "$R7_ROUTE_MANIFEST" ]; then
  echo "route manifest: $(manifest_routes | wc -l) routes"; c="$(manifest_blocklist_conflicts)"
  [ -z "$c" ] && echo "blocklist conflicts: none" || echo "blocklist conflicts (apply would refuse): $c"
else echo "R7_ROUTE_MANIFEST unset: routes UNVERIFIED"; fi
echo "### HEALTH BASELINE (fingerprint)"
existing_server_names > "$OUT/targets.txt"
health_snapshot "$OUT/targets.txt" | tee "$OUT/health.txt"
log "done. Nothing was changed."
