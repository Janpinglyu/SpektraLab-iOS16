#!/usr/bin/env python3
"""Pack the app into an IPA that a side-loading installer accepts.

    python3 ios/Tools/repack-ipa.py <dir-with-Payload> <output.ipa>

Why not `zip` or `ditto`: both write a 24-byte extra field on every entry
(the `UT` extended-timestamp and `ux` Unix field) and stamp
`create_version = 30`. SideStore's unzip rejects that outright:

    Operation Failed
    Archive appears to be corrupt: SpektraLab-xxxx-unsigned.ipa

and the `ditto -c -k` archives it replaced were worse: they unpacked partway
and then reported

    Failed to get bundle ID ... /Payload/App.app

Neither message has anything to do with the bundle's contents. A zip written
by Python's `zipfile` carries no extra fields and versions 20/20, and the one
test IPA built that way installed on the first try.

The file modes are preserved, because iOS needs the executable bit on the
main binary and nothing else.
"""

from __future__ import annotations

import os
import sys
import plistlib
import zipfile
from pathlib import Path

STAMP = (2026, 1, 1, 0, 0, 0)

# Keys Xcode stamps into the built Info.plist that the working reference IPA
# does not carry. The DT* group is what `builtin-infoPlistUtility` derives from
# the SDK; App Store submission requires it, side-loading does not.
DROP_KEYS = frozenset({
    "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms",
    "NSAccentColorName",
    "DTCompiler",
    "DTPlatformBuild",
    "DTPlatformName",
    "DTPlatformVersion",
    "DTSDKBuild",
    "DTSDKName",
    "DTXcode",
    "DTXcodeBuild",
})


def clean_info_plist(raw: bytes) -> bytes:
    """Rewrite an Info.plist without the keys the reference build lacks."""
    parsed = plistlib.loads(raw)
    for key in DROP_KEYS:
        parsed.pop(key, None)

    # `builtin-linkAssetCatalog` rewrites CFBundleIcons after the source plist
    # is processed and leaves only CFBundleIconName; this puts the file list
    # back. With the PNG at the bundle root, iOS resolves it from there.
    primary = parsed.setdefault("CFBundleIcons", {}).setdefault("CFBundlePrimaryIcon", {})
    primary.setdefault("CFBundleIconFiles", ["AppIcon60x60"])
    primary.setdefault("CFBundleIconName", "AppIcon")
    # `fmt=FMT_XML` keeps it text, which is what the reference ships and what
    # every installer reads without complaint.
    return plistlib.dumps(parsed, fmt=plistlib.FMT_XML)


def info(name: str, directory: bool, executable: bool) -> zipfile.ZipInfo:
    zi = zipfile.ZipInfo(name, date_time=STAMP)
    zi.create_system = 3          # Unix, so the mode is honoured
    zi.create_version = 20        # 2.0, the most widely accepted
    zi.extract_version = 20
    if directory:
        zi.compress_type = zipfile.ZIP_STORED
        zi.external_attr = (0o40755 << 16) | 0x10   # directory bit
    else:
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = (0o100755 if executable else 0o100644) << 16
    return zi


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: repack-ipa.py <dir-with-Payload> <output.ipa>", file=sys.stderr)
        sys.exit(2)

    root = Path(sys.argv[1])
    out = Path(sys.argv[2])
    payload = root / "Payload"
    if not payload.is_dir():
        sys.exit(f"no Payload/ under {root}")

    # The main executable is taken from Info.plist rather than from the file
    # mode: a chmod that silently did not apply would ship a 0644 binary, and
    # the app would install and then fail to launch.
    import plistlib
    executables = set()
    for bundle in payload.iterdir():
        if not (bundle.is_dir() and bundle.suffix == ".app"):
            continue
        plist_path = bundle / "Info.plist"
        if not plist_path.is_file():
            continue
        name = plistlib.loads(plist_path.read_bytes()).get("CFBundleExecutable")
        if name:
            executables.add((bundle / name).resolve())

    paths = sorted(payload.rglob("*"))
    # directories first, then files, each group in path order
    paths.sort(key=lambda p: (0 if p.is_dir() else 1, p.as_posix()))

    out.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            name = path.relative_to(root).as_posix()
            if path.is_dir():
                archive.writestr(info(name.rstrip("/") + "/", True, False), b"")
            else:
                executable = path.resolve() in executables
                data = path.read_bytes()
                if name.endswith(".app/Info.plist"):
                    data = clean_info_plist(data)
                archive.writestr(info(name, False, executable), data)
            written += 1

    # --- verify what was actually written --------------------------------
    check = zipfile.ZipFile(out)
    entries = check.infolist()
    with_extra = [i.filename for i in entries if i.extra]
    if with_extra:
        sys.exit(f"extra fields survived on {len(with_extra)} entries: {with_extra[:3]}")
    bad_version = [i.filename for i in entries if i.create_version != 20]
    if bad_version:
        sys.exit(f"create_version is not 20 on: {bad_version[:3]}")
    if check.testzip() is not None:
        sys.exit(f"CRC check failed: {check.testzip()}")

    app = next((i for i in entries if i.filename.endswith(".app/")), None)
    if app is None:
        sys.exit("no .app directory in the archive")
    raw_plist = check.read(app.filename + "Info.plist")
    shipped = plistlib.loads(raw_plist)
    if not shipped.get("CFBundleIdentifier"):
        sys.exit("Info.plist in the archive has no CFBundleIdentifier")
    left = sorted(k for k in DROP_KEYS if k in shipped)
    if left:
        sys.exit(f"keys that should have been stripped survived: {left}")

    executables = [i.filename for i in entries if (i.external_attr >> 16) & 0o111]
    print(f"{out.name}: {len(entries)} entries, {os.path.getsize(out) / 1048576:.2f} MB")
    print(f"  no extra fields, create_version 20, CRC OK")
    print(f"  bundle: {app.filename}")
    print(f"  executables: {[e.split('/')[-1] for e in executables]}")
    print(f"  plist keys : {len(shipped)} | DT*/build keys stripped")
    assert written == len(entries)


if __name__ == "__main__":
    main()
