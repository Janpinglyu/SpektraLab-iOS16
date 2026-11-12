#!/usr/bin/env python3
"""Pack the engine's resources into one file for the app bundle.

    python3 ios/Tools/pack-engine-assets.py <resource-dir> <output-file>

Why one file and not a directory: a sideloading installer (SideStore,
AltStore) unpacks the IPA into its own staging directory and then copies the
`.app` to a fixed name. With 33 loose resource files inside, that copy fails
on iOS 27, and all it reports is

    Failed to get bundle ID ... /Payload/App.app

which names nothing useful. A test bundle with six entries installed fine on
the same device, so the entry count is what matters, not the bundle id.

Format (deliberately trivial -- iOS has no zip/tar reader in the SDK):

    magic   "SPKA"            4 bytes
    count   uint32 little-endian
    repeat  name length       uint16
            name              UTF-8, forward slashes
            data length       uint32
            data

`EngineBridge.swift` reads it back with `Data` and plain integer decoding.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

MAGIC = b"SPKA"


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: pack-engine-assets.py <resource-dir> <output-file>", file=sys.stderr)
        sys.exit(2)

    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    if not src.is_dir():
        sys.exit(f"not a directory: {src}")

    files = sorted(p for p in src.rglob("*") if p.is_file())
    if not files:
        sys.exit(f"nothing to pack in {src}")

    total = 0
    with open(out, "wb") as handle:
        handle.write(MAGIC)
        handle.write(struct.pack("<I", len(files)))
        for path in files:
            name = path.relative_to(src).as_posix().encode("utf-8")
            data = path.read_bytes()
            if len(name) > 0xFFFF:
                sys.exit(f"path too long: {name!r}")
            handle.write(struct.pack("<H", len(name)))
            handle.write(name)
            handle.write(struct.pack("<I", len(data)))
            handle.write(data)
            total += len(data)

    print(f"    {len(files)} files, {total / 1048576:.1f} MB -> {out}")
    print(f"    archive is {out.stat().st_size / 1048576:.1f} MB")


if __name__ == "__main__":
    main()
