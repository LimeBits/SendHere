#!/usr/bin/env bash
# Build a release-signed Android APK with a timestamped filename.
# Signing: android/key.properties + keystore (gitignored). Falls back to debug key if absent.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SendHere"
DIST_DIR="${SENDHERE_DIST_DIR:-${ROOT_DIR}/dist}"
VERSION="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
BUILD="$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f2)"
STAMP="$(date '+%Y%m%d-%H%M')"
APK_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-build${BUILD}-${STAMP}.apk"

# Prefer Homebrew JDK 17 when JAVA_HOME is not set.
if [[ -z "${JAVA_HOME:-}" && -d /opt/homebrew/opt/openjdk@17 ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
fi

if [[ ! -f "${ROOT_DIR}/android/key.properties" ]]; then
  printf 'warning: android/key.properties not found, APK will be debug-signed.\n' >&2
fi

mkdir -p "${DIST_DIR}"
printf '→ Building Android release APK (universal)...\n'
(cd "${ROOT_DIR}" && flutter build apk --release)

cp "${ROOT_DIR}/build/app/outputs/flutter-apk/app-release.apk" "${APK_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "$(basename "${APK_PATH}")" > "$(basename "${APK_PATH}").sha256")
printf '✓ APK ready: %s\n' "${APK_PATH}"
