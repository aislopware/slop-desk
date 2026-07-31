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
CENSUS="${WORK}/window-census" # the compiled CGWindowList window observer (step 4b)
CONNECT_PORT=47420             # uncommon fixed loopback port for the e2e host daemon

# The app's client-control socket, which step 4c asks what the app mounted. AF_UNIX paths cap at
# ~104 bytes and `${WORK}` is already long — keyed by this script's pid under /tmp, removed on the way
# out (the check-multiclient.sh / check-launch-restore.sh discipline). Per-run, never the Application
# Support default: that one is the DEVELOPER's own running app, and asking it would answer about a
# process this gate never launched.
SOCK="/tmp/slopdesk-macos-$$.sock"

# The client's THROWAWAY container, one per run (the check-multiclient.sh / check-launch-restore.sh
# discipline). `CFFIXED_USER_HOME` redirects `NSHomeDirectory()` and Application Support, so every
# device-local file this run touches — `workspace.json`, `device-prefs.json`, `video-prefs.json`,
# `workspace-cache.json`, `folders-frecency.json`, the scrollback journals — is its own.
#
# Load-bearing in EVERY mode, and the default / --renderer modes are the ones that make it so.
# `hasAutomationEnvironment()` keys on `SLOPDESK_AUTOCONNECT_HOST` / `SLOPDESK_VIDEO_AUTOCONNECT_HOST`
# only, and neither of those modes sets one — so both run with `isAutomation == false`, which builds a
# REAL `WorkspacePersistence()` and a REAL `DevicePreferencesStore()`. A direct exec starts a NEW
# process even while the developer's own SlopDesk is running, so without this the gate is a second
# instance autosaving the developer's live layout. HW-observed 2026-07-28: a default-mode launch
# RESTORED the container's `workspace.json` (its own pane ids came back over the control socket) and
# wrote `device-prefs.json` + `video-prefs.json` into it.
CLIENT_HOME="${WORK}/client-home"

# The `UserDefaults` suite this run writes into, keyed by pid and removed by the cleanup trap.
#
# `CFFIXED_USER_HOME` moves Application Support and NOT `UserDefaults` — cfprefsd resolves the real
# home whatever the environment says (probed: a suite write under `CFFIXED_USER_HOME=/private/tmp/…`
# still landed in the real `~/Library/Preferences`). So without this, `AppConnection` records
# `127.0.0.1:${CONNECT_PORT}` in the DEVELOPER's `connection.recentTargets` on every --connect run.
# That list is their recent-hosts menu and it holds five entries: measured before this existed, three
# of the five were gate ports and the host they actually use had been pushed to the last slot.
#
# The suite isolates reads too — `SettingsKey.store` bound to a suite cannot see this bundle's own
# persistent domain — which is a stronger guarantee than `SLOPDESK_SKIP_AUTO_RECONNECT=1` alone: the
# MRU `connectIfSavedTarget()` reads is now EMPTY rather than merely unread.
DEFAULTS_SUITE="slopdesk.gate.macos.$$"

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
  # The app is killed, so its own `atexit` suite cleanup never runs — this is the one that does.
  # Left undone it is a per-run plist in the developer's ~/Library/Preferences, which is exactly how
  # this machine came to hold 55,003 `slopdesk.tests.pid*.plist` files.
  remove_defaults_suite
  if [[ -n "${HOSTD_PID}" ]]; then kill "${HOSTD_PID}" 2> /dev/null || true; fi
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

# The `slopdesk` CLI is how step 4c asks the running app what it MOUNTED, over the shipping
# client-control socket. Built in EVERY mode, because every mode launches a scene.
echo "==> building the slopdesk client CLI (the scene observer)"
(cd "${REPO_ROOT}" && swift build --product slopdesk > /dev/null)

# The WINDOW observer (step 4b). Compiled once here rather than run through `swift` on every poll:
# the census is polled up to 40 times and `swift <file>` recompiles on each one. It reads
# `CGWindowListCopyWindowInfo`, which needs no TCC for owner-pid/layer/bounds — only window TITLES are
# gated behind Screen Recording, and it never asks for one.
echo "==> compiling the window census (CGWindowList; no Screen-Recording / Accessibility TCC)"
swiftc -O "${REPO_ROOT}/scripts/window-census.swift" -o "${CENSUS}" > /dev/null

# ── 2b. (--connect) stand up the host daemon ────────────────────────────────────────────────
if [[ "${CONNECT}" == "1" ]]; then
  echo "==> building + starting slopdesk-hostd on 127.0.0.1:${CONNECT_PORT}"
  (cd "${REPO_ROOT}" && swift build --product slopdesk-hostd > /dev/null)
  # Free the port if a prior run left a daemon behind.
  pkill -f "slopdesk-hostd --port ${CONNECT_PORT}" 2> /dev/null || true
  sleep 0.5
  # Isolation: --port stays FIRST so the pkill pattern above keeps matching. The default spawn
  # is the developer's REAL login zsh — the ShellIntegration shim points its HISTFILE at the
  # real ~/.zsh_history, so the AUTOTYPE proof command would be appended there on every run.
  # A plain sh computes the $((6*7)) proof just as well, and the throwaway HOME sandboxes the
  # history file.
  #
  # HOME sandboxes the history file and NOTHING ELSE. It does not move Application Support; it does
  # not even move `NSHomeDirectory()` — Core Foundation reads the account record unless
  # `CFFIXED_USER_HOME` is set. So `SLOPDESK_APP_SUPPORT_DIR` is what actually gives this daemon a
  # container of its own, and it is not optional: `ScrollbackJournalStore.sweep` runs on hostd's
  # FIRST loop iteration and unlinks everything past the newest 256 journals in whatever directory it
  # resolved. Measured on this host before this line existed: one run of this gate unlinked 5 of the
  # developer's journals and left one of its own behind. The live-writer exemption is no protection
  # either — it consults the SWEEPING process's own map, so a file the developer's live hostd holds
  # an open fd on is unlinked underneath it.
  #
  # `CFFIXED_USER_HOME` is the wrong tool here even though it would work: it also relocates the
  # daemon's home, which is the cwd its panes default to and the volume its vitals measure. Pointing
  # a hostd at one made check-launch-restore.sh flake three runs in five.
  HOSTD_HOME="${WORK}/hostd-home"
  HOSTD_STATE="${WORK}/hostd-state"
  rm -rf "${HOSTD_STATE}"
  mkdir -p "${HOSTD_HOME}" "${HOSTD_STATE}/scrollback" "${HOSTD_STATE}/drop"
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
  HOME="${HOSTD_HOME}" SLOPDESK_APP_SUPPORT_DIR="${HOSTD_STATE}" \
    SLOPDESK_SCROLLBACK_DIR="${HOSTD_STATE}/scrollback" \
    SLOPDESK_FILE_DROP_DIR="${HOSTD_STATE}/drop" \
    SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
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
#   `SLOPDESK_CLIENT_SOCKET` — the socket step 4c asks what the app mounted. `open` can carry ARGV
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
#   ISOLATION. Three vars, on EVERY launch, because a direct exec is a SECOND instance — it starts
#   even while the developer's own SlopDesk is running, which `open` would not.
#     `CFFIXED_USER_HOME` / `HOME` — the throwaway container above. It redirects `NSHomeDirectory()`
#     and Application Support, so nothing this run autosaves can land on the developer's files.
#     `SLOPDESK_DEFAULTS_SUITE` — the throwaway `UserDefaults` suite (see its definition above), the
#     half `CFFIXED_USER_HOME` cannot reach. It isolates BOTH directions, so the MRU this instance
#     reads is EMPTY and the MRU it writes is its own.
#     `SLOPDESK_SKIP_AUTO_RECONNECT=1` — kept, and now the second lock on the same door. It was the
#     only one: `connection.recentTargets` was the DEVELOPER's, and `connectIfSavedTarget()` — the
#     scene task that runs precisely when `isAutomation` is false — dials whatever host is at the top
#     of it. That host is their live `slopdesk-hostd`, which OWNS the workspace layout (docs/45): an
#     automation instance connecting to it reshapes the layout they are working in, and no
#     client-side file isolation protects against that. HW-observed 2026-07-28: a decoy listener on
#     the MRU entry took 17 bytes from a default-mode launch, and 0 with this flag set. It is inert
#     under --connect (the automation branch calls `connect()` explicitly and skips the auto-reconnect
#     task), and set there anyway so the rule holds for every launch in this file rather than for the
#     two that happen to need it today.
#
# Stderr is kept: the SLOPDESK_ECHO_PROBE seam prints keystroke→ingest latency lines there (step 4g).
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK}"
rm -rf "${CLIENT_HOME}"
mkdir -p "${CLIENT_HOME}"
# The suite starts EMPTY, and an empty defaults domain is a FRESH INSTALL:
# `FirstLaunchModel.shouldPresent` is true whenever `firstLaunch.completed` is unset and no
# `SLOPDESK_AUTOCONNECT_*` makes `hasAutomationEnvironment()` true — which is the default and
# --renderer modes exactly. The guided sheet would then open over the window this gate screenshots.
# Seeded rather than asserted: the subject here is the rendered workspace, not the welcome sheet.
# (Before the suite existed this was covered by accident, because the domain was the developer's own
# and they had long since dismissed it.) The delete first, in case a killed run left the suite behind.
remove_defaults_suite
defaults write "${DEFAULTS_SUITE}" firstLaunch.completed -bool YES
APP_LOG="${WORK}/app-stderr.log"
if [[ "${CONNECT}" == "1" ]]; then
  CFFIXED_USER_HOME="${CLIENT_HOME}" HOME="${CLIENT_HOME}" SLOPDESK_SKIP_AUTO_RECONNECT=1 \
    SLOPDESK_DEFAULTS_SUITE="${DEFAULTS_SUITE}" \
    SLOPDESK_AUTOCONNECT_HOST=127.0.0.1 SLOPDESK_AUTOCONNECT_PORT="${CONNECT_PORT}" \
    SLOPDESK_AUTOTYPE="${AUTOTYPE}" SLOPDESK_ECHO_PROBE=1 SLOPDESK_CLIENT_SOCKET="${SOCK}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES > /dev/null 2> "${APP_LOG}" &
else
  CFFIXED_USER_HOME="${CLIENT_HOME}" HOME="${CLIENT_HOME}" SLOPDESK_SKIP_AUTO_RECONNECT=1 \
    SLOPDESK_DEFAULTS_SUITE="${DEFAULTS_SUITE}" \
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

# ── 4b. The app has a WINDOW — asserted off the WINDOW SERVER, in every mode ──────────────────
# "The process is alive" is not "the app came up". A macOS app with ZERO windows is a perfectly
# healthy process: it sits in its run loop, `pgrep` finds it, the settle window passes, and this gate
# printed `alive after Ns ✅` and screenshotted the bare desktop. That is the exact shape that made
# check-video.sh useless for months, and the default and --renderer modes have NOTHING else to say —
# they carry no auto-connect, so the ESTABLISHED/OUT-path checks below never run for them.
#
# Counted with `CGWindowListCopyWindowInfo` (scripts/window-census.swift), because the window server
# is the only thing that knows. The obvious cheaper answer is a lie in two independent ways, and both
# were HW-observed on this host on 2026-07-28:
#   - `slopdesk … windows --json` is answered by `WorkspaceControlBackend.listWindows()`, which maps
#     `WorkspaceStore.tree.sessions` — a value the App's `init()` builds before any scene exists. It
#     is a SESSION count with no window information in it.
#   - the socket does not carry the claim either. `ClientControlServer.start()` hands its listener to
#     `Thread.detachNewThread` and nothing ever calls `stop()`, so a bound socket outlives the scene.
# Proven RED: with the app's window CLOSED and the process still alive, `windows --json` answered `1`
# for as long as it ran, while this census answered `0`.
#
# Still no TCC: owner-pid, window layer and bounds are public CoreGraphics fields; only window TITLES
# are behind Screen Recording, and the census never asks for one.
echo "==> counting the app's on-screen windows (CGWindowList, pid ${PID})…"
WINDOW_COUNT=0
CENSUS_DIAG="${WORK}/window-census.txt"
for _ in $(seq 1 40); do
  # stdout is the COUNT, stderr is one line per window the server attributes to the pid (kept for a
  # red run's diagnosis). Anything that is not a number is not a window.
  WINDOW_COUNT="$("${CENSUS}" "${PID}" 2> "${CENSUS_DIAG}" || echo 0)"
  [[ "${WINDOW_COUNT}" =~ ^[0-9]+$ ]] || WINDOW_COUNT=0
  [[ "${WINDOW_COUNT}" -ge 1 ]] && break
  kill -0 "${PID}" 2> /dev/null || break
  sleep 0.5
done
if [[ "${WINDOW_COUNT}" -lt 1 ]]; then
  echo "==> FAIL: the app is running with NO window (window server reports ${WINDOW_COUNT} for pid ${PID})." >&2
  echo "    No window means no scene, and every scene .task seam is dead with it: the auto-connect," >&2
  echo "    the workspace document, the control socket. A screenshot past this point proves nothing." >&2
  echo "--- windows the server does attribute to this pid ---" >&2
  if [[ -s "${CENSUS_DIAG}" ]]; then cat "${CENSUS_DIAG}" >&2; else echo "  (none at all)" >&2; fi
  echo "--- app stderr ---" >&2
  tail -40 "${APP_LOG}" >&2 2> /dev/null || true
  [[ "${CONNECT}" == "1" ]] && {
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
  }
  exit 1
fi
echo "==> the window server attributes ${WINDOW_COUNT} on-screen window(s) to pid ${PID} ✅"

# ── 4c. …and its SCENE mounted — a separate claim, read off the shipping control socket ───────
# A window is the app's UI; this is the app's STATE. `WorkspaceControlBackend` answers off
# `WorkspaceStore.tree`, so a reply means the scene came up far enough to bind the socket (the bind is
# a scene `.task`) and the store has a session to describe. Kept distinct from 4b on purpose: it is
# what the multi-client and launch-restore gates assert their whole projection on, and conflating it
# with "there is a window" is what made 4b unable to fail.
echo "==> asking the app what it mounted (${SOCK})…"
SCENE_JSON=""
for _ in $(seq 1 40); do
  SCENE_JSON="$("${CLI}" --socket "${SOCK}" windows --json 2> /dev/null || true)"
  [[ -n "${SCENE_JSON}" ]] && break
  kill -0 "${PID}" 2> /dev/null || break
  sleep 0.5
done
# `|| echo 0` covers BOTH an empty answer and a malformed one — either way nothing mounted.
SESSION_COUNT="$(printf '%s' "${SCENE_JSON}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
print(len(json.loads(raw)) if raw else 0)
' 2> /dev/null || echo 0)"
if [[ "${SESSION_COUNT}" -lt 1 ]]; then
  echo "==> FAIL: the app has a window but mounted nothing (${SESSION_COUNT} sessions over ${SOCK})." >&2
  echo "    Either the control socket never bound — it is a scene .task — or the store came up with" >&2
  echo "    no session at all. Every projection this and the other GUI gates read is dead with it." >&2
  echo "--- app stderr ---" >&2
  tail -40 "${APP_LOG}" >&2 2> /dev/null || true
  [[ "${CONNECT}" == "1" ]] && {
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
  }
  exit 1
fi
echo "==> the app mounted ${SESSION_COUNT} session(s) and answers on its control socket ✅"

# ── 4d. (--connect) assert the client↔host TCP session is established ────────────────────────
if [[ "${CONNECT}" == "1" ]]; then
  if lsof -nP -iTCP:"${CONNECT_PORT}" -sTCP:ESTABLISHED > /dev/null 2>&1; then
    echo "==> client↔host session ESTABLISHED on :${CONNECT_PORT} ✅"
  else
    echo "==> FAIL: no ESTABLISHED session on :${CONNECT_PORT} (auto-connect did not land)" >&2
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi

  # ── 4e. (--connect) assert the host shell EXECUTED a typed command (the OUT path) ──────────
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

  # ── 4f. (--connect) ONE auto-connect spawns ONE shell ─────────────────────────────────────
  # The terminal autoconnect shape is a LONE terminal pane, so exactly one shell may ever attach.
  # A second means the client mounted one pane, gave it a PTY, and then let the workspace document
  # replace it — the first shell abandoned on the host and a second spawned for its replacement.
  #
  # Asserted DIRECTLY rather than inferred from 4e. The OUT-path proof used to fail as a side effect
  # of that bug, because the autotype latch was spent by the pane that got torn down; the seam now
  # re-arms and rides the replacement pane's connect edge, which is correct on its own terms and
  # leaves 4d green. Nothing else in this gate would have noticed. Read AFTER 4e so a second attach
  # that happens while the proof is still polling still counts.
  SHELLS="$(grep -c 'shell .* attached' "${HOSTD_LOG}" || true)"
  if [[ "${SHELLS}" != "1" ]]; then
    echo "==> FAIL: one auto-connect must attach exactly 1 shell; saw ${SHELLS}" >&2
    echo "--- hostd log ---" >&2
    cat "${HOSTD_LOG}" >&2
    exit 1
  fi
  echo "==> exactly one shell attached for one auto-connect ✅"

  # ── 4g. (--connect) keystroke-echo latency numbers (SLOPDESK_ECHO_PROBE) ─────────────────
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
