#!/usr/bin/env bash
#
# flows/reset.sh — cancel a pending reinstall before reboot.
#
#   restage reset
#
# Undoes everything a scheduled run prepared *while the current system is
# still running*: the one-shot boot entry, the downloaded installer assets
# and the persisted state. Once the machine has rebooted, this is no longer
# possible — reset only works pre-reboot.
#
# shellcheck shell=bash

rs_import flows/common.sh

rs_flow_reset() {
    rs_require_root
    rs_config_load_all

    if ! rs_state_exists; then
        rs_msg "no pending reinstall found; nothing to reset"
        return 0
    fi

    local mode label
    mode="$(rs_state_get mode 2>/dev/null || echo unknown)"
    label="$(rs_state_get boot_label 2>/dev/null || echo restage)"

    rs_log_info "cancelling pending reinstall (mode=${mode}, boot entry='${label}')"
    if ! rs_confirm "Cancel the pending ${mode:-reinstall}? (the current system stays untouched)" no; then
        rs_log_info "reset aborted"
        return 1
    fi

    rs_boot_remove_once
    rs_state_clear
    rs_log_info "pending reinstall cancelled; the current system will boot normally"
}
