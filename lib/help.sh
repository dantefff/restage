#!/usr/bin/env bash
#
# help.sh — the `restage help` output.
#
# shellcheck shell=bash

rs_import lib/common.sh

rs_print_help() {
    cat <<EOF
${RS_PROG_NAME} ${RS_VERSION} — one-click OS reinstallation & rescue toolkit
for VPS and bare-metal servers. Runs on Linux; a Windows companion launcher
is planned.

USAGE
    ${RS_PROG_NAME} <command> [options]

COMMANDS
    linux <distro> [version]   Reinstall to a Linux distribution.
                               Known distros: see 'distro list' below.
    dd --img <url>             Write a raw/compressed disk image (DD mode).
    windows --image-name NAME  Reinstall to Windows from an official ISO.
    alpine                     Reboot into the Alpine Live rescue environment.
    netboot                    Reboot into the netboot.xyz menu.
    reset                      Cancel a pending reinstall (pre-reboot only).
    version                    Print version information.
    help                       Show this help.

DISTRO LIST
    alpine  debian  ubuntu  almalinux  rocky  openeuler
    arch (manual)  gentoo (manual)

SHARED OPTIONS
    --username USER           Login user for the installed system.
    --password PASS           Login password (min 8 chars; random if omitted).
    --ssh-key KEY             SSH public key (password login is then disabled).
    --ssh-port PORT           SSH port on the installed system (default 22).
    --web-port PORT           Port for the installer's log viewer (default 80).
    --hold N                  N=1: boot installer, don't install (debug).
                              N=2: install, then stay instead of rebooting.
    --frpc-config PATH|URL    Inject a frpc config for out-of-band access.
    --net-dhcp auto|yes|no    Force DHCP/static networking in the installer.
    --bootloader auto|grub|extlinux|efi   Override bootloader detection.
    --dry-run                 Print the action plan and exit without changing
                              anything.
    --yes                     Skip all interactive confirmations.
    --force                   Ignore hardware requirement checks.
    --config FILE             Use an alternative config file.
    --log-level LEVEL         debug | info | warn | error | silent.
    --log-file FILE           Also append logs to FILE.
    -h, --help                Show this help.
    -v, --version             Show version.

EXAMPLES
    # Reinstall to Debian 12 with an SSH key, showing a plan first
    ${RS_PROG_NAME} linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --dry-run

    # Reinstall to Ubuntu 24.04, unattended
    ${RS_PROG_NAME} linux ubuntu 24.04 --password 'ChangeMe123!' --yes

    # Write a Windows image over DD
    ${RS_PROG_NAME} dd --img https://example.com/win.xz --yes

    # Boot a rescue Alpine system to fix things manually
    ${RS_PROG_NAME} alpine

    # Cancel before the machine reboots
    ${RS_PROG_NAME} reset

    # See every known distro
    ${RS_PROG_NAME} help | sed -n '/DISTRO LIST/,/^$/p'

WARNING
    The linux, dd and windows commands erase the ENTIRE primary disk.
    Always run with --dry-run first and keep a rescue plan.

    Non-destructive alternatives: 'alpine' and 'netboot'.

Project: https://github.com/codebyjawad/restage
Report issues at the GitHub repository; see CONTRIBUTING.md before opening
a PR.
EOF
}
