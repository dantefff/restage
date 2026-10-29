#!/usr/bin/env bats
#
# Unit tests for shared CLI credential handling in lib/args.sh.
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/config.sh"
source "${BATS_TEST_DIRNAME}/../../lib/validate.sh"
source "${BATS_TEST_DIRNAME}/../../lib/args.sh"

setup_credentials() {
    rs_config_defaults
    RS_BOOTLOADER_OVERRIDE=auto
    RS_PASSWORD=""
    RS_SSH_KEY=""
}

@test "args: generates a password when neither password nor key is set" {
    setup_credentials
    rs_args_validate_common
    [ -n "$RS_PASSWORD" ]
    [ "${#RS_PASSWORD}" -ge 8 ]
}

@test "args: keeps an explicit password" {
    setup_credentials
    RS_PASSWORD="explicit-pass"
    rs_args_validate_common
    [ "$RS_PASSWORD" = "explicit-pass" ]
}

@test "args: does not generate a password when an SSH key is set" {
    setup_credentials
    RS_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test"
    rs_args_validate_common
    [ -z "$RS_PASSWORD" ]
}
