#!/usr/bin/env bats
#
# Unit tests for lib/oslib.sh (catalog parsing + OS resolution).
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/oslib.sh"
rs_os_load_catalog

@test "catalog: known distros include alpine and debian" {
    run rs_os_known alpine
    [ "$status" -eq 0 ]

    run rs_os_known debian
    [ "$status" -eq 0 ]

    run rs_os_known definitely-not-a-distro
    [ "$status" -ne 0 ]
}

@test "catalog: lists all distros" {
    run rs_os_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpine"* ]]
    [[ "$output" == *"debian"* ]]
}

@test "resolve: alpine picks default version" {
    rs_os_resolve alpine ""
    [ "$RS_OS_NAME" = "alpine" ]
    [ "$RS_OS_VERSION" = "3.22" ]
    [ "$RS_OS_INSTALLER" = "alpine_live" ]
    [[ "$RS_OS_BOOT_KERNEL" == *"v3.22"* ]]
    [[ "$RS_OS_BOOT_KERNEL" == *"/x86_64/netboot/vmlinuz-lts"* ]]
}

@test "resolve: debian uses codename-aware cloud URL and amd64 alias" {
    RS_OS_CATALOG_FILE="${BATS_TEST_DIRNAME}/../../data/distros.conf"
    rs_os_load_catalog
    rs_os_resolve debian 12
    [ "$RS_OS_INSTALLER" = "cloud" ]
    [ "$RS_OS_VERSION" = "12" ]
    [[ "$RS_OS_IMAGE" == *"/bookworm/"* ]]
    [[ "$RS_OS_IMAGE" == *"debian-12-genericcloud-amd64.qcow2"* ]]
    # The boot kernel must be the pinned Alpine version, not Debian 12.
    [[ "$RS_OS_BOOT_KERNEL" == *"v3.22"* ]]
}

@test "resolve: unknown version is rejected" {
    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/oslib.sh"
        rs_os_load_catalog
        rs_os_resolve debian 99
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported version"* ]]
}

@test "resolve: no such distro dies with list" {
    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/oslib.sh"
        rs_os_load_catalog
        rs_os_resolve bogus ""
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown distribution"* ]]
}

@test "expand: substitutes ver, arch, carch, codename" {
    local out
    out="$(rs_os_expand "v{ver}/{arch}/{carch}/{codename}" "12" "x86_64" "amd64" "bookworm")"
    [ "$out" = "v12/x86_64/amd64/bookworm" ]
}

@test "requirements: overrides honoured via RS_FORCE" {
    # Simulate a machine with almost no RAM.
    export RS_OS_MIN_RAM=1048576
    export RS_OS_NAME=debian
    export RS_FORCE=0
    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/oslib.sh"
        RS_OS_MIN_RAM=1048576 RS_OS_NAME=debian RS_FORCE=0 \
            rs_os_check_requirements
    '
    [ "$status" -ne 0 ]

    run bash -c '
        source "${RS_REPO_ROOT}/lib/common.sh"
        source "${RS_REPO_ROOT}/lib/oslib.sh"
        RS_OS_MIN_RAM=1048576 RS_OS_NAME=debian RS_FORCE=1 \
            rs_os_check_requirements
    '
    [ "$status" -eq 0 ]
}
