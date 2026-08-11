#!/usr/bin/env bats
#
# Unit tests for the pure POSIX-sh helpers in runtime/windows.sh
# (netmask math, XML escaping, partition naming). Hardware actions in
# win_main are not exercised here.
#
# shellcheck shell=bash

load ../helpers.bash

# Run a helper in a clean bash so windows.sh's `set -u` does not leak.
run_win() {
    run bash -c "source \"${BATS_TEST_DIRNAME}/../../runtime/windows.sh\"; $*"
}

@test "win_netmask: common prefixes" {
    run_win 'win_netmask 24'
    [ "$output" = "255.255.255.0" ]
    run_win 'win_netmask 8'
    [ "$output" = "255.0.0.0" ]
    run_win 'win_netmask 32'
    [ "$output" = "255.255.255.255" ]
    run_win 'win_netmask 0'
    [ "$output" = "0.0.0.0" ]
}

@test "win_netmask: clamps invalid input" {
    run_win 'win_netmask 33'
    [ "$output" = "255.255.255.0" ]
    run_win 'win_netmask abc'
    [ "$output" = "255.255.255.0" ]
    run_win 'win_netmask 16'
    [ "$output" = "255.255.0.0" ]
}

@test "win_xml_escape: escapes special characters" {
    run_win 'win_xml_escape "a&b<c>d\"e"'
    [ "$output" = "a&amp;b&lt;c&gt;d&quot;e" ]
    run_win 'win_xml_escape "plain"'
    [ "$output" = "plain" ]
}

@test "win_part_name: adds p for numbered devices" {
    run_win 'win_part_name /dev/nvme0n1 1'
    [ "$output" = "/dev/nvme0n1p1" ]
    run_win 'win_part_name /dev/mmcblk0 2'
    [ "$output" = "/dev/mmcblk0p2" ]
    run_win 'win_part_name /dev/vda 3'
    [ "$output" = "/dev/vda3" ]
    run_win 'win_part_name /dev/sda 1'
    [ "$output" = "/dev/sda1" ]
}
