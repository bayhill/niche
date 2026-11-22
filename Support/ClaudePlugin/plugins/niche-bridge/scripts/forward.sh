#!/bin/bash
# Niche bridge: hands one Claude Code hook event (JSON on stdin) to the Niche app.
#
# Privacy: only the fields Niche reads are written to disk, each cut to 200 characters:
#   every event:                                  session_id, hook_event_name, cwd, session_title
#   PermissionRequest, PostToolUse(Failure):      tool_name
#   Notification:                                 notification_type, message
#   SessionStart: source    SessionEnd: reason    StopFailure: error
# Prompts, tool input and tool output are never written (a failed tool call's `error` can hold its output, so `error`
# is kept for StopFailure alone). The JSON is read with /usr/bin/plutil (ships with macOS), held in memory, and the
# reduced event is built as a property list and converted to JSON by plutil, so escaping is always valid.
#
# Prints nothing, always exits 0, never interprets stdin as code. Does nothing unless Niche's spool folder exists
# (Niche running with alerts on), and nothing when the folder already holds more than 50 events (not drained).
exec >/dev/null 2>&1
export LC_ALL=en_US.UTF-8
spool="$HOME/Library/Application Support/Niche/claude-events"
plutil=/usr/bin/plutil
if [ ! -d "$spool" ] || [ ! -x "$plutil" ]; then
  cat >/dev/null
  exit 0
fi
shopt -s nullglob
pending=("$spool"/*.json)
if [ "${#pending[@]}" -gt 50 ]; then
  cat >/dev/null
  exit 0
fi

input="$(cat)"
field() { printf '%s' "$input" | "$plutil" -extract "$1" raw -o - - 2>/dev/null; }

session="$(field session_id)"
event="$(field hook_event_name)"
[ -n "$session" ] && [ -n "$event" ] || exit 0

umask 077
tmp="$(mktemp "$spool/.event.XXXXXX")" || exit 0
"$plutil" -create xml1 "$tmp" || { rm -f "$tmp"; exit 0; }
keys="session_id hook_event_name cwd session_title"
case "$event" in
  PermissionRequest | PostToolUse | PostToolUseFailure) keys="$keys tool_name" ;;
  Notification) keys="$keys notification_type message" ;;
  SessionStart) keys="$keys source" ;;
  SessionEnd) keys="$keys reason" ;;
  StopFailure) keys="$keys error" ;;
esac
for key in $keys; do
  value="$(field "$key")"
  [ -n "$value" ] || continue
  value="${value:0:200}"
  "$plutil" -insert "$key" -string "$value" "$tmp" || { rm -f "$tmp"; exit 0; }
done
"$plutil" -convert json "$tmp" || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$spool/$(date +%s)-$$-$RANDOM$RANDOM.json" || rm -f "$tmp"
exit 0
