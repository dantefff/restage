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
    # trans.sh runs as PID 1 (init=/trans.sh). If PID 1 exits, the kernel
    # has nothing left to run and the box becomes unreachable — no SSH, no
    # shell, nothing short of the provider's console/VNC. That turned every
    # installer-stage failure (e.g. an unresolved Windows ISO link) into a
    # silent, unrecoverable dead end instead of a visible, fixable error.
    #
    # Drop into a reachable rescue state instead: bring up SSH (and the log
    # viewer) with whatever credentials were provided, if those helpers are
    # already defined at this point in trans.sh, then idle forever so the
    # operator can log in, read /restage.log, and retry with corrected
    # input (e.g. `restage windows --iso <direct URL>`) instead of being
    # locked out.
    if command -v setup_root_auth >/dev/null 2>&1; then
        setup_root_auth 2>/dev/null || true
    fi
    if command -v start_sshd >/dev/null 2>&1; then
        start_sshd 2>/dev/null || true
    fi
    if command -v start_logviewer >/dev/null 2>&1; then
        start_logviewer 2>/dev/null || true
    fi
    printf '[restage] FATAL: dropped to a rescue state (SSH port %s if it started) — fix the input and retry; see /restage.log\n' \
        "${RESTAGE_SSH_PORT:-22}"
    while :; do
        sleep 60
    done
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

# Confirm-like helper for the installer. When the host tool was run with
# --yes (RESTAGE_ASSUME_YES=1) it never prompts, keeping the install fully
# unattended. Otherwise it reads from the console.
confirm() {
    if [ "${RESTAGE_ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    _q="$1"
    printf '[restage] %s (y/N) ' "$_q"
    read _reply
    case "$_reply" in
        y | Y | yes | YES) return 0 ;;
    esac
    return 1
}

# Download a URL to a file. busybox wget is preferred, curl is a fallback.
# Usage: fetch <url> <dest>
fetch() {
    _url=$1
    _dest=$2
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$_dest" "$_url" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$_dest" "$_url" && return 0
    fi
    die "no downloader available (need wget or curl)"
}

# Download a URL to stdout. Usage: fetch_stdout <url>
fetch_stdout() {
    _url=$1
    if command -v wget >/dev/null 2>&1; then
        wget -q -O- "$_url" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" && return 0
    fi
    die "no downloader available (need wget or curl)"
}

# Create the busybox applet symlinks (the initrd ships a single busybox
# binary; the stock init script does this, but we boot with init=/trans.sh
# so we have to do it ourselves).
install_applets() {
    if [ -x /bin/busybox ]; then
        /bin/busybox --install -s 2>/dev/null || true
    fi
}

# Write an /etc/apk/repositories file if it is missing. Usage: apk_repos <ver>
apk_repos() {
    _ver=$1
    if [ ! -s /etc/apk/repositories ]; then
        {
            printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/main\n' "$_ver"
            printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/community\n' "$_ver"
        } >/etc/apk/repositories
    fi
    # The netboot initramfs has no apk database yet; without one every apk
    # invocation fails with "Unable to lock database". Initialize it lazily.
    if [ ! -f /lib/apk/db/installed ]; then
        mkdir -p /lib/apk/db
        apk add --initdb >/dev/null 2>&1 || true
    fi
}

# Load the kernel driver for every probed device via its MODALIAS. The stock
# Alpine initramfs /init delegates this to nlplug-findfs; we are PID 1 now so
# we do it ourselves (two passes: PCI transport first, then the devices it
# exposes on virtio/scsi/... buses, then refresh device nodes).
load_device_modules() {
    _m=""
    for _m in /sys/bus/pci/devices/*/modalias; do
        _ma=$(cat "$_m" 2>/dev/null) || continue
        [ -n "$_ma" ] || continue
        modprobe "$_ma" 2>/dev/null || true
    done
    # A bus controller binding here (e.g. a virtio-scsi HBA) makes the
    # kernel probe for its child devices (e.g. the actual disk) on a
    # separate thread; that child's modalias file can appear a moment
    # after the controller's modprobe returns rather than immediately.
    # Rescan a few times with short pauses so late arrivals still bind
    # (seen in practice: virtio-scsi disks staying undetected because
    # sd_mod never got loaded).
    _pass=0
    while [ "$_pass" -lt 5 ]; do
        for _m in /sys/bus/*/devices/*/modalias; do
            _ma=$(cat "$_m" 2>/dev/null) || continue
            [ -n "$_ma" ] || continue
            modprobe "$_ma" 2>/dev/null || true
        done
        _pass=$((_pass + 1))
        [ "$_pass" -lt 5 ] && sleep 1
    done
    mdev -s 2>/dev/null || true
}

# Download and merge Alpine's "modloop" — a squashfs of kernel modules that
# Alpine's official netboot process ships alongside the kernel/initramfs but
# deliberately keeps OUT of the base initramfs to stay small (legacy IDE/ATA
# controllers and other less-common hardware live only here). We boot with a
# custom init (init=/trans.sh) instead of Alpine's own init scripts, so
# nothing fetches or mounts it automatically — without this, any hardware
# whose driver isn't in the small base module set stays invisible no matter
# how many times load_device_modules() retries (e.g. a VPS whose disk is on
# an emulated PIIX3/IDE controller instead of virtio-blk).
#
# Requires networking to already be up. Usage: fetch_modloop <url>
fetch_modloop() {
    _url=${1:?fetch_modloop: missing modloop URL}
    _kver=$(uname -r)
    log "fetching Alpine modloop (extra kernel modules) from $_url"
    if ! fetch "$_url" /modloop.img; then
        warn "could not download modloop; hardware whose driver isn't in the base initramfs will stay undetected"
        return 1
    fi
    mkdir -p /modloop
    modprobe loop 2>/dev/null || true
    modprobe squashfs 2>/dev/null || true
    if ! mount -t squashfs -o loop,ro /modloop.img /modloop 2>/dev/null; then
        warn "could not mount modloop (squashfs support missing?); continuing without extra modules"
        return 1
    fi
    # The internal layout of Alpine's modloop has varied across releases, so
    # find the directory that actually holds this kernel's modules rather
    # than assume a fixed path.
    _src=$(find /modloop -maxdepth 4 -type d -name "$_kver" 2>/dev/null | head -n1)
    if [ -z "$_src" ]; then
        warn "modloop mounted but no module tree for $_kver found inside it"
        return 1
    fi
    cp -a "$_src/." "/lib/modules/$_kver/" 2>/dev/null
    depmod -a "$_kver" 2>/dev/null || depmod 2>/dev/null || true
    log "modloop merged into /lib/modules/$_kver"
    return 0
}
