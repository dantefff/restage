#!/usr/bin/env bats
#
# Unit tests for lib/install.sh (initrd handling) and lib/common.sh helpers.
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/install.sh"

# Build a tiny gzipped cpio archive (a stand-in initrd).
make_initrd() {
    local dir="${BATS_TEST_TMPDIR}/initrd-src"
    rm -rf "${dir}"
    mkdir -p "${dir}/bin"
    echo '#!/bin/sh' >"${dir}/bin/sh"
    chmod +x "${dir}/bin/sh"
    (cd "${dir}" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 >"${BATS_TEST_TMPDIR}/fixture-initrd.gz")
}

@test "initrd type: detects gzip" {
    make_initrd
    run rs_initrd_type "${BATS_TEST_TMPDIR}/fixture-initrd.gz"
    [ "$output" = "gzip" ]
}

@test "initrd type: detects xz and raw" {
    if ! command -v cpio >/dev/null 2>&1 || ! command -v xz >/dev/null 2>&1; then
        skip "cpio/xz not available"
    fi
    make_initrd
    local dir="${BATS_TEST_TMPDIR}/initrd-src"
    (cd "${dir}" && find . -print0 | cpio --null -o -H newc 2>/dev/null | xz -z >"${BATS_TEST_TMPDIR}/fixture-initrd.xz")
    run rs_initrd_type "${BATS_TEST_TMPDIR}/fixture-initrd.xz"
    [ "$output" = "xz" ]

    (cd "${dir}" && find . -print0 | cpio --null -o -H newc 2>/dev/null >"${BATS_TEST_TMPDIR}/fixture-initrd.raw")
    run rs_initrd_type "${BATS_TEST_TMPDIR}/fixture-initrd.raw"
    [ "$output" = "raw" ]
}

@test "initrd patch: unpack/inject/repack roundtrip" {
    if ! command -v cpio >/dev/null 2>&1; then
        skip "cpio not available"
    fi
    make_initrd
    local inject="${BATS_TEST_TMPDIR}/inject"
    mkdir -p "${inject}"
    echo "payload" >"${inject}/trans.sh"

    local out="${BATS_TEST_TMPDIR}/patched.img"
    run rs_initrd_patch "${BATS_TEST_TMPDIR}/fixture-initrd.gz" "${out}" "${inject}"
    [ "$status" -eq 0 ]
    [ -s "${out}" ]

    # Unpack the result and verify both original and injected files exist.
    local verify="${BATS_TEST_TMPDIR}/verify"
    rs_initrd_unpack "${out}" "${verify}"
    [ -f "${verify}/bin/sh" ]
    [ -f "${verify}/trans.sh" ]
    grep -q payload "${verify}/trans.sh"
}

# ------------------------------------------------------------- common ----

@test "common: random hex is hex of the right length" {
    local out
    out="$(rs_random_hex 8)"
    [[ "$out" =~ ^[0-9a-f]{16}$ ]]
}

@test "common: rs_is_yes recognises yes values" {
    rs_is_yes yes && rs_is_yes 1 && rs_is_yes true
    run bash -c 'source "${RS_REPO_ROOT}/lib/common.sh"; rs_is_yes nope'
    [ "$status" -ne 0 ]
}

@test "common: rs_in_list membership" {
    rs_in_list b "a b c"
    run bash -c 'source "${RS_REPO_ROOT}/lib/common.sh"; rs_in_list z "a b c"'
    [ "$status" -ne 0 ]
}
