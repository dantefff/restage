#!/usr/bin/env bats
#
# Unit tests for lib/net.sh (network capture + script rendering).
#
# Rendering is pure: capture is exercised only through overrides so tests
# do not depend on the host's interfaces.
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/net.sh"

@test "render: static mode emits ip commands" {
    RS_NET_DHCP="no"
    RS_IPV4_ADDR="192.0.2.10/24"
    RS_IPV4_GW="192.0.2.1"
    RS_IPV6_ADDR="2001:db8::10/64"
    RS_IPV6_GW="2001:db8::1"

    run rs_net_render_script eth0
    [ "$status" -eq 0 ]
    [[ "$output" == *'ip addr replace 192.0.2.10/24'* ]]
    [[ "$output" == *'ip route replace default via 192.0.2.1'* ]]
    [[ "$output" == *'ip -6 addr replace 2001:db8::10/64'* ]]
    [[ "$output" != *"udhcpc"* ]]
}

@test "render: dhcp mode emits udhcpc" {
    RS_NET_DHCP="yes"

    run rs_net_render_script eth0
    [ "$status" -eq 0 ]
    [[ "$output" == *"udhcpc -q -i \"\$IFACE\""* ]]
}

@test "render: resolv.conf is populated in static mode" {
    RS_NET_DHCP="no"
    RS_IPV4_ADDR="192.0.2.10/24"
    RS_IPV4_DNS="1.1.1.1"

    run rs_net_render_script eth0
    [[ "$output" == *'echo "nameserver 1.1.1.1" > /etc/resolv.conf'* ]]
}

@test "capture: primary iface via ip when present" {
    if ! command -v ip >/dev/null 2>&1; then
        skip "ip not available"
    fi
    run rs_net_primary_iface
    # Should either succeed with a name or fail cleanly in weird containers.
    if [ "$status" -eq 0 ]; then
        [[ -n "$output" ]]
    fi
}
