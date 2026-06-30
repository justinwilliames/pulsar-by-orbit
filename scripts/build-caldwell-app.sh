#!/bin/sh
# build-caldwell-app.sh — compile the SwiftUI menu-bar app and assemble
# a proper Pulsar.app bundle.
#
# Requires macOS 26 (Tahoe) — the app uses Liquid Glass APIs that don't
# exist on earlier macOS versions.
# Requires Swift 6.1+ — bundled with macOS 26.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/macos/CaldwellDashboard"
BUILD_DIR="$APP_DIR/build"
APP_BUNDLE="$BUILD_DIR/Pulsar.app"

# macOS version sanity check
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 26 ]; then
  echo "Error: this app requires macOS 26 (Tahoe) or later." >&2
  echo "Current macOS: $(sw_vers -productVersion)" >&2
  echo "Use Plash or the web dashboard until you upgrade." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Error: swift not found. Install Xcode or Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

cd "$APP_DIR"

# Re-sync the Claude voice-integration payload from the repo's source-of-truth
# copies into the app's staging dir, so a stale Sources/Resources/claude-integration
# can never ship. These are the exact files the in-app installer drops into the
# user's ~/.claude. Keep this list in lockstep with ClaudeIntegrationInstaller.swift.
CLAUDE_STAGE="$APP_DIR/Sources/Resources/claude-integration"
echo "Syncing Claude integration payload into the app staging dir..."
mkdir -p "$CLAUDE_STAGE/scripts"
cp "$REPO_ROOT/SKILL.md"    "$CLAUDE_STAGE/SKILL.md"
cp "$REPO_ROOT/CANON.md"    "$CLAUDE_STAGE/CANON.md"
cp "$REPO_ROOT/voices.json" "$CLAUDE_STAGE/voices.json"
for f in say.sh session-start-voice.sh stop-hook.sh chime.sh turn-start.sh statusline.sh; do
  cp "$REPO_ROOT/scripts/$f" "$CLAUDE_STAGE/scripts/$f"
done

echo "Building release binary (this can take a minute)..."
swift build -c release

BINARY="$APP_DIR/.build/release/CaldwellDashboard"
if [ ! -f "$BINARY" ]; then
  # Apple Silicon may put it under a triple-prefixed dir
  BINARY="$(find "$APP_DIR/.build" -name CaldwellDashboard -type f -path "*/release/*" 2>/dev/null | head -1)"
fi

if [ ! -f "$BINARY" ]; then
  echo "Error: build did not produce a CaldwellDashboard binary under .build/" >&2
  exit 1
fi

echo "Assembling Pulsar.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/CaldwellDashboard"
cp "$APP_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Bundle resources — the app icon (Info.plist sets CFBundleIconFile=AppIcon)
# and the portrait PNGs. CI's package-dmg.yml copies these; the local build
# previously skipped them, producing an icon-less /Applications bundle.
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$APP_DIR/Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [ -d "$REPO_ROOT/assets/portraits" ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/assets"
  cp -R "$REPO_ROOT/assets/portraits" "$APP_BUNDLE/Contents/Resources/assets/portraits"
fi

# OrbitLogo PNGs — copied by SPM into the build's resource bundle; extract
# them into Contents/Resources/ so Bundle.main can find them via NSImage(named:).
RESOURCE_BUNDLE="$(find "$APP_DIR/.build" -name "CaldwellDashboard_CaldwellDashboard.bundle" -path "*/release/*" 2>/dev/null | head -1)"
if [ -n "$RESOURCE_BUNDLE" ] && [ -d "$RESOURCE_BUNDLE" ]; then
  for f in OrbitLogo.png "OrbitLogo@2x.png" "OrbitLogo@3x.png" \
           pulsar-mouth-0.png pulsar-mouth-1.png pulsar-mouth-2.png \
           pulsar-mouth-3.png pulsar-mouth-4.png pulsar-blink.png \
           voyager-mouth-0.png voyager-mouth-1.png voyager-mouth-2.png voyager-mouth-3.png voyager-mouth-4.png voyager-blink.png \
           sentinel-mouth-0.png sentinel-mouth-1.png sentinel-mouth-2.png sentinel-mouth-3.png sentinel-mouth-4.png sentinel-blink.png \
           nova-mouth-0.png nova-mouth-1.png nova-mouth-2.png nova-mouth-3.png nova-mouth-4.png nova-blink.png \
           nebula-mouth-0.png nebula-mouth-1.png nebula-mouth-2.png nebula-mouth-3.png nebula-mouth-4.png nebula-blink.png \
           echo-mouth-0.png echo-mouth-1.png echo-mouth-2.png echo-mouth-3.png echo-mouth-4.png echo-blink.png \
           atlas-mouth-0.png atlas-mouth-1.png atlas-mouth-2.png atlas-mouth-3.png atlas-mouth-4.png atlas-blink.png; do
    src="$RESOURCE_BUNDLE/$f"
    if [ -f "$src" ]; then
      cp "$src" "$APP_BUNDLE/Contents/Resources/$f"
    fi
  done
  echo "Copied OrbitLogo + pulsar-mouth + blink PNGs to Contents/Resources."

  # Claude voice-integration payload: SPM copies the whole directory verbatim
  # into the resource bundle. Lift it into Contents/Resources/claude-integration/
  # so ClaudeIntegrationInstaller can find it via Bundle.main.resourceURL. Keep
  # the scripts executable so the installed hooks run without a chmod dance.
  CI_SRC="$RESOURCE_BUNDLE/claude-integration"
  if [ -d "$CI_SRC" ]; then
    rm -rf "$APP_BUNDLE/Contents/Resources/claude-integration"
    cp -R "$CI_SRC" "$APP_BUNDLE/Contents/Resources/claude-integration"
    chmod +x "$APP_BUNDLE/Contents/Resources/claude-integration/scripts/"*.sh 2>/dev/null || true
    echo "Copied claude-integration payload (skill + hooks + say.sh) to Contents/Resources."
  else
    echo "Warning: claude-integration payload not found in SPM bundle — in-app installer will be unavailable." >&2
  fi
else
  echo "Warning: SPM resource bundle not found — OrbitLogo may not render." >&2
fi

# Embed Sparkle.framework. The binary loads @rpath/Sparkle.framework/... and
# carries an @executable_path/../Frameworks rpath (set in Package.swift), so
# the framework must live at Contents/Frameworks. The 0.2.0 attempt linked
# Sparkle but skipped this embed step and crashed at dyld before drawing a
# pixel — keep this in lockstep with package-dmg.yml's identical block.
FRAMEWORK_SRC="$(dirname "$BINARY")/Sparkle.framework"
if [ ! -d "$FRAMEWORK_SRC" ]; then
  echo "Error: Sparkle.framework not found next to the binary ($FRAMEWORK_SRC)." >&2
  echo "Did 'swift build' resolve the Sparkle SPM dependency?" >&2
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
# ditto preserves the framework's Versions/ symlink layout (cp -R mangles it).
ditto "$FRAMEWORK_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Ad-hoc sign, inside-out: the embedded framework first (--deep catches its
# nested XPC services + Updater.app + Autoupdate), then the whole app last so
# its signature seals the framework and resources. Ad-hoc (`--sign -`) is
# sufficient: Sparkle validates updates via the EdDSA signature
# (SUPublicEDKey), not a Developer ID.
codesign --force --deep --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$APP_BUNDLE"

# Fail loudly on a broken signature — that is precisely the launch-time
# regression Sparkle introduced last time.
if ! codesign --verify --deep --strict "$APP_BUNDLE"; then
  echo "Error: codesign verification failed on $APP_BUNDLE" >&2
  exit 1
fi

echo ""
echo "Built: $APP_BUNDLE"
echo "To install:  $SCRIPT_DIR/install-caldwell-app.sh"
echo "To run now:  open '$APP_BUNDLE'"
echo "Build complete!"
