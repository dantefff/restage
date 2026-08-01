#!/usr/bin/env bats
#
# Unit tests for lib/disk.sh
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/disk.sh"

@test "ptuuid: accepts MBR hex and GPT GUID" {
    run rs_ptuuid_valid "01234567"
    [ "$status" -eq 0 ]

    run rs_ptuuid_valid "01234567-89ab-cdef-0123-456789abcdef"
    [ "$status" -eq 0 ]
}

@test "ptuuid: rejects junk" {
    run rs_ptuuid_valid "not-a-uuid"
    [ "$status" -ne 0 ]

    run rs_ptuuid_valid ""
    [ "$status" -ne 0 ]
}

@test "identify: uses pre-set overrides and validates them" {
    export RS_DISK_DEV="/dev/vda"
    export RS_DISK_PTUUID="deadbeef"
    run rs_disk_identify
    [ "$status" -eq 0 ]

    export RS_DISK_PTUUID="!!!"
    run rs_disk_identify
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid partition-table UUID"* ]]
}

@test "identify: real hardware path works when a disk exists" {
    if ! command -v lsblk >/dev/null 2>&1 || ! command -v findmnt >/dev/null 2>&1; then
        skip "lsblk/findmnt not available"
    fi
    unset RS_DISK_DEV RS_DISK_PTUUID
    run rs_root_device
    if [ "$status" -eq 0 ] && [[ -n "$output" ]]; then
        run rs_main_disk
        if [ "$status" -eq 0 ]; then
            run rs_disk_ptuuid "${output}"
            if [ "$status" -eq 0 ]; then
                run rs_ptuuid_valid "${output}"
                [ "$status" -eq 0 ]
            fi
        fi
    fi
}

@test "parent disk: nvme and mmc names" {
    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/disk.sh"
        rs_parent_disk /dev/nvme0n1p1
    '
    [ "$output" = "/dev/nvme0n1" ]

    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/disk.sh"
        rs_parent_disk /dev/mmcblk0p2
    '
    [ "$output" = "/dev/mmcblk0" ]
}
