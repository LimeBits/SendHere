#!/usr/bin/env bash
# Build and package a Development-signed iOS IPA with a timestamped filename.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SendHere"
BUNDLE_ID="com.brucetso.sendhere"
DIST_DIR="${SENDHERE_DIST_DIR:-${ROOT_DIR}/dist}"
PROFILE_PATH="${SENDHERE_IOS_PROFILE:-${HOME}/Downloads/MyDevProfile.mobileprovision}"
# Use the SHA-1 fingerprint to avoid ambiguity when Keychain contains multiple
# certificates with the same Apple Development display name.
SIGNING_IDENTITY="${SENDHERE_IOS_SIGNING_IDENTITY:-CCE7FDA6BDA84747027DEA56D56B9CA1F36882C6}"
VERSION="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
BUILD="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f2)"
STAMP="$(date '+%Y%m%d-%H%M')"
IPA_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-build${BUILD}-${STAMP}.ipa"
WORK_DIR="${ROOT_DIR}/build/ios/ipa-payload"
APP_PATH="${WORK_DIR}/Payload/${APP_NAME}.app"
ENTITLEMENTS_PATH="${ROOT_DIR}/build/ios/sendhere-entitlements.plist"

if [[ ! -f "${PROFILE_PATH}" ]]; then
  printf 'error: iOS provisioning profile not found: %s\n' "${PROFILE_PATH}" >&2
  printf 'Set SENDHERE_IOS_PROFILE to its .mobileprovision path.\n' >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
printf '→ Building iOS release app...\n'
(cd "${ROOT_DIR}" && flutter build ios --release --no-codesign)

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/Payload"
cp -R "${ROOT_DIR}/build/ios/iphoneos/Runner.app" "${APP_PATH}"
cp "${PROFILE_PATH}" "${APP_PATH}/embedded.mobileprovision"

security cms -D -i "${PROFILE_PATH}" 2>/dev/null |
  plutil -extract Entitlements xml1 -o "${ENTITLEMENTS_PATH}" -
TEAM_ID="$(security cms -D -i "${PROFILE_PATH}" 2>/dev/null |
  plutil -extract TeamIdentifier.0 raw -)"
plutil -replace application-identifier -string "${TEAM_ID}.${BUNDLE_ID}" "${ENTITLEMENTS_PATH}"
plutil -replace keychain-access-groups -xml "<array><string>${TEAM_ID}.${BUNDLE_ID}</string></array>" "${ENTITLEMENTS_PATH}"

printf '→ Signing IPA with development certificate...\n'
codesign --force --deep --sign "${SIGNING_IDENTITY}" \
  --entitlements "${ENTITLEMENTS_PATH}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

rm -f "${IPA_PATH}" "${IPA_PATH}.sha256"
(cd "${WORK_DIR}" && zip -qry "${IPA_PATH}" Payload)
unzip -t "${IPA_PATH}" >/dev/null
(cd "${DIST_DIR}" && shasum -a 256 "$(basename "${IPA_PATH}")" > "$(basename "${IPA_PATH}").sha256")
printf '✓ IPA ready: %s\n' "${IPA_PATH}"
