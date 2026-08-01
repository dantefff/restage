#!/usr/bin/env bash
#
# flows/windows.sh — reinstall to Windows from an official ISO.
#
#   restage windows --image-name "..." [--iso URL | --lang LANG] [options]
#
# When --iso is omitted, a small catalog maps common editions/versions to
# official download pages; the runtime installer fetches the ISO inside the
# Alpine environment. DANGER: overwrites the entire primary disk.
#
# shellcheck shell=bash

rs_import flows/common.sh

# Known (edition -> URL hint) catalog. These are *lookup hints* for the
# massgrave.dev genuine-media database; the runtime installer resolves the
# final direct link. Contributions welcome (see CONTRIBUTING.md).
rs_windows_catalog() {
    RS_WIN_CATALOG=(
        "Windows 11 Enterprise LTSC 2024=https://massgrave.dev/genuine-installation-media"
        "Windows 11 Enterprise Evaluation=https://www.microsoft.com/evalcenter/download-windows-11-enterprise"
        "Windows 11 Pro=https://www.microsoft.com/software-download/windows11"
        "Windows 10 Enterprise LTSC 2021=https://www.microsoft.com/software-download/windows10"
        "Windows Server 2022 Standard=https://www.microsoft.com/evalcenter/download-windows-server-2022"
        "Windows Server 2025 Standard=https://www.microsoft.com/evalcenter/download-windows-server-2025"
    )
}

rs_flow_windows() {
    rs_args_parse_common "$@"
    rs_flow_preflight

    local image_name="" iso=""
    local add_drivers=()
    local args=("${RS_ARGS_LEFT[@]}")
    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            --image-name)
                image_name="${args[1]:?--image-name requires a value}"
                args=("${args[@]:2}")
                ;;
            --iso)
                iso="${args[1]:?--iso requires a URL}"
                args=("${args[@]:2}")
                ;;
            --lang)
                RS_LANG="${args[1]:?--lang requires a language tag}"
                args=("${args[@]:2}")
                ;;
            --rdp-port)
                RS_RDP_PORT="${args[1]:?--rdp-port requires a value}"
                args=("${args[@]:2}")
                ;;
            --allow-ping)
                RS_ALLOW_PING="1"
                args=("${args[@]:1}")
                ;;
            --add-driver)
                add_drivers+=("${args[1]:?--add-driver requires an .inf path or directory}")
                args=("${args[@]:2}")
                ;;
            *)
                rs_die "unknown option for 'windows': ${args[0]}"
                ;;
        esac
    done

    if [[ -z "${image_name}" ]]; then
        rs_die "usage: restage windows --image-name \"<edition>\" [--iso URL] [--lang LANG]"
    fi

    if [[ -z "${iso}" ]]; then
        rs_windows_catalog
        local entry hint found=0
        for entry in "${RS_WIN_CATALOG[@]}"; do
            if [[ "${entry%%=*}" == "${image_name}" ]]; then
                hint="${entry#*=}"
                found=1
                rs_log_info "no --iso given; will resolve '${image_name}' from ${hint}"
                break
            fi
        done
        if (( ! found )); then
            rs_log_warn "no --iso and '${image_name}' is not in the built-in catalog; the runtime installer will search the massgrave.dev database"
        fi
    else
        local reason
        reason="$(rs_validate_image_url "${iso}")" || rs_die "${reason}"
    fi

    if [[ -n "${RS_LANG:-}" ]]; then
        reason="$(rs_validate_lang "${RS_LANG}")" || rs_die "${reason}"
    fi

    rs_disk_identify || rs_die "could not identify the target disk safely; refusing to continue"
    rs_net_capture
    rs_alpine_assets

    RS_OS_NAME="windows"
    RS_IMAGE_NAME="${image_name}"
    RS_ISO_URL="${iso}"

    rs_log_info "planning Windows install: ${image_name}"
    rs_log_warn "the entire disk ${RS_DISK_DEV} (PTUUID=${RS_DISK_PTUUID}) will be overwritten"

    local drivers_arg=""
    if (( ${#add_drivers[@]} > 0 )); then
        drivers_arg="$(printf '%s,' "${add_drivers[@]}")"
        drivers_arg="${drivers_arg%,}"
        rs_log_info "extra drivers: ${drivers_arg}"
    fi

    local stage
    stage="$(rs_runtime_stage "windows" \
        "RESTAGE_LANG=${RS_LANG:-en-us}" \
        "RESTAGE_RDP_PORT=${RS_RDP_PORT:-3389}" \
        "RESTAGE_ALLOW_PING=${RS_ALLOW_PING:-0}" \
        "RESTAGE_DRIVERS=${drivers_arg}")"

    rs_flow_schedule "windows" "${RS_OS_BOOT_KERNEL}" "${RS_OS_BOOT_INITRD}" "${stage}" "init=/trans.sh"
}
