#!/usr/bin/env bash
#
# state.sh — persisted state that lets `restage reset` undo a pending
# reinstall *before* the machine reboots.
#
# State lives in RS_STATE_DIR (default /var/restage) as a flat KEY=VALUE
# file plus a manifest of files we created. It is deliberately plain so a
# human can read exactly what a run is about to do.
#
# shellcheck shell=bash

rs_import lib/common.sh

RS_STATE_DIR="${RS_STATE_DIR:-/var/restage}"

# State paths are resolved per call so RS_STATE_DIR can be overridden at
# runtime (tests override it; reset may point elsewhere).
_rs_state_dir() { printf '%s\n' "${RS_STATE_DIR:-/var/restage}"; }
_rs_state_file() { printf '%s\n' "$(_rs_state_dir)/state.conf"; }
_rs_state_files() { printf '%s\n' "$(_rs_state_dir)/files.list"; }

# Initialise the state directory (no-op if it exists).
rs_state_init() {
    mkdir -p "$(_rs_state_dir)"
}

# Set a key/value pair in the on-disk state.
rs_state_set() {
    local key="${1:?rs_state_set: missing key}" value="${2}"
    local state_file
    state_file="$(_rs_state_file)"
    rs_state_init
    # Rewrite the file, preserving existing keys.
    local tmp="${state_file}.tmp"
    : >"${tmp}"
    if [[ -f "${state_file}" ]]; then
        local line existing_key
        while IFS= read -r line || [[ -n "${line}" ]]; do
            existing_key="${line%%=*}"
            if [[ "${existing_key}" == "${key}" ]]; then
                continue
            fi
            printf '%s\n' "${line}" >>"${tmp}"
        done <"${state_file}"
    fi
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
    mv "${tmp}" "${state_file}"
    chmod 600 "${state_file}"
}

# Read a key from state. Prints nothing and returns 1 when absent.
rs_state_get() {
    local key="${1:?rs_state_get: missing key}"
    local state_file
    state_file="$(_rs_state_file)"
    if [[ -f "${state_file}" ]]; then
        local line
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" == "${key}="* ]]; then
                printf '%s\n' "${line#*=}"
                return 0
            fi
        done <"${state_file}"
    fi
    return 1
}

# Record a file (or dir) created by the current run, so reset can remove it.
rs_state_track_file() {
    local path="${1:?rs_state_track_file: missing path}"
    rs_state_init
    printf '%s\n' "${path}" >>"$(_rs_state_files)"
}

# True when a pending reinstall state exists.
rs_state_exists() {
    [[ -s "$(_rs_state_file)" ]]
}

# Remove every tracked file/dir and the state files themselves.
rs_state_clear() {
    local state_file files_list
    state_file="$(_rs_state_file)"
    files_list="$(_rs_state_files)"
    if [[ -f "${files_list}" ]]; then
        local path
        while IFS= read -r path || [[ -n "${path}" ]]; do
            if [[ -e "${path}" || -L "${path}" ]]; then
                rm -rf -- "${path}" 2>/dev/null || rs_log_warn "could not remove ${path}"
            fi
        done <"${files_list}"
    fi
    rm -f -- "${state_file}" "${files_list}"
    # Remove the state dir only if it's empty now.
    rmdir "$(_rs_state_dir)" 2>/dev/null || true
}
