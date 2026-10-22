#!/usr/bin/env bash
[[ -n "${__CONSTANTS_SH_LOADED:-}" ]] && return
__CONSTANTS_SH_LOADED=1

# constants.sh — resolve install root, load site config from <root>/.env,
# then apply defaults. Precedence: shell env > .env > default.

# DEVOPS_ROOT auto-resolves to the clone location.
_DEVOPS_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVOPS_ROOT="${DEVOPS_ROOT:-${_DEVOPS_SELF}}"

# load_dotenv <file> — export KEY=value lines. Values may contain spaces
# unquoted and nothing in the file is ever executed. Already-set variables win.
load_dotenv() {
    local _file="$1" _line _key _val
    [[ -r "$_file" ]] || return 0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line%$'\r'}"
        [[ -z "$_line" || "$_line" == \#* || "$_line" != *=* ]] && continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        _val="${_val%\"}"; _val="${_val#\"}"
        _val="${_val%\'}"; _val="${_val#\'}"
        [[ -n "${!_key:-}" ]] && continue
        export "${_key}=${_val}"
    done < "$_file"
}

load_dotenv "${DEVOPS_ROOT}/.env"

APPS_ROOT="${APPS_ROOT:-/opt/apps}"
REGISTRY="${REGISTRY:-ghcr.io/example}"
# Registry/repo paths are lowercase-only (GHCR rejects mixed case on pull/push).
REGISTRY="${REGISTRY,,}"
RUNNER_IMAGE="${RUNNER_IMAGE:-myoung34/github-runner:latest}"

CONFIGS_ROOT="${CONFIGS_ROOT:-${DEVOPS_ROOT}/configs}"
LOCKS_ROOT="${LOCKS_ROOT:-${DEVOPS_ROOT}/locks}"
LOGS_ROOT="${LOGS_ROOT:-${DEVOPS_ROOT}/logs}"
BACKUPS_ROOT="${BACKUPS_ROOT:-${DEVOPS_ROOT}/backups}"
VERSIONS_ROOT="${VERSIONS_ROOT:-${DEVOPS_ROOT}/platform/versions}"
HISTORY_ROOT="${HISTORY_ROOT:-${DEVOPS_ROOT}/history}"
