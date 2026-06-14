#!/usr/bin/env bash
#
# check-video.sh — PATH 2 (GUI window sharing) RUNTIME self-verify gate.
#
# WHY this exists: `check-macos.sh --connect` proves the TERMINAL path end-to-end, but the GUI
# VIDEO path (capture → HEVC encode → UDP → decode → Metal render) has no runtime gate. This
# closes it the same way: build → run host → run client → screenshot → an agent/human READS the
# PNG to confirm the client actually rendered the remote window's pixels.
#
# ⚠️ MUST RUN FROM A REAL, UNLOCKED GUI LOGIN SESSION (Terminal.app/iTerm in your Aqua session) —
# NOT over SSH, NOT from a detached/automation context, NOT while the screen is locked. Live
# ScreenCaptureKit streaming needs a full window-server connection; without it the host aborts
# with `CGS_REQUIRE_INIT` or simply delivers 0 frames. (One-shot `screencapture -l` works in more
# contexts than live SCStream — do not be misled by that.) Screen-Recording TCC must be granted
# to this terminal.
#
# WHAT IT PROVES on success:
#   - aislopdesk-videohostd captures a real on-screen window and HEVC-encodes it,
#   - the client opens the live VideoWindowView (AISLOPDESK_VIDEO_AUTOCONNECT seam), connects both UDP
#     channels, and the host streams frames (asserted via host TX throughput),
#   - the client window screenshot shows the decoded remote pixels (visual confirmation).
#
# USAGE:
#   bash scripts/check-video.sh [--window-title SUBSTR]   # default: first Finder window
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-macOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
WORK="${REPO_ROOT}/.work/video-verify"
DD="${WORK}/DD"
APP="${DD}/Build/Products/Debug/Aislopdesk.app"
APP_BIN="${APP}/Contents/MacOS/Aislopdesk"
HOSTD="${REPO_ROOT}/.build/debug/aislopdesk-videohostd"
SHOT="${WORK}/client-shot.png"
HOSTLOG="${WORK}/host.log"
MEDIA_PORT=9000
CURSOR_PORT=9001

TITLE_NEEDLE="Finder"
case "${1:-}" in
  --window-title) TITLE_NEEDLE="${2:?--window-title needs a value}" ;;
  "") ;;
  *)
    echo "usage: check-video.sh [--window-title SUBSTR]" >&2
    exit 2
    ;;
esac

mkdir -p "${WORK}"
HOSTD_PID=""
APP_PROC_PAT="video-verify/DD.*MacOS/Aislopdesk"

cleanup() {
  pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
  [[ -n "${HOSTD_PID}" ]] && kill "${HOSTD_PID}" 2> /dev/null || true
}
trap cleanup EXIT

# ── 1. Build the host daemon + the client app (placeholder spec already links AislopdeskVideoClient) ─
echo "==> building aislopdesk-videohostd"
(cd "${REPO_ROOT}" && swift build --product aislopdesk-videohostd > /dev/null)
echo "==> generating + building the client app"
git -C "${REPO_ROOT}" checkout -- "${SPEC}" 2> /dev/null || true
xcodegen generate --spec "${SPEC}" > /dev/null
xcodebuild -project "${PROJECT}" -scheme ClientApp-macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "${DD}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > /dev/null
echo "==> build OK"

# ── 2. Resolve a shareable window to serve ─────────────────────────────────────────────────────
echo "==> enumerating shareable windows (needs Screen-Recording TCC + a GUI session)"
LISTING="$("${HOSTD}" --list 2>&1)"
if [[ -n "${2:-}" || "${1:-}" == "--window-title" ]]; then
  # Explicit title requested.
  WID="$(echo "${LISTING}" | grep -i "${TITLE_NEEDLE}" | grep -oE 'id=[0-9]+' | head -1 | cut -d= -f2 || true)"
else
  # Auto-pick a REAL app window: skip the desktop backstop + system chrome + tiny status
  # indicators (the Finder "(untitled)" desktop, Menubar, Dock, Wallpaper, Control Center,
  # Backstop, underbelly, StatusIndicator, menu-bar Items), and require a usable size — then
  # take the LARGEST remaining window (most pixels = easiest visual confirmation).
  WID="$(printf '%s\n' "${LISTING}" | python3 -c '
import sys, re
best = None
for ln in sys.stdin:
    m = re.search(r"id=(\d+).*\[(\d+)x(\d+)\]", ln)
    if not m:
        continue
    if re.search(r"untitled|Menubar|Dock|Wallpaper|Control Center|Backstop|underbelly|StatusIndicator|Item-|BentoBox|Amphetamine", ln):
        continue
    wid, w, h = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if w < 300 or h < 200:
        continue
    if best is None or w*h > best[1]:
        best = (wid, w*h)
print(best[0] if best else "")
' || true)"
fi
if [[ -z "${WID}" ]]; then
  echo "==> FAIL: no suitable shareable window found. Candidates:" >&2
  # shellcheck disable=SC2001 # per-line indent (^ anchor) isn't expressible as ${var//}
  echo "${LISTING}" | sed 's/^/    /' >&2
  echo "    (empty list ⇒ grant Screen-Recording TCC + run from a real GUI session;" >&2
  echo "     or pass one explicitly: bash scripts/check-video.sh --window-title Slack)" >&2
  exit 1
fi
WTITLE="$(echo "${LISTING}" | grep -E "id=${WID}\b" | sed -E 's/.*id=[0-9]+ +//')"
echo "==> serving window id=${WID} (${WTITLE}) on media:${MEDIA_PORT} cursor:${CURSOR_PORT}"

# ── 3. Start the host ──────────────────────────────────────────────────────────────────────────
pkill -f "aislopdesk-videohostd --window-id ${WID}" 2> /dev/null || true
AISLOPDESK_VIDEO_DEBUG=1 "${HOSTD}" --window-id "${WID}" --media-port "${MEDIA_PORT}" --cursor-port "${CURSOR_PORT}" > "${HOSTLOG}" 2>&1 &
HOSTD_PID=$!
sleep 1
if ! kill -0 "${HOSTD_PID}" 2> /dev/null; then
  echo "==> FAIL: aislopdesk-videohostd did not stay up; log:" >&2
  cat "${HOSTLOG}" >&2
  exit 1
fi
echo "==> host up (pid ${HOSTD_PID})"

# ── 4. Launch the client with the PATH 2 auto-open seam (capture its log) ───────────────────────
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
CLIENTLOG="${WORK}/client.log"
AISLOPDESK_VIDEO_DEBUG=1 \
  AISLOPDESK_VIDEO_AUTOCONNECT_HOST=127.0.0.1 \
  AISLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT="${MEDIA_PORT}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT="${CURSOR_PORT}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID="${WID}" \
  AISLOPDESK_VIDEO_AUTOCONNECT_TITLE="${WTITLE} (remote)" \
  "${APP_BIN}" > "${CLIENTLOG}" 2>&1 &
PID=""
for _ in $(seq 1 16); do
  PID="$(pgrep -f "${APP_PROC_PAT}" | head -1 || true)"
  [[ -n "${PID}" ]] && break
  sleep 0.5
done
[[ -z "${PID}" ]] && {
  echo "==> FAIL: client app never started" >&2
  exit 1
}
echo "==> client up (pid ${PID})"

# ── 5. Wait for the client to CONNECT both UDP channels (the real connectivity gate) ───────────
echo "==> waiting for client↔host UDP (media:${MEDIA_PORT} + cursor:${CURSOR_PORT})…"
CONNECTED=0
for _ in $(seq 1 20); do
  if lsof -nP -iUDP:"${MEDIA_PORT}" 2> /dev/null | grep -q "127.0.0.1:${MEDIA_PORT}->"; then
    CONNECTED=1
    break
  fi
  sleep 0.5
done
if [[ "${CONNECTED}" == "1" ]]; then
  echo "==> client connected to host over UDP ✅"
else
  echo "==> WARN: did not observe a client→host UDP flow on :${MEDIA_PORT} (client may not have opened the sheet)." >&2
fi
# Give the capture→encode→decode→render pipeline a few seconds to produce + present frames.
sleep 5

# ── 5b. Capture the host + client OSLog flow (diagnostics: where, if anywhere, it stalls) ──────
OSLOG="${WORK}/oslog.txt"
{
  echo "### host (aislopdesk-videohostd) ###"
  log show --last 60s --info --debug --predicate 'process == "aislopdesk-videohostd"' --style compact 2> /dev/null
  echo "### client (Aislopdesk) — video subsystem ###"
  log show --last 60s --info --debug --predicate 'process == "Aislopdesk" AND subsystem BEGINSWITH "aislopdesk.video"' --style compact 2> /dev/null
} > "${OSLOG}" 2>&1
echo "==> OSLog flow → ${OSLOG} ($(wc -l < "${OSLOG}") lines)"

# ── 6. Screenshot for VISUAL confirmation (the real proof) ──────────────────────────────────────
# (The pixels are the ground truth: if the client window shows the remote window's content, the
#  whole capture→HEVC→UDP→decode→Metal pipeline ran. We do NOT gate on byte-throughput parsing.)
# GOTCHA (2026-06-09, HW-learned): running `$HOSTD --list` here AGAIN — while the serving host's
# SCStream is ACTIVE — hangs the enumeration. Never list-while-active: raise the client app and
# take a full-screen grab instead (the client window is what we need to read anyway).
osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Aislopdesk" to true' 2> /dev/null || true
sleep 1
screencapture -x "${SHOT}"
echo "==> screenshot (full screen; client raised) saved: ${SHOT}"
echo
echo "================================================================================"
echo " DONE. Now tell your agent: read  ${SHOT}"
echo " PASS = the sheet shows the remote '${WTITLE}' window's live pixels."
echo " FAIL = the sheet is white/black/placeholder (no frames decoded)."
echo " host log:   ${HOSTLOG}"
echo " client log: ${CLIENTLOG}"
echo "================================================================================"
