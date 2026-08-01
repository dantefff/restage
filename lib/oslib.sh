#!/usr/bin/env bash
#
# oslib.sh — distribution catalog and OS profile resolution.
#
# The catalog (data/distros.conf) is a flat KEY=VALUE file where each key is
# <distro>.<field>. It keeps the list of supported systems declarative so
# adding a distro is a data change, not a code change.
#
# Recognised fields:
#   versions   space-separated version list (e.g. "10 11 12 13")
#   default    version used when none is supplied
#   min_ram    minimum RAM in MiB
#   min_disk   minimum disk space in MiB
#   installer  how to install: cloud | alpine_live | manual | netboot
#   kernel     boot kernel URL (only for installer=manual/netboot)
#   initrd     boot initrd URL (only for installer=manual/netboot)
#   cloud      target cloud-image URL template (only for installer=cloud)
#   codenames  "ver=codename ..." mapping (optional, e.g. Debian)
#   archmap    "x86_64=amd64 aarch64=arm64" alias map for cloud images
#   kernel_args extra kernel cmdline appended by the boot entry
#
# URL templates may contain {ver}, {arch} and {carch} placeholders.
#
# shellcheck shell=bash

rs_import lib/common.sh

RS_OS_CATALOG_FILE="${RS_OS_CATALOG_FILE:-${RS_REPO_ROOT}/data/distros.conf}"

# Fallback boot assets used for any flow that installs through Alpine.
RS_ALPINE_BOOT_VERSION="3.22"
RS_ALPINE_BOOT_KERNEL="https://dl-cdn.alpinelinux.org/alpine/v{ver}/releases/{arch}/netboot/vmlinuz-lts"
RS_ALPINE_BOOT_INITRD="https://dl-cdn.alpinelinux.org/alpine/v{ver}/releases/{arch}/netboot/initramfs-lts"

# ---------------------------------------------------------------- catalog --

# Must be global: libs are sourced inside functions, and a plain `declare -A`
# would create a function-local array that vanishes when the caller returns.
declare -gA RS_OS_CATALOG=()

rs_os_load_catalog() {
    RS_OS_CATALOG=()
    if [[ ! -f "${RS_OS_CATALOG_FILE}" ]]; then
        rs_log_warn "distribution catalog missing: ${RS_OS_CATALOG_FILE}"
        return 1
    fi
    local line key value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"                       # strip comments
        # trim leading/trailing whitespace only (values may contain spaces)
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"               # keys are whitespace-free
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ -z "${key}" ]] && continue
        RS_OS_CATALOG["${key}"]="${value}"
    done <"${RS_OS_CATALOG_FILE}"
}

rs_os_known() {
    local distro="${1:?rs_os_known: missing distro}"
    [[ -n "${RS_OS_CATALOG[${distro}.versions]+x}" ]]
}

# Space-separated list of known distros.
rs_os_list() {
    local key distro
    for key in "${!RS_OS_CATALOG[@]}"; do
        case "${key}" in
            *.versions) printf '%s\n' "${key%%.versions}" ;;
        esac
    done | sort -u
}

_rs_os_field() {
    local distro="${1}" field="${2}"
    printf '%s\n' "${RS_OS_CATALOG[${distro}.${field}]:-}"
}

# ------------------------------------------------------------------ arch --

rs_os_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'x86_64' ;;
        aarch64 | arm64) printf 'aarch64' ;;
        i386 | i486 | i586 | i686) printf 'i386' ;;
        *) printf '%s\n' "$(uname -m)" ;;
    esac
}

# Substitute {ver}, {arch}, {carch} and {codename} in a template.
#   {ver}   = version string
#   {arch}  = standard arch (x86_64/aarch64), used by boot kernels
#   {carch} = distro-specific arch alias, used by cloud images
#   {codename} = codename from the distro.codenames map (may be empty)
rs_os_expand() {
    local tpl="${1:?rs_os_expand: missing template}" ver="${2}" arch="${3}" carch="${4:-${3}}" codename="${5:-}"
    tpl="${tpl//\{ver\}/${ver}}"
    tpl="${tpl//\{arch\}/${arch}}"
    tpl="${tpl//\{carch\}/${carch}}"
    tpl="${tpl//\{codename\}/${codename}}"
    printf '%s\n' "${tpl}"
}

# Codename for a (distro, version), or empty.
rs_os_codename() {
    local distro="${1}" version="${2}"
    local map entry
    map="$(_rs_os_field "${distro}" codenames)"
    for entry in ${map}; do
        if [[ "${entry%%=*}" == "${version}" ]]; then
            printf '%s\n' "${entry#*=}"
            return 0
        fi
    done
    return 1
}

# Per-distro arch alias for cloud images, e.g. x86_64 -> amd64.
rs_os_cloud_arch() {
    local distro="${1}" arch
    arch="$(rs_os_arch)"
    local map entry alias
    map="$(_rs_os_field "${distro}" archmap)"
    for entry in ${map}; do
        alias="${entry#*=}"
        if [[ "${entry%%=*}" == "${arch}" ]]; then
            printf '%s\n' "${alias}"
            return 0
        fi
    done
    printf '%s\n' "${arch}"
}

# ------------------------------------------------------------- resolve OS --

# Resolve a distro+version into RS_OS_* globals. Validates existence and
# version, applies defaults, and expands URL templates.
rs_os_resolve() {
    local distro="${1:?rs_os_resolve: missing distro}" version="${2:-}"
    if ! rs_os_known "${distro}"; then
        rs_die "unknown distribution: ${distro} (known: $(rs_os_list | tr '\n' ' '))"
    fi
    local versions default
    versions="$(_rs_os_field "${distro}" versions)"
    default="$(_rs_os_field "${distro}" default)"
    if [[ -z "${version}" ]]; then
        if [[ -n "${default}" ]]; then
            version="${default}"
            rs_log_info "using default version ${version} for ${distro}"
        elif [[ -n "${versions}" ]]; then
            version="${versions%% *}"
            rs_log_info "using latest version ${version} for ${distro}"
        else
            rs_die "${distro}: no version given and no default in catalog"
        fi
    fi
    if ! rs_in_list "${version}" "${versions}"; then
        rs_die "${distro}: unsupported version '${version}' (supported: ${versions})"
    fi

    local arch installer carch codename
    arch="$(rs_os_arch)"
    carch="$(rs_os_cloud_arch "${distro}")"
    codename="$(rs_os_codename "${distro}" "${version}" || true)"
    installer="$(_rs_os_field "${distro}" installer)"

    RS_OS_NAME="${distro}"
    RS_OS_VERSION="${version}"
    RS_OS_INSTALLER="${installer:-manual}"
    RS_OS_ARCH="${arch}"
    RS_OS_CLOUD_ARCH="${carch}"
    RS_OS_CODENAME="${codename}"
    RS_OS_MIN_RAM="$(_rs_os_field "${distro}" min_ram)"
    RS_OS_MIN_DISK="$(_rs_os_field "${distro}" min_disk)"
    RS_OS_KERNEL_ARGS="$(_rs_os_field "${distro}" kernel_args)"

    case "${RS_OS_INSTALLER}" in
        cloud | alpine_live)
            # Boot Alpine and install from within it. The boot kernel always
            # comes from the pinned Alpine version, never the target's.
            RS_OS_BOOT_KERNEL="$(rs_os_expand "${RS_ALPINE_BOOT_KERNEL}" "${RS_ALPINE_BOOT_VERSION}" "${arch}" "${carch}" "${codename}")"
            RS_OS_BOOT_INITRD="$(rs_os_expand "${RS_ALPINE_BOOT_INITRD}" "${RS_ALPINE_BOOT_VERSION}" "${arch}" "${carch}" "${codename}")"
            local _cloud_tpl
            _cloud_tpl="$(_rs_os_field "${distro}" cloud)"
            if [[ -n "${_cloud_tpl}" ]]; then
                RS_OS_IMAGE="$(rs_os_expand "${_cloud_tpl}" "${version}" "${arch}" "${carch}" "${codename}")"
            else
                RS_OS_IMAGE=""
            fi
            ;;
        manual | netboot)
            # Boot the distro's own netboot assets.
            local _ktpl _itpl
            _ktpl="$(_rs_os_field "${distro}" kernel)"
            _itpl="$(_rs_os_field "${distro}" initrd)"
            if [[ -n "${_ktpl}" ]]; then
                RS_OS_BOOT_KERNEL="$(rs_os_expand "${_ktpl}" "${version}" "${arch}" "${carch}" "${codename}")"
            else
                RS_OS_BOOT_KERNEL=""
            fi
            if [[ -n "${_itpl}" ]]; then
                RS_OS_BOOT_INITRD="$(rs_os_expand "${_itpl}" "${version}" "${arch}" "${carch}" "${codename}")"
            else
                RS_OS_BOOT_INITRD=""
            fi
            RS_OS_IMAGE=""
            ;;
        *)
            rs_die "${distro}: unknown installer type '${RS_OS_INSTALLER}'"
            ;;
    esac

    if [[ -z "${RS_OS_BOOT_KERNEL}" || -z "${RS_OS_BOOT_INITRD}" ]]; then
        rs_die "${distro}: catalog missing boot kernel/initrd URLs"
    fi

    rs_log_debug "resolved ${distro} ${version} (installer=${RS_OS_INSTALLER})"
}

# Resolve the fallback Alpine netboot assets into RS_OS_BOOT_* globals
# (used by flows that install through the Alpine live environment).
rs_alpine_assets() {
    local arch carch
    arch="$(rs_os_arch)"
    carch="$(rs_os_cloud_arch "alpine")"
    RS_OS_BOOT_KERNEL="$(rs_os_expand "${RS_ALPINE_BOOT_KERNEL}" "${RS_ALPINE_BOOT_VERSION}" "${arch}" "${carch}")"
    RS_OS_BOOT_INITRD="$(rs_os_expand "${RS_ALPINE_BOOT_INITRD}" "${RS_ALPINE_BOOT_VERSION}" "${arch}" "${carch}")"
}

# Check current hardware against catalog requirements. Fatal on failure
# unless RS_FORCE is set.
rs_os_check_requirements() {
    local ram_mb disk_mb
    ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ -n "${RS_OS_MIN_RAM}" ]] && (( ram_mb > 0 && ram_mb < RS_OS_MIN_RAM )); then
        if rs_is_yes "${RS_FORCE:-0}"; then
            rs_log_warn "${RS_OS_NAME} wants >=${RS_OS_MIN_RAM} MiB RAM; continuing anyway (--force)"
        else
            rs_die "${RS_OS_NAME} requires >=${RS_OS_MIN_RAM} MiB RAM (have ${ram_mb}); use --force to override"
        fi
    fi
    if command -v df >/dev/null 2>&1 && [[ -n "${RS_OS_MIN_DISK:-}" ]]; then
        disk_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
        if (( disk_mb > 0 && disk_mb < RS_OS_MIN_DISK )); then
            if rs_is_yes "${RS_FORCE:-0}"; then
                rs_log_warn "${RS_OS_NAME} wants >=${RS_OS_MIN_DISK} MiB free; continuing anyway (--force)"
            else
                rs_die "${RS_OS_NAME} requires >=${RS_OS_MIN_DISK} MiB free on / (have ${disk_mb}); use --force to override"
            fi
        fi
    fi
}
