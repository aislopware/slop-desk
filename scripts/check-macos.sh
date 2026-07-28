#!/usr/bin/env bash
#
# check-macos.sh — macOS RUNTIME self-verify gate (the desktop counterpart to maestro+iOS).
#
# WHY this exists: `swift test` proves the headless logic, `check-ios.sh` type-checks the
# iOS slice, and maestro screenshots the iOS Simulator. The one gap is the *macOS GUI app at
# runtime* — maestro cannot drive a native macOS app (it only targets iOS/Android/web). This
# script closes that gap with the toolchain every Mac already has: build → launch → screenshot.
# An agent (or a human) then READS the PNG to confirm the window actually rendered the expected
# UI (connection bar, terminal seam, input bar) — exactly how the iOS path is verified visually.
#
# MODES:
#   (default)    Build the committed PLACEHOLDER app, launch, assert alive AND WINDOWED, screenshot.
#   --renderer   Wire in the libghostty renderer (enable-macos-renderer.sh), build, launch,
#                assert alive AND WINDOWED, screenshot. Verifies the renderer app launches without
#                crashing.
#   --connect    --renderer PLUS a real END-TO-END render check: stand up `slopdesk-hostd` (a real
#                PTY host daemon), launch the renderer app with SLOPDESK_AUTOCONNECT_HOST/PORT set
#                so it auto-connects on launch (no fragile UI automation — see
#                SlopDeskClientApp.autoConnectIfRequested), then assert the TCP session is
#                ESTABLISHED and the app survived, and screenshot the connected terminal so the
#                glyphs libghostty rendered (shell/Starship prompt, ANSI colours, nerd-font
#                icons) can be visually confirmed. ALSO drives the OUT path: SLOPDESK_AUTOTYPE makes
#                the app auto-type a command through the real keystroke→host chain, and the gate
#                asserts the remote shell EXECUTED it (a COMPUTED marker 42 written to a
#                loopback file) — so this proves type→exec→render, not just a live socket.
#
# EXIT: non-zero if the build fails, the app dies within the settle window (a launch/connect
# crash), the app comes up with NO window (see step 4b — the one failure the default and --renderer
# modes could not previously express), or (--connect) no client↔host session is established.
#
# STATUS (2026-06-02): all three modes pass. The earlier --renderer ~3 s launch crash (off-main
# `MainActor.assumeIsolated` in libghostty's wakeup/write/resize callbacks, fired from its
# renderer/io threads) is fixed via the `ghosttyOnMainActor` helper. --connect renders a live
# remote shell end to end.
#
# Requires a logged-in GUI session (WindowServer) — it drives a real window, so it is not
# headless. Run from anywhere: paths resolve relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-macOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
WORK="${REPO_ROOT}/.work/macos-verify"
DD="${WORK}/DerivedData"
APP="${DD}/Build/Products/Debug/SlopDesk.app"
APP_BIN="${APP}/Contents/MacOS/SlopDesk"
SHOT="${WORK}/macos-shot.png"
HOSTD_LOG="${WORK}/hostd.log"
CLI="${REPO_ROOT}/.build/debug/slopdesk"
CONNECT_PORT=47420 # uncommon fixed loopback port for the e2e host daemon

# The app's client-control socket, which step 4b asks whether a window exists. AF_UNIX paths cap at
# ~104 bytes and `${WORK}` is already long — keyed by this script's pid under /tmp, removed on the way
# out (the check-multiclient.sh / check-launch-restore.sh discipline). Per-run, never the Application
# Support default: that one is the DEVELOPER's own running app, and asking it would answer about a
# window this gate never launched.
SOCK="/tmp/slopdesk-macos-$$.sock"

WITH_RENDERER=0
CONNECT=0
case "${1:-}" in
  --renderer) WITH_RENDERER=1 ;;
  --connect)
    WITH_RENDERER=1
    CONNECT=1
    ;;
  "") ;;
  *)
    echo "usage: check-macos.sh [--renderer | --connect]" >&2
    exit 2
    ;;
esac

# --connect needs more settle time (build + TCP connect + first render).
SETTLE=4
[[ "${CONNECT}" == "1" ]] && SETTLE=7

mkdir -p "${WORK}"

# The macOS app and the iOS-Simulator app share the binary name "SlopDesk"; match ONLY the macOS
# build product path so we never touch the Simulator's process.
APP_PROC_PAT="macos-verify/DerivedData.*MacOS/SlopDesk"
HOSTD_PID=""

cleanup() {
  pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
  rm -f "${SOCK}"
  [[ -n "${HOSTD_PID}" ]] && kill "${HOSTD_PID}" 2> /dev/null || true
  if [[ "${WITH_RENDERER}" == "1" ]]; then
    echo "==> restoring committed placeholder project.yml"
    git -C "${REPO_ROOT}" checkout -- "${SPEC}" 2> /dev/null || true
    xcodegen generate --spec "${SPEC}" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── 1. (optional) enable the libghostty renderer ────────────────────────────────────────────
if [[ "${WITH_RENDERER}" == "1" ]]; then
  echo "==> enabling libghostty renderer (will restore on exit)"
  bash "${REPO_ROOT}/scripts/enable-macos-renderer.sh"
else
  # Make sure the .xcodeproj matches the committed spec.
  xcodegen generate --spec "${SPEC}" > /dev/null
fi

# ── 2. Build (unsigned / ad-hoc) ────────────────────────────────────────────────────────────
echo "==> building SlopDesk.app (Debug, unsigned)"
xcodebuild \
  -project "${PROJECT}" \
  -scheme ClientApp-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DD}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build > /dev/null
echo "==> build OK: ${APP}"

# The `slopdesk` CLI is this gate's window observer (step 4b) — it asks the running app, over the
# shipping client-control socket, what it is rendering. Built in EVERY mode, because every mode
# launches a window.
echo "==> building the slopdesk client CLI (the window observer)"
(cd "${REPO_ROOT}" && swift build --product slopdesk > /dev/null)

# ── 2b. (--connect) stand up the host daemon ────────────────────────────────────────────────
if [[ "${CONNECT}" == "1" ]]; then
  echo "==> building + starting slopdesk-hostd on 127.0.0.1:${CONNECT_PORT}"
  (cd "${REPO_ROOT}" && swift build --product slopdesk-hostd > /dev/null)
  # Free the port if a prior run left a daemon behind.
  pkill -f "slopdesk-hostd --port ${CONNECT_PORT}" 2> /dev/null || true
  sleep 0.5
  # Isolation: --port stays FIRST so the pkill pattern above keeps matching. The default spawn
  # is the developer's REAL login zsh — the ShellIntegration shim points its HISTFILE at the
  # real ~/.zsh_history, so the AUTOTYPE proof command would be appended there on every run
  # (and scrollback journals would land in the real Application Support dir). A plain sh
  # computes the $((6*7)) proof just as well, and the throwaway HOME sandboxes both files.
  HOSTD_HOME="${WORK}/hostd-home"
  mkdir -p "${HOSTD_HOME}"
  # The client MUTATES the host's workspace document (docs/45), so the daemon must never be pointed
  # at the developer's real `workspace-state.json` — an automation run would reshape the layout they
  # are actually working in. FRESH per run, and empty: `adoptWorkspace` answers `rejectedStale`
  # against a host that already has a workspace, so a reused dir would keep a stale layout and the
  # screenshot would prove the wrong thing.
  if [[ -z "${WORK}" ]]; then
    echo "==> FAIL: WORK is empty — refusing to run a daemon against an unpinned state dir" >&2
    exit 1
  fi
  HOSTD_WORKSPACE="${WORK}/hostd-workspace"
  rm -rf "${HOSTD_WORKSPACE}"
  mkdir -p "${HOSTD_WORKSPACE}"
  if [[ -z "${HOSTD_WORKSPACE}" ]]; then
    echo "==> FAIL: SLOPDESK_WORKSPACE_STATE_DIR would be empty — refusing to launch hostd" >&2
    exit 1
  fi
  HOME="${HOSTD_HOME}" SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
    "${REPO_ROOT}/.build/debug/slopdesk-hostd" \
    --port "${CONNECT_PORT}" --shell /bin/sh > "${HOSTD_LOG}" 2>&1 &
  HOSTD_PID=$!
  sleep 1
  if ! kill -0 "${HOSTD_PID}" 2> /dev/null; then
    echo "==> FAIL: slopdesk-hostd did not stay up; log:" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi
  echo "==> hostd up (pid ${HOSTD_PID})"

  # OUT-path proof setup: a unique marker whose COMPUTED value (42) appears ONLY if the
  # remote shell actually EXECUTED the typed command — not if it merely echoed the literal
  # keystrokes. The app's SLOPDESK_AUTOTYPE seam pushes this through the real OUT path
  # (terminal.sendInput → ordered drain → SlopDeskClient.sendInput → host PTY). \$((6*7)) is
  # escaped so THIS shell passes it literally; the REMOTE zsh computes 42 and writes the file.
  OUT_NONCE="$$_${RANDOM}"
  OUT_PROOF="${WORK}/out-proof-${OUT_NONCE}.txt"
  OUT_EXPECT="SLOPDESK_OUT_${OUT_NONCE}_42_END"
  rm -f "${OUT_PROOF}"
  AUTOTYPE="echo SLOPDESK_OUT_${OUT_NONCE}_\$((6*7))_END > '${OUT_PROOF}'; echo SLOPDESK_OUT_${OUT_NONCE}_\$((6*7))_END"
fi

# ── 3. Launch + poll for the macOS process ──────────────────────────────────────────────────
# EVERY mode execs the bundle's BINARY, never `open`, and every mode carries
# `-ApplePersistenceIgnoreState YES`. Both halves are load-bearing, and the reason is written down
# here because it has now bitten twice — once in this gate, once in check-video.sh.
#
#   ENV. LaunchServices forwards NO shell environment, and every seam these modes read is a
#   `SLOPDESK_*` env var: the auto-connect pair, the autotype command, the echo probe, and
#   `SLOPDESK_CLIENT_SOCKET` — the socket step 4b asks whether a window exists. `open` can carry ARGV
#   (`open "${APP}" --args …`) but there is no `open` flag that carries an ENVIRONMENT, so an
#   `open`-launched app is one this gate cannot address.
#
#   PERSISTENCE. A direct exec goes down AppKit's persistence path and brings the app up with ZERO
#   windows. No window ⇒ no scene ⇒ not one scene `.task` runs: no auto-connect, no control socket,
#   no workspace document. The process sits in its run loop with no UI and no sockets.
#   (HW-confirmed 2026-07-28 on this host: with the flag ⇒ a window every time; without it ⇒ zero
#   windows every time. `GuiGateLaunchContractTests` pins the flag onto every `"${APP_BIN}"` line in
#   this file, and pins that no gate launches the app through `open` at all.)
#
# Stderr is kept: the SLOPDESK_ECHO_PROBE seam prints keystroke→ingest latency lines there (step 4f).
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK}"
APP_LOG="${WORK}/app-stderr.log"
if [[ "${CONNECT}" == "1" ]]; then
  SLOPDESK_AUTOCONNECT_HOST=127.0.0.1 SLOPDESK_AUTOCONNECT_PORT="${CONNECT_PORT}" \
    SLOPDESK_AUTOTYPE="${AUTOTYPE}" SLOPDESK_ECHO_PROBE=1 SLOPDESK_CLIENT_SOCKET="${SOCK}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES > /dev/null 2> "${APP_LOG}" &
else
  SLOPDESK_CLIENT_SOCKET="${SOCK}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES > /dev/null 2> "${APP_LOG}" &
fi
PID=""
for _ in $(seq 1 16); do
  PID="$(pgrep -f "${APP_PROC_PAT}" || true)"
  [[ -n "${PID}" ]] && break
  sleep 0.5
done
if [[ -z "${PID}" ]]; then
  echo "==> FAIL: app never started a process" >&2
  exit 1
fi
echo "==> launched (pid ${PID}); settling ${SETTLE}s"

# ── 4. Assert it survived the settle window ─────────────────────────────────────────────────
sleep "${SETTLE}"
if ! pgrep -f "${APP_PROC_PAT}" > /dev/null; then
  echo "==> FAIL: app died within ${SETTLE}s of launch (likely a launch/connect crash)" >&2
  [[ "${CONNECT}" == "1" ]] && {
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
  }
  exit 1
fi
echo "==> alive after ${SETTLE}s ✅"

# ── 4b. The app has a WINDOW — asserted, in every mode ───────────────────────────────────────
# "The process is alive" is not "the app came up". A macOS app with ZERO windows is a perfectly
# healthy process: it sits in its run loop, `pgrep` finds it, the settle window passes, and this gate
# printed `alive after Ns ✅` and screenshotted the bare desktop. That is the exact shape that made
# check-video.sh useless for months, and until this assertion existed the default and --renderer modes
# had NOTHING else to say — they carry no auto-connect, so the ESTABLISHED/OUT-path checks below never
# ran for them. Proven RED on this host: launched without `-ApplePersistenceIgnoreState YES` the app
# reports 0 windows for the whole settle window and the gate still exited 0.
#
# Read off the SHIPPING client-control socket rather than off pixels or AX: no Screen-Recording and no
# Accessibility TCC, and the answer is `WorkspaceStore.tree` — the value the window paints. It is also
# a two-in-one claim, because `ClientControlServer.start()` is itself a scene `.task`: a windowless
# app never binds the socket at all, so it fails here on the connect, not on the count.
echo "==> asking the app what it is rendering (${SOCK})…"
WINDOW_JSON=""
for _ in $(seq 1 40); do
  WINDOW_JSON="$("${CLI}" --socket "${SOCK}" windows --json 2> /dev/null || true)"
  [[ -n "${WINDOW_JSON}" ]] && break
  kill -0 "${PID}" 2> /dev/null || break
  sleep 0.5
done
# `|| echo 0` covers BOTH an empty answer and a malformed one — either way it is not a window.
WINDOW_COUNT="$(printf '%s' "${WINDOW_JSON}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
print(len(json.loads(raw)) if raw else 0)
' 2> /dev/null || echo 0)"
if [[ "${WINDOW_COUNT}" -lt 1 ]]; then
  echo "==> FAIL: the app is running with NO window (${WINDOW_COUNT} reported over ${SOCK})." >&2
  echo "    No window means no scene, and every scene .task seam is dead with it: the auto-connect," >&2
  echo "    the workspace document, the control socket. A screenshot past this point proves nothing." >&2
  echo "--- app stderr ---" >&2
  tail -40 "${APP_LOG}" >&2 2> /dev/null || true
  [[ "${CONNECT}" == "1" ]] && {
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
  }
  exit 1
fi
echo "==> the app reports ${WINDOW_COUNT} window(s) ✅"

# ── 4c. (--connect) assert the client↔host TCP session is established ────────────────────────
if [[ "${CONNECT}" == "1" ]]; then
  if lsof -nP -iTCP:"${CONNECT_PORT}" -sTCP:ESTABLISHED > /dev/null 2>&1; then
    echo "==> client↔host session ESTABLISHED on :${CONNECT_PORT} ✅"
  else
    echo "==> FAIL: no ESTABLISHED session on :${CONNECT_PORT} (auto-connect did not land)" >&2
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi

  # ── 4d. (--connect) assert the host shell EXECUTED a typed command (the OUT path) ──────────
  # ESTABLISHED only proves a live socket. This proves the round trip: the app auto-typed a
  # command through the real OUT path, the host PTY ran it, and the shell COMPUTED 42 (so this
  # is execution, not a literal-keystroke echo). The remote shell wrote the marker to a file on
  # this same (loopback) host, which we now read — a deterministic, machine-checked assertion.
  echo "==> waiting for OUT-path proof (auto-typed command must EXECUTE on the host)…"
  OUT_OK=0
  for _ in $(seq 1 24); do
    [[ -f "${OUT_PROOF}" ]] && grep -q "${OUT_EXPECT}" "${OUT_PROOF}" 2> /dev/null && {
      OUT_OK=1
      break
    }
    sleep 0.5
  done
  if [[ "${OUT_OK}" == "1" ]]; then
    echo "==> OUT-path PROVEN: keystrokes → host PTY → shell EXECUTED (computed 42 → ${OUT_EXPECT}) ✅"
  else
    echo "==> FAIL: auto-typed command never executed on host (no ${OUT_EXPECT} in ${OUT_PROOF})" >&2
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi

  # ── 4e. (--connect) ONE auto-connect spawns ONE shell ─────────────────────────────────────
  # The terminal autoconnect shape is a LONE terminal pane, so exactly one shell may ever attach.
  # A second means the client mounted one pane, gave it a PTY, and then let the workspace document
  # replace it — the first shell abandoned on the host and a second spawned for its replacement.
  #
  # Asserted DIRECTLY rather than inferred from 4d. The OUT-path proof used to fail as a side effect
  # of that bug, because the autotype latch was spent by the pane that got torn down; the seam now
  # re-arms and rides the replacement pane's connect edge, which is correct on its own terms and
  # leaves 4c green. Nothing else in this gate would have noticed. Read AFTER 4c so a second attach
  # that happens while the proof is still polling still counts.
  SHELLS="$(grep -c 'shell .* attached' "${HOSTD_LOG}" || true)"
  if [[ "${SHELLS}" != "1" ]]; then
    echo "==> FAIL: one auto-connect must attach exactly 1 shell; saw ${SHELLS}" >&2
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi
  echo "==> exactly one shell attached for one auto-connect ✅"

  # ── 4f. (--connect) keystroke-echo latency numbers (SLOPDESK_ECHO_PROBE) ─────────────────
  # The probe prints one "key→ingest NN.Nms" line per echoed keystroke on the app's stderr —
  # the user-feel span (wire out + host PTY + wire back + client delivery to the render feed).
  # Informational, never a failure: the smoothness-work A/B number, not a gate.
  if [[ -s "${APP_LOG}" ]] && grep -q "echo-probe" "${APP_LOG}"; then
    SAMPLES="$(grep -o 'key→ingest [0-9.]*ms' "${APP_LOG}" | grep -o '[0-9.]*' | sort -n)"
    COUNT="$(echo "${SAMPLES}" | grep -c . || true)"
    MEDIAN="$(echo "${SAMPLES}" | awk '{a[NR]=$1} END{ if (NR) printf "%.1f", a[int((NR+1)/2)] }')"
    P95="$(echo "${SAMPLES}" | awk '{a[NR]=$1} END{ if (NR) printf "%.1f", a[int(NR*0.95)>0?int(NR*0.95):1] }')"
    echo "==> echo latency (n=${COUNT}): median ${MEDIAN}ms, p95 ${P95}ms (key→render-feed, loopback)"
  fi
fi

# ── 5. Screenshot for visual verification ───────────────────────────────────────────────────
# Raised through System Events, never by `open`ing the bundle. `open` on an app that is ALREADY
# running with zero windows makes AppKit RE-OPEN one — so the old bring-to-front repaired the exact
# failure this gate now asserts, one line before the screenshot, and handed the human a picture of a
# healthy window. Best-effort (`|| true`): the raise wants Accessibility TCC, no assertion depends on
# it, and every claim above was read off a socket.
osascript -e 'tell application "System Events" to set frontmost of first process whose name is "SlopDesk" to true' 2> /dev/null || true
sleep 1
screencapture -x "${SHOT}"
echo "==> screenshot: ${SHOT}"
if [[ "${CONNECT}" == "1" ]]; then
  echo "==> macOS END-TO-END check OK — open the screenshot to confirm libghostty rendered the"
  echo "    live remote shell (prompt, ANSI colours, nerd-font glyphs)."
else
  echo "==> macOS runtime check OK — open the screenshot to verify the rendered window."
fi
