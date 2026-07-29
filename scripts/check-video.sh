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
# WITH `--second-client` it also proves the multi-client half (docs/45 §10): a SECOND client
# instance, given only the TERMINAL autoconnect, learns the detached `.desktop` pane from the HOST's
# workspace document, dials its own UDP lane, and decodes + presents the SAME window — while the
# first client keeps streaming. That is the one claim a unit test cannot make: two concurrent
# `SCStream`s and two `VTCompressionSession`s on ONE capture target, which the hang-safety rule
# forbids constructing in XCTest. Its assertions are the pair, never one: client B rendering while A
# went dark is a takeover, not a fan-out, so A's marker counts are re-read AFTER B is up and must
# have GROWN.
#
# It runs TWO daemons: slopdesk-videohostd for the pixels, and slopdesk-hostd because the detached
# .desktop pane is an object in the HOST's workspace document (docs/45) — the client asks for it with
# an intent and has nowhere to send one without a terminal daemon. Both get a throwaway
# `SLOPDESK_APP_SUPPORT_DIR` container and the hostd a throwaway SLOPDESK_WORKSPACE_STATE_DIR, so an
# automation run can never reshape the developer's real layout — nor sweep their scrollback journals,
# nor read and then UNLINK the `parked-windows.json` crash journal their own videohostd owns. HOME
# alone did none of that: it does not move Application Support and does not move `NSHomeDirectory()`.
#
# USAGE:
#   bash scripts/check-video.sh [--window-title SUBSTR] [--second-client]
#     default target: the largest real app window; --second-client adds the fan-out half above.
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

# The throwaway `<Application Support>/SlopDesk` both daemons resolve, and the throwaway
# `UserDefaults` suite the client app writes. Fresh per run; the suite is removed by the cleanup trap.
# See check-macos.sh for the full argument — the short version is that neither HOME nor
# `CFFIXED_USER_HOME` covers what these two need covered.
DAEMON_STATE="${WORK}/daemon-state"
DEFAULTS_SUITE="slopdesk.gate.video.$$"

# Takes the run's suite away COMPLETELY — the domain AND the file it lives in. `defaults delete`
# empties the domain and leaves a 42-byte plist behind, so a gate that stops there costs the
# developer one file per run. That is not a hypothetical shape: the XCTest side of the same mistake
# put 55,003 `slopdesk.tests.pid*.plist` files in this machine's ~/Library/Preferences.
#
# `${HOME}` here is the DEVELOPER's, deliberately. cfprefsd resolves the real home whatever
# `CFFIXED_USER_HOME` says — which is the entire reason a suite is needed — so the run's plist is in
# their Preferences directory and nowhere else, and this shell is the one that still knows the path.
remove_defaults_suite() {
  defaults delete "${DEFAULTS_SUITE}" 2> /dev/null || true
  rm -f "${HOME}/Library/Preferences/${DEFAULTS_SUITE}.plist"
}

TITLE_NEEDLE="Finder"
TITLE_EXPLICIT=0
SECOND_CLIENT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-title)
      TITLE_NEEDLE="${2:?--window-title needs a value}"
      TITLE_EXPLICIT=1
      shift 2
      ;;
    --second-client)
      SECOND_CLIENT=1
      shift
      ;;
    *)
      echo "usage: check-video.sh [--window-title SUBSTR] [--second-client]" >&2
      exit 2
      ;;
  esac
done

mkdir -p "${WORK}"
# Before ANY daemon runs, including the `--list` enumeration below: `slopdesk-videohostd` folds
# `video-prefs.json` into `EnvConfig.overlay` on its very first line of `main`, so even the listing
# pass would otherwise read the developer's tuning and measure a configuration nobody wrote down.
rm -rf "${DAEMON_STATE}"
mkdir -p "${DAEMON_STATE}/scrollback" "${DAEMON_STATE}/drop"
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
  # The app is killed, so its own `atexit` suite cleanup never runs — this is the one that does.
  remove_defaults_suite
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
LISTING="$(SLOPDESK_APP_SUPPORT_DIR="${DAEMON_STATE}" \
  SLOPDESK_SCROLLBACK_DIR="${DAEMON_STATE}/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${DAEMON_STATE}/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${DAEMON_STATE}" \
  "${HOSTD}" --list 2>&1)"
if [[ "${TITLE_EXPLICIT}" == "1" ]]; then
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
# The container is not hygiene for THIS daemon, it is damage control: `parked-windows.json` is a
# crash journal it READS at launch (AX-moving the windows it names back off a dead virtual display)
# and UNLINKS the moment its own parked set goes empty. Pointed at the real one, an automation run
# would restore — then destroy — the record belonging to the developer's own videohostd.
SLOPDESK_VIDEO_DEBUG=1 SLOPDESK_APP_SUPPORT_DIR="${DAEMON_STATE}" \
  SLOPDESK_SCROLLBACK_DIR="${DAEMON_STATE}/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${DAEMON_STATE}/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${DAEMON_STATE}" \
  "${HOSTD}" --window-id "${WID}" --media-port "${MEDIA_PORT}" --cursor-port "${CURSOR_PORT}" > "${HOSTLOG}" 2>&1 &
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
HOME="${HOSTD_HOME}" SLOPDESK_APP_SUPPORT_DIR="${DAEMON_STATE}" \
  SLOPDESK_SCROLLBACK_DIR="${DAEMON_STATE}/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${DAEMON_STATE}/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
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
#
# `CFFIXED_USER_HOME` is the client's half of the isolation the two daemons already have. The video
# autoconnect env makes `hasAutomationEnvironment()` true, so `WorkspacePersistence` /
# `DevicePreferencesStore` / the document cache are all nil here — but `PreferencesStore` is built
# UNCONDITIONALLY in the App's `init()`, and it writes the `video-prefs.json` sidecar that
# `slopdesk-hostd` folds into `EnvConfig.overlay` at ITS launch. Without the redirect this gate
# rewrites a file that changes how the developer's own daemon comes up next time.
# `SLOPDESK_DEFAULTS_SUITE` is the half `CFFIXED_USER_HOME` cannot reach: cfprefsd resolves the real
# home whatever the environment says, so the app's `UserDefaults` needs its own throwaway suite or
# this run's connect lands in the developer's recent-hosts MRU.
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
CLIENT_HOME="${WORK}/client-home"
rm -rf "${CLIENT_HOME}"
mkdir -p "${CLIENT_HOME}"
# An empty defaults domain is a FRESH INSTALL. The video autoconnect env makes
# `hasAutomationEnvironment()` true, so `FirstLaunchModel.shouldPresent` is false here whatever the
# flag says — seeded anyway, so no gate's screenshot depends on which env var happens to suppress the
# welcome sheet today. The delete first, in case a killed run left the suite behind.
remove_defaults_suite
defaults write "${DEFAULTS_SUITE}" firstLaunch.completed -bool YES
CLIENTLOG="${WORK}/client.log"
CFFIXED_USER_HOME="${CLIENT_HOME}" HOME="${CLIENT_HOME}" \
  SLOPDESK_DEFAULTS_SUITE="${DEFAULTS_SUITE}" \
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
#   `PRESENTED#N`      — `MetalVideoRenderer.render`, immediately AFTER
#                        `commandBuffer.present(drawable)` (frame 0, then every 120th).
# Both land within a frame of each other on a healthy session. The OSLog flow captured below carries
# the session SETUP only ("client decode pipeline up at capture WxH") — there is no per-frame counter
# in it, and "the pipeline was built" is the premise, not the claim.
#
# NOT `RENDER#`, and that distinction is the whole assertion. `RENDER#` prints the instant
# `metalLayer.nextDrawable()` returns, which is BEFORE every guard that follows it: `makeTexture` for
# either plane, `CVMetalTextureGetTexture`, `makeCommandBuffer` / `makeRenderCommandEncoder`. Each of
# those `return`s having encoded no pass and presented nothing. So a decoder that starts vending a
# non-NV12 or 10-bit `CVPixelBuffer` accumulates decode markers, prints `RENDER#0` once, draws NOTHING
# ever — and a gate that counted `RENDER#` passed on it.
#
# The two halves fail differently and that is the point: decoded-but-never-presented is a present-path
# regression (the pixels exist and never reach a drawable); neither is a decode regression.
echo "==> waiting for a DECODED frame and a PRESENTED frame…"
DECODED=0
PRESENTED=0
for _ in $(seq 1 40); do
  DECODED="$(grep -c 'DECODED frame #' "${CLIENTLOG}" 2> /dev/null || true)"
  PRESENTED="$(grep -c 'PRESENTED#' "${CLIENTLOG}" 2> /dev/null || true)"
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
  echo "    and never reached a drawable — the Metal present path (no CAMetalLayer drawable, a plane" >&2
  echo "    that will not make an MTLTexture, a command encoder the device refused, a pacer that never" >&2
  echo "    fires). The remote-desktop pane is blank." >&2
  echo "    (RENDER# markers seen: $(grep -c 'RENDER#' "${CLIENTLOG}" 2> /dev/null || true) — those print BEFORE" >&2
  echo "     the texture/encoder guards, so a positive count here is the signature of exactly this bug.)" >&2
  echo "--- client log ---" >&2
  tail -60 "${CLIENTLOG}" >&2
  exit 1
fi
echo "==> frames DECODED and PRESENTED (${DECODED} decode / ${PRESENTED} present markers) ✅"

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

# ── 5f. The SECOND client (opt-in): the fan-out half of docs/45 ────────────────────────────────
# The question this answers is the one left HW-PENDING: the workspace document advertises
# `pane/videoTarget` to every attached client, but nothing established that two clients can watch one
# window — two `SCStream`s and two `VTCompressionSession`s on a single capture target — and the
# hang-safety rule forbids constructing any of those four objects in XCTest.
#
# B gets the TERMINAL autoconnect and NOTHING else. No `SLOPDESK_VIDEO_AUTOCONNECT_*`: giving it those
# would have B mint its own detached pane from its own environment, which proves only that two
# independently-configured clients can both dial — the trivial case. Withholding them makes B learn
# the pane from the HOST's document (`pane/kind` + `pane/videoTarget`), resolve the ports off its
# `ConnectionTarget` defaults, and dial a window nobody told it about. That is the real second-device
# shape, and it exercises the document → satellite-window → video-lane path end to end.
if [[ "${SECOND_CLIENT}" == "1" ]]; then
  echo "==> launching a SECOND client (document-driven, no video autoconnect)"
  CLIENT_B_HOME="${WORK}/client-b-home"
  CLIENT_B_LOG="${WORK}/client-b.log"
  rm -rf "${CLIENT_B_HOME}"
  mkdir -p "${CLIENT_B_HOME}"
  # Its own container (so it shares neither `workspace-cache.json` nor `device-prefs.json` with A),
  # the same throwaway Defaults suite (the pair are meant to agree, and what is being kept out is the
  # developer's own MRU), and the same `-ApplePersistenceIgnoreState YES` without which AppKit brings
  # it up with zero windows and every scene `.task` silently never runs.
  CFFIXED_USER_HOME="${CLIENT_B_HOME}" HOME="${CLIENT_B_HOME}" \
    SLOPDESK_DEFAULTS_SUITE="${DEFAULTS_SUITE}" \
    SLOPDESK_VIDEO_DEBUG=1 \
    SLOPDESK_AUTOCONNECT_HOST=127.0.0.1 \
    SLOPDESK_AUTOCONNECT_PORT="${CONNECT_PORT}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES > "${CLIENT_B_LOG}" 2>&1 &
  PID_B=""
  for _ in $(seq 1 16); do
    PID_B="$(pgrep -f "${APP_PROC_PAT}" | grep -v "^${PID}$" | head -1 || true)"
    [[ -n "${PID_B}" ]] && break
    sleep 0.5
  done
  [[ -z "${PID_B}" ]] && {
    echo "==> FAIL: the second client never started" >&2
    cat "${CLIENT_B_LOG}" >&2
    exit 1
  }
  echo "==> second client up (pid ${PID_B})"

  # 5f-i. TWO accepted workspace channels. Without this, everything below could be measuring a B that
  # never reached the document at all — and a B with no document has no pane to render, so its
  # silence would read as "two SCStreams are impossible" when it means "B never asked".
  echo "==> waiting for a SECOND workspace document channel on :${CONNECT_PORT}…"
  for _ in $(seq 1 40); do
    [[ "$(grep -cE "workspace channel .* accepted" "${TERMLOG}" || true)" -ge 2 ]] && break
    sleep 0.5
  done
  CHANNELS="$(grep -cE "workspace channel .* accepted" "${TERMLOG}" || true)"
  if [[ "${CHANNELS}" -lt 2 ]]; then
    echo "==> FAIL: the second client never opened a workspace document channel (saw ${CHANNELS})." >&2
    echo "--- hostd log ---" >&2
    tail -60 "${TERMLOG}" >&2
    echo "--- client B log ---" >&2
    tail -60 "${CLIENT_B_LOG}" >&2
    exit 1
  fi
  echo "==> two workspace document channels ✅"

  # 5f-ii. B decoded AND presented — the same two-legged assertion 5c makes of A, for the same
  # reason: a lane that dialled can stay blank for ever.
  echo "==> waiting for the second client to DECODE and PRESENT…"
  DECODED_B=0
  PRESENTED_B=0
  for _ in $(seq 1 60); do
    DECODED_B="$(grep -c 'DECODED frame #' "${CLIENT_B_LOG}" 2> /dev/null || true)"
    PRESENTED_B="$(grep -c 'PRESENTED#' "${CLIENT_B_LOG}" 2> /dev/null || true)"
    [[ "${DECODED_B}" -gt 0 && "${PRESENTED_B}" -gt 0 ]] && break
    sleep 0.5
  done
  if [[ "${DECODED_B}" -lt 1 || "${PRESENTED_B}" -lt 1 ]]; then
    echo "==> FAIL: the second client rendered nothing (${DECODED_B} decode / ${PRESENTED_B} present)." >&2
    echo "    It HAS the document (two channels accepted above), so this is the fan-out claim itself" >&2
    echo "    failing: either the client never materialised the document's desktop pane, or the host" >&2
    echo "    cannot serve a second SCStream / VTCompressionSession on one capture target." >&2
    echo "--- video host log ---" >&2
    tail -60 "${HOSTLOG}" >&2
    echo "--- client B log ---" >&2
    tail -60 "${CLIENT_B_LOG}" >&2
    exit 1
  fi
  echo "==> second client DECODED + PRESENTED (${DECODED_B} / ${PRESENTED_B}) ✅"

  # 5f-iii. And A is STILL streaming. This is the assertion that separates a fan-out from a takeover:
  # a host that can only hold one session per target might well hand the newcomer the stream and leave
  # the incumbent on a frozen last frame — in which case every check above still passes. Re-read A's
  # counters and require GROWTH, not merely a non-zero total from before B existed.
  A_BEFORE="${DECODED}"
  sleep 3
  A_AFTER="$(grep -c 'DECODED frame #' "${CLIENTLOG}" 2> /dev/null || true)"
  if [[ "${A_AFTER}" -le "${A_BEFORE}" ]]; then
    echo "==> FAIL: the FIRST client stopped decoding once the second attached (${A_BEFORE} → ${A_AFTER})." >&2
    echo "    The second client took the stream over instead of joining it — a fan-out serves both." >&2
    echo "--- video host log ---" >&2
    tail -60 "${HOSTLOG}" >&2
    echo "--- client A log ---" >&2
    tail -60 "${CLIENTLOG}" >&2
    exit 1
  fi
  echo "==> the first client kept streaming across the join (${A_BEFORE} → ${A_AFTER} decodes) ✅"

  # 5f-iv. Two SEPARATE UDP lanes, one per client process. Asserted per-PID rather than by counting
  # sockets on :${MEDIA_PORT}: the host's own bound socket lives there too, so a total is not a
  # per-client fact, and this must not pass because one client holds two flows.
  for pair in "A:${PID}" "B:${PID_B}"; do
    name="${pair%%:*}"
    pid="${pair##*:}"
    if ! lsof -nP -iUDP -a -p "${pid}" 2> /dev/null | grep -q ":${MEDIA_PORT}"; then
      echo "==> FAIL: client ${name} (pid ${pid}) holds no UDP flow to :${MEDIA_PORT}." >&2
      exit 1
    fi
  done
  echo "==> both clients hold their own media lane ✅"
fi

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
#
# Raised BY PID, not by process name. With two instances there are two processes called SlopDesk, and
# `first process whose name is "SlopDesk"` picks whichever the window server happens to answer with —
# so a name-matched raise photographs one client twice and calls it two. One shot per instance, each
# taken with THAT instance in front, is what makes the pair readable as a pair.
raise_and_shoot() {
  local pid="$1" path="$2" label="$3"
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is ${pid}) to true" \
    2> /dev/null || true
  sleep 1
  screencapture -x "${path}"
  echo "==> screenshot (${label} raised) saved: ${path}"
}
raise_and_shoot "${PID}" "${SHOT}" "client A"
if [[ "${SECOND_CLIENT}" == "1" ]]; then
  SHOT_B="${WORK}/client-b-shot.png"
  raise_and_shoot "${PID_B}" "${SHOT_B}" "client B"
fi
echo
echo "================================================================================"
echo " DONE. Document channel, UDP flow, a decoded + presented frame and the one-shell rule are all"
echo " ASSERTED above; what is left is whether the pixels are the RIGHT ones. Tell your agent:"
echo " read  ${SHOT}"
echo " PASS = the remote-desktop window shows the remote '${WTITLE}' window's live pixels."
echo " FAIL = it shows some OTHER window, or a stale/garbled frame. A blank pane cannot reach here."
echo " host log:   ${HOSTLOG}"
echo " client log: ${CLIENTLOG}"
if [[ "${SECOND_CLIENT}" == "1" ]]; then
  echo " client B:   ${CLIENT_B_LOG}  (document-driven — it was given a port, never a window)"
  echo " read  ${SHOT_B}"
  echo " PASS also needs client B's OWN window showing that same remote window's live pixels —"
  echo " two clients watching one target, which is the claim no unit test may construct."
fi
echo "================================================================================"
