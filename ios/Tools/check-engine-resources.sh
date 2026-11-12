#!/usr/bin/env bash
#
#  check-engine-resources.sh — is the engine's data in the app?
#
#  A pre-build *check*, not a build step. It reports rather than bakes: the
#  kernels and the baked resources are produced by `ios/Tools/build-engine.sh`,
#  which needs the Metal compiler and therefore a machine that has one.
#
#  Why it matters: without the metallib the engine starts and then fails when
#  it cannot load its library, and without `spektrafilm_constants.bin` it
#  fails at the first read. Both failures surface as an engine error at
#  runtime, on a phone, where the cause is a build step nobody ran. This
#  script turns them into one line at build time.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dst="$here/../../build"

missing=0
note_missing() {
  echo "error: the engine's resources are incomplete: $1 is missing."
  echo "       run ios/Tools/build-engine.sh bundle before building the app."
  missing=1
}

# The resources ship as one archive now (see `pack-engine-assets.py`): a
# sideloading installer fails to copy a bundle that holds 33 loose files.
if [ ! -f "$dst/engine-assets.bin" ]; then
  note_missing "$dst/engine-assets.bin"
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "the engine's resources are in place ($(du -h "$dst/engine-assets.bin" | cut -f1) archive, shipped separately)"
