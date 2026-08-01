#!/usr/bin/env bash
#
# flows/netboot.sh — reboot into netboot.xyz.
#
#   restage netboot [options]
#
# Boots the netboot.xyz menu so you can install a huge catalogue of systems
# manually over the network. NOT destructive: your disk is only touched if
# you choose to install something from the menu.
#
# shellcheck shell=bash

rs_import flows/common.sh

RS_NETBOOT_ISO_URL="https://boot.netboot.xyz/ipxe/netboot.xyz.iso"
RS_NETBOOT_EFI_URL="https://boot.netboot.xyz/ipxe/netboot.xyz.efi"
RS_MEMDISK_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03/memdisk/memdisk"

rs_flow_netboot() {
    rs_args_parse_common "$@"
    rs_flow_preflight

    local leftover=("${RS_ARGS_LEFT[@]}")
    if (( ${#leftover[@]} > 0 )); then
        rs_die "unknown option for 'netboot': ${leftover[0]}"
    fi

    local loader
    loader="$(rs_boot_detect)"
    if [[ "${loader}" != "grub" && "${loader}" != "efi" ]]; then
        rs_die "netboot currently requires grub (BIOS or EFI); detected loader: ${loader}"
    fi

    local dir="${RS_INSTALL_DIR}"
    mkdir -p "${dir}"
    rs_state_track_file "${dir}"

    if [[ "${loader}" == "grub" ]] && [[ ! -d /sys/firmware/efi ]]; then
        # BIOS grub: boot the ISO through syslinux memdisk.
        rs_plan_step "download netboot.xyz ISO (${RS_NETBOOT_ISO_URL})"
        rs_plan_step "download memdisk (${RS_MEMDISK_URL})"
        rs_plan_step "install one-shot grub entry '${RS_BOOT_LABEL}' (memdisk + ISO)"
        rs_plan_gate

        rs_fetch "${RS_NETBOOT_ISO_URL}" "${dir}/netboot.xyz.iso"
        rs_fetch "${RS_MEMDISK_URL}" "${dir}/memdisk"

        local iso_path mem_path
        iso_path="$(rs_boot_grub_path "${dir}/netboot.xyz.iso")"
        mem_path="$(rs_boot_grub_path "${dir}/memdisk")"
        local stanza
        stanza="linux16 ${mem_path}\n    initrd16 ${iso_path}"
        rs_boot_write_custom_grub "restage-netboot" "$(printf '%b' "${stanza}")"
    else
        # EFI grub: chainload the EFI app directly.
        rs_plan_step "download netboot.xyz EFI app (${RS_NETBOOT_EFI_URL})"
        rs_plan_step "install one-shot grub entry '${RS_BOOT_LABEL}' (chainload EFI)"
        rs_plan_gate

        rs_fetch "${RS_NETBOOT_EFI_URL}" "${dir}/netboot.xyz.efi"

        local efi_path
        efi_path="$(rs_boot_grub_path "${dir}/netboot.xyz.efi")"
        rs_boot_write_custom_grub "restage-netboot" "chainloader ${efi_path}"
    fi

    rs_state_set mode "netboot"
    rs_state_set boot_label "${RS_BOOT_LABEL}"
    rs_state_set install_dir "${dir}"
    rs_state_set scheduled_at "$(date -Is)"

    if rs_confirm "Reboot now to enter netboot.xyz?" yes; then
        rs_log_info "rebooting now"
        if rs_dry_run "reboot"; then
            sync
            reboot
        fi
    else
        rs_log_info "not rebooting now; run 'reboot' when ready (or 'restage reset')"
    fi
}
