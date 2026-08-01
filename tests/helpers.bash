#!/usr/bin/env bash
#
# helpers.bash — shared test environment for bats.
#
# Every test sources the libraries directly and runs in an isolated
# temporary work/state directory. Tests must never touch the real disk or
# bootloader: hardware-dependent functions are exercised through their
# pure helpers (validation, rendering, catalog resolution) and the dry-run
# paths of the CLI.
#
# shellcheck shell=bash

setup() {
    export RS_REPO_ROOT
    RS_REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export RS_WORK_DIR="${BATS_TEST_TMPDIR}/work"
    export RS_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    export RS_CONFIG_PATH="${BATS_TEST_TMPDIR}/nope.conf"
    export RS_LOG_LEVEL="error"
    export NO_COLOR=1
    export RS_DRY_RUN=0
    export RS_ASSUME_YES=0

    # Deterministic hardware overrides so tests don't depend on the host.
    export RS_DISK_DEV="${RS_DISK_DEV:-/dev/vda}"
    export RS_DISK_PTUUID="${RS_DISK_PTUUID:-01234567}"

    # shellcheck source=/dev/null
    source "${RS_REPO_ROOT}/lib/common.sh"
}

teardown() {
    rm -rf -- "${RS_WORK_DIR}" "${RS_STATE_DIR}"
}
