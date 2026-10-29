#!/usr/bin/env bash
#
# flows/common.sh — shared plumbing for all flows.
#
# Everything flows have in common is here: preflight checks, building the
# injected runtime payload, patching the initrd, installing the one-shot
# boot entry, persisting state, and the optional reboot.
#
# shellcheck shell=bash

rs_import lib/common.sh
rs_import lib/state.sh
rs_import lib/disk.sh
rs_import lib/net.sh
rs_import lib/boot.sh
rs_import lib/install.sh
rs_import lib/oslib.sh
rs_import lib/plan.sh
rs_import lib/args.sh

RS_INSTALL_DIR="${RS_INSTALL_DIR:-/boot/restage}"
RS_BOOT_LABEL="restage"

# Safety checks shared by every flow that touches the disk.
rs_flow_preflight() {
    rs_require_root
    rs_os_load_catalog
    if rs_state_exists; then
        if rs_is_yes "${RS_FORCE:-0}"; then
            rs_log_warn "a previous pending reinstall was found; replacing it"
            rs_flow_abort_pending
        else
            rs_die "a reinstall is already pending; run 'restage reset' first (or --force to replace)"
        fi
    fi
    rs_args_validate_common
}

# Cancel any pending reinstall that is still pre-reboot (used by --force and
# by the reset command).
rs_flow_abort_pending() {
    local label
    label="$(rs_state_get boot_label 2>/dev/null || echo restage)"
    rs_boot_remove_once
    rs_state_clear
    rs_log_info "removed pending reinstall (boot entry '${label}')"
}

# Resolve whether /boot lives on its own partition (affects grub paths).
rs_boot_is_separate() {
    [[ -n "$(findmnt -no SOURCE /boot 2>/dev/null)" ]]
}

# Map an absolute path into a grub-relative path.
rs_boot_grub_path() {
    local abs="${1:?rs_boot_grub_path: missing path}"
    if rs_boot_is_separate; then
        printf '%s\n' "${abs#/boot}"
    else
        printf '%s\n' "${abs}"
    fi
}

# POSIX single-quote a value for safe inclusion in generated shell files.
rs_sh_quote() {
    local v="${1}"
    v="${v//\'/\'\\\'\'}"
    printf "'%s'\n" "${v}"
}

# Prepare the directory that will be injected into the initrd.
#   rs_runtime_stage <mode> <extra_keyvals...>
rs_runtime_stage() {
    local mode="${1:?rs_runtime_stage: missing mode}"
    shift
    local stage="${RS_WORK_DIR}/runtime-stage"
    mkdir -p "${stage}"

    # 1. runtime scripts
    cp "${RS_REPO_ROOT}/runtime/common.sh" "${stage}/restage-common.sh"
    cp "${RS_REPO_ROOT}/runtime/trans.sh" "${stage}/trans.sh"
    cp "${RS_REPO_ROOT}/runtime/initrd-network.sh" "${stage}/initrd-network.sh"
    cp "${RS_REPO_ROOT}/runtime/windows.sh" "${stage}/windows.sh"
    cp "${RS_REPO_ROOT}/runtime/windows-unattend.xml" "${stage}/windows-unattend.xml"

    # 2. rendered network bring-up script
    rs_net_render_script "${RS_NET_IFACE}" >"${stage}/network.sh"

    # 3. custom drivers staged by the windows flow (--add-driver)
    if [[ -n "${RS_RUNTIME_DRIVER_DIR:-}" ]] && [[ -d "${RS_RUNTIME_DRIVER_DIR}" ]]; then
        mkdir -p "${stage}/drivers"
        cp -a "${RS_RUNTIME_DRIVER_DIR}/." "${stage}/drivers/"
    fi

    # 3. runtime environment (POSIX-quoted so the initrd can source it)
    {
        printf 'RESTAGE_MODE=%s\n' "$(rs_sh_quote "${mode}")"
        printf 'RESTAGE_DISK_PTUUID=%s\n' "$(rs_sh_quote "${RS_DISK_PTUUID}")"
        printf 'RESTAGE_DISK_DEV=%s\n' "$(rs_sh_quote "${RS_DISK_DEV}")"
        printf 'RESTAGE_USERNAME=%s\n' "$(rs_sh_quote "${RS_USERNAME}")"
        printf 'RESTAGE_PASSWORD=%s\n' "$(rs_sh_quote "${RS_PASSWORD}")"
        printf 'RESTAGE_SSH_KEY=%s\n' "$(rs_sh_quote "${RS_SSH_KEY}")"
        printf 'RESTAGE_SSH_PORT=%s\n' "$(rs_sh_quote "${RS_SSH_PORT}")"
        printf 'RESTAGE_WEB_PORT=%s\n' "$(rs_sh_quote "${RS_WEB_PORT}")"
        printf 'RESTAGE_HOLD=%s\n' "$(rs_sh_quote "${RS_HOLD}")"
        printf 'RESTAGE_NET_IFACE=%s\n' "$(rs_sh_quote "${RS_NET_IFACE}")"
        printf 'RESTAGE_NET_MAC=%s\n' "$(rs_sh_quote "${RS_NET_MAC}")"
        printf 'RESTAGE_IPV4=%s\n' "$(rs_sh_quote "${RS_IPV4_ADDR}")"
        printf 'RESTAGE_IPV6=%s\n' "$(rs_sh_quote "${RS_IPV6_ADDR}")"
        printf 'RESTAGE_GW4=%s\n' "$(rs_sh_quote "${RS_IPV4_GW}")"
        printf 'RESTAGE_GW6=%s\n' "$(rs_sh_quote "${RS_IPV6_GW}")"
        printf 'RESTAGE_DNS1=%s\n' "$(rs_sh_quote "${RS_IPV4_DNS%% *}")"
        printf 'RESTAGE_NET_MODE=%s\n' "$(rs_net_is_dhcp && printf 'dhcp' || printf 'static')"
        printf 'RESTAGE_ASSUME_YES=%s\n' "$(rs_sh_quote "${RS_ASSUME_YES}")"
        printf 'RESTAGE_ALPINE_VER=%s\n' "$(rs_sh_quote "${RS_ALPINE_BOOT_VERSION:-3.22}")"
        printf 'RESTAGE_MODLOOP_URL=%s\n' "$(rs_sh_quote "${RS_OS_BOOT_MODLOOP:-}")"
        printf 'RESTAGE_OS=%s\n' "$(rs_sh_quote "${RS_OS_NAME:-}")"
        printf 'RESTAGE_OS_VERSION=%s\n' "$(rs_sh_quote "${RS_OS_VERSION:-}")"
        printf 'RESTAGE_IMAGE=%s\n' "$(rs_sh_quote "${RS_OS_IMAGE:-}")"
        printf 'RESTAGE_IMAGE_NAME=%s\n' "$(rs_sh_quote "${RS_IMAGE_NAME:-}")"
        printf 'RESTAGE_ISO_URL=%s\n' "$(rs_sh_quote "${RS_ISO_URL:-}")"
        printf 'RESTAGE_RDP_PORT=%s\n' "$(rs_sh_quote "${RS_RDP_PORT:-3389}")"
        printf 'RESTAGE_ALLOW_PING=%s\n' "$(rs_sh_quote "${RS_ALLOW_PING:-0}")"
        for kv in "$@"; do
            printf '%s\n' "${kv}"
        done
    } >"${stage}/restage.conf"
    chmod 755 "${stage}/trans.sh" "${stage}/initrd-network.sh" "${stage}/network.sh"

    printf '%s\n' "${stage}"
}

# The shared execution tail: fetch installer assets, patch the initrd with
# the staged runtime, install the one-shot boot entry, save state, reboot.
#   rs_flow_schedule <mode> <kernel_url> <initrd_url> <stage> <cmdline>
rs_flow_schedule() {
    local mode="${1}" kernel_url="${2}" initrd_url="${3}" stage="${4}" cmdline="${5}"
    local kernel_path initrd_path kpath ipath
    kernel_path="${RS_INSTALL_DIR}/vmlinuz"
    initrd_path="${RS_INSTALL_DIR}/initrd.img"
    patched="${RS_INSTALL_DIR}/initrd-patched.img"

    rs_plan_step "download installer kernel from ${kernel_url}"
    rs_plan_step "download installer initrd from ${initrd_url}"
    rs_plan_step "patch initrd with runtime installer (mode=${mode})"
    rs_plan_step "install one-shot boot entry '${RS_BOOT_LABEL}'"
    rs_plan_step "reboot into the installer"

    rs_plan_gate

    rs_log_info "staging installer in ${RS_INSTALL_DIR}"
    if rs_dry_run "create ${RS_INSTALL_DIR}"; then
        mkdir -p "${RS_INSTALL_DIR}"
        rs_state_track_file "${RS_INSTALL_DIR}"
    fi

    rs_fetch "${kernel_url}" "${kernel_path}"
    rs_fetch "${initrd_url}" "${initrd_path}"

    if rs_dry_run "patch initrd"; then
        rs_initrd_patch "${initrd_path}" "${patched}" "${stage}"
    fi

    kpath="$(rs_boot_grub_path "${kernel_path}")"
    ipath="$(rs_boot_grub_path "${patched}")"

    rs_boot_write_once "${RS_BOOT_LABEL}" "${kpath}" "${ipath}" "${cmdline}"

    # Persist everything needed by `reset`.
    rs_state_set mode "${mode}"
    rs_state_set boot_label "${RS_BOOT_LABEL}"
    rs_state_set install_dir "${RS_INSTALL_DIR}"
    rs_state_set scheduled_at "$(date -Is)"
    rs_log_info "state saved to ${RS_STATE_DIR} (run 'restage reset' to cancel before reboot)"

    rs_log_info "reinstall scheduled. Credentials for the installer session:"
    rs_log_info "  username: ${RS_USERNAME}"
    if [[ -n "${RS_PASSWORD}" ]]; then
        rs_log_info "  password: ${RS_PASSWORD}"
    elif [[ -n "${RS_SSH_KEY}" ]]; then
        rs_log_info "  password: (none; SSH key authentication)"
    else
        rs_log_info "  password: (none)"
    fi

    if rs_is_yes "${RS_HOLD:-0}" || [[ "${mode}" == "alpine" ]]; then
        rs_log_info "hold mode: not rebooting automatically (--hold ${RS_HOLD})"
        return 0
    fi
    if rs_confirm "Reboot now to begin the reinstall?" yes; then
        rs_log_info "rebooting now"
        if rs_dry_run "reboot"; then
            sync
            reboot
        fi
    else
        rs_log_info "not rebooting now; run 'reboot' when ready (before that, 'restage reset' still works)"
    fi
}
