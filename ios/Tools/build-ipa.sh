#!/usr/bin/env bash
#
#  build-ipa.sh — build a signed IPA on a Mac, in one command.
#
#  Usage:
#      ios/Tools/build-ipa.sh                 # archive + export, signed
#      ios/Tools/build-ipa.sh --unsigned      # archive only, no signing
#
#  This is the local counterpart of `.github/workflows/build-ios.yml`: the same
#  steps, in the same order, on a machine that has Xcode. The CI is there for
#  people who do not have a Mac; this is here for people who do, and for the
#  case where the CI cannot reach a private certificate.
#
#  The signing material is expected in the environment:
#
#      SPEKTRAFILM_SIGN_IDENTITY="Apple Development: Name (TEAMID)"
#      SPEKTRAFILM_TEAM_ID=TEAMID
#      SPEKTRAFILM_PROVISIONING_PROFILE="My Profile Name"
#      SPEKTRAFILM_BUNDLE_ID=com.hanze.spektralab
#
#  and the certificate and the profile installed into the keychain already
#  (Xcode's "Manage Certificates" does that, or `security import` does it by
#  hand). Without them the build is ad-hoc and the IPA will not install.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

unsigned=0
if [ "${1:-}" = "--unsigned" ]; then
  unsigned=1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is not on the PATH. This script needs a Mac with Xcode." >&2
  exit 1
fi

echo "==> the engine, for iOS"
python3 tools/apply-ios-patch.py engine

echo "==> the engine's kernels and resources"
ios/Tools/build-engine.sh bundle

echo "==> the app icon (needs Pillow; skipped with a warning if absent)"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 tools/make-app-icon.py
else
  echo "warning: Pillow is not installed (pip install Pillow); the app will ship without a custom icon." >&2
fi

# `CFBundleIconFiles` names `AppIcon60x60`; iOS looks for the @2x and @3x
# files beside the executable. The asset catalog alone is not enough here
# because `INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE` is off so the hand-written
# CFBundleIcons survives. A device with only the @2x file shows a missing or
# fallback home-screen icon.
iconset=ios/SpektraLab/Assets.xcassets/AppIcon.appiconset
cp "$iconset/icon-60@2x.png" ios/SpektraLab/AppIcon60x60@2x.png
cp "$iconset/icon-60@3x.png" ios/SpektraLab/AppIcon60x60@3x.png

echo "==> the Xcode project"
python3 ios/Tools/gen-project.py

if [ "$unsigned" -eq 1 ]; then
  echo "==> the unsigned device build"
  mkdir -p build/ipa
  xcodebuild -project ios/SpektraLab.xcodeproj \
    -scheme SpektraLab \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -destination "generic/platform=iOS" \
    CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tee build/xcodebuild.log

  app="build/DerivedData/Build/Products/Release-iphoneos/SpektraLab.app"
  if [ ! -f "$app/Info.plist" ] || [ ! -x "$app/SpektraLab" ]; then
    echo "error: the device app bundle is incomplete: $app" >&2
    exit 1
  fi

  stage="build/unsigned-stage"
  rm -rf "$stage"
  mkdir -p "$stage/Payload"
  ditto --norsrc --noextattr --noqtn --noacl "$app" "$stage/Payload/SpektraLab.app"
  staged_app="$stage/Payload/SpektraLab.app"
  executable="$(plutil -extract CFBundleExecutable raw - < "$staged_app/Info.plist")"
  find "$staged_app" -type f -exec chmod a-x {} +
  chmod a+x "$staged_app/$executable"

  python3 ios/Tools/repack-ipa.py "$stage" build/ipa/SpektraLab-unsigned.ipa
  echo "==> done (unsigned): build/ipa/SpektraLab-unsigned.ipa"
  exit 0
fi

echo "==> the archive"
mkdir -p build
set -o pipefail
xcodebuild -project ios/SpektraLab.xcodeproj \
  -target SpektraLab \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination "generic/platform=iOS" \
  -archivePath build/SpektraLab.xcarchive \
  archive 2>&1 | tee build/xcodebuild.log

echo "==> the IPA"
mkdir -p build/ipa
bundle="${SPEKTRAFILM_BUNDLE_ID:-com.hanze.spektralab}"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
  <key>teamID</key>
  <string>${SPEKTRAFILM_TEAM_ID:-}</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${bundle}</key>
    <string>${SPEKTRAFILM_PROVISIONING_PROFILE:-}</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/SpektraLab.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/ipa 2>&1 | tee build/export.log

echo ""
echo "the IPA is at:"
ls -la build/ipa
