#!/usr/bin/env bash
[[ -n "${__WEBHOOK_SH_LOADED:-}" ]] && return
__WEBHOOK_SH_LOADED=1

VENV_ROOT="${VENV_ROOT:-${DEVOPS_ROOT}/.venv}"
WEBHOOK_BIN="${WEBHOOK_BIN:-${VENV_ROOT}/bin/devoplats-webhook}"
WEBHOOK_SERVICE="${WEBHOOK_SERVICE:-gh-runner-webhook}"
WEBHOOK_UNIT_PATH="${WEBHOOK_UNIT_PATH:-/etc/systemd/system/${WEBHOOK_SERVICE}.service}"
WEBHOOK_TEMPLATE="${WEBHOOK_TEMPLATE:-${DEVOPS_ROOT}/github-runners/gh-runner-webhook.service.template}"
WEBHOOK_HEALTH_URL="${WEBHOOK_HEALTH_URL:-http://127.0.0.1:${WEBHOOK_PORT:-10000}/healthz}"

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] \
        || die "This command needs root; run it with sudo and the absolute path (${DEVOPS_ROOT}/bin/devops)"
}

webhook_unit_installed() {
    [[ -f "$WEBHOOK_UNIT_PATH" ]]
}

webhook_active() {
    command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet "$WEBHOOK_SERVICE"
}

webhook_healthy() {
    command -v curl >/dev/null 2>&1 \
        && curl -fsS --max-time 3 "$WEBHOOK_HEALTH_URL" >/dev/null 2>&1
}
