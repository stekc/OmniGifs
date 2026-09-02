#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"

private_data_found=0
while IFS= read -r -d '' file; do
    [[ -f "${file}" && "${file}" != "scripts/check-publication.sh" ]] || continue
    if rg -n -I '/Users/[^/]+/|Documents/Codex|TemporaryItems' "${file}"; then
        private_data_found=1
    fi
done < <(git ls-files --cached --others --exclude-standard -z)

if (( private_data_found != 0 )); then
    echo "Publication check found a local filesystem path" >&2
    exit 1
fi

oversized=0
while IFS= read -r -d '' file; do
    [[ -f "${file}" ]] || continue
    size="$(/usr/bin/stat -f '%z' "${file}")"
    if (( size > 50 * 1024 * 1024 )); then
        echo "Publication candidate exceeds 50 MiB: ${file}" >&2
        oversized=1
    fi
done < <(git ls-files --cached --others --exclude-standard -z)

(( oversized == 0 ))
