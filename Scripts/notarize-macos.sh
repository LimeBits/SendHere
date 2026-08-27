#!/usr/bin/env bash
# Notarize and staple a Flutter-built SendHere .dmg or .app.
set -euo pipefail

if [[ $# -ne 1 || ! -e "$1" ]]; then
  printf 'Usage: %s <path-to.dmg-or-.app>\n' "$(basename "$0")" >&2
  exit 1
fi

TARGET="$1"
PROFILE="${NOTARIZE_PROFILE:-${SENDHERE_NOTARIZE_PROFILE:-sendhere-notary}}"
if xcrun notarytool history --keychain-profile "${PROFILE}" &>/dev/null; then
  AUTH_ARGS=(--keychain-profile "${PROFILE}")
elif [[ -n "${NOTARIZE_APPLE_ID:-}" && -n "${NOTARIZE_TEAM_ID:-}" && -n "${NOTARIZE_PASSWORD:-}" ]]; then
  AUTH_ARGS=(--apple-id "${NOTARIZE_APPLE_ID}" --team-id "${NOTARIZE_TEAM_ID}" --password "${NOTARIZE_PASSWORD}")
else
  printf 'error: notarization credentials are missing.\n' >&2
  exit 1
fi

xcrun notarytool submit "${TARGET}" "${AUTH_ARGS[@]}" --wait --timeout 30m
xcrun stapler staple "${TARGET}"
xcrun stapler validate "${TARGET}"
printf '✓ Notarized: %s\n' "${TARGET}"
