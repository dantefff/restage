#!/usr/bin/env bash
#
# tests/run.sh — run the full test suite.
#
# Requires bats-core (https://github.com/bats-core/bats-core).
#   make test        (see Makefile)
#   tests/run.sh
#
# shellcheck shell=bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if ! command -v bats >/dev/null 2>&1; then
    echo "error: bats-core is required (see docs/development.md)" >&2
    exit 1
fi

echo "==> running unit + integration tests"
bats --print-output-on-failure tests/unit tests/integration
