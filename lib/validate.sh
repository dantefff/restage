#!/usr/bin/env bash
#
# validate.sh — strict input validation for every user-supplied value.
#
# All validators return 0 on success and print a machine-checkable failure
# reason on stdout (so tests can assert on messages). The CLI layer wraps
# them with user-facing errors.
#
# shellcheck shell=bash

rs_import lib/common.sh

# ----------------------------------------------------------------- usernames --

rs_validate_username() {
    local user="${1:-}"
    if [[ "${user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        return 0
    fi
    printf 'invalid username "%s": must start with a lowercase letter or underscore, ' "${user}"
    printf 'then lowercase letters, digits, - or _ (max 32 chars)\n'
    return 1
}

# ----------------------------------------------------------------- passwords --

rs_validate_password() {
    local pw="${1:-}"
    if [[ -z "${pw}" ]]; then
        return 0 # empty = generate a random one
    fi
    if (( ${#pw} < 8 )); then
        printf 'invalid password: must be at least 8 characters (got %d)\n' "${#pw}"
        return 1
    fi
    if [[ "${pw}" == *[[:space:]]* ]]; then
        printf 'invalid password: must not contain whitespace\n'
        return 1
    fi
    if [[ "${pw}" == *'"'* || "${pw}" == *"'"* ]]; then
        printf 'invalid password: must not contain quotes\n'
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------- ports --

rs_validate_port() {
    local port="${1:-}"
    if [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    printf 'invalid port "%s": must be an integer between 1 and 65535\n' "${port}"
    return 1
}

# ----------------------------------------------------------------- SSH keys --

# Accepts an OpenSSH public key line or a comment-free public key.
rs_validate_ssh_key() {
    local key="${1:-}"
    [[ -z "${key}" ]] && return 0
    # e.g. ssh-ed25519 AAAAC3Nza... comment
    if [[ "${key}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        return 0
    fi
    printf 'invalid SSH public key: expected "<keytype> <base64> [comment]"\n'
    return 1
}

# --------------------------------------------------------------- URLs/links --

rs_validate_url() {
    local url="${1:-}" what="${2:-URL}"
    case "${url}" in
        http://* | https://* | ftp://*)
            # reject whitespace or quote characters anywhere in the URL
            case "${url}" in
                *[[:space:]]* | *\"* | *\'*) 
                    printf 'invalid %s "%s": must not contain spaces or quotes\n' "${what}" "${url}"
                    return 1
                    ;;
            esac
            return 0
            ;;
        magnet:?*)
            if [[ "${url}" =~ ^magnet:\?xt=urn:btih:[0-9a-fA-F]{40} ]]; then
                return 0
            fi
            ;;
    esac
    printf 'invalid %s "%s": expected http(s)://, ftp:// or a magnet link\n' "${what}" "${url}"
    return 1
}

# Allow file:// for local testing but reject anything that isn't a URL at all.
rs_validate_image_url() {
    local url="${1:-}"
    case "${url}" in
        http://* | https://* | ftp://* | magnet:\?* | file://*) return 0 ;;
    esac
    printf 'invalid image URL "%s"\n' "${url}"
    return 1
}

# ---------------------------------------------------------------- languages --

rs_validate_lang() {
    local lang="${1:-}"
    if [[ "${lang}" =~ ^[a-z]{2}(-[a-zA-Z]{2,4})?$ ]]; then
        return 0
    fi
    printf 'invalid language tag "%s": expected e.g. en-us, zh-cn\n' "${lang}"
    return 1
}

# ------------------------------------------------------------------- holds --

rs_validate_hold() {
    local hold="${1:-0}"
    case "${hold}" in
        0 | 1 | 2) return 0 ;;
    esac
    printf 'invalid --hold value "%s": expected 0, 1 or 2\n' "${hold}"
    return 1
}

# ------------------------------------------------------------- boot override --

rs_validate_bootloader() {
    local bl="${1:-}"
    case "${bl}" in
        auto | grub | extlinux | efi) return 0 ;;
    esac
    printf 'invalid --bootloader "%s": expected auto, grub, extlinux or efi\n' "${bl}"
    return 1
}

# ---------------------------------------------------------------- booleans --

rs_validate_bool() {
    local v="${1:-}" what="${2:-value}"
    case "${v}" in
        0 | 1 | yes | no | true | false) return 0 ;;
    esac
    printf 'invalid %s "%s": expected yes/no or 0/1\n' "${what}" "${v}"
    return 1
}

# ------------------------------------------------------------- version regex --

rs_validate_distro_version() {
    local v="${1:-}"
    if [[ "${v}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || [[ "${v}" =~ ^(rolling|stable|tumbleweed)$ ]]; then
        return 0
    fi
    printf 'invalid version "%s": expected dotted digits (e.g. 12, 24.04) or rolling/stable\n' "${v}"
    return 1
}
