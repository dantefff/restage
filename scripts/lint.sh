#!/usr/bin/env bash
#
# scripts/lint.sh — static analysis for every shell file in the repo.
#
#   scripts/lint.sh
#
# Failures here break CI. Uses shellcheck (https://www.shellcheck.net).
#   bash files  : -S warning
#   runtime     : -s sh  (strict POSIX, runs in busybox)
#   bats files  : -S warning, excluding source-load diagnostics
#
# shellcheck shell=bash

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "error: shellcheck is required (see docs/development.md)" >&2
    exit 1
fi

fail=0

check() {
    local file="$1"
    shift
    if ! shellcheck "$@" "${file}"; then
        fail=1
    fi
}

echo "==> bash syntax check"
for f in restage.sh bin/* lib/*.sh flows/*.sh scripts/*.sh tests/run.sh; do
    [ -f "${f}" ] || continue
    bash -n "${f}" || fail=1
done

echo "==> POSIX syntax check (runtime)"
for f in runtime/*.sh; do
    sh -n "${f}" || fail=1
done

echo "==> shellcheck: bash (warning)"
for f in restage.sh bin/* lib/*.sh flows/*.sh; do
    check "${f}" -S warning
done

echo "==> shellcheck: runtime (POSIX sh, warning)"
for f in runtime/*.sh; do
    check "${f}" -s sh -S warning
done

echo "==> shellcheck: dev scripts (warning)"
for f in scripts/*.sh tests/run.sh; do
    check "${f}" -S warning
done

echo "==> shellcheck: bats tests (warning, no source-load noise)"
for f in tests/unit/*.bats tests/integration/*.bats; do
    check "${f}" -S warning -e SC1090 -e SC1091
done

if [[ "${fail}" -eq 0 ]]; then
    echo "lint OK"
else
    echo "lint FAILED" >&2
fi
exit "${fail}"
