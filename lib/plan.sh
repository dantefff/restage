#!/usr/bin/env bash
#
# plan.sh — an explicit, reviewable action plan.
#
# Every flow records the steps it is about to take *before* it does
# anything. The plan is:
#
#   * printed for `--dry-run` (no changes are made), and
#   * shown for interactive confirmation before execution.
#
# This is the project's primary safety mechanism: nothing destructive
# happens until the operator has seen exactly what will occur.
#
# shellcheck shell=bash

rs_import lib/common.sh

RS_PLAN=()

# Reset the plan.
rs_plan_reset() {
    RS_PLAN=()
}

# Record a step. Description should be a full sentence fragment, e.g.
#   rs_plan_step "download Debian 12 netboot kernel"
#   rs_plan_step "write one-shot boot entry 'restage'"
rs_plan_step() {
    RS_PLAN+=("${1:?rs_plan_step: missing description}")
}

# Human-readable plan summary. Returns non-zero when there is nothing to do.
rs_plan_show() {
    if (( ${#RS_PLAN[@]} == 0 )); then
        rs_msg "warning: plan is empty — nothing will be done"
        return 1
    fi
    rs_msg "the following actions will be performed:"
    local i step
    i=0
    for step in "${RS_PLAN[@]}"; do
        i=$((i + 1))
        printf '  %2d. %s\n' "${i}" "${step}" >&2
    done
}

# Gate that sits between "plan built" and "execute".
#   * dry-run: print the plan and exit 0 (nothing executed)
#   * otherwise: print the plan and ask for confirmation (unless --yes)
rs_plan_gate() {
    rs_plan_show || rs_die "nothing to do; refusing to continue"
    if [[ "${RS_DRY_RUN:-0}" == "1" ]]; then
        rs_msg "dry-run: plan validated, no changes were made"
        exit 0
    fi
    if ! rs_confirm "Proceed with the actions above?" no; then
        rs_msg "aborted by user"
        exit 1
    fi
}
