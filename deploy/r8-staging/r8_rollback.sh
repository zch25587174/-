#!/usr/bin/env bash
# Removes exactly the files r8_apply.sh added (per manifest), validates, graceful reload.
# Falls back to the full /etc/nginx tarball only if the config no longer validates.
# Usage: sudo ./r8_rollback.sh [path/to/apply-run-dir]
set -euo pipefail
. "$(dirname "$0")/r8_lib.sh"
need_root
RUN="${1:-$(readlink -f "$STATE_ROOT/last-apply")}"
[ -f "$RUN/manifest.txt" ] || die "no manifest in $RUN"
health_snapshot > "$RUN/health.pre-rollback.txt"
while read -r f; do log "remove $f"; rm -f -- "$f"; done < "$RUN/manifest.txt"
if nginx -t; then nginx -s reload
else log "config invalid; restoring $RUN/etc-nginx.before.tgz"; tar -C / -xzf "$RUN/etc-nginx.before.tgz"; nginx -t && nginx -s reload; fi
sleep 3; health_snapshot > "$RUN/health.post-rollback.txt"
health_regressions "$RUN/health.before.txt" "$RUN/health.post-rollback.txt" || true
log "rollback complete. Certificates in /etc/letsencrypt were left in place (inert without the vhost)."
