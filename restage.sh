#!/usr/bin/env bash
#
# restage — one-click OS reinstallation and rescue toolkit for VPS and
# bare-metal servers.
#
#   restage linux   <distro> [version]   reinstall to a Linux distribution
#   restage dd      --img URL            write a raw/compressed disk image
#   restage windows --image-name NAME     reinstall to Windows (official ISO)
#   restage alpine                        boot into the Alpine Live rescue env
#   restage netboot                       boot into netboot.xyz
#   restage reset                         cancel a pending reinstall
#   restage version | help
#
# See `restage help`, the README, or docs/ for full usage. Every flow that
# touches the disk validates inputs, shows an explicit action plan, and
# refuses to proceed without confirmation unless --yes is given.
#
# shellcheck shell=bash

set -o nounset

# Locate the repo root even when invoked via a symlink or a relative path.
_resolve_self() {
    local s="$1"
    while [[ -L "${s}" ]]; do
        local target
        target="$(readlink "${s}")"
        case "${target}" in
            /*) s="${target}" ;;
            *) s="$(dirname "${s}")/${target}" ;;
        esac
    done
    printf '%s\n' "${s}"
}

RS_REPO_ROOT="${RS_REPO_ROOT:-$(cd "$(dirname "$(_resolve_self "${BASH_SOURCE[0]}")")" && pwd)}"

# shellcheck source=lib/common.sh
source "${RS_REPO_ROOT}/lib/common.sh"
rs_import lib/help.sh
rs_import lib/args.sh
rs_import lib/config.sh

# Usage/help text (implemented in lib/help.sh).
rs_help() {
    rs_print_help
}

# Version banner.
rs_version() {
    printf '%s %s\n' "${RS_PROG_NAME}" "${RS_VERSION}"
    printf 'repository: https://github.com/codebyjawad/restage\n'
}

rs_main() {
    # Early pass for flags that must act before config loading.
    rs_args_prescan "$@"
    rs_config_load_all

    local cmd="${1:-}"
    if [[ -z "${cmd}" ]]; then
        rs_help
        exit 1
    fi
    if [[ "${cmd}" == "-h" || "${cmd}" == "--help" || "${cmd}" == "help" ]]; then
        rs_help
        exit 0
    fi
    if [[ "${cmd}" == "-v" || "${cmd}" == "--version" || "${cmd}" == "version" ]]; then
        rs_version
        exit 0
    fi
    shift

    case "${cmd}" in
        linux)
            rs_import flows/linux.sh
            rs_flow_linux "$@"
            ;;
        dd)
            rs_import flows/dd.sh
            rs_flow_dd "$@"
            ;;
        windows)
            rs_import flows/windows.sh
            rs_flow_windows "$@"
            ;;
        alpine)
            rs_import flows/alpine.sh
            rs_flow_alpine "$@"
            ;;
        netboot)
            rs_import flows/netboot.sh
            rs_flow_netboot "$@"
            ;;
        reset)
            rs_import flows/reset.sh
            rs_flow_reset "$@"
            ;;
        *)
            rs_die "unknown command: ${cmd} — see 'restage help'"
            ;;
    esac
}

rs_main "$@"
