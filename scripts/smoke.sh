#!/bin/bash
# Builds, installs and checks Notcher end to end, capturing each notch state with sample data.
# Needs an unlocked display and Screen Recording permission for the terminal.
#   scripts/smoke.sh [output-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/smoke}"
APP="$HOME/Applications/Notcher.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"
mkdir -p "$OUT"
cd "$ROOT"

echo "==> Tests"
swift test 2>&1 | grep -E "Test run with [0-9]{2,}|✘|error:" || true

echo "==> Bundle"
scripts/bundle.sh > "$OUT/bundle.log" 2>&1 || { cat "$OUT/bundle.log"; exit 1; }
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP" && codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority)="

echo "==> Conversion"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -x Notcher 2>/dev/null || true' EXIT
swift scripts/make-icon.swift "$TMP/sample.png" > /dev/null
swift run -c release webpify "$TMP/sample.png" 2>/dev/null | tail -2
test -s "$TMP/sample.webp"

wait_for_app() { local n=0; until pgrep -x Notcher > /dev/null || [ $n -gt 100 ]; do n=$((n + 1)); /bin/sleep 0.1; done; /bin/sleep 2; }
NOTCH_X="$(swift -e 'import AppKit; let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!; print(Int(s.frame.midX))' 2>/dev/null | tail -1)"
capture() { # name, then app flags
  local name="$1"; shift
  scripts/run.sh --fixtures "$@"; wait_for_app
  screencapture -x -R "$((NOTCH_X - 440)),0,880,300" "$OUT/$name.png" && echo "captured $name"
  pkill -x Notcher 2>/dev/null || true; /bin/sleep 0.5
}
echo "==> States"
capture closed --force-state closed
capture activity --force-state activity
capture hover --force-state hover
capture nudge --force-state nudge
capture drop --force-state drop
capture home --force-state expanded
capture shelf --force-state expanded --page shelf
capture clipboard --force-state expanded --page clipboard
capture screenshots --force-state expanded --page screenshots
capture colour --force-state expanded --page colour
capture dev-servers --force-state expanded --page devServers
capture builds --force-state expanded --page builds

echo "==> Log"
/usr/bin/log show --last 3m --style compact \
  --predicate "process == \"Notcher\" AND subsystem == \"$BUNDLE_ID\" AND (messageType == error OR messageType == fault)" 2>/dev/null \
  | grep -vc '^Timestamp' | sed 's/^/error or fault lines from the app: /'
echo "Screenshots in $OUT"
