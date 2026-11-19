#!/bin/zsh
# Knob installer.
#   ./install.sh              build, set up (first time only), install and start
#   ./install.sh --setup      choose the screen, sound control and apps again
#   ./install.sh --uninstall  remove Knob, its LaunchAgent, setup and saved levels
set -euo pipefail
cd "${0:A:h}"

APP=Knob
LABEL=local.knob
DEST="$HOME/Applications/$APP.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$HOME/Library/Application Support/Knob/config.plist"

unload() { launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true; }

case "${1:-}" in
  --uninstall)
    unload
    rm -f "$AGENT"
    rm -rf "$DEST" "${CONFIG:h}"
    defaults delete "$LABEL" 2>/dev/null || true
    echo "Knob removed. Its permissions can be removed in System Settings > Privacy & Security >"
    echo "Accessibility and Screen & System Audio Recording."
    exit 0 ;;
  ""|--setup) ;;
  *) echo "Usage: ./install.sh [--setup | --uninstall]"; exit 2 ;;
esac

if (( $(sw_vers -productVersion | cut -d. -f1) < 15 )); then
  echo "Knob needs macOS 15 or later."; exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Knob is built from source. Install Apple's command line tools first: xcode-select --install"; exit 1
fi
SWIFT_MAJOR=$(xcrun swiftc --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)
if (( ${SWIFT_MAJOR:-0} < 6 )); then
  echo "Knob needs Swift 6 or later. Update the command line tools (Software Update)."; exit 1
fi

echo "Building Knob…"
BUILD="build/$APP.app"
rm -rf build
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
xcrun swiftc -O -wmo -target "$(uname -m)-apple-macos15.0" -Xlinker -dead_strip \
  -o "$BUILD/Contents/MacOS/$APP" Sources/*.swift
cp Resources/Info.plist "$BUILD/Contents/"
cp "Resources/$APP.icns" "$BUILD/Contents/Resources/"

# An Apple Development certificate, if there is one, keeps macOS permissions across reinstalls.
# Signed by fingerprint: a renewed certificate leaves two identities with the same name.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$BUILD"

# Set up on request, the first time, or when the saved setup can't be read.
if [[ "${1:-}" == --setup ]] || ! "$BUILD/Contents/MacOS/$APP" --check >/dev/null 2>&1; then
  echo
  "$BUILD/Contents/MacOS/$APP" --setup
fi

# Everything that can fail happens before the installed copy is touched.
"$BUILD/Contents/MacOS/$APP" --write-agent "$DEST/Contents/MacOS/$APP"
unload
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILD" "$DEST"
if [[ -z "$IDENTITY" ]]; then
  # A new ad hoc signature voids the old Accessibility grant: ask again instead of failing silently.
  defaults delete "$LABEL" askedForAccessibility 2>/dev/null || true
  tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
fi
launchctl bootstrap "gui/$UID" "$AGENT"

echo
"$DEST/Contents/MacOS/$APP" --check
echo
echo "Installed in ~/Applications. Knob now starts whenever this screen connects."
if [[ -z "$IDENTITY" ]]; then
  echo "Signed without a developer certificate: after a reinstall, allow Knob again when macOS asks. If the"
  echo "volume keys stay silent, remove Knob from Accessibility in System Settings and add it back."
fi
