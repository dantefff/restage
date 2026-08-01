#!/usr/bin/env bash
#
# flows/dd.sh — write a raw disk image (DD mode).
#
#   restage dd --img URL [options]
#
# Supports raw images, optionally compressed (.gz .xz .zst) or wrapped in a
# tar archive. DANGER: overwrites the entire primary disk.
#
# shellcheck shell=bash

rs_import flows/common.sh

rs_flow_dd() {
    rs_args_parse_common "$@"
    rs_flow_preflight

    local img=""
    # Consume flow-specific options from the leftovers.
    local args=("${RS_ARGS_LEFT[@]}")
    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            --img)
                img="${args[1]:?--img requires a URL}"
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
            --cloud-data)
                RS_CLOUD_DATA="${args[1]:?--cloud-data requires a path or URL}"
                args=("${args[@]:2}")
                ;;
            *)
                rs_die "unknown option for 'dd': ${args[0]}"
                ;;
        esac
    done

    if [[ -z "${img}" ]]; then
        rs_die "usage: restage dd --img <url> [--rdp-port PORT] [--allow-ping] [--cloud-data DIR]"
    fi
    local reason
    reason="$(rs_validate_image_url "${img}")" || rs_die "${reason}"

    rs_disk_identify || rs_die "could not identify the target disk safely; refusing to continue"
    rs_net_capture
    rs_alpine_assets

    RS_OS_NAME="dd"
    RS_OS_IMAGE="${img}"

    rs_log_info "planning DD of ${img} onto ${RS_DISK_DEV} (PTUUID=${RS_DISK_PTUUID})"
    rs_log_warn "the entire disk ${RS_DISK_DEV} will be overwritten"

    local stage
    stage="$(rs_runtime_stage "dd" \
        "RESTAGE_RDP_PORT=${RS_RDP_PORT:-3389}" \
        "RESTAGE_ALLOW_PING=${RS_ALLOW_PING:-0}" \
        "RESTAGE_CLOUD_DATA=${RS_CLOUD_DATA:-}")"

    rs_flow_schedule "dd" "${RS_OS_BOOT_KERNEL}" "${RS_OS_BOOT_INITRD}" "${stage}" "init=/trans.sh"
}
