#!/usr/bin/env bash
# Package Flutter's macOS Release app as a drag-to-Applications DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SendHere"
APP_PATH="${ROOT_DIR}/build/macos/Build/Products/Release/${APP_NAME}.app"
DIST_DIR="${SENDHERE_DIST_DIR:-${ROOT_DIR}/dist}"
# Set SENDHERE_SIGNING_IDENTITY to a Developer ID Application certificate for
# distributable builds. Without it Flutter's nested framework signature can be
# invalid after packaging, which macOS reports to recipients as “damaged”.
SIGNING_IDENTITY="${SENDHERE_SIGNING_IDENTITY:-}"
VERSION="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
BUILD="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f2)"
STAMP="$(date '+%Y%m%d-%H%M')"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-build${BUILD}-${STAMP}.dmg"
RW_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-build${BUILD}-${STAMP}-rw.dmg"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sendhere-dmg.XXXXXX")"

# Always rebuild. `flutter build` is itself incremental, but skipping it
# entirely whenever APP_PATH already exists (the previous behavior) silently
# re-packaged a stale .app left over from an older build with a fresh,
# misleading timestamped filename -- the DMG name said "new" while the
# contents were whatever code was last compiled, possibly days earlier.
printf '→ Building Flutter macOS release app...\n'
(cd "${ROOT_DIR}" && flutter build macos --release)
if [[ ! -d "${APP_PATH}" ]]; then
  printf 'error: Flutter macOS app not found: %s\n' "${APP_PATH}" >&2
  exit 1
fi

if [[ -n "${SIGNING_IDENTITY}" ]]; then
  printf '→ Signing app with %s\n' "${SIGNING_IDENTITY}"
  codesign --force --deep --options runtime --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
else
  printf 'warning: no Developer ID signing identity configured; this DMG may be blocked by Gatekeeper.\n' >&2
fi

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${RW_PATH}"
cleanup() { hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true; rmdir "${MOUNT_DIR}" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil create -size "100m" -volname "${APP_NAME}" -ov -fs HFS+ -layout SPUD -type UDIF "${RW_PATH}" >/dev/null
hdiutil attach "${RW_PATH}" -readwrite -noverify -noautoopen -mountpoint "${MOUNT_DIR}" >/dev/null
cp -R "${APP_PATH}" "${MOUNT_DIR}/"
ln -s /Applications "${MOUNT_DIR}/Applications"
hdiutil detach "${MOUNT_DIR}" -quiet
trap - EXIT
rmdir "${MOUNT_DIR}" 2>/dev/null || true
hdiutil convert "${RW_PATH}" -format UDZO -o "${DMG_PATH}" >/dev/null
rm -f "${RW_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${DMG_PATH}").sha256")
printf '✓ DMG ready: %s\n' "${DMG_PATH}"
