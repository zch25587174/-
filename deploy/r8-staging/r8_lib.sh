#!/usr/bin/env bash
# Shared helpers for the GrandA R8 staging kit. Sourced, not executed.
DOMAIN="${DOMAIN:-jp.granda-jp.com}"
ACME_ROOT="${ACME_ROOT:-/var/www/granda-r8-acme}"
CERT_DIR="${CERT_DIR:-/etc/letsencrypt/live/$DOMAIN}"
STATE_ROOT="${STATE_ROOT:-/root/granda-r8}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[r8 %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { log "ABORT: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# Where this server's Nginx loads vhosts from (read-only detection).
nginx_vhost_dir() {
  local dump; dump="$(nginx -T 2>/dev/null)"
  if grep -qE '^\s*include\s+/etc/nginx/sites-enabled/' <<<"$dump"; then echo sites-enabled
  elif grep -qE '^\s*include\s+/etc/nginx/conf\.d/' <<<"$dump"; then echo conf.d
  else echo unknown; fi
}

# Every server_name Nginx currently serves, except wildcards/defaults and our domain.
existing_server_names() {
  nginx -T 2>/dev/null | grep -v '^\s*#' | grep -oE '\bserver_name\s+[^;]+' | sed -E 's/^server_name\s+//' \
    | tr ' ' '\n' | grep -vE '^(_|localhost|\*.*|~.*|)$' | grep -vxF "$DOMAIN" | sort -u
}

# Snapshot of existing sites + services. Output is diffable line-by-line.
health_snapshot() {
  local n
  for n in $(existing_server_names); do
    printf 'site %s https %s\n' "$n" "$(curl --noproxy '*' -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$n:443:127.0.0.1" "https://$n/")"
    printf 'site %s http %s\n'  "$n" "$(curl --noproxy '*' -s  -o /dev/null -m 10 -w '%{http_code}' --resolve "$n:80:127.0.0.1"  "http://$n/")"
  done
  { systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null || true; } | awk '{print "svc " $1}' | sort
  if command -v docker >/dev/null; then { docker ps --format 'ctr {{.Names}}' 2>/dev/null || true; } | sort; fi
  if command -v pm2 >/dev/null; then { pm2 jlist 2>/dev/null || true; } | python3 -c 'import json,sys
try: [print("pm2",p["name"]) for p in json.load(sys.stdin) if p["pm2_env"]["status"]=="online"]
except Exception: pass' | sort; fi
}

# Regression = a site that answered before now returns 000/5xx, or a running service/container vanished.
health_regressions() {
  local before="$1" after="$2"
  awk 'NR==FNR { b[$1" "$2" "$3]=$4; seen[$0]=1; next }
       $1=="site" { k=$1" "$2" "$3; if ((k in b) && b[k] !~ /^(000|5)/ && $4 ~ /^(000|5)/) print "SITE_DOWN " k " " b[k] "->" $4; next }' \
       "$before" "$after"
  comm -23 <(grep -E '^(svc|ctr|pm2) ' "$before" | sort) <(grep -E '^(svc|ctr|pm2) ' "$after" | sort) | sed 's/^/STOPPED /'
}

resources() {
  echo "== uptime/load"; uptime
  echo "== memory";      free -m
  echo "== disk";        df -h / /var 2>/dev/null
  echo "== top cpu";     ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu | head -12
}
