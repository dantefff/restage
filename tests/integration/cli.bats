#!/usr/bin/env bats
#
# Integration tests: exercise the CLI end-to-end (dry-run paths only —
# nothing is ever downloaded, written to disk, or rebooted).
#
# shellcheck shell=bash

load ../helpers.bash

CLI="${BATS_TEST_DIRNAME}/../../restage.sh"

run_cli() {
    RS_WORK_DIR="${BATS_TEST_TMPDIR}/work" \
        RS_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
        RS_DISK_DEV="/dev/vda" RS_DISK_PTUUID="01234567" \
        NO_COLOR=1 RS_LOG_LEVEL=info \
        bash "${CLI}" "$@"
}

@test "cli: version" {
    run run_cli version
    [ "$status" -eq 0 ]
    [[ "$output" == "restage "* ]]
}

@test "cli: help lists all commands" {
    run run_cli help
    [ "$status" -eq 0 ]
    for cmd in linux dd windows alpine netboot reset; do
        [[ "$output" == *"$cmd"* ]]
    done
}

@test "cli: unknown command errors" {
    run run_cli frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command"* ]]
}

@test "cli: linux dry-run prints a plan and changes nothing" {
    run run_cli linux debian 12 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"the following actions will be performed"* ]]
    [[ "$output" == *"no changes were made"* ]]
    # The plan must reference the correctly-pinned Alpine boot assets.
    [[ "$output" == *"v3.22/releases/x86_64/netboot/vmlinuz-lts"* ]]
    [[ ! -e "${BATS_TEST_TMPDIR}/state" ]]
}

@test "cli: linux rejects an invalid password before planning" {
    run run_cli linux debian 12 --password short --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 8 characters"* ]]
}

@test "cli: dd dry-run works with --img" {
    run run_cli dd --img https://example.com/image.gz --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=dd"* ]] || [[ "$output" == *"DD of"* ]]
}

@test "cli: dd requires --img" {
    run run_cli dd --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"--img"* ]]
}

@test "cli: dd rejects non-URL images" {
    run run_cli dd --img "not-a-url" --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid image URL"* ]]
}

@test "cli: windows dry-run resolves a catalog edition" {
    run run_cli windows --image-name "Windows 11 Pro" --lang en-us --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Windows 11 Pro"* ]]
}

@test "cli: windows dry-run plans the unattended install steps" {
    run run_cli windows --image-name "Windows 11 Pro" --lang en-us --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"partition"* ]]
    [[ "$output" == *"installer partition"* ]]
    [[ "$output" == *"autounattend.xml"* ]]
    [[ "$output" == *"one-shot boot"* ]]
}

@test "cli: windows dry-run accepts net and driver options" {
    local driver="${BATS_TEST_TMPDIR}/netkvm.inf"
    printf '[Version]\n' >"${driver}"
    run run_cli windows --image-name "Windows 11 Pro" --lang en-us \
        --rdp-port 3390 --allow-ping --add-driver "${driver}" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"one-shot boot"* ]]
}

@test "cli: windows stages an executable network.sh" {
    run run_cli windows --image-name "Windows 11 Pro" --lang en-us --dry-run
    [ "$status" -eq 0 ]
    [ -x "${RS_WORK_DIR}/runtime-stage/network.sh" ]
}

@test "cli: windows requires --image-name" {
    run run_cli windows --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"--image-name"* ]]
}

@test "cli: alpine dry-run plans a rescue boot" {
    run run_cli alpine --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Alpine Live"* ]]
}

@test "cli: reset with no pending state is a no-op" {
    run run_cli reset
    [ "$status" -eq 0 ]
    [[ "$output" == *"no pending reinstall"* ]]
}

@test "cli: config file values are honoured" {
    local cfg="${BATS_TEST_TMPDIR}/restage.conf"
    echo "log_level = debug" >"${cfg}"
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../helpers.bash' 2>/dev/null || true
        RS_CONFIG_PATH='${cfg}' RS_WORK_DIR='${BATS_TEST_TMPDIR}/work' \
        RS_STATE_DIR='${BATS_TEST_TMPDIR}/state' \
        RS_DISK_DEV=/dev/vda RS_DISK_PTUUID=01234567 NO_COLOR=1 \
        bash '${CLI}' linux debian 12 --dry-run
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEBUG"* ]]
}
