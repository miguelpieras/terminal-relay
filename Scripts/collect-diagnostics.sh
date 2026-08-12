#!/bin/bash
set -euo pipefail

# Collects recent Terminal Relay macOS app logs into one file for diagnosing
# a problem right after it happened. All app logging lives in the macOS
# unified log (system-managed and size-bounded); this just extracts the
# app's subsystem so nothing has to be reproduced under `log stream`.
#
# Usage: Scripts/collect-diagnostics.sh [window] [output-file]
#   window       `log show --last` window, default 1h (e.g. 30m, 2h, 1d)
#   output-file  default ~/Desktop/terminal-relay-diagnostics-<timestamp>.log

window="${1:-1h}"
output="${2:-$HOME/Desktop/terminal-relay-diagnostics-$(/bin/date +%Y%m%d-%H%M%S).log}"

/usr/bin/log show \
    --last "$window" \
    --style compact \
    --info \
    --predicate 'subsystem == "com.mpieras.TerminalRelay"' \
    > "$output"

echo "Wrote $(wc -l < "$output" | tr -d ' ') log lines to $output"
