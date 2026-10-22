#!/usr/bin/env bash
[[ -n "${__BACKUP_SH_LOADED:-}" ]] && return
__BACKUP_SH_LOADED=1

backup_db() {
    local prefix failed="false"
    prefix="BACKUP_${APP_ENVKEY}"

    local db_count
    db_count=$(yq eval ".backup.databases | length" "$CONFIG_FILE" 2>/dev/null || echo "0")

    if [[ "$db_count" -eq 0 ]]; then
        log_warn "No backup config for ${APP}, skipping database backup"
        return 0
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    for i in $(seq 0 $((db_count - 1))); do
        local engine service database username password db_var
        engine=$(yq eval ".backup.databases[$i].engine" "$CONFIG_FILE")
        service=$(yq eval ".backup.databases[$i].service" "$CONFIG_FILE")
        database=$(yq eval ".backup.databases[$i].name" "$CONFIG_FILE")

        db_var="${prefix}_USER"; username="${!db_var:-}"
        db_var="${prefix}_PASS"; password="${!db_var:-}"

        if [[ -z "$username" || -z "$password" ]]; then
            log_error "Missing ${prefix}_USER/${prefix}_PASS for ${APP}/${database} in ${DEVOPS_ROOT}/.env"
            failed="true"
            continue
        fi

        local out_file="${BACKUP_DIR}/${ts}-${database}.sql.gz"
        log_info "Backing up ${engine} database '${database}' via container ${service}"

        local dump_ok="true"
        case "$engine" in
            postgres)
                docker exec -e PGPASSWORD="$password" "$service" \
                    pg_dump -U "$username" --clean --if-exists "$database" \
                    | gzip > "$out_file" || dump_ok="false"
                ;;
            mysql)
                docker exec -e MYSQL_PWD="$password" "$service" \
                    mysqldump --no-tablespaces -u"$username" "$database" \
                    | gzip > "$out_file" || dump_ok="false"
                ;;
            *)
                log_error "Unsupported backup engine '${engine}' for ${database} (${APP})"
                failed="true"
                continue
                ;;
        esac

        if [[ "$dump_ok" != "true" ]]; then
            rm -f "$out_file"
            log_error "Backup failed for ${APP}/${database}"
            failed="true"
            continue
        fi

        log_ok "Backup written to ${out_file}"
    done

    [[ "$failed" == "true" ]] && return 1
    return 0
}
