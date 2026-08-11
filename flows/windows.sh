#!/usr/bin/env bash
#
# flows/windows.sh — reinstall to Windows from an official ISO.
#
#   restage windows --image-name "..." [--iso URL | --lang LANG] [options]
#
# When --iso is omitted, a small catalog maps common editions/versions to
# official download pages; the runtime installer fetches the ISO inside the
# Alpine environment. For a fully unattended install, prefer a direct ISO
# URL with --iso. DANGER: overwrites the entire primary disk.
#
# shellcheck shell=bash

rs_import flows/common.sh

# Known (edition -> URL hint) catalog. These are *lookup hints* for the
# massgrave.dev genuine-media database; the runtime installer tries to
# resolve the final direct link. Contributions welcome (see CONTRIBUTING.md).
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

# Best-effort attempt to scrape a direct .iso link out of a catalog hint
# page. This runs on the HOST — with a normal network stack, before the
# disk is touched or the box reboots — instead of inside the minimal
# Alpine installer, where a failed resolve used to mean the runtime hit
# `die()` as PID 1 and the box became unreachable with no way back in
# short of the provider's console.
#
# In practice this rarely succeeds: Microsoft's software-download and
# evalcenter pages build the real link with JavaScript after a bot check,
# and massgrave.dev's page is a human-facing index, not a single file link.
# The scrape is kept as a courtesy for any hint page that does expose a
# plain link; --iso with a direct URL is the only reliable path today.
rs_windows_resolve_iso_hint() {
    local hint="${1:?rs_windows_resolve_iso_hint: missing hint URL}"
    local page
    page="$(curl -fsSL --max-time 20 "${hint}" 2>/dev/null)" || return 1
    local url
    url="$(printf '%s\n' "${page}" | grep -oiE 'https?://[^[:space:]"'"'"'<>]*\.iso' | head -n1)"
    [[ -n "${url}" ]] || return 1
    printf '%s\n' "${url}"
}

# True when the host is running on virtio (KVM) hardware, so the installer
# should bundle virtio drivers for Windows.
rs_windows_virtio() {
    local vendor
    for vendor in /sys/class/net/*/device/vendor; do
        [[ -e "${vendor}" ]] || continue
        if grep -qi "0x1af4" "${vendor}" 2>/dev/null; then
            return 0
        fi
    done
    if grep -qi "virtio" /sys/block/*/device/model 2>/dev/null; then
        return 0
    fi
    return 1
}

# Stage --add-driver inputs (an .inf file or a whole directory) so they can
# be injected into the initrd and later into boot.wim.
rs_stage_windows_drivers() {
    local out="${RS_WORK_DIR}/driver-stage"
    mkdir -p "${out}"
    local src
    for src in "$@"; do
        if [[ -f "${src}" ]]; then
            cp "${src}" "${out}/$(basename "${src}")"
        elif [[ -d "${src}" ]]; then
            cp -a "${src}/." "${out}/"
        else
            rs_die "driver path not found: ${src}"
        fi
    done
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

    local iso_hint=""
    if [[ -z "${iso}" ]]; then
        rs_windows_catalog
        local entry hint found=0
        for entry in "${RS_WIN_CATALOG[@]}"; do
            if [[ "${entry%%=*}" == "${image_name}" ]]; then
                hint="${entry#*=}"
                iso_hint="${hint}"
                found=1
                break
            fi
        done
        if (( ! found )); then
            rs_die "no --iso given and '${image_name}' is not in the built-in catalog; pass a direct download URL: restage windows --image-name \"${image_name}\" --iso <direct .iso URL> --yes"
        fi
        # Resolve for real outside --dry-run only: dry-run must stay a safe,
        # offline preview (no network calls, no chance of dying here). The
        # real run resolves — and requires success — on the HOST, before
        # the disk is touched or the box reboots, so a bad/unscrapable hint
        # fails loudly in the operator's current shell instead of inside
        # the installer after reboot (see rs_windows_resolve_iso_hint).
        if [[ "${RS_DRY_RUN:-0}" == "1" ]]; then
            rs_log_info "dry-run: no --iso given; would resolve '${image_name}' from ${hint} before rebooting"
        else
            rs_log_info "no --iso given; resolving '${image_name}' from ${hint} on the host, before touching the disk"
            local resolved
            if resolved="$(rs_windows_resolve_iso_hint "${hint}")"; then
                rs_log_info "resolved a direct ISO link: ${resolved}"
                iso="${resolved}"
            else
                rs_die "could not automatically resolve a direct ISO download link from ${hint} — that page requires a browser session (login/bot-check/JavaScript) and cannot be scraped with curl. Re-run with a direct link instead: restage windows --image-name \"${image_name}\" --iso <direct .iso URL> --yes"
            fi
        fi
    fi

    if [[ -n "${iso}" ]]; then
        local reason
        reason="$(rs_validate_image_url "${iso}")" || rs_die "${reason}"
    fi

    if [[ -n "${RS_LANG:-}" ]]; then
        local reason
        reason="$(rs_validate_lang "${RS_LANG}")" || rs_die "${reason}"
    fi

    rs_disk_identify || rs_die "could not identify the target disk safely; refusing to continue"
    rs_net_capture
    rs_alpine_assets

    RS_OS_NAME="windows"
    RS_IMAGE_NAME="${image_name}"
    RS_ISO_URL="${iso}"

    local drivers_arg=""
    if (( ${#add_drivers[@]} > 0 )); then
        export RS_RUNTIME_DRIVER_DIR="${RS_WORK_DIR}/driver-stage"
        rs_stage_windows_drivers "${add_drivers[@]}"
        rs_log_info "staged ${#add_drivers[@]} extra driver path(s) for injection into boot.wim"
    fi

    rs_log_info "planning Windows install: ${image_name}"
    rs_log_warn "the entire disk ${RS_DISK_DEV} (PTUUID=${RS_DISK_PTUUID}) will be overwritten"

    # The windows-specific steps are recorded before the shared plan so the
    # operator sees them all in --dry-run.
    rs_plan_step "partition ${RS_DISK_DEV} (EFI + MSR + Windows + installer)"
    rs_plan_step "download the Windows ISO and mount it"
    rs_plan_step "copy ISO files to the installer partition"
    rs_plan_step "render autounattend.xml for an unattended setup"
    rs_plan_step "install a one-shot boot entry that starts Windows Setup"

    local virtio="0"
    if rs_windows_virtio; then
        virtio="1"
        rs_log_info "virtio hardware detected; the installer will bundle virtio drivers"
    fi

    local stage
    stage="$(rs_runtime_stage "windows" \
        "RESTAGE_LANG=${RS_LANG:-en-us}" \
        "RESTAGE_RDP_PORT=${RS_RDP_PORT:-3389}" \
        "RESTAGE_ALLOW_PING=${RS_ALLOW_PING:-0}" \
        "RESTAGE_ISO_HINT=${iso_hint}" \
        "RESTAGE_VIRTIO=${virtio}")"

    rs_flow_schedule "windows" "${RS_OS_BOOT_KERNEL}" "${RS_OS_BOOT_INITRD}" "${stage}" "init=/trans.sh"
}
