#!/usr/bin/env bats
#
# Unit tests for lib/boot.sh
#
# The tests exercise the grub entry writer against throwaway files so no
# bootloader on the host is touched.
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/boot.sh"
source "${BATS_TEST_DIRNAME}/../../lib/state.sh"

@test "detect: returns one of grub|extlinux|efi|none" {
    run rs_boot_detect
    [ "$status" -eq 0 ]
    case "$output" in
        grub | extlinux | efi | none) : ;;
        *)
            echo "unexpected bootloader detection: ${output}" >&2
            return 1
            ;;
    esac
}

@test "render grub entry: well-formed menuentry" {
    local out
    out="$(rs_boot_render_grub_entry "restage" "/vmlinuz" "/initrd.img" "init=/trans.sh")"
    [[ "$out" == *'menuentry "restage" --id restage {'* ]]
    [[ "$out" == *"linux /vmlinuz init=/trans.sh"* ]]
    [[ "$out" == *"initrd /initrd.img"* ]]
    [[ "$out" == *"}" ]]
}

@test "write grub: creates entry file and sources it in grub.cfg" {
    local cfg="${BATS_TEST_TMPDIR}/grub.cfg"
    touch "${cfg}"
    export RS_GRUB_CFG="${cfg}"
    export RS_GRUB_ENTRY_FILE="${BATS_TEST_TMPDIR}/entry.cfg"
    export RS_DRY_RUN=0

    # grub-reboot won't exist in the test env; the function must still write
    # the entry and degrade gracefully.
    run rs_boot_write_grub "restage" "/vmlinuz" "/initrd.img" "init=/trans.sh"
    [ "$status" -eq 0 ]

    [ -f "${RS_GRUB_ENTRY_FILE}" ]
    grep -q "source ${RS_GRUB_ENTRY_FILE}" "${cfg}"

    # idempotent: a second call must not duplicate the source line.
    run rs_boot_write_grub "restage" "/vmlinuz" "/initrd.img" "init=/trans.sh"
    [ "$(grep -c "source ${RS_GRUB_ENTRY_FILE}" "${cfg}")" = "1" ]
}

@test "remove grub: cleans up entry file and source line" {
    local cfg="${BATS_TEST_TMPDIR}/grub.cfg"
    local entry="${BATS_TEST_TMPDIR}/entry.cfg"
    printf '# restage one-shot entry (managed)\nsource %s\n' "${entry}" >"${cfg}"
    echo 'menuentry "x" {}' >"${entry}"
    export RS_GRUB_CFG="${cfg}"
    export RS_GRUB_ENTRY_FILE="${entry}"

    run rs_boot_remove_grub
    [ "$status" -eq 0 ]
    [ ! -f "${entry}" ]
    if grep -q "source" "${cfg}"; then
        echo "expected source line to be removed, still present" >&2
        return 1
    fi
}

@test "write grub: dry-run performs no writes" {
    local cfg="${BATS_TEST_TMPDIR}/grub.cfg"
    touch "${cfg}"
    export RS_GRUB_CFG="${cfg}"
    export RS_GRUB_ENTRY_FILE="${BATS_TEST_TMPDIR}/entry.cfg"
    export RS_DRY_RUN=1

    run rs_boot_write_grub "restage" "/vmlinuz" "/initrd.img" "init=/trans.sh"
    [ "$status" -eq 0 ]
    [ ! -f "${RS_GRUB_ENTRY_FILE}" ]
    [ ! -s "${cfg}" ]
}
