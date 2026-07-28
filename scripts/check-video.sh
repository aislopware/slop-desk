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
#   - slopdesk-videohostd captures a real on-screen window and HEVC-encodes it,
#   - the client boots the DETACHED remote-desktop window (SLOPDESK_VIDEO_AUTOCONNECT seam mints a
#     window-targeted detached .desktop pane), connects both UDP channels, and the host streams frames,
#   - the client DECODED at least one frame and PRESENTED at least one frame into a Metal drawable —
#     the two legs a live dial cannot vouch for (step 5c),
#   - the desktop-window screenshot shows the decoded remote pixels (visual confirmation).
#
# It runs TWO daemons: slopdesk-videohostd for the pixels, and slopdesk-hostd because the detached
# .desktop pane is an object in the HOST's workspace document (docs/45) — the client asks for it with
# an intent and has nowhere to send one without a terminal daemon. Both get a throwaway HOME and the
# hostd a throwaway SLOPDESK_WORKSPACE_STATE_DIR, so an automation run can never reshape the
# developer's real layout.
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
APP="${DD}/Build/Products/Debug/SlopDesk.app"
APP_BIN="${APP}/Contents/MacOS/SlopDesk"
HOSTD="${REPO_ROOT}/.build/debug/slopdesk-videohostd"
SHOT="${WORK}/client-shot.png"
HOSTLOG="${WORK}/host.log"
TERMLOG="${WORK}/hostd.log"
MEDIA_PORT=9000
CURSOR_PORT=9001
CONNECT_PORT=47421 # the TERMINAL daemon that owns the workspace document (47420 is check-macos.sh)

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
TERMD_PID=""
APP_PROC_PAT="video-verify/DD.*MacOS/SlopDesk"

# How long a daemon may take to honour its SIGTERM before this script stops asking (×0.5s).
# slopdesk-videohostd's own wedge watchdog force-exits at 5s, so the window has to be longer than
# that or the escalation below would fire on a daemon that was about to stop by itself.
REAP_PATIENCE=16

# SIGTERM, then VERIFY, then SIGKILL.
#
# `kill` only ASKS. slopdesk-videohostd answers a termination signal with an orderly drain — bye to
# every client, stop the SCStream, restore parked windows — and that drain can WEDGE on a leaked
# SCStream continuation (its own source says so, and this gate has been seen exiting straight past
# one). The daemon's watchdog force-exits five seconds later, which is long after this script has
# returned to the shell: the run LOOKS finished while :9000 is still bound, and the next run's host
# fails to bind against a phantom. So wait for the process to actually be gone, and escalate if it is
# not — a gate that leaves daemons behind costs more than the one it just failed.
reap() {
  local pid="$1" name="$2"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2> /dev/null || return 0 # already gone
  for _ in $(seq 1 "${REAP_PATIENCE}"); do
    kill -0 "${pid}" 2> /dev/null || return 0
    sleep 0.5
  done
  echo "==> ${name} (pid ${pid}) did not stop on SIGTERM — SIGKILL" >&2
  kill -9 "${pid}" 2> /dev/null || true
}

cleanup() {
  pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
  reap "${HOSTD_PID}" slopdesk-videohostd
  reap "${TERMD_PID}" slopdesk-hostd
}
# INT/TERM as well as EXIT: a bash EXIT trap does NOT run when the shell is killed by an untrapped
# signal, so a Ctrl-C or a harness timeout would otherwise strand both daemons — the very state the
# reap above exists to prevent. Each handler re-raises nothing; the explicit `exit` runs `cleanup`
# once through the EXIT trap.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── 1. Build both host daemons + the client app (placeholder spec already links SlopDeskVideoClient) ─
echo "==> building slopdesk-videohostd + slopdesk-hostd"
(cd "${REPO_ROOT}" && swift build --product slopdesk-videohostd > /dev/null)
(cd "${REPO_ROOT}" && swift build --product slopdesk-hostd > /dev/null)
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
# The listing line ends with the pixel size; the remote window's NAME is the app + title alone.
# It becomes the detached pane's window title, so it is read off the screenshot — keep it clean.
WTITLE="$(echo "${LISTING}" | grep -E "id=${WID}\b" | sed -E 's/.*id=[0-9]+ +//; s/ *\[[0-9]+x[0-9]+\] *$//')"
echo "==> serving window id=${WID} (${WTITLE}) on media:${MEDIA_PORT} cursor:${CURSOR_PORT}"

# ── 3. Start the host ──────────────────────────────────────────────────────────────────────────
pkill -f "slopdesk-videohostd --window-id ${WID}" 2> /dev/null || true
SLOPDESK_VIDEO_DEBUG=1 "${HOSTD}" --window-id "${WID}" --media-port "${MEDIA_PORT}" --cursor-port "${CURSOR_PORT}" > "${HOSTLOG}" 2>&1 &
HOSTD_PID=$!
sleep 1
if ! kill -0 "${HOSTD_PID}" 2> /dev/null; then
  echo "==> FAIL: slopdesk-videohostd did not stay up; log:" >&2
  cat "${HOSTLOG}" >&2
  exit 1
fi
echo "==> host up (pid ${HOSTD_PID})"

# ── 3b. Start the TERMINAL daemon too — it owns the workspace document ─────────────────────────
# The video pane is a DETACHED `.desktop` pane in the workspace tree, and the tree is the host's
# (docs/45). `bootstrapFromEnvironment` mints it with an intent over `channelClass 1`, so with no
# `slopdesk-hostd` there is no document to send it to and the client renders an empty window —
# this gate would pass on a blank screenshot. `WorkspaceStore.videoTarget(from:)` reads
# SLOPDESK_AUTOCONNECT_PORT for the TCP leg of the very same `ConnectionTarget`, so pointing that
# at this daemon is the whole wiring.
echo "==> starting slopdesk-hostd on 127.0.0.1:${CONNECT_PORT}"
pkill -f "slopdesk-hostd --port ${CONNECT_PORT}" 2> /dev/null || true
sleep 0.5
# Both dirs FRESH per run, under ${WORK}. The state dir is correctness, not hygiene: the client's
# `adoptWorkspace` is `rejectedStale` against a host that already has a workspace, so a reused dir
# would silently keep a stale layout and the proof would render the wrong thing. It is also the
# automation-safety gate — a client that mutates the HOST can reshape the developer's real layout,
# and `persistence: nil` on the client protects nothing from that.
if [[ -z "${WORK}" ]]; then
  echo "==> FAIL: WORK is empty — refusing to run a daemon against an unpinned state dir" >&2
  exit 1
fi
HOSTD_HOME="${WORK}/hostd-home"
HOSTD_WORKSPACE="${WORK}/hostd-workspace"
rm -rf "${HOSTD_WORKSPACE}"
mkdir -p "${HOSTD_HOME}" "${HOSTD_WORKSPACE}"
if [[ -z "${HOSTD_WORKSPACE}" ]]; then
  echo "==> FAIL: SLOPDESK_WORKSPACE_STATE_DIR would be empty — refusing to launch hostd" >&2
  exit 1
fi
HOME="${HOSTD_HOME}" SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
  "${REPO_ROOT}/.build/debug/slopdesk-hostd" \
  --port "${CONNECT_PORT}" --shell /bin/sh > "${TERMLOG}" 2>&1 &
TERMD_PID=$!
sleep 1
if ! kill -0 "${TERMD_PID}" 2> /dev/null; then
  echo "==> FAIL: slopdesk-hostd (the workspace document) did not stay up; log:" >&2
  cat "${TERMLOG}" >&2
  exit 1
fi
echo "==> hostd up (pid ${TERMD_PID})"

# ── 4. Launch the client with the PATH 2 auto-open seam (capture its log) ───────────────────────
# -ApplePersistenceIgnoreState YES is LOAD-BEARING, exactly as in check-macos.sh: launching the
# bundle binary directly on AppKit's persistence path brings the app up with ZERO windows. No
# window ⇒ no scene, and every automation seam this gate depends on is a scene `.task` — the
# auto-connect, the workspace-document channel, the video pane. The app then sits in its run loop
# with no UI, no TCP, no UDP, and the screenshot shows the desktop. Ignoring persisted state makes
# every automation launch a clean first launch. (HW-confirmed 2026-07-28: `YES` ⇒ window + session
# + frames; omitted or `NO` ⇒ 0 windows, 0 sockets, every time.)
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
CLIENTLOG="${WORK}/client.log"
SLOPDESK_VIDEO_DEBUG=1 \
  SLOPDESK_VIDEO_AUTOCONNECT_HOST=127.0.0.1 \
  SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT="${MEDIA_PORT}" \
  SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT="${CURSOR_PORT}" \
  SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID="${WID}" \
  SLOPDESK_VIDEO_AUTOCONNECT_TITLE="${WTITLE} (remote)" \
  SLOPDESK_AUTOCONNECT_PORT="${CONNECT_PORT}" \
  "${APP_BIN}" -ApplePersistenceIgnoreState YES > "${CLIENTLOG}" 2>&1 &
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

# ── 5. The connectivity gates — machine-checked, and FATAL ─────────────────────────────────────
# A client that never dialled cannot have rendered anything, so a screenshot taken past this point
# would prove nothing. These are assertions, not observations: the gate exits non-zero and dumps
# the logs rather than printing a warning and carrying on to a picture of the desktop.

# 5a. The workspace DOCUMENT leg first. The detached `.desktop` pane is an object in the HOST's
# document (docs/45): the client asks for it with an intent over `channelClass 1`, so the terminal
# daemon accepting that channel is what everything below hangs off. Failing here says the document
# never opened; failing at 5b says it opened and the video leg still did not dial.
#
# Matched on the ACCEPT line specifically. `workspace channel …` is also the prefix hostd uses for
# every refusal and error on that channel — `refused — already open`, `receive ended`, `malformed
# subscribe dropped`, `unknown verb dropped` — and the first of those is logged with no accept at
# all, so a substring match would print "accepted ✅" for a channel the host turned away.
echo "==> waiting for the workspace document channel on :${CONNECT_PORT}…"
DOC_OK=0
for _ in $(seq 1 20); do
  if grep -qE "workspace channel .* accepted" "${TERMLOG}" 2> /dev/null; then
    DOC_OK=1
    break
  fi
  sleep 0.5
done
if [[ "${DOC_OK}" != "1" ]]; then
  echo "==> FAIL: slopdesk-hostd never accepted a workspace channel — the client has no document to" >&2
  echo "    send its pane-spawn intent to, so no remote-desktop pane can exist." >&2
  echo "--- hostd log ---" >&2
  cat "${TERMLOG}" >&2
  echo "--- client log ---" >&2
  cat "${CLIENTLOG}" >&2
  exit 1
fi
echo "==> workspace document channel accepted ✅"

# 5b. Both UDP channels.
echo "==> waiting for client↔host UDP (media:${MEDIA_PORT} + cursor:${CURSOR_PORT})…"
CONNECTED=0
for _ in $(seq 1 20); do
  if lsof -nP -iUDP:"${MEDIA_PORT}" 2> /dev/null | grep -q "127.0.0.1:${MEDIA_PORT}->"; then
    CONNECTED=1
    break
  fi
  sleep 0.5
done
if [[ "${CONNECTED}" != "1" ]]; then
  echo "==> FAIL: no client→host UDP flow on :${MEDIA_PORT} — the remote-desktop pane never dialled." >&2
  echo "--- video host log ---" >&2
  cat "${HOSTLOG}" >&2
  echo "--- client log ---" >&2
  cat "${CLIENTLOG}" >&2
  exit 1
fi
echo "==> client connected to host over UDP ✅"
# Give the capture→encode→decode→render pipeline a few seconds to produce + present frames.
sleep 5

# 5c. A frame was DECODED, and a frame was PRESENTED.
#
# Everything above proves the client DIALLED. A client that dialled can still show a blank pane for
# ever — a VT decompression session that errors out on the first IDR, a `CAMetalLayer` that never
# hands out a drawable, a decode gate that never re-opens — and in every one of those capture, encode
# and both sockets stay perfectly healthy, so not one check above moves. Without this the gate printed
# ✅ four times and exited 0 on a white window, and the pixels were left entirely to a human reading
# a PNG that nothing forced anyone to open.
#
# Read off the client's own `SLOPDESK_VIDEO_DEBUG` stream, which this gate already turns on:
#   `DECODED frame #N` — `SlopDeskVideoClientSession.finishDecode`, decode-SUCCESS path only
#                        (frame 1, then every 15th),
#   `RENDER#N`         — `MetalVideoRenderer.render`, AFTER `metalLayer.nextDrawable()` returned a
#                        drawable (frame 0, then every 120th).
# Both land within a frame of each other on a healthy session. The OSLog flow captured below carries
# the session SETUP only ("client decode pipeline up at capture WxH") — there is no per-frame counter
# in it, and "the pipeline was built" is the premise, not the claim.
#
# The two halves fail differently and that is the point: decoded-but-never-presented is a present-path
# regression (the pixels exist and never reach a drawable); neither is a decode regression.
echo "==> waiting for a DECODED frame and a PRESENTED frame…"
DECODED=0
PRESENTED=0
for _ in $(seq 1 40); do
  DECODED="$(grep -c 'DECODED frame #' "${CLIENTLOG}" 2> /dev/null || true)"
  PRESENTED="$(grep -c 'RENDER#' "${CLIENTLOG}" 2> /dev/null || true)"
  [[ "${DECODED}" -gt 0 && "${PRESENTED}" -gt 0 ]] && break
  sleep 0.5
done
if [[ "${DECODED}" -lt 1 ]]; then
  echo "==> FAIL: the client decoded NOT ONE frame. Both sockets are up and the host is streaming," >&2
  echo "    so this is the decode leg: VideoToolbox rejected the stream, or the decode gate never" >&2
  echo "    re-opened. The remote-desktop pane is blank." >&2
  echo "--- video host log ---" >&2
  tail -60 "${HOSTLOG}" >&2
  echo "--- client log ---" >&2
  tail -60 "${CLIENTLOG}" >&2
  exit 1
fi
if [[ "${PRESENTED}" -lt 1 ]]; then
  echo "==> FAIL: the client is decoding (${DECODED} decode marker(s)) and PRESENTED none. The pixels exist" >&2
  echo "    and never reached a drawable — the Metal present path (no CAMetalLayer drawable, no" >&2
  echo "    renderer, a pacer that never fires). The remote-desktop pane is blank." >&2
  echo "--- client log ---" >&2
  tail -60 "${CLIENTLOG}" >&2
  exit 1
fi
echo "==> frames DECODED and PRESENTED (${DECODED} decode / ${PRESENTED} render markers) ✅"

# 5d. ONE auto-connect spawns ONE shell. The video shape is a lone terminal plus a DETACHED
# desktop pane, and a `.desktop` pane runs no PTY — so exactly one shell may ever attach. A second
# means the bootstrap adopted a tree the window was not already showing and abandoned the first
# pane's shell. Read AFTER the render settle, so a late second attach still counts.
SHELLS="$(grep -c 'shell .* attached' "${TERMLOG}" || true)"
if [[ "${SHELLS}" != "1" ]]; then
  echo "==> FAIL: one auto-connect must attach exactly 1 shell; saw ${SHELLS}" >&2
  echo "--- hostd log ---" >&2
  cat "${TERMLOG}" >&2
  exit 1
fi
echo "==> exactly one shell attached for one auto-connect ✅"

# ── 5e. Capture the host + client OSLog flow (diagnostics: where, if anywhere, it stalls) ──────
OSLOG="${WORK}/oslog.txt"
{
  echo "### host (slopdesk-videohostd) ###"
  log show --last 60s --info --debug --predicate 'process == "slopdesk-videohostd"' --style compact 2> /dev/null
  echo "### client (SlopDesk) — video subsystem ###"
  log show --last 60s --info --debug --predicate 'process == "SlopDesk" AND subsystem BEGINSWITH "slopdesk.video"' --style compact 2> /dev/null
} > "${OSLOG}" 2>&1
echo "==> OSLog flow → ${OSLOG} ($(wc -l < "${OSLOG}") lines)"

# ── 6. Screenshot for VISUAL confirmation (the real proof) ──────────────────────────────────────
# (The pixels are the ground truth: if the client window shows the remote window's content, the
#  whole capture→HEVC→UDP→decode→Metal pipeline ran. We do NOT gate on byte-throughput parsing.)
# GOTCHA (2026-06-09, HW-learned): running `$HOSTD --list` here AGAIN — while the serving host's
# SCStream is ACTIVE — hangs the enumeration. Never list-while-active: raise the client app and
# take a full-screen grab instead (the client window is what we need to read anyway).
osascript -e 'tell application "System Events" to set frontmost of first process whose name is "SlopDesk" to true' 2> /dev/null || true
sleep 1
screencapture -x "${SHOT}"
echo "==> screenshot (full screen; client raised) saved: ${SHOT}"
echo
echo "================================================================================"
echo " DONE. Document channel, UDP flow, a decoded + presented frame and the one-shell rule are all"
echo " ASSERTED above; what is left is whether the pixels are the RIGHT ones. Tell your agent:"
echo " read  ${SHOT}"
echo " PASS = the remote-desktop window shows the remote '${WTITLE}' window's live pixels."
echo " FAIL = it shows some OTHER window, or a stale/garbled frame. A blank pane cannot reach here."
echo " host log:   ${HOSTLOG}"
echo " client log: ${CLIENTLOG}"
echo "================================================================================"
