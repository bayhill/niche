#!/bin/bash
# Builds the vendored mediaremote-adapter without cmake.
#   Vendor/MediaRemoteAdapter/build.sh <outdir>
# Produces:
#   <outdir>/MediaRemoteAdapter.framework   (versioned framework; also carries the test client at
#                                            Versions/A/MediaRemoteAdapterTestClient for the `test` self-check)
#   <outdir>/mediaremote-adapter.pl
set -euo pipefail

if [ $# -ne 1 ]; then echo "usage: $0 <outdir>" >&2; exit 2; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
NAME="MediaRemoteAdapter"
FW="$OUT/$NAME.framework"
VER="$FW/Versions/A"
CLANG="$(xcrun --find clang)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMMON=(-isysroot "$SDK" -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -fobjc-arc -O2 -w)

rm -rf "$FW" "$OUT/mediaremote-adapter.pl"
mkdir -p "$VER/Resources"

"$CLANG" "${COMMON[@]}" -dynamiclib -fvisibility=default \
  -I "$HERE/include" -I "$HERE/src" \
  -install_name "@rpath/$NAME.framework/Versions/A/$NAME" \
  -current_version 0.1.0 -compatibility_version 0.1.0 \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  "$HERE"/src/adapter/*.m "$HERE"/src/private/MediaRemote.m "$HERE"/src/utility/*.m \
  -o "$VER/$NAME"

"$CLANG" "${COMMON[@]}" -I "$HERE/src/test" \
  -framework Foundation -framework MediaPlayer \
  "$HERE/src/test/main.m" "$HERE/src/test/NowPlayingTest.m" \
  -o "$VER/${NAME}TestClient"

cat > "$VER/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>com.vandenbe.$NAME</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

ln -s A "$FW/Versions/Current"
ln -s "Versions/Current/$NAME" "$FW/$NAME"
ln -s "Versions/Current/${NAME}TestClient" "$FW/${NAME}TestClient"
ln -s Versions/Current/Resources "$FW/Resources"

# Ad-hoc signatures so the result runs as is; scripts/bundle.sh re-signs the framework with the app identity.
codesign --force --sign - "$VER/${NAME}TestClient"
codesign --force --sign - "$FW"

cp "$HERE/bin/mediaremote-adapter.pl" "$OUT/mediaremote-adapter.pl"
echo "built $FW and $OUT/mediaremote-adapter.pl"
