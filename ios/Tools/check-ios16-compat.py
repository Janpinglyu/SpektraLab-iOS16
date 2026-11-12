#!/usr/bin/env python3
"""Static guard for the iOS 16 compatibility build.

This runs on any machine -- no Xcode, no macOS, no engine checkout needed --
so a Windows/Linux checkout can verify the tree before pushing it to a macOS
runner. It fails when:

  * the four deployment-target declarations disagree, or
  * an iOS 17+/26-only SwiftUI API appears anywhere outside the guarded
    compatibility layer at the top of ContentView.swift.

Lowering `MinimumOSVersion` alone is not enough: a binary that links a
Liquid Glass symbol installs on iOS 16 and crashes at launch. Every such
API must be reached through `labGlass*` / `LabGlassContainer` / the other
availability-gated helpers. Re-run this after editing any Swift file.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IOS = REPO / "ios"
TARGET = "16.0"

# API -> why it is not available on the deployment target.
FORBIDDEN: dict[str, str] = {
    r"\.snappy\(": "iOS 17 .snappy animation (use .spring)",
    r"\.bouncy\(": "iOS 17 .bouncy animation (use .spring)",
    r"\.smooth\(": "iOS 17 .smooth animation (use .easeOut)",
    r"\.onChange\([^\n]*\{\s*_,": "iOS 17 two-parameter onChange (use the single-parameter form)",
    r"\.onChange\([^)]*initial:": "iOS 17 onChange(of:initial:)",
    r"\.sensoryFeedback\(": "iOS 17 sensoryFeedback (use labSelectionFeedback)",
    r"\.presentationBackground\(": "iOS 16.4 presentationBackground (use labPresentationBackground)",
    r"GlassEffectContainer\(": "iOS 26 GlassEffectContainer (use LabGlassContainer)",
    r"(?<![A-Za-z])glassEffect\(": "iOS 26 glassEffect (use labGlass/labGlassInteractive/labGlassTint)",
    r"\.buttonStyle\(\.glass": "iOS 26 glass button style",
    r"\.symbolEffect\(": "iOS 17 symbolEffect",
    r"\.scrollTargetBehavior\(": "iOS 17 scrollTargetBehavior",
    r"\.scrollTargetLayout\(": "iOS 17 scrollTargetLayout",
    r"\.scrollPosition\(": "iOS 17 scrollPosition",
    r"\.containerRelativeFrame\(": "iOS 17 containerRelativeFrame",
    r"\.visualEffect\(": "iOS 17 visualEffect",
    r"\.geometryGroup\(": "iOS 17 geometryGroup",
    r"\.safeAreaPadding\(": "iOS 17 safeAreaPadding",
    r"\.phaseAnimator\(": "iOS 17 phaseAnimator",
    r"\.keyframeAnimator\(": "iOS 17 keyframeAnimator",
    r"\.inspector\(": "iOS 17 inspector",
    r"\.fontWidth\(": "iOS 17 fontWidth",
    r"\.fontDesign\(": "iOS 16.1 fontDesign",
    r"\.typesettingLanguage\(": "iOS 17 typesettingLanguage",
    r"\.tabBarMinimizeBehavior\(": "iOS 26 tab bar behaviour",
    r"\.scrollEdgeEffectStyle\(": "iOS 26 scroll edge effect",
    r"@Observable\b": "iOS 17 Observation macro",
    r"@Bindable\b": "iOS 17 Observation macro",
}

failures: list[str] = []


def check(label: str, ok: bool, problem: str = "") -> None:
    line = f"  [{'ok' if ok else 'FAIL'}] {label}"
    if not ok and problem:
        line += f" -- {problem}"
    print(line)
    if not ok:
        failures.append(f"{label}: {problem or 'check failed'}")


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def deployment_targets() -> None:
    gen = text(IOS / "Tools" / "gen-project.py")
    m = re.search(r'IOS_MIN\s*=\s*os\.environ\.get\("SPEKTRALAB_IOS_MIN",\s*"([^"]+)"\)', gen)
    check("gen-project.py IOS_MIN", bool(m) and m.group(1) == TARGET,
          (m.group(1) if m else "declaration not found") + f", expected {TARGET}")

    sh = text(IOS / "Tools" / "build-engine.sh")
    m = re.search(r'IOS_MIN="\$\{SPEKTRALAB_IOS_MIN:-([^}]+)\}"', sh)
    check("build-engine.sh Metal target", bool(m) and m.group(1) == TARGET,
          (m.group(1) if m else "declaration not found") + f", expected {TARGET}")

    plist = text(IOS / "SpektraLab" / "Info.plist")
    m = re.search(r"<key>MinimumOSVersion</key>\s*<string>([^<]+)</string>", plist)
    check("Info.plist MinimumOSVersion", bool(m) and m.group(1) == TARGET,
          (m.group(1) if m else "key not found") + f", expected {TARGET}")

    pbx = text(IOS / "SpektraLab.xcodeproj" / "project.pbxproj")
    found = set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;]+);", pbx))
    check("project.pbxproj build settings", found == {TARGET},
          f"found {sorted(found) or 'none'}, expected only {TARGET}")


def sources() -> None:
    swift_files = sorted((IOS / "SpektraLab").rglob("*.swift"))
    hits = 0
    for path in swift_files:
        src = text(path)
        # The compatibility layer is everything above LabBackdrop in
        # ContentView.swift; only that region may reference the new symbols.
        if path.name == "ContentView.swift":
            src = src.split("struct LabBackdrop", 1)[-1]
        for pattern, reason in FORBIDDEN.items():
            for m in re.finditer(pattern, src):
                line = src.count("\n", 0, m.start()) + 1
                print(f"  [FAIL] {path.relative_to(REPO)}:{line} -- {reason}: {m.group(0)!r}")
                hits += 1
                failures.append(f"{path.name}: {reason}")

    compat = text(IOS / "SpektraLab" / "ContentView.swift").split("struct LabBackdrop", 1)[0]
    guards = len(re.findall(r"#available\(iOS 26\.0", compat))
    check("Liquid Glass calls are availability-gated", guards >= 4,
          f"found {guards} #available(iOS 26.0) guards, expected at least 4")
    check("older-Xcode fallback is present", "#if compiler(>=6.2)" in compat,
          "missing #if compiler(>=6.2)")
    check("no unguarded iOS 17+/26 API", hits == 0,
          f"{hits} occurrence(s) across {len(swift_files)} Swift files")


def main() -> int:
    print(f"SpektraLab iOS {TARGET} compatibility check")
    print(f"repository: {REPO}")
    deployment_targets()
    sources()
    if failures:
        print(f"\nFAILED ({len(failures)} problem(s)). Do not build an IPA from this tree.")
        return 1
    print(f"\nOK: all deployment targets are {TARGET} and every newer API is guarded.")
    print("Build with Xcode (or the CI workflow), then re-check the shipped")
    print("IPA's Info.plist: MinimumOSVersion must still read 16.0.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
