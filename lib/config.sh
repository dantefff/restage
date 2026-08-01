#!/usr/bin/env bash
#
# config.sh — configuration file loading and defaults.
#
# restage supports an optional INI-flavoured config file:
#
#     # comment
#     log_level = info
#     assume_yes = 0
#     ssh_port = 22
#
# Keys are converted to the corresponding RS_* option. Unknown keys are
# ignored with a warning. The CLI always overrides the config file.
#
# shellcheck shell=bash

rs_import lib/common.sh

# Map of config key -> RS_* variable name. Only these keys are accepted.
rs_config_defaults() {
    RS_LOG_LEVEL="${RS_LOG_LEVEL:-${RS_LOG_LEVEL_DEFAULT}}"
    RS_LOG_FILE="${RS_LOG_FILE:-}"
    RS_ASSUME_YES="${RS_ASSUME_YES:-0}"
    RS_DRY_RUN="${RS_DRY_RUN:-0}"
    RS_SSH_PORT="${RS_SSH_PORT:-22}"
    RS_WEB_PORT="${RS_WEB_PORT:-80}"
    RS_USERNAME="${RS_USERNAME:-root}"
    RS_PASSWORD="${RS_PASSWORD:-}"
    RS_SSH_KEY="${RS_SSH_KEY:-}"
    RS_HOLD="${RS_HOLD:-0}"
    RS_STATE_DIR="${RS_STATE_DIR:-/var/restage}"
    RS_WORK_DIR="${RS_WORK_DIR:-/restage}"
    RS_FORCE="${RS_FORCE:-0}"
    RS_NET_DHCP="${RS_NET_DHCP:-auto}"
}

# True if the given config key was explicitly set on the CLI (and therefore
# must win over any config file).
_rs_config_cli_locked() {
    local key="${1}" item
    for item in "${RS_CLI_SET[@]:-}"; do
        [[ "${item}" == "${key}" ]] && return 0
    done
    return 1
}

# Apply a single `key = value` line from a config file.
rs_config_apply_line() {
    local key="${1}" value="${2}"
    if _rs_config_cli_locked "${key}"; then
        rs_log_debug "config key '${key}' ignored (set on the command line)"
        return 0
    fi
    case "${key}" in
        log_level) RS_LOG_LEVEL="${value}" ;;
        log_file) RS_LOG_FILE="${value}" ;;
        assume_yes) RS_ASSUME_YES="${value}" ;;
        dry_run) RS_DRY_RUN="${value}" ;;
        ssh_port) RS_SSH_PORT="${value}" ;;
        web_port) RS_WEB_PORT="${value}" ;;
        username) RS_USERNAME="${value}" ;;
        password) RS_PASSWORD="${value}" ;;
        ssh_key) RS_SSH_KEY="${value}" ;;
        hold) RS_HOLD="${value}" ;;
        state_dir) RS_STATE_DIR="${value}" ;;
        work_dir) RS_WORK_DIR="${value}" ;;
        force) RS_FORCE="${value}" ;;
        net_dhcp) RS_NET_DHCP="${value}" ;;
        *)
            rs_msg "ignoring unknown config key: ${key}"
            ;;
    esac
}

# Load a single config file (does not fail if absent).
rs_config_load_file() {
    local path="${1}"
    if [[ ! -f "${path}" ]]; then
        return 0
    fi
    rs_log_debug "loading config: ${path}"
    local line key value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # strip comments
        line="${line%%#*}"
        [[ -z "${line}" ]] && continue
        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%"${value##*[![:space:]]}"}" # rtrim
            value="${value#\"}"
            value="${value%\"}"
            rs_config_apply_line "${key}" "${value}"
        else
            rs_msg "malformed config line ignored: ${line}"
        fi
    done <"${path}"
}

# Load all configured files in order (first wins, later files don't override).
rs_config_load_all() {
    rs_config_defaults
    local path
    IFS=':' read -r -a _rs_paths <<<"${RS_CONFIG_PATH}"
    for path in "${_rs_paths[@]}"; do
        [[ -z "${path}" ]] && continue
        rs_config_load_file "${path}"
    done
}
