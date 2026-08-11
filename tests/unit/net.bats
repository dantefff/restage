#!/usr/bin/env bats
#
# Unit tests for lib/net.sh capture/rendering.
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/net.sh"

# Emulate `ip -o addr show` output (Ubuntu iproute2 format).
stub_ip() {
    ip() {
        if [[ "$1" == "-o" && "$2" == "addr" ]]; then
            printf '2: eth0    inet 169.58.143.165/17 brd 169.58.255.255 scope global eth0\\       valid_lft forever\n'
        fi
    }
}

@test "net: cidr capture keeps the prefix length" {
    stub_ip
    run rs_net_iface_cidr_v4 eth0
    [ "$output" = "169.58.143.165/17" ]
}

@test "net: dns capture prefers resolv.conf nameservers" {
    local resolv="${BATS_TEST_TMPDIR}/resolv.conf"
    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' >"${resolv}"
    local dns
    dns="$(awk '/^nameserver/{print $2}' "${resolv}" 2>/dev/null | grep -vE '^(127\.|::1$)' | tr '\n' ' ' | sed 's/ $//')"
    [ "$dns" = "9.9.9.9 1.1.1.1" ]
}

@test "net: static render includes the /prefix and a default DNS" {
    RS_IPV4_ADDR="192.0.2.10/24"
    RS_IPV4_GW="192.0.2.1"
    RS_IPV6_ADDR=""
    RS_IPV6_GW=""
    RS_IPV4_DNS=""
    RS_NET_DHCP="no"
    run rs_net_render_script eth0
    [[ "$output" == *"ip addr replace 192.0.2.10/24 dev"* ]]
    [[ "$output" == *"nameserver 1.1.1.1"* ]]
    [[ "$output" == *"nameserver 8.8.8.8"* ]]
}

@test "net: static render writes captured dns when present" {
    RS_IPV4_ADDR="192.0.2.10/24"
    RS_IPV4_GW="192.0.2.1"
    RS_IPV6_ADDR=""
    RS_IPV6_GW=""
    RS_IPV4_DNS="9.9.9.9 1.1.1.1"
    RS_NET_DHCP="no"
    run rs_net_render_script eth0
    [[ "$output" == *"nameserver 9.9.9.9"* ]]
}
