#!/usr/bin/env bash
# PATH-2 INPUT verify harness: fresh host (clean UDP pin) + one synclient gesture, then dump
# the injection trace. Proves the host-side input-ordering / button-balance fix deterministically
# over real UDP loopback (no GUI client / no computer-use cursor war).
#   video-input-test.sh <synclient args...>
# ⚠️ Set WID to a real on-screen window id from `slopdesk-videohostd --list` (TextEdit is ideal).
#    Must run from a REAL GUI login session (Screen-Recording + Accessibility/Post-Event TCC).
# NOTE: the legacy SLOPDESK_INPUT_UNORDERED A/B mode was removed (greenfield: the ordered
#       single-consumer pump is the only path), so this harness now verifies that one path.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit
WID="${WID:-267}"
HLOG=/tmp/slopdesk-host.log
# A throwaway `<Application Support>/SlopDesk` for the daemon this harness starts, fresh per run.
#
# `parked-windows.json` is the reason it is not optional. `slopdesk-videohostd` READS that file on
# its way up — AX-moving whatever windows it names back off a dead virtual display — and UNLINKS it
# unconditionally, before it even tries to decode it. Pointed at the real container, this harness
# restores and then destroys the crash journal belonging to the developer's own videohostd, and
# moves their windows while doing it. `video-prefs.json` folds into `EnvConfig.overlay` at the same
# moment, so an un-isolated run also measures a configuration nobody wrote down.
#
# `GuiGateLaunchContractTests` walks `scripts/` and requires this of every daemon launch it finds,
# which is how this file — a manual harness rather than a gate — came to be counted at all.
STATE="$(mktemp -d "${TMPDIR:-/tmp}/slopdesk-input-test.XXXXXX")"
mkdir -p "${STATE}/scrollback" "${STATE}/drop"
pkill -f "slopdesk-videohostd --window-id" 2> /dev/null
sleep 1.2
env SLOPDESK_INPUT_TRACE=1 SLOPDESK_APP_SUPPORT_DIR="${STATE}" \
  SLOPDESK_SCROLLBACK_DIR="${STATE}/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${STATE}/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${STATE}" \
  .build/release/slopdesk-videohostd --window-id "${WID}" --media-port 9000 --cursor-port 9001 --scale 2 > "${HLOG}" 2>&1 &
echo "host pid $! (wid=${WID})"
sleep 2.5
python3 "$(dirname "${BASH_SOURCE[0]}")/video-input-synclient.py" "$@"
sleep 1.5
echo "=== INJECTED ORDER ==="
grep "inject #" "${HLOG}" | sed -E 's/.*\[inject #([0-9]+)\]: /#\1 /' | tr '\n' ' '
echo
echo "down=$(grep -c 'mouseDown' "${HLOG}")  up=$(grep -c 'mouseUp' "${HLOG}")  drag=$(grep -c 'mouseDrag' "${HLOG}")"
