#!/usr/bin/env bash
# Removes exactly the files r8_apply.sh added (per manifest), validates, graceful reload,
# then re-checks existing sites/services against the pre-apply baseline. Idempotent.
# Usage: sudo ./r8_rollback.sh [path/to/apply-run-dir]
set -euo pipefail
umask 077
. "$(dirname "$0")/r8_lib.sh"
need_root
validate_inputs
exec 9>"$STATE_ROOT/.lock"; flock -n 9 || die "another r8 run holds $STATE_ROOT/.lock"
RUN="$(readlink -f "${1:-$STATE_ROOT/last-apply}")" || die "no apply run found"
case "$RUN" in "$STATE_ROOT"/apply-*) ;; *) die "not an r8 apply run dir: $RUN" ;; esac
r8_restore "$RUN"
log "certificates under $(dirname "$CERT_DIR") were left in place (inert without the vhost)."
