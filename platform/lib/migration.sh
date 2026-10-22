#!/usr/bin/env bash
[[ -n "${__MIGRATION_SH_LOADED:-}" ]] && return
__MIGRATION_SH_LOADED=1

# run_migration — return 0 on success/skip, 1 if the migration actually failed
run_migration() {
    local enabled automatic service reason
    enabled="$(load_config "migration.enabled" "false")"

    if [[ "$enabled" != "true" ]]; then
        reason="$(load_config "migration.reason" "")"
        if [[ -n "$reason" ]]; then
            log_info "Migrations disabled for ${APP} — ${reason}"
        else
            log_info "Migrations disabled for ${APP}, skipping"
        fi
        return 0
    fi

    automatic="$(load_config "migration.automatic" "true")"
    if [[ "$automatic" != "true" ]]; then
        log_warn "Automatic migration disabled for ${APP} — skipping (run manually inside the container)"
        return 0
    fi

    service="$(load_config "migration.service" "app")"

    local cmd=()
    while IFS= read -r item; do
        [[ -n "$item" ]] && cmd+=("$item")
    done < <(yq eval ".migration.command[]" "$CONFIG_FILE" 2>/dev/null)

    if [[ "${#cmd[@]}" -eq 0 ]]; then
        log_error "migration.enabled=true but migration.command is empty in ${CONFIG_FILE}"
        return 1
    fi

    log_info "Running migration for ${APP}: ${cmd[*]}"
    if docker_exec "$service" "${cmd[@]}"; then
        log_ok "Migration succeeded"
        return 0
    else
        log_error "Migration failed"
        return 1
    fi
}
