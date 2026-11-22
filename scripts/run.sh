#!/bin/bash
# Restarts the installed app, passing any arguments through (see DebugOptions for the flags).
#   scripts/run.sh --force-state expanded --fixtures
set -euo pipefail
pkill -x Niche 2>/dev/null || true
open -n "$HOME/Applications/Niche.app" --args "$@"
