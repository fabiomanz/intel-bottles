#!/usr/bin/env bash
#
# Run by build_root.sh on the build runner before qtwebengine is built.
#
# Qt 6.11.2's WebEngine needs Apple's Metal shader compiler, which Xcode 26 no longer
# bundles -- it is a separate component, and GitHub's runner image does not install it.
# Without it Qt's configure does not fail: it prints "QtWebEngine won't be built. Build
# requires Metal Toolchain" into a log brew never shows, builds only QtPdf, and the result
# looks like a successful 26-minute build (that is how a 3.4 MB qtwebengine bottle got
# published on 2026-10-04). So install the component, and fail loudly if that does not
# work rather than let the build quietly drop WebEngine again.

set -euo pipefail

if xcrun metal --version >/dev/null 2>&1; then
  echo "    Metal toolchain already installed"
  exit 0
fi

for attempt in 1 2 3; do
  echo "    downloading the Metal toolchain (attempt $attempt)"
  if xcodebuild -downloadComponent MetalToolchain || sudo xcodebuild -downloadComponent MetalToolchain; then
    if xcrun metal --version >/dev/null 2>&1; then
      xcrun metal --version 2>&1 | head -1 | sed 's/^/    /'
      exit 0
    fi
  fi
  sleep 30
done

echo "    could not install the Metal toolchain; qtwebengine would build without WebEngine" >&2
exit 1
