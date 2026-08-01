#!/usr/bin/env bash
#
# scripts/test.sh — lint then run the tests (the same gate CI uses).
#
#   scripts/test.sh
#
# shellcheck shell=bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

./scripts/lint.sh
./tests/run.sh

echo "all checks passed"
