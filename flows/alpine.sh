#!/usr/bin/env bash
#
# flows/alpine.sh — reboot into the Alpine Live rescue environment.
#
#   restage alpine [options]
#
# NOT an automatic reinstall: boots a minimal Alpine system over the
# network, brings up networking, starts sshd and drops to a shell so you can
# rescue data, inspect disks, or run install steps manually. Nothing is
# erased unless you do it yourself.
#
# shellcheck shell=bash

rs_import flows/common.sh

rs_flow_alpine() {
    rs_args_parse_common "$@"
    rs_flow_preflight

    local leftover=("${RS_ARGS_LEFT[@]}")
    if (( ${#leftover[@]} > 0 )); then
        rs_die "unknown option for 'alpine': ${leftover[0]}"
    fi

    rs_os_resolve alpine ""
    rs_net_capture
    RS_HOLD=1

    rs_log_info "planning boot into Alpine Live (rescue) ${RS_OS_VERSION}"
    rs_log_warn "this flow does NOT erase any data; it boots a live environment for manual work"

    local stage
    stage="$(rs_runtime_stage "alpine" "RESTAGE_OS_INSTALLER=alpine_live")"

    rs_flow_schedule "alpine" "${RS_OS_BOOT_KERNEL}" "${RS_OS_BOOT_INITRD}" "${stage}" "init=/trans.sh"
}
