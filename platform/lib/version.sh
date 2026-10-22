#!/usr/bin/env bash
# platform/lib/version.sh - read/write per app+env version state

[[ -n "${__VERSION_SH_LOADED:-}" ]] && return
__VERSION_SH_LOADED=1

_current_file()  { echo "${VERSIONS_ROOT}/${APP}.${ENVIRONMENT}.current"; }
_previous_file() { echo "${VERSIONS_ROOT}/${APP}.${ENVIRONMENT}.previous"; }

_read_version() {
    local f="$1"
    [[ -f "$f" ]] && cat "$f" || echo ""
}

get_current_version()  { _read_version "$(_current_file)"; }
get_previous_version() { _read_version "$(_previous_file)"; }

is_image_digest() {
    [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

set_current_version() {
    ensure_directory "$VERSIONS_ROOT"
    echo "$1" > "$(_current_file)"
}

set_previous_version() {
    ensure_directory "$VERSIONS_ROOT"
    echo "$1" > "$(_previous_file)"
}
