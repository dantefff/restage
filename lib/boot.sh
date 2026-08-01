#!/usr/bin/env bash
#
# boot.sh — one-shot boot entry management.
#
# The reinstaller schedules a single boot into the installer and must be
# able to *undo* that (via `restage reset`) without touching the rest of the
# bootloader configuration.
#
# Supported bootloaders:
#   * grub   — a `restage` menuentry is sourced from a dedicated file that we
#              append to grub.cfg, then `grub-reboot` selects it once.
#   * extlinux — an entry appended to extlinux.conf; `extlinux --once`
#              selects it for the next boot only.
#   * efi    — via efibootmgr + a grub2-efi chain if available; otherwise we
#              warn loudly (most EFI systems run grub, which is handled above).
#
# shellcheck shell=bash

rs_import lib/common.sh

RS_BOOTLOADER_OVERRIDE="${RS_BOOTLOADER_OVERRIDE:-auto}"
RS_GRUB_CFG="${RS_GRUB_CFG:-}"
RS_GRUB_ENTRY_FILE="${RS_GRUB_ENTRY_FILE:-/boot/restage/entry.cfg}"
RS_EXTLINUX_CFG="${RS_EXTLINUX_CFG:-/boot/extlinux/extlinux.conf}"
RS_EFI_MOUNT="${RS_EFI_MOUNT:-/boot/efi}"

# Detect which bootloader is in use. Prints: grub | extlinux | efi | none
rs_boot_detect() {
    if [[ "${RS_BOOTLOADER_OVERRIDE}" != "auto" ]]; then
        printf '%s\n' "${RS_BOOTLOADER_OVERRIDE}"
        return 0
    fi
    if command -v grub-reboot >/dev/null 2>&1 || command -v grub2-reboot >/dev/null 2>&1; then
        printf 'grub\n'
    elif command -v extlinux >/dev/null 2>&1 && [[ -f "${RS_EXTLINUX_CFG}" ]]; then
        printf 'extlinux\n'
    elif [[ -d /sys/firmware/efi ]] && command -v efibootmgr >/dev/null 2>&1; then
        printf 'efi\n'
    else
        printf 'none\n'
    fi
}

_rs_grub_reboot_cmd() {
    if command -v grub-reboot >/dev/null 2>&1; then
        printf 'grub-reboot'
    else
        printf 'grub2-reboot'
    fi
}

_rs_grub_entry_path() {
    # Locate the primary grub.cfg for the running system.
    if [[ -n "${RS_GRUB_CFG}" ]]; then
        printf '%s\n' "${RS_GRUB_CFG}"
        return 0
    fi
    local candidates
    candidates="/boot/grub2/grub.cfg /boot/grub/grub.cfg"
    local c
    for c in ${candidates}; do
        [[ -f "${c}" ]] && { printf '%s\n' "${c}"; return 0; }
    done
    return 1
}

# Render a grub menuentry that boots kernel/initrd with cmdline.
rs_boot_render_grub_entry() {
    local label="${1:?rs_boot_render_grub_entry: missing label}"
    local kernel="${2:?rs_boot_render_grub_entry: missing kernel}"
    local initrd="${3:-}"
    local cmdline="${4:-}"
    printf 'menuentry "%s" --id restage {\n' "${label}"
    printf '    linux %s %s\n' "${kernel}" "${cmdline}"
    if [[ -n "${initrd}" ]]; then
        printf '    initrd %s\n' "${initrd}"
    fi
    printf '}\n'
}

# Install the one-shot grub entry. Kernel/initrd are grub paths (may include
# a prefix like /boot/...).
rs_boot_write_grub() {
    local label="${1}" kernel="${2}" initrd="${3:-}" cmdline="${4:-}"
    local cfg entry_dir entry_file
    cfg="$(_rs_grub_entry_path)" || rs_die "could not locate grub.cfg"
    entry_dir="$(dirname "${RS_GRUB_ENTRY_FILE}")"
    entry_file="${RS_GRUB_ENTRY_FILE}"
    rs_log_info "installing grub one-shot entry '${label}'"
    if ! rs_dry_run "write grub entry to ${cfg}"; then
        return 0
    fi
    mkdir -p "${entry_dir}"
    rs_boot_render_grub_entry "${label}" "${kernel}" "${initrd}" "${cmdline}" >"${entry_file}"
    # Ensure the entry file is sourced from grub.cfg exactly once.
    if ! grep -qF "source ${entry_file}" "${cfg}" 2>/dev/null; then
        printf '\n# restage one-shot entry (managed)\n' >>"${cfg}"
        printf 'source %s\n' "${entry_file}" >>"${cfg}"
    fi
    # grub-reboot selects the entry by title for the next boot only.
    "$(_rs_grub_reboot_cmd)" "${label}" >/dev/null 2>&1 || {
        rs_log_warn "grub-reboot failed; the machine may need manual entry selection"
    }
    rs_state_track_file "${entry_file}" 2>/dev/null || true
    rs_state_track_file "${entry_dir}" 2>/dev/null || true
}

rs_boot_write_extlinux() {
    local label="${1}" kernel="${2}" initrd="${3:-}" cmdline="${4:-}"
    if [[ ! -f "${RS_EXTLINUX_CFG}" ]]; then
        rs_die "extlinux.conf not found at ${RS_EXTLINUX_CFG}"
    fi
    rs_log_info "installing extlinux one-shot entry '${label}'"
    if ! rs_dry_run "write extlinux entry to ${RS_EXTLINUX_CFG}"; then
        return 0
    fi
    {
        printf '\nLABEL %s\n' "${label}"
        printf '    LINUX %s\n' "${kernel}"
        if [[ -n "${initrd}" ]]; then
            printf '    INITRD %s\n' "${initrd}"
        fi
        if [[ -n "${cmdline}" ]]; then
            printf '    APPEND %s\n' "${cmdline}"
        fi
    } >>"${RS_EXTLINUX_CFG}"
    if command -v extlinux >/dev/null 2>&1; then
        extlinux --once "${label}" >/dev/null 2>&1 || rs_log_warn "extlinux --once failed; entry may need manual selection"
    fi
}

rs_boot_write_efi() {
    # EFI without grub: we attempt a chainload via grub2-efi if present.
    # A raw kernel+initrd cannot be booted directly with efibootmgr.
    if command -v grub-install >/dev/null 2>&1; then
        rs_log_warn "EFI detected: falling back to grub (grub-install is available)"
        rs_boot_write_grub "$@"
        return 0
    fi
    rs_die "EFI system without grub or a compatible boot manager is not supported; " \
        "use --bootloader to override or install grub first"
}

# High-level entry point: install a one-shot entry using the detected loader.
rs_boot_write_once() {
    local label="${1:?rs_boot_write_once: missing label}"
    local kernel="${2:?rs_boot_write_once: missing kernel}"
    local initrd="${3:-}" cmdline="${4:-}"
    local loader
    loader="$(rs_boot_detect)"
    case "${loader}" in
        grub) rs_boot_write_grub "${label}" "${kernel}" "${initrd}" "${cmdline}" ;;
        extlinux) rs_boot_write_extlinux "${label}" "${kernel}" "${initrd}" "${cmdline}" ;;
        efi) rs_boot_write_efi "${label}" "${kernel}" "${initrd}" "${cmdline}" ;;
        *)
            rs_die "no supported bootloader found; boot into the installer manually and rerun"
            ;;
    esac
}

# Write a fully custom grub entry (used by the netboot flow which boots a
# memdisk + ISO or a chainloaded EFI app rather than a plain kernel).
# $1 = label, $2 = raw menuentry body (without the surrounding menuentry{}).
rs_boot_write_custom_grub() {
    local label="${1:?rs_boot_write_custom_grub: missing label}" body="${2:?rs_boot_write_custom_grub: missing body}"
    local cfg entry_file entry_dir
    cfg="$(_rs_grub_entry_path)" || rs_die "could not locate grub.cfg"
    entry_file="${RS_GRUB_ENTRY_FILE}"
    entry_dir="$(dirname "${entry_file}")"
    if ! rs_dry_run "write custom grub entry '${label}'"; then
        return 0
    fi
    mkdir -p "${entry_dir}"
    {
        printf 'menuentry "%s" --id restage {\n' "${label}"
        printf '%s\n' "${body}"
        printf '}\n'
    } >"${entry_file}"
    if ! grep -qF "source ${entry_file}" "${cfg}" 2>/dev/null; then
        printf '\n# restage one-shot entry (managed)\n' >>"${cfg}"
        printf 'source %s\n' "${entry_file}" >>"${cfg}"
    fi
    "$(_rs_grub_reboot_cmd)" "${label}" >/dev/null 2>&1 || {
        rs_log_warn "grub-reboot failed; the machine may need manual entry selection"
    }
    rs_state_track_file "${entry_file}" 2>/dev/null || true
    rs_state_track_file "${entry_dir}" 2>/dev/null || true
}

# Undo a grub one-shot entry (used by `reset`).
rs_boot_remove_grub() {
    local cfg entry_file
    cfg="$(_rs_grub_entry_path)" || return 1
    entry_file="${RS_GRUB_ENTRY_FILE}"
    if [[ -f "${entry_file}" ]]; then
        rm -f "${entry_file}"
    fi
    # Remove the source line + marker comment we added.
    if [[ -f "${cfg}" ]]; then
        sed -i '\|# restage one-shot entry (managed)|d' "${cfg}"
        sed -i "\|source ${entry_file}|d" "${cfg}"
    fi
    # Clear any pending grub-reboot selection.
    if command -v grub-editenv >/dev/null 2>&1 && [[ -f /boot/grub/grubenv ]]; then
        grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    fi
    rs_log_info "removed grub one-shot entry"
}

# Undo an extlinux one-shot entry.
rs_boot_remove_extlinux() {
    local label="${1:-restage}"
    if [[ -f "${RS_EXTLINUX_CFG}" ]]; then
        sed -i '/^LABEL '${label}'$/,/^$/d' "${RS_EXTLINUX_CFG}"
        extlinux --once - >/dev/null 2>&1 || true
    fi
    rs_log_info "removed extlinux one-shot entry"
}

# Undo whatever one-shot entry was installed.
rs_boot_remove_once() {
    local loader
    loader="$(rs_boot_detect)"
    case "${loader}" in
        grub | efi) rs_boot_remove_grub ;;
        extlinux) rs_boot_remove_extlinux "restage" ;;
    esac
}
