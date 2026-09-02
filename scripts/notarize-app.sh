#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
APP_PATH="${PROJECT_DIRECTORY}/outputs/OmniGifs.app"
ARCHIVE_PATH="${PROJECT_DIRECTORY}/outputs/OmniGifs.zip"

if [[ -z "${CODE_SIGN_IDENTITY:-}" || "${CODE_SIGN_IDENTITY}" == "-" ]]; then
    echo "CODE_SIGN_IDENTITY must name a Developer ID Application certificate" >&2
    exit 2
fi
if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "NOTARYTOOL_PROFILE must name a notarytool keychain profile" >&2
    exit 2
fi

"${SCRIPT_DIRECTORY}/build-app.sh"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"
/usr/bin/xcrun notarytool submit \
    "${ARCHIVE_PATH}" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait
/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/sbin/spctl --assess --type execute --verbose=2 "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
