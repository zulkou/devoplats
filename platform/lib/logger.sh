#!/usr/bin/env bash
[[ -n "${__LOGGER_SH_LOADED:-}" ]] && return
__LOGGER_SH_LOADED=1

COLOR_RED=$'\033[0;31m'; COLOR_YELLOW=$'\033[0;33m'
COLOR_GREEN=$'\033[0;32m'; COLOR_BLUE=$'\033[0;34m'; COLOR_RESET=$'\033[0m'

LOG_FILE=""

# init_logger — call after init_environment (needs LOG_DIR)
# file name = the running command: deploy.log, backup.log, etc.
init_logger() {
    local command_name; command_name="$(basename "$0")"
    LOG_FILE="${LOG_DIR}/${command_name}.log"
    touch "$LOG_FILE"
}

_log() {
    local level="$1" color="$2"; shift 2
    local line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE"
    echo "${color}${line}${COLOR_RESET}"
}

log_info()  { _log "INFO"  "$COLOR_BLUE"   "$@"; }
log_warn()  { _log "WARN"  "$COLOR_YELLOW" "$@"; }
log_error() { _log "ERROR" "$COLOR_RED"    "$@" >&2; }
log_ok()    { _log "OK"    "$COLOR_GREEN"  "$@"; }
