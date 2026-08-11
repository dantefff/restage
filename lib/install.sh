#!/usr/bin/env bash
#
# install.sh — installer asset download and initrd patching.
#
# The reinstaller boots a minimal kernel + initrd from the network. Before
# rebooting we patch that initrd to carry:
#   * the runtime installer scripts (runtime/*),
#   * a rendered network bring-up script,
#   * credentials and the target OS descriptor,
# so that the installer needs no other inputs after reboot.
#
# shellcheck shell=bash

rs_import lib/common.sh
rs_import lib/state.sh

RS_WORK_DIR="${RS_WORK_DIR:-/restage}"
RS_CURL_RETRIES="${RS_CURL_RETRIES:-5}"

# Download a URL to a destination file with retries and partial-failure
# detection. Uses curl; falls back to wget when curl is unavailable.
rs_fetch() {
    local url="${1:?rs_fetch: missing url}" dest="${2:?rs_fetch: missing dest}"
    rs_log_info "downloading ${url}"
    if command -v curl >/dev/null 2>&1; then
        local i
        for i in $(seq 1 "${RS_CURL_RETRIES}"); do
            if curl -fsSL --retry 3 --connect-timeout 15 -o "${dest}" "${url}"; then
                return 0
            fi
            rs_log_warn "download attempt ${i}/${RS_CURL_RETRIES} failed for ${url}"
        done
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --tries="${RS_CURL_RETRIES}" -O "${dest}" "${url}"; then
            return 0
        fi
    else
        rs_die "neither curl nor wget is available"
    fi
    rs_die "failed to download ${url}"
}

# Type of an initrd: gzip | xz | zstd | raw
rs_initrd_type() {
    local file="${1:?rs_initrd_type: missing file}"
    local magic
    magic="$(od -An -N6 -tx1 "${file}" | tr -d ' \n')"
    case "${magic}" in
        1f8b*) printf 'gzip' ;;
        fd377a585a00*) printf 'xz' ;;
        28b52ffd*) printf 'zstd' ;;
        *) printf 'raw' ;;
    esac
}

# Unpack an initrd into a directory.
rs_initrd_unpack() {
    local initrd="${1:?rs_initrd_unpack: missing initrd}" dir="${2:?rs_initrd_unpack: missing dir}"
    local type
    type="$(rs_initrd_type "${initrd}")"
    mkdir -p "${dir}"
    case "${type}" in
        gzip)
            zcat "${initrd}" | cpio -id -D "${dir}" 2>/dev/null
            ;;
        xz)
            xz -dc "${initrd}" | cpio -id -D "${dir}" 2>/dev/null
            ;;
        zstd)
            zstd -dc "${initrd}" | cpio -id -D "${dir}" 2>/dev/null
            ;;
        raw)
            cpio -id -D "${dir}" <"${initrd}" 2>/dev/null
            ;;
    esac
    rs_log_debug "unpacked ${type} initrd into ${dir}"
}

# Repack a directory back into a gzip'd cpio initrd at $dest.
rs_initrd_pack() {
    local dir="${1:?rs_initrd_pack: missing dir}" dest="${2:?rs_initrd_pack: missing dest}"
    ( cd "${dir}" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 >"${dest}" )
    rs_log_debug "repacked initrd -> ${dest}"
}

# Patch an initrd with injected files.
#   rs_initrd_patch <src_initrd> <dest_initrd> <inject_dir>
#   where <inject_dir> contains files placed at the initrd's root.
rs_initrd_patch() {
    local src="${1:?rs_initrd_patch: missing src}" dest="${2:?rs_initrd_patch: missing dest}"
    local inject="${3:?rs_initrd_patch: missing inject dir}"
    local tmp
    mkdir -p "${RS_WORK_DIR}"
    tmp="$(mktemp -d "${RS_WORK_DIR}/initrd.XXXXXX")"
    rs_initrd_unpack "${src}" "${tmp}"
    cp -a "${inject}/." "${tmp}/"
    # Make the installer the initramfs PID 1. The stock Alpine netboot /init
    # insists on finding a bootable root and switch_root'ing into it, so a
    # bare `init=/trans.sh` never reaches our script on diskless installs.
    cp "${tmp}/trans.sh" "${tmp}/init"
    chmod 755 "${tmp}/init"
    rs_initrd_pack "${tmp}" "${dest}"
    # shellcheck disable=SC2154
    [[ -d "${tmp}" ]] && rm -rf "${tmp}"
}

# Download and verify an installer kernel+initrd pair. Sets:
#   RS_INSTALL_KERNEL  RS_INSTALL_INITRD  RS_INSTALL_BASE  RS_INSTALL_PATCHED
rs_installer_fetch() {
    local kernel_url="${1:?rs_installer_fetch: missing kernel url}"
    local initrd_url="${2:?rs_installer_fetch: missing initrd url}"
    mkdir -p "${RS_WORK_DIR}"
    RS_INSTALL_BASE="${RS_WORK_DIR}/installer"
    RS_INSTALL_KERNEL="${RS_INSTALL_BASE}/vmlinuz"
    RS_INSTALL_INITRD="${RS_INSTALL_BASE}/initrd.img"
    RS_INSTALL_PATCHED="${RS_INSTALL_BASE}/initrd-patched.img"

    rs_fetch "${kernel_url}" "${RS_INSTALL_KERNEL}"
    rs_fetch "${initrd_url}" "${RS_INSTALL_INITRD}"
    rs_state_track_file "${RS_INSTALL_BASE}"

    # Minimal sanity check on what we downloaded.
    local ksize isize
    ksize="$(stat -c %s "${RS_INSTALL_KERNEL}")"
    isize="$(stat -c %s "${RS_INSTALL_INITRD}")"
    if (( ksize < 1000000 || isize < 1000000 )); then
        rs_log_warn "downloaded installer assets look suspiciously small (kernel=${ksize}B initrd=${isize}B)"
    fi
}
