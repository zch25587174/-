#!/usr/bin/env bash
# READ-ONLY. Records the baseline required before any R8 change (task sections 3, 4, 7, 8).
# Changes nothing on the server. Usage: sudo ./r8_preflight.sh [R7_PORT]
set -uo pipefail
. "$(dirname "$0")/r8_lib.sh"
need_root
R7_PORT="${1:-${R7_PORT:-}}"
TS="$(date +%Y%m%d-%H%M%S)"; OUT="$STATE_ROOT/preflight-$TS"; mkdir -p "$OUT"; chmod 700 "$STATE_ROOT"
exec > >(tee "$OUT/report.txt") 2>&1

log "preflight -> $OUT"
echo "### RESOURCES";               resources
echo "### LISTENING SOCKETS";       ss -ltnpH | sort -k4
echo "### PUBLIC (0.0.0.0/[::]) LISTENERS"; ss -ltnH | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/ {print $4}' | sort -u
echo "### RUNNING SERVICES";        systemctl list-units --type=service --state=running --no-legend --plain | awk '{print $1}'
echo "### PM2 / DOCKER";            (command -v pm2 >/dev/null && pm2 jlist 2>/dev/null | head -c 4000; echo) ; (command -v docker >/dev/null && docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}')
echo "### NGINX";                   nginx -v 2>&1; systemctl is-active nginx; nginx -t 2>&1 | tail -2
echo "vhost dir: $(nginx_vhost_dir)"
nginx -T > "$OUT/nginx-T.txt" 2>&1
echo "existing server_names:"; existing_server_names | sed 's/^/  /'
echo "### $DOMAIN ALREADY CONFIGURED?"
grep -nE "server_name[^;]*\b${DOMAIN//./\\.}\b" "$OUT/nginx-T.txt" && echo "YES - STOP: inspect before adding a vhost" || echo "no (expected)"
echo "### DNS"
PUB_IP="$(curl -s -m 5 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 || true)"
echo "server public IP (Tencent metadata): ${PUB_IP:-UNKNOWN}"
for r in 1.1.1.1 8.8.8.8 119.29.29.29; do echo "$DOMAIN @$r: $(dig +short A "$DOMAIN" @"$r" 2>/dev/null | tr '\n' ' ')"; done
echo "NS: $(dig +short NS "${DOMAIN#*.}" 2>/dev/null | tr '\n' ' ')"
echo "### TLS"
if [ -d "$CERT_DIR" ]; then openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -enddate -ext subjectAltName; else echo "no cert at $CERT_DIR"; fi
command -v certbot >/dev/null && certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' || echo "certbot: not installed"
echo "### R7 APP"
if [ -n "$R7_PORT" ]; then
  ss -ltnpH "sport = :$R7_PORT"
  ss -ltnH "sport = :$R7_PORT" | awk '{print $4}' | grep -qvE '^(127\.0\.0\.1|\[::1\]):' && echo "R7 BIND: PUBLIC - FIX BEFORE R8" || echo "R7 BIND: localhost only (ok)"
  echo "GET / -> $(curl --noproxy "*" -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1:$R7_PORT/")"
  echo "GET /admin/ -> $(curl --noproxy "*" -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1:$R7_PORT/admin/")"
else
  echo "R7_PORT not given: identify it from LISTENING SOCKETS above (127.0.0.1 listener owned by the R7 process)."
fi
echo "### HEALTH BASELINE"; health_snapshot | tee "$OUT/health.txt"
log "done. Nothing was changed."
