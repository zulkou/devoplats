#!/usr/bin/env bash
[[ -n "${__VALIDATE_SH_LOADED:-}" ]] && return
__VALIDATE_SH_LOADED=1

healthcheck_config_url() {
    local url var_name var_value

    url="$(load_config "healthcheck.url")"
    [[ -n "$url" ]] || { log_error "No healthcheck.url configured in ${CONFIG_FILE}"; return 1; }

    while [[ "$url" =~ \$\{([a-zA-Z_][a-zA-Z_0-9]*)\} ]]; do
        var_name="${BASH_REMATCH[1]}"
        var_value="${!var_name:-}"
        url="${url//\$\{${var_name}\}/${var_value}}"
    done
    printf '%s\n' "$url"
}

validate_healthcheck_url() {
    local url="$1" expected="${APP_SLUG}-${ENVIRONMENT}" host

    if [[ ! "$url" =~ ^https?://([A-Za-z0-9][A-Za-z0-9_.-]*)(:[0-9]+)?([/?#][^[:space:]]*)?$ ]]; then
        log_error "Invalid healthcheck.url '${url}' — expected http(s)://<container>[:port][/path]"
        return 1
    fi

    host="${BASH_REMATCH[1]}"
    if [[ "$host" != "$expected" ]]; then
        log_error "healthcheck.url host '${host}' is not the app container '${expected}' — remote Docker healthchecks must target the container by name"
        return 1
    fi
}

validate_healthcheck_config() {
    local url
    url="$(healthcheck_config_url)" || return 1
    validate_healthcheck_url "$url"
}

validate_compose_no_bind_mounts() {
    local json violations err tag
    local -a compose_cmd

    [[ -f "$COMPOSE_FILE" ]] || { log_error "Compose file not found: ${COMPOSE_FILE}"; return 1; }
    command -v docker >/dev/null 2>&1 || { log_error "docker is required to validate ${COMPOSE_FILE}"; return 1; }
    command -v python3 >/dev/null 2>&1 || { log_error "python3 is required to validate ${COMPOSE_FILE}"; return 1; }

    tag="${IMAGE_TAG:-validation}"
    compose_cmd=(docker compose --project-directory "$COMPOSE_PROJECT_DIR" -f "$COMPOSE_FILE")

    if ! json=$(IMAGE_TAG="$tag" "${compose_cmd[@]}" config --no-env-resolution --format json 2>/dev/null); then
        if ! json=$(IMAGE_TAG="$tag" "${compose_cmd[@]}" config --format json 2>/dev/null); then
            err=$(IMAGE_TAG="$tag" "${compose_cmd[@]}" config --format json 2>&1 >/dev/null || true)
            log_error "Could not parse ${COMPOSE_FILE}: $(printf '%s\n' "$err" | sed -n '1,3p')"
            return 1
        fi
    fi

    if ! violations=$(printf '%s' "$json" | python3 -c '
import json
import sys

try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(2)

for name, service in (doc.get("services") or {}).items():
    for volume in (service.get("volumes") or []):
        if volume.get("type") == "bind":
            source = volume.get("source", "?")
            target = volume.get("target", "?")
            print(f"{name}: {source} -> {target}")
'); then
        log_error "Could not inspect volumes in ${COMPOSE_FILE}"
        return 1
    fi

    [[ -z "$violations" ]] && return 0

    while IFS= read -r violation; do
        [[ -n "$violation" ]] && log_error "Bind mount rejected: ${violation}"
    done <<< "$violations"
    log_error "Remote Docker cannot use bind mounts in ${COMPOSE_FILE}; use named volumes or bake files into the image"
    return 1
}

validate_app_config() {
    validate_healthcheck_config || return 1
    validate_compose_no_bind_mounts || return 1
}
