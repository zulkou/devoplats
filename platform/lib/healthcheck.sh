#!/usr/bin/env bash
[[ -n "${__HEALTHCHECK_SH_LOADED:-}" ]] && return
__HEALTHCHECK_SH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/validate.sh"

healthcheck() {
    local url expected_status host actual_status
    url="$(healthcheck_config_url)" || return 1
    expected_status="$(load_config "healthcheck.expected_status" "200")"

    if [[ "${HEALTHCHECK_ALLOW_EXTERNAL:-}" != "1" ]]; then
        validate_healthcheck_url "$url" || return 1
    fi

    # Strip scheme, path and port to compare the URL host with the app container.
    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"

    if [[ "$host" == "${APP_SLUG}-${ENVIRONMENT}" ]]; then
        # Container names resolve only inside the app's Compose network, which
        # may live on a remote daemon — discover it and probe from a throwaway
        # container attached to that network.
        local probe_image="${HEALTHCHECK_PROBE_IMAGE:-curlimages/curl:latest}"
        local -a networks=()
        local network network_output
        if ! network_output=$(docker inspect --format \
            '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
            "$host" 2>/dev/null); then
            log_error "Could not inspect container ${host} to discover its Docker network"
            return 1
        fi
        while IFS= read -r network; do
            [[ -n "$network" ]] && networks+=("$network")
        done <<< "$network_output"

        if [[ ${#networks[@]} -eq 0 ]]; then
            log_error "Container ${host} is not attached to a Docker network"
            return 1
        fi

        actual_status="000"
        for network in "${networks[@]}"; do
            log_info "Healthcheck: GET ${url} via ${probe_image} on ${network} (expecting ${expected_status})"
            actual_status=$(docker run --rm --network "$network" "$probe_image" \
                -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
            actual_status="${actual_status:-000}"
            if [[ "$actual_status" == "$expected_status" ]]; then
                break
            fi
        done
    else
        log_info "Healthcheck: GET ${url} (expecting ${expected_status})"
        actual_status=$(curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    fi
    actual_status="${actual_status:-000}"

    if [[ "$actual_status" == "$expected_status" ]]; then
        log_ok "Healthcheck passed (${actual_status})"
        return 0
    else
        log_error "Healthcheck failed: got ${actual_status}, expected ${expected_status}"
        return 1
    fi
}
