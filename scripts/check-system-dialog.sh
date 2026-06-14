#!/usr/bin/env bash
# check-system-dialog.sh — E2E for the "system popups in their own pane" feature.
# Launches host + client (monitor FORCED on), connects a primary Finder pane, then triggers a REAL
# SecurityAgent admin-password prompt (Cancelled, never submitted) and screenshots the client: a SECOND
# pane should auto-appear streaming the password dialog. Loopback (host+client on this Mac).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${REPO_ROOT}/.work/sysdialog-verify/DD"
APP_BIN="${DD}/Build/Products/Debug/Aislopdesk.app/Contents/MacOS/Aislopdesk"
HOSTD="${REPO_ROOT}/.build/debug/aislopdesk-videohostd"
WORK="${REPO_ROOT}/.work/sysdialog-verify"
mkdir -p "${WORK}"
SHOT="${WORK}/client-shot.png"
HOSTLOG="${WORK}/host.log"
CLIENTLOG="${WORK}/client.log"
MEDIA_PORT=9000
CURSOR_PORT=9001
APP_PROC_PAT="sysdialog-verify/DD.*MacOS/Aislopdesk"
HOSTD_PID=""
cleanup() {
  pkill -f "${APP_PROC_PAT}" 2> /dev/null
  [[ -n "${HOSTD_PID}" ]] && kill "${HOSTD_PID}" 2> /dev/null
  pkill -x osascript 2> /dev/null
}
trap cleanup EXIT

# 1. Pick a primary Finder window (proves the connection is live).
LISTING="$("${HOSTD}" --list 2>&1)"
WID="$(printf '%s\n' "${LISTING}" | python3 -c '
import sys,re
best=None
for ln in sys.stdin:
    m=re.search(r"id=(\d+).*\[(\d+)x(\d+)\]",ln)
    if not m: continue
    if re.search(r"untitled|Menubar|Dock|Wallpaper|Control Center|Backstop|underbelly|StatusIndicator|Item-",ln): continue
    wid,w,h=int(m.group(1)),int(m.group(2)),int(m.group(3))
    if w<300 or h<200: continue
    if best is None or w*h>best[1]: best=(wid,w*h)
print(best[0] if best else "")')"
[[ -z "${WID}" ]] && {
  echo "FAIL: no primary window"
  echo "${LISTING}"
  exit 1
}
WTITLE="$(echo "${LISTING}" | grep -E "id=${WID}\b" | sed -E 's/.*id=[0-9]+ +//')"
echo "==> primary pane window id=${WID} (${WTITLE})"

# 2. Host: serve the mux (per-hello windows + session-less listSystemDialogs).
AISLOPDESK_VIDEO_DEBUG=1 "${HOSTD}" --media-port "${MEDIA_PORT}" --cursor-port "${CURSOR_PORT}" > "${HOSTLOG}" 2>&1 &
HOSTD_PID=$!
sleep 1
kill -0 "${HOSTD_PID}" 2> /dev/null || {
  echo "FAIL: host died"
  cat "${HOSTLOG}"
  exit 1
}
echo "==> host up (pid ${HOSTD_PID})"

# 3. Client: video-autoconnect (primary pane) + FORCE the system-dialog monitor on.
pkill -f "${APP_PROC_PAT}" 2> /dev/null
sleep 0.5
AISLOPDESK_VIDEO_DEBUG=1 \
  AISLOPDESK_SYSTEM_DIALOG_PANES=force \
  AISLOPDESK_VIDEO_AUTOCONNECT_HOST=127.0.0.1 \
  AISLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT="${MEDIA_PORT}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT="${CURSOR_PORT}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID="${WID}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_TITLE="${WTITLE} (remote)" \
  "${APP_BIN}" > "${CLIENTLOG}" 2>&1 &
for _ in $(seq 1 16); do
  pgrep -f "${APP_PROC_PAT}" > /dev/null && break
  sleep 0.5
done
pgrep -f "${APP_PROC_PAT}" > /dev/null || {
  echo "FAIL: client never started"
  cat "${CLIENTLOG}"
  exit 1
}
echo "==> client up; waiting for UDP connect…"
for _ in $(seq 1 20); do
  lsof -nP -iUDP:"${MEDIA_PORT}" 2> /dev/null | grep -q "127.0.0.1:${MEDIA_PORT}->" && {
    echo "==> connected ✅"
    break
  }
  sleep 0.5
done
sleep 3 # let the primary pane stream

# 4. Trigger a REAL SecurityAgent prompt (Cancelled later — never submitted).
echo "==> triggering admin-password prompt"
osascript -e 'do shell script "true" with administrator privileges' > /dev/null 2>&1 &
# 5. Give the monitor (2s poll) time to detect + spawn + stream the dialog pane.
sleep 6

# 6. Raise client + screenshot.
osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Aislopdesk" to true' 2> /dev/null
sleep 1
screencapture -x "${SHOT}"
echo "==> screenshot saved: ${SHOT}"
echo "==> host TX / dialog evidence:"
grep -iE 'dialog|listSystemDialogs|securityagent' "${HOSTLOG}" | tail -8
echo "DONE — read ${SHOT}"
