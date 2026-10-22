#!/usr/bin/env bash
[[ -n "${__TEST_SH_LOADED:-}" ]] && return
__TEST_SH_LOADED=1

# run_test — return 0 on success/skip, 1 if a test fails or config is wrong
# Supports two config shapes:
#   test.command: [array]      — a single shell command
#   test.steps:   {name: [..]} — named steps, fail-fast, insertion order
run_test() {
    local enabled reason
    enabled="$(load_config "test.enabled" "false")"

    if [[ "$enabled" != "true" ]]; then
        reason="$(load_config "test.reason" "")"
        if [[ -n "$reason" ]]; then
            log_info "Tests disabled for ${APP} — ${reason}"
        else
            log_info "Tests disabled for ${APP}, skipping"
        fi
        return 0
    fi

    local steps_count cmd_count
    steps_count="$(yq eval '.test.steps // {} | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
    cmd_count="$(yq eval '.test.command // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"

    if [[ "$steps_count" -gt 0 && "$cmd_count" -gt 0 ]]; then
        log_error "Both test.steps and test.command set in ${CONFIG_FILE} — use only one"
        return 1
    fi

    if [[ "$steps_count" -eq 0 && "$cmd_count" -eq 0 ]]; then
        log_error "test.enabled=true but neither test.steps nor test.command is set in ${CONFIG_FILE}"
        return 1
    fi

    local cmd=() item name

    if [[ "$steps_count" -gt 0 ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            cmd=()
            while IFS= read -r item; do
                [[ -n "$item" ]] && cmd+=("$item")
            done < <(yq eval ".test.steps.\"${name}\"[]" "$CONFIG_FILE")

            log_info "Running step '${name}' for ${APP}: ${cmd[*]}"
            if ! ( cd "$RUNTIME" && "${cmd[@]}" ); then
                log_error "Step '${name}' failed for ${APP}"
                return 1
            fi
            log_ok "Step '${name}' passed"
        done < <(yq eval '.test.steps | to_entries | .[].key' "$CONFIG_FILE")
    else
        cmd=()
        while IFS= read -r item; do
            [[ -n "$item" ]] && cmd+=("$item")
        done < <(yq eval '.test.command[]' "$CONFIG_FILE")

        log_info "Running tests for ${APP}: ${cmd[*]}"
        if ! ( cd "$RUNTIME" && "${cmd[@]}" ); then
            log_error "Tests failed for ${APP}"
            return 1
        fi
    fi
}
