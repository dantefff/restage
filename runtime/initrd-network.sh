#!/bin/sh
#
# runtime/initrd-network.sh — bring up networking inside the installer.
#
# If a /network.sh script was injected by the host tool, it is executed
# (it encodes either the captured static config or a DHCP fallback).
# Otherwise we fall back to udhcpc on every interface.
#
# Strict POSIX sh. Run early in trans.sh, before any downloads.

set -u

initrd_network_up() {
    if [ -f /network.sh ]; then
        log "applying injected network configuration"
        sh /network.sh && return 0
        warn "injected network config failed; falling back to DHCP"
    fi

    for iface in /sys/class/net/*; do
        name=${iface##*/}
        case "$name" in lo | sit* | tun*) continue ;; esac
        ip link set "$name" up 2>/dev/null || true
        udhcpc -q -i "$name" 2>/dev/null && return 0
        udhcpc -q -i "$name" -t 15 2>/dev/null && return 0
    done
    return 1
}

# Ensure DNS is usable even if nothing set resolv.conf.
ensure_resolv() {
    if [ ! -s /etc/resolv.conf ]; then
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
    fi
}

# Source a captured static config if one exists (host may inject /net-static.sh).
initrd_network_apply_static() {
    if [ -f /net-static.sh ]; then
        . /net-static.sh
    fi
}
