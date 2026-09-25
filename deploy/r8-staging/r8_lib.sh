#!/usr/bin/env bash
# Shared helpers for the GrandA R8 staging kit. Sourced, not executed.
# Every path/port is overridable so tests/run_tests.sh can drive a throwaway Nginx
# on high ports; defaults are the real server layout.
DOMAIN="${DOMAIN:-jp.granda-jp.com}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
NGINX_CONF="${NGINX_CONF:-}"                      # empty = nginx's compiled-in default
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
ACME_ROOT="${ACME_ROOT:-/var/www/granda-r8-acme}"
CERT_DIR="${CERT_DIR:-/etc/letsencrypt/live/$DOMAIN}"
RENEW_HOOK_DIR="${RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
STATE_ROOT="${STATE_ROOT:-/root/granda-r8}"
RELOAD_WAIT="${RELOAD_WAIT:-3}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-}"          # Host header for bare-IP probes
SYSTEMD_RUN_DIR="${SYSTEMD_RUN_DIR:-/run/systemd/system}"
R8_CRON_PATHS="${R8_CRON_PATHS:-/etc/crontab /etc/cron.d /var/spool/cron}"
# Facts only R7's source/operator can supply. Unset => related checks report UNVERIFIED.
R7_ADMIN_LOGIN_PATH="${R7_ADMIN_LOGIN_PATH:-}"
R7_HEALTH_PATH="${R7_HEALTH_PATH:-}"
R7_ROUTE_MANIFEST="${R7_ROUTE_MANIFEST:-}"        # file: "<path> [expected_status]" per line
R8_HEALTH_URLS="${R8_HEALTH_URLS:-}"              # file: "<name> <url>" per line (existing services)
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for what staging never serves: rendered into the vhost,
# probed by r8_verify.sh, and checked against the R7 route manifest.
BLOCKED_EXTS='env|sql|sqlite|sqlite3|db|dump|bak|backup|old|orig|swp|log|tar|tgz|gz|zip|7z|rar|ini|conf|pem|key'
BLOCKED_DIRS='backups?|dumps?|logs?|node_modules|storage/logs'
# shellcheck disable=SC2034  # used by r8_verify.sh
SENSITIVE_PROBES=(/.env /.git/HEAD /.git/config /backup.sql /db.sqlite /dump.sql.gz /backups/ /logs/ /app.log /config.bak /.DS_Store /server.key)

log()  { printf '[r8 %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { log "ABORT: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# Everything interpolated into Nginx config or commands is validated here (no quoting games).
validate_inputs() {
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "invalid DOMAIN"
  local p v
  for p in HTTP_PORT HTTPS_PORT ${R7_PORT:+R7_PORT}; do
    v="${!p}"; [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || die "invalid $p"
  done
  for p in R7_ADMIN_LOGIN_PATH R7_HEALTH_PATH; do
    v="${!p}"; [ -z "$v" ] || [[ "$v" =~ ^/[A-Za-z0-9._~/-]*$ && "$v" != *..* ]] || die "invalid $p (allowed: /[A-Za-z0-9._~/-])"
  done
  for p in NGINX_DIR ACME_ROOT CERT_DIR RENEW_HOOK_DIR STATE_ROOT; do
    v="${!p}"; [[ "$v" =~ ^/[A-Za-z0-9._/-]+$ && "$v" != *..* ]] || die "invalid $p"
  done
  for p in R7_ROUTE_MANIFEST R8_HEALTH_URLS; do v="${!p}"; [ -z "$v" ] || [ -r "$v" ] || die "$p file not readable: $v"; done
  [ -z "$NGINX_CONF" ] || [[ "$NGINX_CONF" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid NGINX_CONF"
  [ -z "$SERVER_PUBLIC_IP" ] || [[ "$SERVER_PUBLIC_IP" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid SERVER_PUBLIC_IP"
}

nginx_cmd() { if [ -n "$NGINX_CONF" ]; then nginx -c "$NGINX_CONF" "$@"; else nginx "$@"; fi; }
nginx_master_pid() {  # uses the parsed config's pid directive (needs load_nginx)
  local f; f="$(awk '$1=="pid"{sub(/;$/,"",$2); print $2; exit}' <<<"$NGINX_STMTS")"
  cat -- "${f:-/run/nginx.pid}" 2>/dev/null || true
}

# Parse the live config ONCE per run: comment-stripped `nginx -T`, one statement per line.
load_nginx() {
  NGINX_T_RAW="$(nginx_cmd -T 2>/dev/null)" || return 1
  NGINX_STMTS="$(printf '%s\n' "$NGINX_T_RAW" \
    | sed -E -e 's/^[[:space:]]*#.*$//' -e "s/[[:space:]]+#[^\"']*\$//" \
    | tr '\n\t' '  ' | sed -E 's/([;{}])/\1\n/g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g')"
}
all_server_names() { awk '$1=="server_name"{sub(/;$/,""); for(i=2;i<=NF;i++) print $i}' <<<"$NGINX_STMTS" | sort -u; }
# Concrete hostnames of existing sites (wildcards/regex/catch-alls cannot be probed).
existing_server_names() { all_server_names | grep -vE '^(_|localhost|""|)$|[*]|^~' | grep -vxF -- "$DOMAIN" || true; }
nginx_vhost_dir() {
  if   grep -qF "include $NGINX_DIR/sites-enabled/" <<<"$NGINX_STMTS"; then echo sites-enabled
  elif grep -qF "include $NGINX_DIR/conf.d/"        <<<"$NGINX_STMTS"; then echo conf.d
  else echo unknown; fi
}
# "<socket> <default 0|1> <http2 0|1>" for every listen. Bare port / 0.0.0.0 => "*:port".
nginx_listens() {
  awk '$1=="listen"{ sub(/;$/,""); a=$2; if (a ~ /^unix:/) next
         if (a ~ /^[0-9]+$/) a="*:" a; sub(/^0\.0\.0\.0:/,"*:",a)
         d=0; h=0; for(i=3;i<=NF;i++){ if($i=="default_server"||$i=="default") d=1; if($i=="http2") h=1 }
         print a, d, h }' <<<"$NGINX_STMTS"
}

# Decide how the jp vhost listens WITHOUT changing any existing site's behaviour.
#  - never `default_server` for DOMAIN; never listen-level `http2` (it is per address:port
#    in Nginx <1.25 and would switch every site on :443 to HTTP/2).
#  - a socket that already serves sites MUST already have an explicit default_server,
#    otherwise DOMAIN could become the bare-IP/unknown-host landing site => BLOCK (fail closed).
#  - a socket nobody listened on gets a reject-only default sink (was: connection refused).
# Sets R_LISTEN_HTTP R_LISTEN_HTTPS R_SINKS R_HTTP2 IPV6 HTTP2_MODE POLICY_REPORT; returns 1 on BLOCK.
plan_listen_policy() {
  local listens sock n d kind blocked=0 sink_ssl socks
  listens="$(nginx_listens)"
  IPV6=no; grep -q '^\[::\]:' <<<"$listens" && IPV6=yes
  HTTP2_MODE=off
  [ -n "$(awk -v a="*:$HTTPS_PORT" -v b="[::]:$HTTPS_PORT" '$3==1 && ($1==a || $1==b)' <<<"$listens")" ] && HTTP2_MODE=listen-level
  grep -qE '^http2 on;' <<<"$NGINX_STMTS" && HTTP2_MODE=directive
  R_HTTP2=""; [ "$HTTP2_MODE" = directive ] && R_HTTP2="http2 on;"
  R_LISTEN_HTTP="listen $HTTP_PORT;"; R_LISTEN_HTTPS="listen $HTTPS_PORT ssl;"
  if [ "$IPV6" = yes ]; then
    R_LISTEN_HTTP+=$'\n'"listen [::]:$HTTP_PORT;"; R_LISTEN_HTTPS+=$'\n'"listen [::]:$HTTPS_PORT ssl;"
  fi
  R_SINKS=""; POLICY_REPORT=""
  socks=("*:$HTTP_PORT" "*:$HTTPS_PORT"); [ "$IPV6" = yes ] && socks+=("[::]:$HTTP_PORT" "[::]:$HTTPS_PORT")
  for sock in "${socks[@]}"; do
    n="$(awk -v s="$sock" '$1==s' <<<"$listens" | wc -l)"
    d="$(awk -v s="$sock" '$1==s && $2==1' <<<"$listens" | wc -l)"
    if [ "$n" -gt 0 ] && [ "$d" -gt 0 ]; then kind="OK existing explicit default_server"
    elif [ "$n" -gt 0 ]; then kind="BLOCK $n existing server(s), no explicit default_server"; blocked=1
    else
      kind="SINK no existing listener -> reject-only default sink"
      [[ "$sock" == *":$HTTPS_PORT" ]] && sink_ssl=" ssl" || sink_ssl=""
      R_SINKS+="server {"$'\n'"    listen ${sock#\*:}$sink_ssl default_server;"$'\n'"    server_name _;"$'\n'
      [ -n "$sink_ssl" ] && R_SINKS+="    ssl_reject_handshake on;"$'\n'
      R_SINKS+="    return 444;"$'\n'"}"$'\n'
    fi
    POLICY_REPORT+="  $sock: $kind"$'\n'
  done
  POLICY_REPORT+="  HTTP2 mirror: $HTTP2_MODE (jp never sets listen-level http2)"$'\n'"  IPv6 listeners: $IPV6"
  [ "$blocked" = 0 ]
}

# Render the vhost. $1 = http (ACME phase, no HTTPS server) | full.
render_vhost() {
  local zone="" loc=""
  if [ -n "$R7_ADMIN_LOGIN_PATH" ]; then
    zone='limit_req_zone $binary_remote_addr zone=granda_r8_login:10m rate=10r/m;'
    loc="location = $R7_ADMIN_LOGIN_PATH {"$'\n'"    limit_req zone=granda_r8_login burst=5 nodelay;"$'\n'"    limit_req_status 429;"$'\n'"    include $NGINX_DIR/granda-r8-proxy.inc;"$'\n'"}"
  fi
  R_PHASE="$1" R_DOMAIN="$DOMAIN" R_ACME="$ACME_ROOT" R_CERT="$CERT_DIR" R_SNIP="$NGINX_DIR/granda-r8-proxy.inc" \
  R_EXTS="$BLOCKED_EXTS" R_DIRS="$BLOCKED_DIRS" R_LISTEN_HTTP="$R_LISTEN_HTTP" R_LISTEN_HTTPS="$R_LISTEN_HTTPS" \
  R_SINKS="$R_SINKS" R_HTTP2="$R_HTTP2" R_LOGIN_ZONE="$zone" R_LOGIN_LOCATION="$loc" \
  awk '
    /@@HTTPS_BEGIN/ { skip = (ENVIRON["R_PHASE"] == "http"); next }
    /@@HTTPS_END/   { skip = 0; next }
    skip { next }
    { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t ~ /^__(LISTEN_HTTP|LISTEN_HTTPS|SINKS|HTTP2|LOGIN_ZONE|LOGIN_LOCATION)__$/) {
        v = ENVIRON["R_" substr(t, 3, length(t) - 4)]; ind = substr($0, 1, match($0, /[^ \t]/) - 1)
        n = split(v, L, "\n"); for (i = 1; i <= n; i++) if (L[i] != "") print ind L[i]
        next }
      gsub(/__DOMAIN__/, ENVIRON["R_DOMAIN"]); gsub(/__ACME_ROOT__/, ENVIRON["R_ACME"])
      gsub(/__CERT_DIR__/, ENVIRON["R_CERT"]); gsub(/__PROXY_SNIPPET__/, ENVIRON["R_SNIP"])
      gsub(/__BLOCKED_EXTS__/, ENVIRON["R_EXTS"]); gsub(/__BLOCKED_DIRS__/, ENVIRON["R_DIRS"])
      print }' "$KIT_DIR/jp.granda-jp.com.conf.tmpl"
}
render_proxy_snippet() { sed "s/__R7_PORT__/$R7_PORT/g" "$KIT_DIR/granda-r8-proxy.inc.tmpl"; }

# Paths in the R7 manifest that the staging blocklist would 404 (must be empty to apply).
manifest_routes() { [ -n "$R7_ROUTE_MANIFEST" ] && sed -E 's/#.*//' "$R7_ROUTE_MANIFEST" | awk 'NF{print $1, ($2 ? $2 : 200)}'; }
manifest_blocklist_conflicts() {
  manifest_routes | awk '{print $1}' | grep -E "/\.[^w/]|\.($BLOCKED_EXTS)(\?|$)|^/($BLOCKED_DIRS)(/|$)" || true
}

# ---------- health fingerprint (regression detection) ----------
# Stable per-target facts, tab-separated "<target>\t<field>\t<value>". No full-body hashes:
# only status, protocol, redirect target (query stripped), critical headers, <title> hash, cert.
_probe() {  # target url [curl args...]
  local target="$1" url="$2"; shift 2
  local h b meta code ver
  h="$(mktemp)"; b="$(mktemp)"
  meta="$(curl --noproxy '*' -sk -m 10 -D "$h" -o "$b" -w '%{http_code} %{http_version}' "$@" "$url" 2>/dev/null)" || true
  read -r code ver <<<"$meta"
  printf '%s\tstatus\t%s\n%s\tproto\t%s\n' "$target" "${code:-000}" "$target" "${ver:-0}"
  local f v
  for f in location content-type x-robots-tag strict-transport-security x-frame-options; do
    v="$(tr -d '\r' <"$h" | awk -v f="$f" 'tolower($1)==f":" {sub(/^[^:]*:[ ]*/,""); print; exit}')"
    [ "$f" = location ] && v="${v%%\?*}"
    printf '%s\thdr.%s\t%s\n' "$target" "$f" "${v:--}"
  done
  printf '%s\ttitle\t%s\n' "$target" "$(grep -oi '<title>[^<]*' "$b" | head -1 | sha1sum | cut -c1-12)"
  rm -f -- "$h" "$b"
}
_cert() {  # target port [servername]
  local sni=(-noservername); [ -n "${3:-}" ] && sni=(-servername "$3")
  printf '%s\tcert\t%s\n' "$1" "$(timeout 10 openssl s_client -connect "127.0.0.1:$2" "${sni[@]}" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | sha1sum | cut -c1-12)"
}
health_snapshot() {  # $1 = file of existing hostnames (fixed at baseline)
  local n ip="${SERVER_PUBLIC_IP:-127.0.0.1}" unk="r8-unknown-host.invalid"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    _probe "site:$n:http"  "http://$n:$HTTP_PORT/"   --resolve "$n:$HTTP_PORT:127.0.0.1"
    _probe "site:$n:https" "https://$n:$HTTPS_PORT/" --resolve "$n:$HTTPS_PORT:127.0.0.1"
    _cert  "site:$n:https" "$HTTPS_PORT" "$n"
  done < "$1"
  _probe "bare:http"  "http://127.0.0.1:$HTTP_PORT/" -H "Host: $ip"
  _probe "bare:https" "https://127.0.0.1:$HTTPS_PORT/"
  _cert  "bare:https" "$HTTPS_PORT"
  _probe "unknown:http"  "http://$unk:$HTTP_PORT/"   --resolve "$unk:$HTTP_PORT:127.0.0.1"
  _probe "unknown:https" "https://$unk:$HTTPS_PORT/" --resolve "$unk:$HTTPS_PORT:127.0.0.1"
  _cert  "unknown:https" "$HTTPS_PORT" "$unk"
  # Services: only what is healthy/running now is tracked; missing or changed later = regression.
  if [ -d "$SYSTEMD_RUN_DIR" ] && command -v systemctl >/dev/null; then
    { systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null || true; } \
      | awk '{printf "svc:%s\tstate\trunning\n", $1}'
  fi
  if command -v docker >/dev/null; then
    { docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || true; } | awk -F'|' '{
        h="nohealthcheck"; if ($2 ~ /\(healthy\)/) h="healthy"; else if ($2 ~ /\(unhealthy\)/) h="unhealthy"; else if ($2 ~ /health: starting/) h="starting"
        printf "ctr:%s\tstate\trunning:%s\n", $1, h }'
  fi
  if command -v pm2 >/dev/null; then
    { pm2 jlist 2>/dev/null || true; } | python3 -c 'import json,sys
try:
    for p in json.load(sys.stdin):
        if p["pm2_env"]["status"] == "online": print("pm2:%s\tstate\tonline" % p["name"])
except Exception: pass'
  fi
  if [ -n "$R8_HEALTH_URLS" ] && [ -f "$R8_HEALTH_URLS" ]; then
    local name url
    while read -r name url _; do
      [[ -z "$name" || "$name" == \#* ]] && continue
      printf 'url:%s\tstatus\t%s\n' "$name" "$(curl --noproxy '*' -s -o /dev/null -m 10 -w '%{http_code}' -- "$url" 2>/dev/null || echo 000)"
    done < "$R8_HEALTH_URLS"
  fi
  true
}
# $1,$2 = two baseline samples (fields that differ between them are dynamic and ignored)
# $3 = post-change sample. Targets already failing (000/5xx) at baseline are ignored.
health_regressions() {
  awk -F'\t' '
    FNR==1 { f++ }
    f==1 { k=$1 FS $2; b[k]=$3; tg[k]=$1; if ($2=="status" && $3 ~ /^(000|5)/) bad[$1]=1; next }
    f==2 { k=$1 FS $2; s2[k]=1; if ((k in b) && b[k]!=$3) dyn[k]=1; next }
         { a[$1 FS $2]=$3 }
    END { for (k in b) { if ((k in dyn) || !(k in s2) || (tg[k] in bad)) continue
            if (!(k in a)) print "MISSING\t" k "\t(was " b[k] ")"
            else if (a[k] != b[k]) print "CHANGED\t" k "\t" b[k] " -> " a[k] } }' "$1" "$2" "$3" | sort
}

# ---------- certificate renewal ----------
# CERT_RENEWAL = PASS | GAPS | FAIL (no email is NOT a failure). Prints details, sets CERT_RENEWAL.
cert_renewal_status() {
  local mech="" days="" p
  if command -v certbot >/dev/null; then
    if [ -d "$SYSTEMD_RUN_DIR" ] && command -v systemctl >/dev/null; then
      for p in certbot.timer snap.certbot.renew.timer; do systemctl is-active --quiet "$p" 2>/dev/null && mech="systemd:$p"; done
    fi
    if [ -z "$mech" ]; then
      # Debian's cron.d/certbot deliberately skips itself when systemd is running.
      local lines cron_paths; read -r -a cron_paths <<<"$R8_CRON_PATHS"   # split on spaces, no globbing
      lines="$(grep -rhsE 'certbot[^#]*renew' -- "${cron_paths[@]}" 2>/dev/null | grep -v '^[[:space:]]*#' || true)"
      [ -d "$SYSTEMD_RUN_DIR" ] && lines="$(grep -v 'run/systemd/system' <<<"$lines" || true)"
      [ -n "$lines" ] && mech="cron"
    fi
  fi
  if [ -f "$CERT_DIR/fullchain.pem" ]; then
    local end; end="$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -n "$end" ] && days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  fi
  echo "certbot: $(command -v certbot >/dev/null && echo present || echo ABSENT)"
  echo "renewal mechanism: ${mech:-ABSENT}"
  echo "certificate: ${days:+$days days left}${days:-not issued yet}"
  if [ -n "$days" ] && { [ "$days" -lt 0 ] || [ -z "$mech" ]; }; then CERT_RENEWAL=FAIL
  elif [ -z "$mech" ] || { [ -n "$days" ] && [ "$days" -lt 14 ]; }; then CERT_RENEWAL=GAPS
  else CERT_RENEWAL=PASS; fi
  echo "CERT_RENEWAL = $CERT_RENEWAL"
}

# ---------- rollback (single implementation; used by r8_apply.sh and r8_rollback.sh) ----------
r8_restore() {  # $1 = apply run dir
  local run="$1" f reg
  [ -f "$run/manifest.txt" ] || die "no manifest in $run"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$NGINX_DIR"/*|"$RENEW_HOOK_DIR"/*) ;; *) log "refusing to remove out-of-scope path: $f"; continue ;; esac
    [[ "$f" == *..* ]] && { log "refusing path with '..': $f"; continue; }
    rm -f -- "$f"
  done < "$run/manifest.txt"
  if nginx_cmd -t >/dev/null 2>&1; then nginx_cmd -s reload
  else
    log "config invalid after removing R8 files; restoring full $NGINX_DIR backup"
    tar -C "$(dirname "$NGINX_DIR")" -xzf "$run/nginx.before.tgz"
    nginx_cmd -t && nginx_cmd -s reload
  fi
  sleep "$RELOAD_WAIT"
  health_snapshot "$run/targets.txt" > "$run/health.after-rollback.txt"
  reg="$(health_regressions "$run/health.before.txt" "$run/health.before2.txt" "$run/health.after-rollback.txt")"
  if [ -n "$reg" ]; then printf '%s\n' "$reg"; log "WARNING: differences remain after rollback - investigate"; return 1; fi
  log "rollback verified: existing sites, bare-IP/unknown-host behaviour and services match baseline"
}

resources() {
  echo "== uptime/load"; uptime
  echo "== memory";      free -m
  echo "== disk";        df -h / /var 2>/dev/null || true
  echo "== top cpu";     ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu | head -12
}
