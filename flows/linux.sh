#!/usr/bin/env bash
#
# flows/linux.sh — reinstall to a Linux distribution.
#
#   restage linux [DISTRO [VERSION]] [options]
#
# DANGER: this flow repartitions and rewrites the entire primary disk.
#
# shellcheck shell=bash

rs_import flows/common.sh

rs_flow_linux() {
    rs_args_parse_common "$@"
    rs_flow_preflight

    local distro="${RS_POSITIONAL[0]:-}"
    local version="${RS_POSITIONAL[1]:-}"

    if [[ -z "${distro}" ]]; then
        rs_die "usage: restage linux <distro> [version]" \
            $'\n'"known distros: $(rs_os_list | tr '\n' ' ')"
    fi

    rs_os_resolve "${distro}" "${version}"
    rs_os_check_requirements
    rs_disk_identify || rs_die "could not identify the target disk safely; refusing to continue"
    rs_net_capture

    rs_log_info "planning install of ${RS_OS_NAME} ${RS_OS_VERSION} (${RS_OS_ARCH})"

    # alpine_live is a rescue boot, not an automated install.
    local mode="linux" cmdline="init=/trans.sh"
    if [[ "${RS_OS_INSTALLER}" == "alpine_live" ]]; then
        mode="alpine"
        RS_HOLD="${RS_HOLD:-1}"
        rs_log_warn "${RS_OS_NAME} installs through the Alpine live environment (rescue mode)"
    fi

    local stage
    stage="$(rs_runtime_stage "${mode}" \
        "RESTAGE_OS_INSTALLER=${RS_OS_INSTALLER}" \
        "RESTAGE_OS_ARCH=${RS_OS_ARCH}")"

    rs_flow_schedule "${mode}" "${RS_OS_BOOT_KERNEL}" "${RS_OS_BOOT_INITRD}" "${stage}" "${cmdline}"
}
