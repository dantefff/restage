#!/usr/bin/env bash
#
# args.sh — shared CLI parsing.
#
# restage uses a plain, explicit option parser (rather than getopt) so that
# every flag, its aliases and its validation are obvious and unit-testable.
# Shared options are consumed by rs_args_parse_common; flow-specific options
# are handled by each flow and appended to RS_ARGS_FLOW_* variables.
#
# shellcheck shell=bash

rs_import lib/common.sh
rs_import lib/config.sh
rs_import lib/validate.sh

RS_POSITIONAL=()
RS_CLI_SET=()

# First pass: pull out the handful of options that affect config/logging
# loading, so they take effect as early as possible. Values set here are
# recorded in RS_CLI_SET so a config file cannot override explicit CLI flags.
rs_args_prescan() {
    local arg
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --config)
                RS_CONFIG_PATH="${2:?--config requires a path}"
                RS_CLI_SET+=("config_path")
                shift 2
                ;;
            --log-level)
                RS_LOG_LEVEL="${2:?--log-level requires a value}"
                RS_CLI_SET+=("log_level")
                shift 2
                ;;
            --log-file)
                RS_LOG_FILE="${2:?--log-file requires a path}"
                RS_CLI_SET+=("log_file")
                shift 2
                ;;
            --dry-run)
                RS_DRY_RUN="1"
                RS_CLI_SET+=("dry_run")
                shift
                ;;
            --yes)
                RS_ASSUME_YES="1"
                RS_CLI_SET+=("assume_yes")
                shift
                ;;
            *) shift ;;
        esac
    done
}

# True when an option consumes a following value. Covers every option the
# flows define (the shared ones are handled by rs_args_parse_common itself).
_rs_arg_takes_value() {
    case "${1#--}" in
        username | password | ssh-key | ssh-port | web-port | hold | frpc-config | \
        net-dhcp | bootloader | config | log-level | log-file | \
        img | rdp-port | cloud-data | image-name | iso | lang | add-driver)
            return 0
            ;;
    esac
    return 1
}

# Parse shared options (all commands). Positional arguments land in
# RS_POSITIONAL; flow-specific options (with their values) are passed
# through in RS_ARGS_LEFT for the flow to consume.
rs_args_parse_common() {
    RS_POSITIONAL=()
    RS_ARGS_LEFT=()
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --username)
                RS_USERNAME="${2:?--username requires a value}"
                shift 2
                ;;
            --password)
                RS_PASSWORD="${2:?--password requires a value}"
                shift 2
                ;;
            --ssh-key)
                RS_SSH_KEY="${2:?--ssh-key requires a value}"
                shift 2
                ;;
            --ssh-port)
                RS_SSH_PORT="${2:?--ssh-port requires a value}"
                shift 2
                ;;
            --web-port)
                RS_WEB_PORT="${2:?--web-port requires a value}"
                shift 2
                ;;
            --hold)
                RS_HOLD="${2:?--hold requires a value (0|1|2)}"
                shift 2
                ;;
            --frpc-config)
                RS_FRPC_CONFIG="${2:?--frpc-config requires a path or URL}"
                shift 2
                ;;
            --force)
                RS_FORCE="1"
                shift
                ;;
            --net-dhcp)
                RS_NET_DHCP="${2:?--net-dhcp requires a value (auto|yes|no)}"
                shift 2
                ;;
            --bootloader)
                RS_BOOTLOADER_OVERRIDE="${2:?--bootloader requires a value (auto|grub|extlinux|efi)}"
                shift 2
                ;;
            --config)
                RS_CONFIG_PATH="${2:?--config requires a path}"
                shift 2
                ;;
            --log-level)
                RS_LOG_LEVEL="${2:?--log-level requires a value}"
                shift 2
                ;;
            --log-file)
                RS_LOG_FILE="${2:?--log-file requires a path}"
                shift 2
                ;;
            --dry-run)
                RS_DRY_RUN="1"
                shift
                ;;
            --yes)
                RS_ASSUME_YES="1"
                shift
                ;;
            --help | -h)
                rs_help
                exit 0
                ;;
            --)
                shift
                RS_POSITIONAL+=("$@")
                break
                ;;
            -*) 
                # Flow-specific or unknown option: keep it with its value.
                local _opt="${1}"
                RS_ARGS_LEFT+=("${_opt}")
                shift
                if _rs_arg_takes_value "${_opt}"; then
                    RS_ARGS_LEFT+=("${1:-}")
                    shift
                fi
                ;;
            *)
                RS_POSITIONAL+=("${1}")
                shift
                ;;
        esac
    done
}

# Central validation of the shared user/credential options.
rs_args_validate_common() {
    local reason
    reason="$(rs_validate_username "${RS_USERNAME}")" || rs_die "${reason}"
    reason="$(rs_validate_password "${RS_PASSWORD}")" || rs_die "${reason}"
    reason="$(rs_validate_ssh_key "${RS_SSH_KEY}")" || rs_die "${reason}"
    reason="$(rs_validate_port "${RS_SSH_PORT}")" || rs_die "${reason}"
    reason="$(rs_validate_port "${RS_WEB_PORT}")" || rs_die "${reason}"
    reason="$(rs_validate_hold "${RS_HOLD}")" || rs_die "${reason}"
    reason="$(rs_validate_bootloader "${RS_BOOTLOADER_OVERRIDE}")" || rs_die "${reason}"
    if [[ "${RS_NET_DHCP:-auto}" != "auto" ]]; then
        reason="$(rs_validate_bool "${RS_NET_DHCP}" "net-dhcp")" || rs_die "${reason}"
    fi
    # No password and no key would leave the installed system unreachable:
    # sshd ships with password auth and root login disabled. Generate a
    # password and show it (the help promises this) instead of installing a
    # system nobody can log into.
    if [[ -z "${RS_PASSWORD}" && -z "${RS_SSH_KEY}" ]]; then
        RS_PASSWORD="$(rs_random_hex 8)"
        rs_log_warn "no password or SSH key set; generated a random root password"
    fi
}
