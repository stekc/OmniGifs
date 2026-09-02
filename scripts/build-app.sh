#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
XCODE_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
OUTPUT_DIRECTORY="${PROJECT_DIRECTORY}/outputs"
OUTPUT_APP="${OUTPUT_DIRECTORY}/OmniGifs.app"
ICON_SOURCE="${PROJECT_DIRECTORY}/Sources/OmniGifs/Resources/omnigifs-icon.svg"
MODEL_SOURCE_DIRECTORY="${OMNIGIFS_MODEL_DIR:-${PROJECT_DIRECTORY}/.build/openai-clip-models}"
STAGING_DIRECTORY="$(mktemp -d)"
STAGING_APP="${STAGING_DIRECTORY}/OmniGifs.app"
ICONSET_DIRECTORY="${STAGING_DIRECTORY}/OmniGifs.iconset"

function finish {
    /bin/rm -rf "${STAGING_DIRECTORY}"
}
trap finish EXIT

cd "${PROJECT_DIRECTORY}"
env DEVELOPER_DIR="${XCODE_PATH}" /usr/bin/xcrun swift build -c release --product OmniGifs

/bin/mkdir -p \
    "${STAGING_APP}/Contents/MacOS" \
    "${STAGING_APP}/Contents/Resources/Licenses"
/bin/cp "${PROJECT_DIRECTORY}/.build/release/OmniGifs" "${STAGING_APP}/Contents/MacOS/OmniGifs"
/bin/cp "${PROJECT_DIRECTORY}/Support/Info.plist" "${STAGING_APP}/Contents/Info.plist"
/usr/bin/xcrun swift \
    "${PROJECT_DIRECTORY}/scripts/render-app-icon.swift" \
    "${ICON_SOURCE}" \
    "${ICONSET_DIRECTORY}"
/usr/bin/iconutil -c icns \
    "${ICONSET_DIRECTORY}" \
    -o "${STAGING_APP}/Contents/Resources/OmniGifs.icns"
/bin/cp \
    "${PROJECT_DIRECTORY}/Sources/OmniGifs/Resources/clip-merges.txt" \
    "${STAGING_APP}/Contents/Resources/clip-merges.txt"
/bin/cp \
    "${PROJECT_DIRECTORY}/Sources/OmniGifs/Resources/omnigifs-icon.svg" \
    "${STAGING_APP}/Contents/Resources/omnigifs-icon.svg"
/bin/cp \
    "${PROJECT_DIRECTORY}/THIRD_PARTY_NOTICES.md" \
    "${STAGING_APP}/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
/bin/cp \
    "${PROJECT_DIRECTORY}/LICENSE" \
    "${STAGING_APP}/Contents/Resources/Licenses/OmniGifs-LICENSE.txt"
/usr/bin/ditto \
    "${PROJECT_DIRECTORY}/LICENSES" \
    "${STAGING_APP}/Contents/Resources/Licenses/ThirdParty"

if [[ ! -d "${MODEL_SOURCE_DIRECTORY}/openai_clip_vit_b32_image.mlpackage" \
   || ! -d "${MODEL_SOURCE_DIRECTORY}/openai_clip_vit_b32_text.mlpackage" ]]; then
    echo "OpenAI CLIP models are missing from ${MODEL_SOURCE_DIRECTORY}" >&2
    echo "Run scripts/prepare-openai-clip-models.py or set OMNIGIFS_MODEL_DIR." >&2
    exit 1
fi
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/Models"
env DEVELOPER_DIR="${XCODE_PATH}" /usr/bin/xcrun coremlcompiler compile \
    "${MODEL_SOURCE_DIRECTORY}/openai_clip_vit_b32_image.mlpackage" \
    "${STAGING_APP}/Contents/Resources/Models"
env DEVELOPER_DIR="${XCODE_PATH}" /usr/bin/xcrun coremlcompiler compile \
    "${MODEL_SOURCE_DIRECTORY}/openai_clip_vit_b32_text.mlpackage" \
    "${STAGING_APP}/Contents/Resources/Models"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "${CODE_SIGN_IDENTITY}" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "${STAGING_APP}"
else
    /usr/bin/codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "${CODE_SIGN_IDENTITY}" \
        "${STAGING_APP}"
fi

/bin/mkdir -p "${OUTPUT_DIRECTORY}"
if [[ -e "${OUTPUT_APP}" ]]; then
    /bin/rm -rf "${OUTPUT_APP}"
fi
/usr/bin/ditto "${STAGING_APP}" "${OUTPUT_APP}"

echo "Built ${OUTPUT_APP}"
