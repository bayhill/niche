#!/bin/bash
# Notcher bridge: hands one Claude Code hook event (JSON on stdin) to the Notcher app.
#
# Privacy: only a handful of short fields are written to disk (session id, cwd, event name, tool name, notification
# type/title/message, start source, end reason, error, session title), each cut to 200 characters. Prompts, tool
# input and tool output are never written. The JSON is read with /usr/bin/plutil (ships with macOS), held in memory,
# and the reduced event is built as a property list and converted to JSON by plutil, so escaping is always valid.
#
# Prints nothing, always exits 0, never interprets stdin as code. Does nothing unless Notcher's spool folder exists
# (Notcher running with alerts on), and nothing when the folder already holds more than 50 events (not drained).
exec >/dev/null 2>&1
export LC_ALL=en_US.UTF-8
spool="$HOME/Library/Application Support/Notcher/claude-events"
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
for key in session_id hook_event_name cwd tool_name notification_type title message source reason error session_title; do
  value="$(field "$key")"
  [ -n "$value" ] || continue
  value="${value:0:200}"
  "$plutil" -insert "$key" -string "$value" "$tmp" || { rm -f "$tmp"; exit 0; }
done
"$plutil" -convert json "$tmp" || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$spool/$(date +%s)-$$-$RANDOM$RANDOM.json" || rm -f "$tmp"
exit 0
