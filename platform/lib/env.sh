#!/usr/bin/env bash
[[ -n "${__ENV_SH_LOADED:-}" ]] && return
__ENV_SH_LOADED=1

# env.sh — local environment gate.
# Platform config, infra credentials, and backup credentials live in
# <install-root>/.env. App secrets live beside config.yml:
#   <configs-root>/<app>/.env
# fetch_env copies that file to <apps-root>/<app>/.env for Compose.

LOCAL_ONLY_ENV_PREFIXES="${LOCAL_ONLY_ENV_PREFIXES:-BACKUP_}"

_env_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$*"
    else
        echo "WARN: $*" >&2
    fi
}

_is_local_only_key() {
    local key="$1" prefix
    for prefix in $LOCAL_ONLY_ENV_PREFIXES; do
        [[ "$key" == "${prefix}"* ]] && return 0
    done
    return 1
}

app_env_file() {
    echo "${CONFIGS_ROOT}/${APP}/.env"
}

app_runtime_env_file() {
    echo "${APPS_ROOT}/${APP}/.env"
}

load_infra_env() {
    local infra_env_file="${DEVOPS_ROOT}/.env" perms
    [[ -f "$infra_env_file" ]] || return 0
    perms=$(stat -c '%a' "$infra_env_file" 2>/dev/null || true)
    [[ "$perms" == @(600|640) ]] \
        || _env_warn "Infra env file ${infra_env_file} has loose permissions (${perms:-unknown}), expected 600 or 640"
    load_dotenv "$infra_env_file"
}

fetch_env() {
    local source runtime perms key line tmp
    source="$(app_env_file)"
    runtime="$(app_runtime_env_file)"

    if [[ ! -f "$source" ]]; then
        if [[ -f "$runtime" ]]; then
            die "App env file not found at ${source} — move the existing ${runtime} there (mode 600)"
        fi
        die "No app env file at ${source} — create it (mode 600)"
    fi

    perms=$(stat -c '%a' "$source" 2>/dev/null || true)
    [[ "$perms" == @(600|640) ]] \
        || _env_warn "App env file ${source} has loose permissions (${perms:-unknown}), expected 600 or 640"

    if [[ "$source" == "$runtime" ]]; then
        die "CONFIGS_ROOT and APPS_ROOT resolve to the same path (${source}); keep app configs and runtime dirs separate"
    fi

    tmp="$(mktemp "${runtime}.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
            key="${BASH_REMATCH[2]}"
            if _is_local_only_key "$key"; then
                _env_warn "App env file ${source} contains local-only key '${key}' — keep BACKUP_* in ${DEVOPS_ROOT}/.env"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$source"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$runtime"
    log_info "Loaded app env for ${APP} from ${source}"
}
