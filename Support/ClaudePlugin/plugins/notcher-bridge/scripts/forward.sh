#!/bin/bash
# Notcher bridge: hands one Claude Code hook event (JSON on stdin) to the Notcher app.
# Prints nothing, always exits 0, and does nothing unless Notcher's spool folder exists (alerts enabled).
exec >/dev/null 2>&1
spool="$HOME/Library/Application Support/Notcher/claude-events"
if [ ! -d "$spool" ]; then
  cat >/dev/null
  exit 0
fi
umask 077
tmp="$(mktemp "$spool/.event.XXXXXX")" || { cat >/dev/null; exit 0; }
# Keep the first 64 KiB (the fields Notcher reads come first); drain the rest so the writer never blocks.
{ head -c 65536 >"$tmp"; cat >/dev/null; }
if [ -s "$tmp" ]; then
  mv -f "$tmp" "$spool/$(date +%s)-$$-$RANDOM$RANDOM.json" || rm -f "$tmp"
else
  rm -f "$tmp"
fi
exit 0
