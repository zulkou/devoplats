#!/usr/bin/env bash
set -euo pipefail

# cleanup.sh — reap stuck runners and prune dangling images.
# Scheduling is optional: run manually or from cron/systemd later.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/platform/lib/constants.sh"

DRY_RUN=false
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

log() {
    printf '%s [cleanup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        "$@"
    fi
}

remote_host="${DOCKER_HOST:-}"
remote_context="${DOCKER_CONTEXT:-}"
unset DOCKER_HOST DOCKER_CONTEXT

if ! command -v docker >/dev/null 2>&1; then
    log "docker is not available"
    exit 1
fi

run_local_runner_cleanup() {
    local runners id since min

    if ! runners=$(docker ps --filter ancestor="${RUNNER_IMAGE}" \
        --format '{{.ID}} {{.RunningFor}}' 2>&1); then
        log "warning: could not list local runner containers: ${runners%%$'\n'*}"
        return 0
    fi

    while read -r id since; do
        [[ -n "$id" ]] || continue
        case "$since" in
            *minutes)
                min=${since%% *}
                if [[ $min =~ ^[0-9]+$ ]] && [[ $min -ge 10 ]]; then
                    if $DRY_RUN; then
                        log "dry-run: would kill runner ${id} (running for ${since})"
                    else
                        docker kill "$id" >/dev/null 2>&1 || true
                        log "killed runner ${id} (running for ${since})"
                    fi
                fi
                ;;
            *hour*|*days*|*weeks*|*month*)
                if $DRY_RUN; then
                    log "dry-run: would kill runner ${id} (running for ${since})"
                else
                    docker kill "$id" >/dev/null 2>&1 || true
                    log "killed runner ${id} (running for ${since})"
                fi
                ;;
        esac
    done <<< "$runners"
}

refresh_runner_image() {
    local output

    if $DRY_RUN; then
        log "dry-run: would ensure ${RUNNER_IMAGE} is present"
        return 0
    fi
    if docker image inspect "${RUNNER_IMAGE}" >/dev/null 2>&1; then
        log "runner image present: ${RUNNER_IMAGE}"
        return 0
    fi
    if output=$(with_timeout docker pull "${RUNNER_IMAGE}" 2>&1); then
        log "pulled ${RUNNER_IMAGE}"
    else
        log "warning: could not pull ${RUNNER_IMAGE}: ${output%%$'\n'*}"
    fi
}

prune_dangling() {
    local label="$1" output
    shift

    if $DRY_RUN; then
        log "dry-run: would prune dangling images older than 24h on ${label}"
        return 0
    fi
    if output=$(with_timeout "$@" image prune -f --filter "until=24h" 2>&1); then
        log "pruned dangling images older than 24h on ${label}: ${output##*$'\n'}"
    else
        log "warning: could not prune ${label}: ${output%%$'\n'*}"
    fi
}

run_local_runner_cleanup
refresh_runner_image
prune_dangling "local daemon" docker

if [[ -n "$remote_host" ]]; then
    prune_dangling "remote daemon" env "DOCKER_HOST=${remote_host}" docker
elif [[ -n "$remote_context" ]]; then
    prune_dangling "remote context ${remote_context}" env "DOCKER_CONTEXT=${remote_context}" docker
else
    log "remote prune skipped: DOCKER_HOST/DOCKER_CONTEXT is not set"
fi
