#!/usr/bin/env bash
#
# scripts/release.sh — prepare a semantic-version release.
#
#   scripts/release.sh patch        # 0.1.0 -> 0.1.1
#   scripts/release.sh minor        # 0.1.0 -> 0.2.0
#   scripts/release.sh major        # 0.1.0 -> 1.0.0
#   scripts/release.sh 1.2.3        # explicit
#
# The script:
#   1. derives and writes the new version to VERSION,
#   2. appends a CHANGELOG.md section from commits since the last tag,
#   3. prints the git commands you should run (commit + tag + push).
#
# It does NOT push anything on its own.
#
# shellcheck shell=bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

VERSION_FILE="VERSION"
CHANGELOG="CHANGELOG.md"

current="$(cat "${VERSION_FILE}")"
echo "current version: ${current}"

new="${1:-}"
if [[ -z "${new}" ]]; then
    echo "usage: $0 [patch|minor|major|X.Y.Z]" >&2
    exit 1
fi

case "${new}" in
    patch | minor | major)
        IFS='.' read -r maj min pat <<<"${current}"
        case "${new}" in
            patch) pat=$((pat + 1)) ;;
            minor) min=$((min + 1)) && pat=0 ;;
            major) maj=$((maj + 1)) && min=0 && pat=0 ;;
        esac
        new="${maj}.${min}.${pat}"
        ;;
    *)
        [[ "${new}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            echo "error: version must be X.Y.Z (got '${new}')" >&2
            exit 1
        }
        ;;
esac

echo "new version:     ${new}"

# --- changelog section from commits since the previous tag -----------------
prev_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
today="$(date +%Y-%m-%d)"

if [[ -n "${prev_tag}" ]]; then
    log="$(git log --oneline --no-merges "${prev_tag}..HEAD" 2>/dev/null || true)"
else
    log="$(git log --oneline --no-merges 2>/dev/null || true)"
fi

{
    echo "## [${new}] - ${today}"
    echo
    if [[ -n "${log}" ]]; then
        while IFS= read -r line; do
            echo "- ${line}"
        done <<<"${log}"
    else
        echo "- Initial release."
    fi
    echo
    if [[ -s "${CHANGELOG}" ]]; then
        echo "---"
        cat "${CHANGELOG}"
    fi
} >"${CHANGELOG}.tmp"
mv "${CHANGELOG}.tmp" "${CHANGELOG}"

printf '%s\n' "${new}" >"${VERSION_FILE}"

echo
echo "done. Next steps:"
echo "  git add ${VERSION_FILE} ${CHANGELOG}"
echo "  git commit -m \"chore: release v${new}\""
echo "  git tag -a v${new} -m \"release v${new}\""
echo "  git push origin main --tags"
