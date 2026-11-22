#!/bin/bash
# Builds Niche, assembles Niche.app by hand (no Xcode project), signs it and installs it.
#   scripts/bundle.sh            release build, install to ~/Applications (quits a running Niche and replaces the installed copy)
#   CONFIG=debug scripts/bundle.sh
#   INSTALL=0 scripts/bundle.sh  build/Niche.app only
#   NICHE_SIGN_IDENTITY="My Identity" scripts/bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
INSTALL="${INSTALL:-1}"
APP_NAME="Niche"
# The bundle identifier has one source: Resources/Info.plist.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"
# Code-signing identity. Override with NICHE_SIGN_IDENTITY; falls back to ad-hoc signing when it is not in the keychain.
IDENTITY="${NICHE_SIGN_IDENTITY:-Niche Local Signing}"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

cd "$ROOT"
echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# SwiftPM resource bundles resolve through Bundle.module, which does not work in a hand-assembled app.
if compgen -G "$BIN/Niche_*.bundle" > /dev/null; then
  echo "error: a Niche target declares SwiftPM resources ($(basename "$(compgen -G "$BIN/Niche_*.bundle" | head -1)"))." >&2
  echo "       Put files in Resources/ or Support/ and load them via Bundle.main instead." >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# App icon: macOS 26 .icon (Icon Composer) if present, else a plain .icns.
if [ -d Resources/AppIcon.icon ]; then
  xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$ROOT/build/icon.plist" > /dev/null
elif [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Licence and third-party notices travel with the binary.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Claude Code plugin (installed into the user's Claude config only on explicit opt-in inside the app).
if [ -n "$(ls -A Support/ClaudePlugin 2>/dev/null)" ]; then
  cp -R Support/ClaudePlugin "$APP/Contents/Resources/ClaudePlugin"
fi

# Now Playing adapter: build.sh <outdir> must produce MediaRemoteAdapter.framework and mediaremote-adapter.pl.
if [ -x Vendor/MediaRemoteAdapter/build.sh ]; then
  echo "==> Building MediaRemoteAdapter"
  OUT="$ROOT/build/adapter"
  rm -rf "$OUT" && mkdir -p "$OUT"
  Vendor/MediaRemoteAdapter/build.sh "$OUT"
  cp -R "$OUT/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
  cp "$OUT/mediaremote-adapter.pl" "$APP/Contents/Resources/"
fi

# An identity is a certificate with its private key; a certificate alone cannot sign. A self-signed one is listed as
# not trusted, which is fine for running on this Mac, so the "valid only" filter is not used.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then SIGN="$IDENTITY"; else SIGN="-"; echo "warning: '$IDENTITY' not found; ad-hoc signing (permissions will not persist across rebuilds)"; fi
echo "==> Signing with: $SIGN"
find "$APP/Contents/Frameworks" -maxdepth 1 -mindepth 1 -print0 | while IFS= read -r -d '' nested; do
  codesign --force --sign "$SIGN" "$nested"
done
# Hardened runtime: another process cannot load code into the app to borrow its Calendar, folder or Automation access.
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID" --options runtime --entitlements Resources/Niche.entitlements "$APP"
codesign --verify --strict "$APP"

if [ "$INSTALL" = "1" ]; then
  mkdir -p "$INSTALL_DIR"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rsync -a --delete "$APP/" "$INSTALL_DIR/$APP_NAME.app/"
  codesign --verify --strict "$INSTALL_DIR/$APP_NAME.app"
  echo "==> Installed $INSTALL_DIR/$APP_NAME.app"
fi
