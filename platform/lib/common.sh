#!/usr/bin/env bash
[[ -n "${__COMMON_SH_LOADED:-}" ]] && return
__COMMON_SH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/constants.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

die() { echo "FATAL: $*" >&2; exit 1; }

require_command() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

ensure_directory() {
    for d in "$@"; do
        [[ -d "$d" ]] || mkdir -p "$d"
    done
}

confirm() {
    local prompt="${1:-Are you sure?}" reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# app_slug <name> — canonical name for Docker images and Compose projects:
# lowercase, any run of other characters collapses to "-", leading/trailing
# "-" trimmed. Must keep at least one alphanumeric.
app_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# parse_args "$@" — populates APP, ENVIRONMENT, TAG
parse_args() {
    APP="" ENVIRONMENT="" TAG="" YES="false" BACKUP_FILE="" ENGINE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)    APP="$2"; shift 2 ;;
            --env)    ENVIRONMENT="$2"; shift 2 ;;
            --tag)    TAG="$2"; shift 2 ;;
            --backup) BACKUP_FILE="$2"; shift 2 ;;
            --engine) ENGINE="$2"; shift 2 ;;
            --yes)    YES="true"; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

# record_history <action> <version> <result>
# Audit trail, kept separate from logs/ — easy to review without grepping app logs
record_history() {
    local action="$1" version="$2" result="$3"
    ensure_directory "$HISTORY_ROOT"
    printf '%s %s %s %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "${ENVIRONMENT:-unknown}" "$version" "$result" \
        >> "${HISTORY_ROOT}/${APP}.log"
}

# validate_args APP ENVIRONMENT [TAG] — check required variables are set
validate_args() {
    for var_name in "$@"; do
        [[ -n "${!var_name:-}" ]] || die "Missing required argument: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    done

    if [[ -n "${ENVIRONMENT:-}" ]]; then
        local allowed="${DEPLOY_ENVS:-dev prod}"
        case " ${allowed} " in
            *" ${ENVIRONMENT} "*) ;;
            *) die "Invalid --env '${ENVIRONMENT}' — must be one of: ${allowed} (see DEPLOY_ENVS in .env)" ;;
        esac
    fi

    if [[ -n "${APP:-}" ]]; then
        [[ "$APP" =~ ^[A-Za-z0-9._-]+$ && "$APP" != "." && "$APP" != ".." ]] \
            || die "Invalid app name '${APP}' — use letters, digits, '.', '_' or '-' (GitHub repo charset)"
        [[ -d "${APPS_ROOT}/${APP}" ]] || die "Unknown app '${APP}' — no runtime dir at ${APPS_ROOT}/${APP}"
    fi
}

# init_environment — derive all standard paths from APP; run after parse_args
init_environment() {
    [[ -n "${APP:-}" ]] || die "init_environment called before APP is set"

    require_command yq
    APP_SLUG="$(app_slug "$APP")"
    [[ -n "$APP_SLUG" ]] || die "Cannot derive a valid name from '${APP}' — it needs at least one alphanumeric character"
    APP_ENVKEY="${APP_SLUG^^}"
    APP_ENVKEY="${APP_ENVKEY//-/_}"

    RUNTIME="${APPS_ROOT}/${APP}"
    COMPOSE_PROJECT_DIR="${RUNTIME}"
    COMPOSE_FILE="${COMPOSE_PROJECT_DIR}/compose.yml"
    # Image paths are lowercase-only, so the slug (not the raw name) is used.
    IMAGE="${REGISTRY}/${APP_SLUG}"
    LOG_DIR="${LOGS_ROOT}/${APP}"
    BACKUP_DIR="${BACKUPS_ROOT}/${APP}"
    CONFIG_FILE="${CONFIGS_ROOT}/${APP}/config.yml"
    IMAGE_TAG="${TAG:-}"

    export APP ENVIRONMENT TAG RUNTIME COMPOSE_PROJECT_DIR COMPOSE_FILE IMAGE LOG_DIR BACKUP_DIR CONFIG_FILE IMAGE_TAG
    export APP_SLUG APP_ENVKEY

    ensure_directory "$LOG_DIR" "$BACKUP_DIR"
}

# load_config <key.path> [default] — read CONFIG_FILE through yq.
load_config() {
    local key="$1" default="${2:-}" val
    [[ -f "$CONFIG_FILE" ]] || { echo "$default"; return; }
    val=$(yq eval ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
    [[ -z "$val" || "$val" == "null" ]] && echo "$default" || echo "$val"
}
