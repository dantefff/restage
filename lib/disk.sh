#!/usr/bin/env bash
#
# disk.sh — safe disk identification.
#
# The reinstaller must never write to the wrong device. Instead of trusting
# names like /dev/sda (which can change between boots), every flow resolves
# the *primary* disk of the current system, records its partition table UUID
# (PTUUID), and hands that UUID to the runtime installer. The installer then
# re-resolves the disk by UUID inside the initrd — names may change, UUIDs
# do not.
#
# shellcheck shell=bash

rs_import lib/common.sh

# The device backing the current root filesystem, e.g. /dev/sda2, /dev/vda1.
rs_root_device() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -no SOURCE / 2>/dev/null && return 0
    fi
    # Fallback: parse mountinfo for the root mount.
    if [[ -r /proc/self/mountinfo ]]; then
        local line major minor dev
        while IFS= read -r line || [[ -n "${line}" ]]; do
            # field 3 = major:minor, field 5 = mount point, field 9 = mount source
            major="$(printf '%s' "${line}" | cut -d' ' -f3 | cut -d: -f1)"
            minor="$(printf '%s' "${line}" | cut -d' ' -f3 | cut -d: -f2)"
            local mpoint mdev
            mpoint="$(printf '%s' "${line}" | cut -d' ' -f5)"
            if [[ "${mpoint}" == "/" ]]; then
                if [[ -b "/dev/block/${major}:${minor}" ]]; then
                    dev="$(readlink -f "/dev/block/${major}:${minor}")"
                    printf '%s\n' "${dev}"
                    return 0
                fi
                # try udev database
                if command -v udevadm >/dev/null 2>&1; then
                    mdev="$(udevadm info -q name -p "/sys/dev/block/${major}:${minor}" 2>/dev/null)"
                    if [[ -n "${mdev}" ]]; then
                        printf '/dev/%s\n' "${mdev}"
                        return 0
                    fi
                fi
            fi
        done < /proc/self/mountinfo
    fi
    return 1
}

# The parent disk of a partition device (sda2 -> sda, nvme0n1p1 -> nvme0n1).
rs_parent_disk() {
    local dev="${1:?rs_parent_disk: missing device}"
    if command -v lsblk >/dev/null 2>&1; then
        local parent
        parent="$(lsblk -no PKNAME "${dev}" 2>/dev/null)"
        [[ -n "${parent}" ]] && { printf '/dev/%s\n' "${parent}"; return 0; }
    fi
    # Fallback heuristic: strip a trailing [0-9]+ (and p prefix for nvme/mmc).
    local base="${dev##*/}"
    if [[ "${base}" =~ (nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        printf '/dev/%s\n' "${BASH_REMATCH[1]}"
    elif [[ "${base}" =~ (mmcblk[0-9]+)p[0-9]+$ ]]; then
        printf '/dev/%s\n' "${BASH_REMATCH[1]}"
    else
        base="${base%[0-9]}"
        printf '/dev/%s\n' "${base}"
    fi
}

# Main system disk. Prints the device, or exits with an error.
rs_main_disk() {
    local root part disk
    root="$(rs_root_device)" || rs_die "cannot determine the root filesystem device"
    part="$(readlink -f "${root}")"
    disk="$(rs_parent_disk "${part}")" || rs_die "cannot determine the disk for ${part}"
    if [[ ! -b "${disk}" ]]; then
        rs_die "resolved disk ${disk} is not a block device (root=${root})"
    fi
    rs_log_debug "main disk: ${disk} (root device: ${root})"
    printf '%s\n' "${disk}"
}

# Partition table UUID (PTUUID) of a disk, 8-hex or 36-char GUID.
rs_disk_ptuuid() {
    local disk="${1:?rs_disk_ptuuid: missing disk}"
    local uuid
    if command -v blkid >/dev/null 2>&1; then
        uuid="$(blkid -s PTUUID -o value "${disk}" 2>/dev/null)"
    fi
    if [[ -z "${uuid}" ]] && command -v fdisk >/dev/null 2>&1; then
        uuid="$(fdisk -l "${disk}" 2>/dev/null | awk -F'[: ]+' '/Disk identifier/{print $3}')"
    fi
    [[ -z "${uuid}" ]] && { rs_log_error "no partition table UUID for ${disk}"; return 1; }
    printf '%s\n' "${uuid}"
}

# Validate that a string looks like a PTUUID (MBR 8-hex or GPT GUID).
rs_ptuuid_valid() {
    local uuid="${1:-}"
    if [[ "${uuid}" =~ ^[0-9a-fA-F]{8}$ ]]; then
        return 0
    fi
    if [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        return 0
    fi
    return 1
}

# Full disk identification bundle, exported as RS_DISK_* globals.
# When RS_DISK_DEV and RS_DISK_PTUUID are pre-set (e.g. in tests or when the
# operator knows the target in advance), they are validated and used as-is.
rs_disk_identify() {
    if [[ -n "${RS_DISK_DEV:-}" && -n "${RS_DISK_PTUUID:-}" ]]; then
        if ! rs_ptuuid_valid "${RS_DISK_PTUUID}"; then
            rs_die "pre-set RS_DISK_PTUUID '${RS_DISK_PTUUID}' is not a valid partition-table UUID"
        fi
        rs_log_debug "using pre-set disk: ${RS_DISK_DEV} (PTUUID=${RS_DISK_PTUUID})"
        return 0
    fi
    local disk
    disk="$(rs_main_disk)" || return 1
    local uuid
    uuid="$(rs_disk_ptuuid "${disk}")" || return 1
    if ! rs_ptuuid_valid "${uuid}"; then
        rs_die "unexpected PTUUID '${uuid}' on ${disk}; aborting for safety"
    fi
    RS_DISK_DEV="${disk}"
    RS_DISK_PTUUID="${uuid}"
    rs_log_info "target disk: ${RS_DISK_DEV} (PTUUID=${RS_DISK_PTUUID})"
}
