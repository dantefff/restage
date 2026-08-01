#!/usr/bin/env bats
#
# Unit tests for lib/plan.sh and lib/state.sh
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/plan.sh"
source "${BATS_TEST_DIRNAME}/../../lib/state.sh"

# ---------------------------------------------------------------- plan ----

@test "plan: steps are recorded and shown" {
    rs_plan_reset
    rs_plan_step "download installer kernel"
    rs_plan_step "write one-shot boot entry"

    run rs_plan_show
    [ "$status" -eq 0 ]
    [[ "$output" == *"1. download installer kernel"* ]]
    [[ "$output" == *"2. write one-shot boot entry"* ]]
}

@test "plan: empty plan warns and returns non-zero" {
    rs_plan_reset
    run rs_plan_show
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "plan: gate exits 0 in dry-run without executing" {
    rs_plan_reset
    rs_plan_step "do something"
    export RS_DRY_RUN=1
    run rs_plan_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"no changes were made"* ]]
}

# --------------------------------------------------------------- state ----

@test "state: set, get and clear roundtrip" {
    export RS_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    rs_state_set mode "linux"
    rs_state_set boot_label "restage"

    run rs_state_get mode
    [ "$status" -eq 0 ]
    [ "$output" = "linux" ]

    run rs_state_get boot_label
    [ "$output" = "restage" ]

    rs_state_exists
    [ "$?" -eq 0 ]

    rs_state_clear
    run rs_state_exists
    [ "$status" -ne 0 ]
}

@test "state: missing keys return non-zero" {
    export RS_STATE_DIR="${BATS_TEST_TMPDIR}/state2"
    run rs_state_get nope
    [ "$status" -ne 0 ]
}

@test "state: tracked files are removed on clear" {
    export RS_STATE_DIR="${BATS_TEST_TMPDIR}/state3"
    local f="${BATS_TEST_TMPDIR}/tracked.txt"
    echo hi >"${f}"
    rs_state_track_file "${f}"
    rs_state_clear
    [ ! -e "${f}" ]
}
