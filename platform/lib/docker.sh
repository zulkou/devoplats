#!/usr/bin/env bash
# platform/lib/docker.sh - the only place allowed to call `docker compose`

[[ -n "${__DOCKER_SH_LOADED:-}" ]] && return
__DOCKER_SH_LOADED=1

_dc() {
    docker compose --project-directory "$COMPOSE_PROJECT_DIR" -f "$COMPOSE_FILE" "$@"
}

docker_login() {
    require_command docker
    load_infra_env
    [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]] || die "GHCR_USERNAME / GHCR_TOKEN not set — check ${DEVOPS_ROOT}/.env"
    local registry_host="${REGISTRY%%/*}"
    echo "$GHCR_TOKEN" | docker login "$registry_host" -u "$GHCR_USERNAME" --password-stdin
}

docker_pull() {
    log_info "Pulling ${IMAGE}:${IMAGE_TAG}"
    _dc pull
}

# image_digest <ref> — digest for IMAGE from a locally known image reference
image_digest() {
    local ref="$1" digests
    digests=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null || true)
    digests=$(printf '%s\n' "$digests" | grep -F "${IMAGE}@" | head -n 1 || true)
    [[ -n "$digests" ]] && printf '%s\n' "${digests#*@}"
}

# running_image_digest <service> — digest of the image behind a compose service
running_image_digest() {
    local service="$1" cid image_id
    cid=$(_dc ps -q "$service" 2>/dev/null || true)
    [[ -n "$cid" ]] || return 0
    image_id=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)
    [[ -n "$image_id" ]] || return 0
    image_digest "$image_id"
}

docker_pull_digest() {
    local digest="$1"
    log_info "Pulling ${IMAGE}@${digest}"
    docker pull "${IMAGE}@${digest}"
}

docker_tag_digest() {
    local digest="$1" tag="$2"
    docker tag "${IMAGE}@${digest}" "${IMAGE}:${tag}"
}

docker_up() {
    log_info "Starting containers for ${APP}"
    _dc up -d
}

docker_down() {
    log_info "Stopping containers for ${APP}"
    _dc down
}

# wait_for_service <service> [timeout_seconds]
# Wait until the container is up (and healthy, if the image has its own HEALTHCHECK)
wait_for_service() {
    local service="$1" timeout="${2:-${SERVICE_WAIT_TIMEOUT:-60}}" elapsed=0 container status

    container="$(_dc ps -q "$service")"
    [[ -n "$container" ]] || { log_error "Service ${service} is not running"; return 1; }

    while (( elapsed < timeout )); do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null)
        case "$status" in
            healthy|running) return 0 ;;
            unhealthy) log_error "Service ${service} reported unhealthy"; return 1 ;;
        esac
        sleep 2; ((elapsed+=2))
    done

    log_error "Timed out waiting for service ${service} to be ready"
    return 1
}

# docker_exec <service> <command...>
docker_exec() {
    local service="$1"; shift
    _dc exec -T "$service" "$@"
}
