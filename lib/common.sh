#!/usr/bin/env bash
#
# common.sh — logging, error handling, and shared helpers for restage.
#
# This module is *sourced* by other scripts; it performs no work at load
# time beyond defining defaults. Everything it defines is namespaced with
# the `rs_` (restage) prefix.
#
# shellcheck shell=bash

set -o nounset

RS_PROG_NAME="${RS_PROG_NAME:-restage}"
RS_VERSION="unknown"

# ---------------------------------------------------------------- repo root --

# Locate the repository root regardless of how this file was sourced.
# Returns the absolute path on stdout.
rs_repo_root() {
    local script
    script="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    script="$(readlink -f "${script}" 2>/dev/null || realpath "${script}" 2>/dev/null || echo "${script}")"
    local dir
    dir="$(dirname "${script}")"
    # Walk up until we find the marker file that identifies the repo root.
    while [[ "${dir}" != "/" && ! -f "${dir}/VERSION" ]]; do
        dir="$(dirname "${dir}")"
    done
    if [[ -f "${dir}/VERSION" ]]; then
        printf '%s\n' "${dir}"
    else
        printf '%s\n' "$(dirname "${dir}")"
    fi
}

RS_REPO_ROOT="${RS_REPO_ROOT:-$(rs_repo_root)}"
if [[ -f "${RS_REPO_ROOT}/VERSION" ]]; then
    RS_VERSION="$(cat "${RS_REPO_ROOT}/VERSION")"
fi

# Source a module from lib/ or another path, relative to the repo root.
#   rs_import lib/validate.sh
rs_import() {
    local rel="${1:?rs_import: missing path}"
    local path="${RS_REPO_ROOT}/${rel}"
    if [[ ! -f "${path}" ]]; then
        printf 'internal error: cannot import "%s" (%s missing)\n' "${rel}" "${path}" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "${path}"
}

# ---------------------------------------------------------------- logging --

# Level numbers (higher = more severe / less verbose output).
#   debug=0  info=1  warn=2  error=3  silent=4
RS_LOG_LEVEL_DEFAULT="info"
RS_LOG_LEVEL="${RS_LOG_LEVEL:-${RS_LOG_LEVEL_DEFAULT}}"
RS_LOG_FILE="${RS_LOG_FILE:-}"               # optional file sink, appended to

_rs_log_num() {
    case "${1:-info}" in
        debug) echo 0 ;;
        info) echo 1 ;;
        warn) echo 2 ;;
        error) echo 3 ;;
        silent) echo 4 ;;
        *) echo 1 ;;
    esac
}

_rs_log_enabled() {
    # $1 = level of the message being emitted
    local want
    want="$(_rs_log_num "${1}")"
    [[ "${want}" -ge "$(_rs_log_num "${RS_LOG_LEVEL}")" ]]
}

_rs_use_color() {
    [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]
}

# Emit a timestamped, level-prefixed log line to stderr (and RS_LOG_FILE if set).
_rs_log_line() {
    local level="${1}" msg="${2}"
    local stamp
    stamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s [%s] %s\n' "${stamp}" "${level}" "${msg}" >&2
    if [[ -n "${RS_LOG_FILE}" ]]; then
        printf '%s [%s] %s\n' "${stamp}" "${level}" "${msg}" >>"${RS_LOG_FILE}"
    fi
}

rs_log_debug() {
    if _rs_log_enabled debug; then _rs_log_line DEBUG "$*"; fi
}
rs_log_info() {
    if _rs_log_enabled info; then _rs_log_line INFO "$*"; fi
}
rs_log_warn() {
    if _rs_log_enabled warn; then _rs_log_line WARN "$*"; fi
}
rs_log_error() {
    if _rs_log_enabled error; then _rs_log_line ERROR "$*"; fi
}

# Print a human-facing message (always shown unless level is `silent`).
rs_msg() {
    if [[ "$(_rs_log_num "${RS_LOG_LEVEL}")" -ne 4 ]]; then
        printf '%s: %s\n' "${RS_PROG_NAME}" "$*" >&2
    fi
}

# Exit with an error message. Optionally takes an exit code first:
#   rs_die "boom"          -> exit 1
#   rs_die 2 "boom"        -> exit 2
rs_die() {
    local code=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift
    fi
    rs_log_error "$*"
    exit "${code}"
}

# --------------------------------------------------------------- execution --

# Guard a destructive action behind dry-run mode.
# Usage:
#   if rs_dry_run "download installer kernel"; then
#       rs_fetch "${url}" "${dest}"
#   fi
# Returns 0 when the action should proceed, 1 when it was skipped.
rs_dry_run() {
    if [[ "${RS_DRY_RUN:-0}" == "1" ]]; then
        rs_log_info "[dry-run] ${*}"
        return 1
    fi
    return 0
}

# Interactive confirmation. Pass a question and optional default.
#   rs_confirm "Proceed?"            # default: no
#   rs_confirm "Proceed?" yes        # default: yes
# Returns 0 if yes, 1 if no. In non-interactive mode honours $RS_ASSUME_YES.
rs_confirm() {
    local prompt="${1:?rs_confirm: missing prompt}" default="${2:-no}"
    if [[ "${RS_ASSUME_YES:-0}" == "1" ]]; then
        rs_log_info "confirmation assumed yes (--yes): ${prompt}"
        return 0
    fi
    if [[ "${RS_DRY_RUN:-0}" == "1" ]]; then
        rs_log_info "[dry-run] would ask: ${prompt} (assumed yes for planning)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        rs_log_warn "not interactive; refusing ${prompt} (use --yes to override)"
        return 1
    fi
    local hint
    case "${default}" in
        yes) hint="[Y/n]" ;;
        no) hint="[y/N]" ;;
        *) hint="[y/N]" ;;
    esac
    local reply
    while :; do
        printf '%s %s ' "${prompt}" "${hint}" >&2
        IFS= read -r reply || return 1
        case "${reply}" in
            "") [[ "${default}" == "yes" ]] && return 0 || return 1 ;;
            y | Y | yes | YES) return 0 ;;
            n | N | no | NO) return 1 ;;
        esac
    done
}

# Fail if a required command is not present on PATH.
rs_require() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            rs_die "required command not found: ${cmd}"
        fi
    done
}

# Fail unless we are running as root (reinstalls require root).
rs_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        rs_die "this tool must be run as root (it reconfigures disks and bootloaders)"
    fi
}

# True if $1 is an obvious "yes" value.
rs_is_yes() {
    case "${1:-}" in
        1 | yes | YES | Yes | true | TRUE | on | ON) return 0 ;;
    esac
    return 1
}

# True if $1 is in the whitespace-separated list $2.
rs_in_list() {
    local item="${1}" list="${2:-}"
    local entry
    for entry in ${list}; do
        [[ "${entry}" == "${item}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------- misc kit --

# Generate $1 bytes of random lowercase hex (default 8).
rs_random_hex() {
    local n="${1:-8}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "${n}"
    elif [[ -r /dev/urandom ]]; then
        od -An -N "$((n / 2 + 1))" -tx1 /dev/urandom | tr -d ' \n' | cut -c1-"$((n * 2))"
    else
        # Last resort, not cryptographically strong — better than nothing.
        printf '%s' "$$$(date +%s)" | sha256sum | cut -c1-"$((n * 2))"
    fi
}

# Non-interactive-agnostic URL check.
# Returns 0 if the URL looks fetchable (scheme whitelist).
rs_validate_url_shape() {
    case "${1:-}" in
        http://* | https://*) return 0 ;;
        *) return 1 ;;
    esac
}

# Clean up a password/hash value of surrounding quotes used on the CLI.
rs_unquote() {
    local v="${1}"
    v="${v#\"}"
    v="${v%\"}"
    printf '%s\n' "${v}"
}

# ------------------------------------------------------------- config path --

# Default configuration file locations, in priority order.
RS_CONFIG_PATH_DEFAULT="/etc/restage.conf:${RS_REPO_ROOT}/restage.conf"
RS_CONFIG_PATH="${RS_CONFIG_PATH:-${RS_CONFIG_PATH_DEFAULT}}"
