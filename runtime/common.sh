#!/bin/sh
#
# runtime/common.sh — minimal helpers for the initrd-side installer.
#
# This file is copied INTO the initrd and runs in a busybox/ash
# environment, so it must stay strict POSIX sh with no bashisms and no
# dependencies beyond busybox applets.
#
# It is sourced by trans.sh.

set -u

# Every log line is prefixed so it is greppable from the console or VNC.
log() {
    printf '[restage] %s\n' "$*"
}

warn() {
    printf '[restage] WARN: %s\n' "$*"
}

die() {
    printf '[restage] FATAL: %s\n' "$*"
    exit 1
}

# Load KEY=VALUE pairs from a generated config file into the environment.
# The host tool writes every value POSIX-single-quoted, so sourcing is safe.
# Usage: load_conf /restage.conf
load_conf() {
    [ -f "$1" ] || die "configuration file $1 not found"
    # shellcheck disable=SC1090
    . "$1"
}

# Require a command, or die with a clear message.
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Wait for network link on $1 (seconds).
wait_link() {
    _iface="$1"
    _n=0
    while [ "$_n" -lt 30 ]; do
        if ip link show "$_iface" >/dev/null 2>&1; then
            state=$(ip -o link show "$_iface" 2>/dev/null | awk '{print $9}')
            [ "$state" = "UP" ] && return 0
        fi
        sleep 1
        _n=$((_n + 1))
    done
    warn "link on $_iface did not come up in time"
    return 1
}

# Confirm-like helper for the installer (always reads from the console).
confirm() {
    _q="$1"
    printf '[restage] %s (y/N) ' "$_q"
    read _reply
    case "$_reply" in
        y | Y | yes | YES) return 0 ;;
    esac
    return 1
}
