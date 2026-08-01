#!/usr/bin/env bats
#
# Unit tests for lib/config.sh
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/config.sh"

@test "defaults: sensible values" {
    rs_config_defaults
    [ "$RS_SSH_PORT" = "22" ]
    [ "$RS_WEB_PORT" = "80" ]
    [ "$RS_USERNAME" = "root" ]
    [ "$RS_DRY_RUN" = "0" ]
}

@test "config file: parsed keys applied" {
    local cfg="${BATS_TEST_TMPDIR}/restage.conf"
    cat >"${cfg}" <<'EOF'
# comment line
ssh_port = 2222
log_level = debug
username = deploy
EOF
    RS_CONFIG_PATH="${cfg}"
    rs_config_load_all
    [ "$RS_SSH_PORT" = "2222" ]
    [ "$RS_LOG_LEVEL" = "debug" ]
    [ "$RS_USERNAME" = "deploy" ]
}

@test "config file: unknown keys warn but do not fail" {
    local cfg="${BATS_TEST_TMPDIR}/restage.conf"
    echo "bogus_key = 1" >"${cfg}"
    RS_CONFIG_PATH="${cfg}"
    run rs_config_load_all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignoring unknown config key: bogus_key"* ]]
}

@test "config file: CLI flags win over file" {
    local cfg="${BATS_TEST_TMPDIR}/restage.conf"
    echo "ssh_port = 2222" >"${cfg}"
    RS_CLI_SET=("ssh_port")
    RS_CONFIG_PATH="${cfg}"
    rs_config_load_all
    [ "$RS_SSH_PORT" = "22" ]
}

@test "config file: missing file is a no-op" {
    RS_CONFIG_PATH="${BATS_TEST_TMPDIR}/definitely-missing.conf"
    run rs_config_load_all
    [ "$status" -eq 0 ]
}

@test "config file: malformed lines are ignored with a warning" {
    local cfg="${BATS_TEST_TMPDIR}/restage.conf"
    printf 'this line has no equals\nssh_port = 2200\n' >"${cfg}"
    RS_CONFIG_PATH="${cfg}"
    rs_config_load_all
    [ "$RS_SSH_PORT" = "2200" ]
}
