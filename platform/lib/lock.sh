#!/usr/bin/env bash
[[ -n "${__LOCK_SH_LOADED:-}" ]] && return
__LOCK_SH_LOADED=1

acquire_deploy_lock() {
    local lock_dir="${LOCKS_ROOT:-${DEVOPS_ROOT}/locks}"
    local lock_file="${lock_dir}/${APP}.${ENVIRONMENT}.lock"

    [[ "${DEPLOY_LOCK_HELD:-}" == "1" ]] && return 0

    command -v flock >/dev/null 2>&1 || die "flock is required for deploy locking"
    ensure_directory "$lock_dir"
    exec 9>"$lock_file"
    if ! flock -n 9; then
        log_error "Another operation is already running for ${APP} (${ENVIRONMENT})"
        return 1
    fi

    DEPLOY_LOCK_HELD=1
    export DEPLOY_LOCK_HELD
}
