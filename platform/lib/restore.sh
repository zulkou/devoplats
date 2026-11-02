#!/usr/bin/env bash
[[ -n "${__RESTORE_SH_LOADED:-}" ]] && return
__RESTORE_SH_LOADED=1

restore_database() {
    local engine="$1" service="$2" database="$3" backup_file="$4"
    local prefix username password db_var backup_path

    if [[ -z "$engine" || -z "$service" || -z "$database" || -z "$backup_file" ]]; then
        log_error "restore_database requires engine, service, database, and backup file"
        return 1
    fi

    if [[ "$backup_file" == */* || "$backup_file" == "." || "$backup_file" == ".." ]]; then
        log_error "Invalid backup filename: ${backup_file}"
        return 1
    fi

    backup_path="${BACKUP_DIR}/${backup_file}"
    [[ -f "$backup_path" ]] || {
        log_error "Backup file not found: ${backup_path}"
        return 1
    }

    prefix="BACKUP_${APP_ENVKEY}"
    db_var="${prefix}_USER"
    username="${!db_var:-}"
    db_var="${prefix}_PASS"
    password="${!db_var:-}"
    [[ -n "$username" && -n "$password" ]] || {
        log_error "Missing ${prefix}_USER/${prefix}_PASS credentials"
        return 1
    }

    log_warn "Restoring ${engine} database '${database}' from ${backup_file}"
    case "$engine" in
        postgres)
            if ! gunzip -c "$backup_path" | docker exec -i -e PGPASSWORD="$password" "$service" \
                psql -v ON_ERROR_STOP=1 -U "$username" "$database"; then
                log_error "Database restore failed for ${APP}/${database} from ${backup_file}"
                return 1
            fi
            ;;
        mysql)
            if ! gunzip -c "$backup_path" | docker exec -i -e MYSQL_PWD="$password" "$service" \
                mysql -u"$username" "$database"; then
                log_error "Database restore failed for ${APP}/${database} from ${backup_file}"
                return 1
            fi
            ;;
        *)
            log_error "Unsupported backup engine: ${engine}"
            return 1
            ;;
    esac

    log_ok "Database restored for ${APP} from ${backup_file}"
    return 0
}

restore_backup_file() {
    local backup_file="$1" engine_filter="${2:-}"
    local database db_entries engine service

    [[ -n "$backup_file" ]] || {
        log_error "A backup filename is required"
        return 1
    }
    if [[ "$backup_file" == */* || "$backup_file" == "." || "$backup_file" == ".." ]]; then
        log_error "Invalid backup filename: ${backup_file}"
        return 1
    fi

    database="$(basename "$backup_file" .sql.gz)"
    database="${database#*-}"
    database="${database#*-}"

    db_entries="$(yq eval ".backup.databases[] | select(.name == \"${database}\") | [.engine, .service] | @tsv" "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$db_entries" ]] || {
        log_error "No backup config entry for database '${database}' in ${APP}"
        return 1
    }

    if [[ "$(grep -c . <<<"$db_entries")" -gt 1 ]]; then
        [[ -n "$engine_filter" ]] || {
            log_error "Multiple backup entries for '${database}'; specify --engine"
            return 1
        }
        engine="$engine_filter"
        service="$(yq eval ".backup.databases[] | select(.name == \"${database}\" and .engine == \"${engine_filter}\") | .service" "$CONFIG_FILE")"
        [[ -n "$service" ]] || {
            log_error "No ${engine_filter} entry for '${database}'"
            return 1
        }
    else
        IFS=$'\t' read -r engine service <<<"$db_entries"
    fi

    restore_database "$engine" "$service" "$database" "$backup_file"
}
