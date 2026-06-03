#!/usr/bin/env bash
# PATH-2 INPUT verify harness: fresh host (clean UDP pin) + one synclient gesture, then dump
# the injection trace. Proves the host-side input-ordering / button-balance fix deterministically
# over real UDP loopback (no GUI client / no computer-use cursor war).
#   video-input-test.sh <fixed|legacy> <synclient args...>
# ⚠️ Set WID to a real on-screen window id from `rwork-videohostd --list` (TextEdit is ideal).
#    Must run from a REAL GUI login session (Screen-Recording + Accessibility/Post-Event TCC).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MODE="$1"; shift
WID="${WID:-267}"
HLOG=/tmp/rwork-host-$MODE.log
UNORD=""; [ "$MODE" = "legacy" ] && UNORD="RWORK_INPUT_UNORDERED=1"
pkill -f "rwork-videohostd --window-id" 2>/dev/null; sleep 1.2
env RWORK_INPUT_TRACE=1 $UNORD \
  .build/release/rwork-videohostd --window-id "$WID" --media-port 9000 --cursor-port 9001 --scale 2 >"$HLOG" 2>&1 &
echo "host pid $! (mode=$MODE wid=$WID)"; sleep 2.5
python3 "$(dirname "${BASH_SOURCE[0]}")/video-input-synclient.py" "$@"
sleep 1.5
echo "=== INJECTED ORDER ($MODE) ==="
grep "inject #" "$HLOG" | sed -E 's/.*\[inject #([0-9]+)\]: /#\1 /' | tr '\n' ' '; echo
echo "down=$(grep -c 'mouseDown' "$HLOG")  up=$(grep -c 'mouseUp' "$HLOG")  drag=$(grep -c 'mouseDrag' "$HLOG")"
