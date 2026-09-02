#!/usr/bin/env python3

import pathlib
import struct
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke-test-app.py /path/to/OmniGifs.app")

    app = pathlib.Path(sys.argv[1])
    executable = app / "Contents" / "MacOS" / "OmniGifs"
    text = b"installation smoke test"
    request = struct.pack("<I", len(text)) + text
    result = subprocess.run(
        [executable, "--omnigifs-text-embedding-worker"],
        input=request,
        capture_output=True,
        check=False,
        timeout=60,
    )
    if result.returncode != 0:
        sys.stderr.buffer.write(result.stderr)
        raise SystemExit(f"OmniGifs worker exited with status {result.returncode}")
    if len(result.stdout) < 4:
        raise SystemExit("OmniGifs worker returned no embedding packet")

    length = struct.unpack("<I", result.stdout[:4])[0]
    payload = result.stdout[4:]
    if length != 512 * 4 or len(payload) != length:
        raise SystemExit(
            f"OmniGifs worker returned an invalid embedding packet ({len(payload)} bytes)"
        )


if __name__ == "__main__":
    main()
