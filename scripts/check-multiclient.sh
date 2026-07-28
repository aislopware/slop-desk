#!/usr/bin/env bash
#
# check-multiclient.sh — the docs/45 headline claim, on real hardware: TWO clients, ONE layout.
#
# WHY this exists: `docs/45-multi-client-state-sync.md` ends Phase 5b with "nobody has yet watched
# two real clients converge on one layout. That is the open item." Everything under it — the
# host-owned topology, the intent ops, the optimistic patch, the projection — exists to make one
# sentence true: a gesture on one client shows up on the other. The headless suite proves each link
# (`WorkspaceConvergenceTests` two mirrors byte-identical, `WorkspaceDocumentReconcileTests` a
# document change reconciling the registry, `AutomationBootstrapLaunchTests` a refused adopt snapping
# back to host truth) and NOTHING composes them in two real processes. This does.
#
# WHAT IT PROVES on success:
#   - one `slopdesk-hostd` serves TWO macOS client instances, each with its own container,
#   - both open a workspace-document channel (`channelClass 1`) — the hostd log names them,
#   - the second client ABANDONS the layout it minted at launch (its `adoptWorkspace` is refused
#     against a host that already has one) and projects host truth instead,
#   - a REAL menu gesture on client A — Split Right, New Tab, Close Tab — reaches client B's own
#     projection, in both directions (a pane appearing AND a tab disappearing),
#   - the pane inventory is exact: N panes in the layout ⇒ N live shells on the host,
#   - and no pane was ever minted a SECOND shell — a live census can be waited out, a duplicated
#     `attached for pane <uuid>` line cannot.
#
# HOW IT OBSERVES THE SECOND CLIENT — the interesting design problem, decided out loud:
#   The claim under test is "client B's VIEW follows", so the observation has to come off client B.
#   Three honest options:
#     (a) read the host's `workspace-state.json` — rejected: that is the HOST's copy. "The host
#         applied it" is not the claim; it is the premise.
#     (b) diff screenshots — rejected as the ASSERTION (kept as evidence, step 8): two windows of
#         one app, anti-aliased text, no mechanical comparison that is not brittle.
#     (c) ask client B what it is rendering. Chosen — and it needs no test seam, because the
#         shipping client-control socket already answers it: `slopdesk --socket … panes|tabs|windows`
#         is served by `WorkspaceControlBackend`, which reads `WorkspaceStore.tree` — the projection
#         of `workspaceMirror.topology`, the exact value the window paints. Each instance gets its
#         own `SLOPDESK_CLIENT_SOCKET`, so the two are addressed independently.
#   The comparison is TOPOLOGY only — pane ids, their owning tab, pane kind, tab order, per-tab pane
#   count, session tab counts. Titles / cwd / focus are deliberately excluded: docs/45 §4.1 files
#   them as LIVENESS (pushed on a pane's own control channel, which with `SLOPDESK_PANE_FANOUT` off
#   only ONE client holds) and §8.2 makes focus device-overridable on purpose. Topology is what
#   Phase 5b makes host-owned, and topology is what this gate pins.
#
# THE GESTURE is a real menu click (System Events, addressed by unix id) rather than an env seam:
# `Panes ▸ Split Right` is the path a human takes, and driving it proves the command → intent → host
# → fan-out → projection chain end to end. That makes **Accessibility TCC** a hard requirement for
# whatever terminal runs this — the gate fails loudly and says so if it is missing.
#
# ⚠️ MUST RUN FROM A REAL, UNLOCKED GUI LOGIN SESSION (Terminal.app/iTerm in your Aqua session).
# It opens two app windows, raises them and screenshots the screen. Needs Accessibility TCC (the
# gesture + the window arrangement) and Screen Recording TCC (the screenshot).
#
# USAGE:
#   bash scripts/check-multiclient.sh
#   SLOPDESK_PANE_FANOUT=1 bash scripts/check-multiclient.sh   # + the PTY fan-out assertion (step 7b)
#
# EXIT: non-zero if a build fails, a client dies, either client never opens a workspace channel, the
# two projections ever disagree, a gesture never lands, or the shell count does not match the layout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-macOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
WORK="${REPO_ROOT}/.work/multiclient-verify"
DD="${WORK}/DD"
APP="${DD}/Build/Products/Debug/SlopDesk.app"
APP_BIN="${APP}/Contents/MacOS/SlopDesk"
CLI="${REPO_ROOT}/.build/debug/slopdesk"
HOSTD_LOG="${WORK}/hostd.log"
CONNECT_PORT=47422 # 47420 is check-macos.sh, 47421 is check-video.sh

# The client-control sockets. AF_UNIX paths are capped at ~104 bytes and `${WORK}` is already long,
# so these live in /tmp keyed by THIS script's pid — short, unique per run, removed on the way out.
SOCK_A="/tmp/slopdesk-mc-$$-a.sock"
SOCK_B="/tmp/slopdesk-mc-$$-b.sock"

# The daemon's throwaway `<Application Support>/SlopDesk`, and the throwaway `UserDefaults` suite the
# two client instances share. Fresh per run; the suite is removed by the cleanup trap.
#
# HOME covers neither. It does not move Application Support and does not move `NSHomeDirectory()` —
# Core Foundation reads the account record unless `CFFIXED_USER_HOME` is set — so a hostd given HOME
# alone still sweeps the developer's scrollback journals (`keepNewest: 256`, on its first loop
# iteration) and still resolves `~/Downloads` as its file-drop directory. `CFFIXED_USER_HOME` would
# fix the paths and break the daemon: it also relocates the home its panes take their default cwd
# from, and pointing a hostd at one made check-launch-restore.sh flake three runs in five.
HOSTD_STATE="${WORK}/hostd-state"
DEFAULTS_SUITE="slopdesk.gate.multiclient.$$"

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

# `SLOPDESK_PANE_FANOUT` is `== "1"`, default-OFF, and stays that way. With it unset the two clients
# CANNOT hold one pane's PTY — which is fine, because LAYOUT convergence is the Phase 5b claim. Step
# 7b is the separate assertion for the flag-ON shape, and it is skipped when the flag is unset.
FANOUT="${SLOPDESK_PANE_FANOUT:-}"

APP_PROC_PAT="multiclient-verify/DD.*MacOS/SlopDesk"
HOSTD_PID=""
PID_A=""
PID_B=""

mkdir -p "${WORK}"

# SIGTERM, then VERIFY, then SIGKILL — the check-video.sh discipline. A gate that leaves a daemon
# holding :47422 costs the next run its bind.
REAP_PATIENCE=16
reap() {
  local pid="$1" name="$2"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2> /dev/null || return 0
  for _ in $(seq 1 "${REAP_PATIENCE}"); do
    kill -0 "${pid}" 2> /dev/null || return 0
    sleep 0.5
  done
  echo "==> ${name} (pid ${pid}) did not stop on SIGTERM — SIGKILL" >&2
  kill -9 "${pid}" 2> /dev/null || true
}

cleanup() {
  pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
  reap "${HOSTD_PID}" slopdesk-hostd
  rm -f "${SOCK_A}" "${SOCK_B}"
  # Both instances are killed, so neither runs its own `atexit` suite cleanup — this is the one that
  # does. Left undone it is a per-run plist in the developer's ~/Library/Preferences.
  remove_defaults_suite
}
# INT/TERM as well as EXIT: a bash EXIT trap does not run for an untrapped signal, so a Ctrl-C would
# otherwise strand the daemon and both app instances.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Dumps a log to stderr, or says it is missing. `2> /dev/null >&2` would be the obvious spelling and
# is WRONG: redirections apply left to right, so fd2 is already /dev/null by the time `>&2` clones
# it, and the dump goes nowhere. The first red run of this gate printed three empty sections.
dump() {
  local label="$1" path="$2" lines="${3:-0}"
  echo "--- ${label} ---" >&2
  if [[ ! -s "${path}" ]]; then
    echo "(empty or missing: ${path})" >&2
    return 0
  fi
  if [[ "${lines}" -gt 0 ]]; then tail -"${lines}" "${path}" >&2; else cat "${path}" >&2; fi
}

# Every failure path dumps the same evidence, so a red run never needs a second one to diagnose.
fatal() {
  echo "==> FAIL: $*" >&2
  dump "hostd log" "${HOSTD_LOG}"
  dump "client A stderr" "${WORK}/client-A.log" 40
  dump "client B stderr" "${WORK}/client-B.log" 40
  exit 1
}

# ── 0. The topology signature ───────────────────────────────────────────────────────────────────
# One canonical, order-preserving string per client, built from what THAT client says it is
# rendering. Order is kept (tab order and DFS pane order ARE the layout); the liveness/device fields
# are dropped for the reason in the header.
signature() {
  local socket="$1"
  {
    "${CLI}" --socket "${socket}" windows --json
    "${CLI}" --socket "${socket}" tabs --json
    "${CLI}" --socket "${socket}" panes --json
  } | python3 -c '
import json, sys
raw = sys.stdin.read()
# Three concatenated JSON arrays, one per verb, in the order emitted above.
decoder, index, docs = json.JSONDecoder(), 0, []
while index < len(raw):
    while index < len(raw) and raw[index].isspace():
        index += 1
    if index >= len(raw):
        break
    value, index = decoder.raw_decode(raw, index)
    docs.append(value)
if len(docs) != 3:
    sys.exit("expected 3 JSON documents, got %d" % len(docs))
windows, tabs, panes = docs
out = []
for w in windows:
    out.append("window %s tabs=%d" % (w["id"], w["tabCount"]))
for t in tabs:
    out.append("tab %s window=%s panes=%d" % (t["id"], t["windowId"], t["paneCount"]))
for p in panes:
    out.append("pane %s tab=%s kind=%s" % (p["id"], p["tabId"], p["kind"]))
print("\n".join(out))
'
}

# Counts lines of a given kind in a signature — the structural predicate each gesture waits on, so
# "both clients still show the OLD layout" can never satisfy a convergence check.
count_of() { grep -c "^$1 " <<< "$2" 2> /dev/null || true; }

# Counts accepted workspace channels in the hostd log. Matched on the ACCEPT word specifically: hostd
# prefixes its refusals and errors on that channel with `workspace channel …` too, so a substring
# match would report success for a channel it turned away (the trap check-video.sh documents).
accepted_channels() { grep -c 'workspace channel .* accepted' "${HOSTD_LOG}" 2> /dev/null || true; }
# Re-read on every poll — a `$(…)` in an `await` argument list would be expanded once, before the
# first attempt, and then compared against itself forever.
channels_are() { [[ "$(accepted_channels)" == "$1" ]]; }

# Polls a condition on a bounded deadline. Every wait in this gate is a real observable — a bare
# `sleep` long enough to "usually" work is how a gate starts passing for the wrong reason.
await() {
  local what="$1" tries="$2"
  shift 2
  for _ in $(seq 1 "${tries}"); do
    if "$@"; then return 0; fi
    sleep 0.5
  done
  fatal "timed out waiting for ${what}"
}

# Waits until BOTH clients report the same signature AND it carries the expected counts.
# Fatal on timeout, printing both signatures — the whole point of the gate is what they disagree on.
converge() {
  local what="$1" want_tabs="$2" want_panes="$3"
  local sig_a="" sig_b=""
  for _ in $(seq 1 40); do
    sig_a="$(signature "${SOCK_A}" 2> /dev/null || true)"
    sig_b="$(signature "${SOCK_B}" 2> /dev/null || true)"
    if [[ -n "${sig_a}" && "${sig_a}" == "${sig_b}" ]] &&
      [[ "$(count_of tab "${sig_a}")" == "${want_tabs}" ]] &&
      [[ "$(count_of pane "${sig_a}")" == "${want_panes}" ]]; then
      echo "==> ${what}: both clients project ${want_tabs} tab(s) / ${want_panes} pane(s), identically ✅"
      return 0
    fi
    sleep 0.5
  done
  echo "==> client A projects:" >&2
  awk '{ print "    " $0 }' <<< "${sig_a}" >&2
  echo "==> client B projects:" >&2
  awk '{ print "    " $0 }' <<< "${sig_b}" >&2
  fatal "${what}: the two clients did not converge on ${want_tabs} tab(s) / ${want_panes} pane(s)."
}

# ── 1. Build ────────────────────────────────────────────────────────────────────────────────────
echo "==> building slopdesk-hostd + the slopdesk client CLI"
(cd "${REPO_ROOT}" && swift build --product slopdesk-hostd > /dev/null)
(cd "${REPO_ROOT}" && swift build --product slopdesk > /dev/null)
echo "==> generating + building SlopDesk.app (Debug, unsigned)"
xcodegen generate --spec "${SPEC}" > /dev/null
xcodebuild -project "${PROJECT}" -scheme ClientApp-macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "${DD}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > /dev/null
echo "==> build OK: ${APP}"

# ── 2. One host daemon, with a workspace of its own ─────────────────────────────────────────────
# FRESH state dir per run, for correctness as much as hygiene: `adoptWorkspace` answers
# `rejectedStale` against a host that already has a workspace, so a reused dir would leave client A's
# adopt refused too and the gate would be proving something else entirely. The throwaway HOME keeps
# the spawned shells out of the developer's real shell history — and ONLY that; the container above
# is what keeps this daemon out of their Application Support.
pkill -f "slopdesk-hostd --port ${CONNECT_PORT}" 2> /dev/null || true
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK_A}" "${SOCK_B}"
sleep 0.5
if [[ -z "${WORK}" ]]; then
  echo "==> FAIL: WORK is empty — refusing to run a daemon against an unpinned state dir" >&2
  exit 1
fi
HOSTD_HOME="${WORK}/hostd-home"
HOSTD_WORKSPACE="${WORK}/hostd-workspace"
rm -rf "${HOSTD_WORKSPACE}" "${HOSTD_STATE}"
mkdir -p "${HOSTD_HOME}" "${HOSTD_WORKSPACE}" "${HOSTD_STATE}/scrollback" "${HOSTD_STATE}/drop"
echo "==> starting slopdesk-hostd on 127.0.0.1:${CONNECT_PORT}"
HOME="${HOSTD_HOME}" SLOPDESK_APP_SUPPORT_DIR="${HOSTD_STATE}" \
  SLOPDESK_SCROLLBACK_DIR="${HOSTD_STATE}/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${HOSTD_STATE}/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
  SLOPDESK_PANE_FANOUT="${FANOUT}" \
  "${REPO_ROOT}/.build/debug/slopdesk-hostd" \
  --port "${CONNECT_PORT}" --shell /bin/sh > "${HOSTD_LOG}" 2>&1 &
HOSTD_PID=$!
await "slopdesk-hostd to bind :${CONNECT_PORT}" 20 \
  grep -q "listening on .*:${CONNECT_PORT}" "${HOSTD_LOG}"
kill -0 "${HOSTD_PID}" 2> /dev/null || fatal "slopdesk-hostd did not stay up"
echo "==> hostd up (pid ${HOSTD_PID})"

# ── 3. Two client instances, one machine ────────────────────────────────────────────────────────
# The gates exec the bundle binary DIRECTLY (LaunchServices forwards no environment, and every seam
# here is a `SLOPDESK_*` env var), which is also what lets two instances of one app coexist.
#   - `CFFIXED_USER_HOME` gives each its own `NSHomeDirectory()`/Application Support container, so
#     the two do not share `workspace-cache.json` / `device-prefs.json`. It does NOT redirect
#     `UserDefaults` — both instances read one Defaults domain, which is why nothing here depends on
#     a per-instance default.
#   - `SLOPDESK_DEFAULTS_SUITE` makes that one domain a THROWAWAY one rather than the developer's.
#     Shared between the two instances on purpose: the pair are meant to agree, and the thing being
#     kept out is the developer's own `connection.recentTargets`, which both would otherwise write
#     `127.0.0.1:47422` into on connect.
#   - `SLOPDESK_CLIENT_SOCKET` is how step 5 onwards addresses each instance INDEPENDENTLY.
#   - `-ApplePersistenceIgnoreState YES` is load-bearing exactly as in check-macos.sh /
#     check-video.sh: without it AppKit comes up with ZERO windows and every scene `.task` — the
#     auto-connect, the workspace channel — silently never runs.
# An empty defaults domain is a FRESH INSTALL. The autoconnect env makes
# `hasAutomationEnvironment()` true, so `FirstLaunchModel.shouldPresent` is false here whatever the
# flag says — seeded anyway, so no gate depends on which env var happens to suppress the welcome
# sheet today. The delete first, in case a killed run left the suite behind.
remove_defaults_suite
defaults write "${DEFAULTS_SUITE}" firstLaunch.completed -bool YES

launch_client() {
  local name="$1" socket="$2" container="${WORK}/client-$1"
  rm -rf "${container}"
  mkdir -p "${container}"
  CFFIXED_USER_HOME="${container}" HOME="${container}" \
    SLOPDESK_DEFAULTS_SUITE="${DEFAULTS_SUITE}" \
    SLOPDESK_CLIENT_SOCKET="${socket}" \
    SLOPDESK_AUTOCONNECT_HOST=127.0.0.1 SLOPDESK_AUTOCONNECT_PORT="${CONNECT_PORT}" \
    SLOPDESK_PANE_FANOUT="${FANOUT}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES > "${WORK}/client-${name}.log" 2>&1 &
  echo "$!"
}

# Waits for an instance to answer on its control socket — the app is up AND its scene has mounted.
await_client() {
  local name="$1" socket="$2" pid="$3"
  for _ in $(seq 1 40); do
    kill -0 "${pid}" 2> /dev/null || fatal "client ${name} (pid ${pid}) died during launch"
    if "${CLI}" --socket "${socket}" windows --json > /dev/null 2>&1; then
      echo "==> client ${name} up (pid ${pid}), answering on ${socket} ✅"
      return 0
    fi
    sleep 0.5
  done
  fatal "client ${name} never answered on its control socket ${socket}"
}

echo "==> launching client A"
PID_A="$(launch_client A "${SOCK_A}")"
await_client A "${SOCK_A}" "${PID_A}"
# A first, and its DOCUMENT CHANNEL live, before B exists at all. That ordering is what puts A's
# `adoptWorkspace` in front of B's: the client stages the adopt as soon as its channel goes live, the
# host serialises intents on one actor, and at this instant B has no connection to race with. So A's
# layout is the one the host keeps, and B arrives at a host that already has one — the real
# second-device shape, and the case where the refusal path has to work. Waited on the host's own
# accept line rather than a settle long enough to usually work.
await "client A's workspace document channel" 40 channels_are 1
echo "==> launching client B"
PID_B="$(launch_client B "${SOCK_B}")"
await_client B "${SOCK_B}" "${PID_B}"

# ── 4. Both opened a workspace-document channel ─────────────────────────────────────────────────
echo "==> waiting for TWO workspace document channels on :${CONNECT_PORT}…"
for _ in $(seq 1 40); do
  if channels_are 2; then break; fi
  sleep 0.5
done
[[ "$(accepted_channels)" == "2" ]] ||
  fatal "expected 2 accepted workspace channels (one per client); saw $(accepted_channels)"
echo "==> both clients hold a workspace document channel (channelClass 1) ✅"

# ── 5. Baseline: the second client gave up its OWN layout ───────────────────────────────────────
# B launched with the same automation bootstrap as A, so it minted its own session/tab/pane and
# mounted them before any document existed. Its `adoptWorkspace` then met a host that already had
# one and came back `rejectedStale`. Agreeing here means B threw its own ids away and took A's —
# convergence from two DIFFERENT starting layouts, which is a stronger claim than starting empty.
converge "baseline" 1 1

# ── 6. The gesture path ─────────────────────────────────────────────────────────────────────────
# A real menu click on client A, addressed by unix id so the two same-named processes stay distinct.
# The menu bar belongs to the FRONTMOST app, so the raise has to have landed before the click — waited
# on, not slept through: an app that is still coming forward has the other instance's menu bar, and
# the click would drive the wrong client.
is_frontmost() {
  [[ "$(osascript -e "tell application \"System Events\" to get frontmost of \
    (first process whose unix id is $1)" 2> /dev/null || true)" == "true" ]]
}
click_menu() {
  local pid="$1" menu="$2" item="$3"
  osascript -e "tell application \"System Events\" to set frontmost of \
    (first process whose unix id is ${pid}) to true" > /dev/null 2>&1 ||
    fatal "cannot raise pid ${pid} via System Events. This gate drives a REAL menu gesture, so the
    terminal running it needs Accessibility TCC (System Settings ▸ Privacy & Security ▸ Accessibility)."
  await "pid ${pid} to become frontmost" 20 is_frontmost "${pid}"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid}) to \
    click (first menu item of menu 1 of menu bar item \"${menu}\" of menu bar 1 \
    whose name starts with \"${item}\")" > /dev/null 2>&1 ||
    fatal "the '${menu} ▸ ${item}' menu item did not click on pid ${pid} — either the menu lost the
    item, or this terminal lacks Accessibility TCC."
  echo "==> clicked '${menu} ▸ ${item}' on pid ${pid}"
}

# 6a. A SPLIT: a pane that only client A's gesture could have created must appear in B's projection.
click_menu "${PID_A}" Panes "Split Right"
converge "after A splits" 1 2

# 6b. A NEW TAB: a whole tab object, minted client-side and accepted by the host.
click_menu "${PID_A}" Tabs "New Tab"
converge "after A opens a tab" 2 3

# 6c. A CLOSE: convergence has to work in the REMOVING direction too. A close is the op that has to
# agree on a successor as well as on the set (docs/45 §Phase 5b, the shared MRU ring).
click_menu "${PID_A}" Tabs "Close Tab"
converge "after A closes that tab" 1 2

# ── 7. N panes ⇒ N shells ───────────────────────────────────────────────────────────────────────
# The layout says two panes; the host must be running exactly two shells. Counted as LIVE children
# of the daemon rather than as log lines: the cumulative `shell … attached` count also includes the
# pane B minted at launch and the pane the closed tab took with it, both of which were reaped — a
# leak is a shell that is still THERE.
#
# A BARE CHILD COUNT IS WRONG, and the same count in check-launch-restore.sh made that gate flaky
# (2 of 8 runs red on a clean tree, 3 of 3 under an FSEvents burst). hostd forks non-PTY helpers as
# well as shells — `TerminfoResolver` runs `/usr/bin/infocmp`, `HostMetadataProbe` runs
# `/usr/bin/git` and `/usr/sbin/lsof`, `ShellIntegration` probes `$ZDOTDIR` with a `--norcs` zsh —
# and each is a child of hostd for as long as it lives. `${WORK}` is under this repo, so the
# daemon's HOME is too, so a pane's project key resolves to slop-desk itself and every write this
# gate makes to its own logs arms `RepoStatusWatcher`'s debounced `git` probe. A settle cannot help:
# the helper is TRANSIENT, so a count that catches one is red for a reason no amount of waiting
# addresses, and the next read shows the right number under a message announcing the wrong one.
#
# The discriminator is what `PTYProcess` does and `Foundation.Process` does not: the shell is forked
# with `login_tty(slave)`, i.e. `setsid()`, so it is a SESSION LEADER — `getsid(pid) == pid`. A
# `Process()` child is given its own process GROUP but stays in hostd's session, so it is not.
#
# REACHED, then HELD — never a single read the instant `converge` returns. The settle covers ONE
# thing: the host kills a reaped pane's PTY child before it broadcasts the diff `converge` waits on,
# so `pgrep` can still see a child the kernel has not collected yet. That is milliseconds, not a
# round trip, and the budget is sized for a loaded machine rather than for a churn — a re-dial is
# caught by 7a below, which no amount of waiting can satisfy. The hold afterwards is the other half:
# a shell that appears LATE must not slip in behind the assertion.
LIVE_SHELL_SETTLE=8 # ×0.5 s
LIVE_SHELL_HOLD=6   # ×1 s
# ONE census of hostd's live children, as `<pid> pty` / `<pid> helper` lines (see above).
#
# `|| true` around `pgrep`: it exits 1 when it matches NOTHING, and under `set -euo pipefail` that
# would kill the script on the one observation worth printing — "the host has no shells at all".
hostd_children() {
  { pgrep -P "${HOSTD_PID}" || true; } | python3 -c '
import os, sys
for line in sys.stdin:
    pid = int(line)
    try:
        leader = os.getsid(pid) == pid
    except OSError:
        continue  # exited between the pgrep and the getsid — not live
    print(pid, "pty" if leader else "helper")
'
}
shells_in() { awk '$2 == "pty"' <<< "$1" | grep -c . || true; }
live_shells() { shells_in "$(hostd_children)"; }
FINAL_SIG="$(signature "${SOCK_A}" 2> /dev/null || true)"
PANE_COUNT="$(count_of pane "${FINAL_SIG}")"
# Takes the SAMPLE that went red, never a fresh read: a helper lives for tens of milliseconds, so a
# re-read prints a different set of children than the one the count was made from.
shell_census_failed() {
  echo "--- the children of hostd this census read (pty = a shell, helper = git/lsof/infocmp/…) ---" >&2
  local pid kind
  while read -r pid kind; do
    [[ -n "${pid}" ]] || continue
    echo "    ${pid} ${kind} $(ps -o command= -p "${pid}" 2> /dev/null || true)" >&2
  done <<< "$2"
  fatal "the layout has ${PANE_COUNT} pane(s) but the host is running $(shells_in "$2") shell(s) $1"
}
for _ in $(seq 1 "${LIVE_SHELL_SETTLE}"); do
  [[ "$(live_shells)" != "${PANE_COUNT}" ]] || break
  sleep 0.5
done
CENSUS="$(hostd_children)"
[[ "$(shells_in "${CENSUS}")" == "${PANE_COUNT}" ]] ||
  shell_census_failed "and stayed there for $((LIVE_SHELL_SETTLE / 2))s — that is a leak, not a churn" \
    "${CENSUS}"
for second in $(seq 1 "${LIVE_SHELL_HOLD}"); do
  sleep 1
  CENSUS="$(hostd_children)"
  [[ "$(shells_in "${CENSUS}")" == "${PANE_COUNT}" ]] ||
    shell_census_failed "${second}s after the counts matched — a pane was re-dialled behind the check" \
      "${CENSUS}"
done
echo "==> ${PANE_COUNT} pane(s) in the layout, ${PANE_COUNT} live shell(s) on the host, held ${LIVE_SHELL_HOLD}s ✅"

# 7a. ONE pane, ONE shell, EVER — the assertion a churn cannot outlive.
#
# The census above counts what is ALIVE, so anything that spawns and dies inside the settle is
# invisible to it. That is exactly the shape of the bug this run exists to keep closed: with
# `SLOPDESK_PANE_FANOUT=1` the tab close made client B re-dial the dying pane in the window between
# the host's `channelClose` and the document diff removing it, and a pane channel naming a session
# the host no longer has is a SPAWN — a whole login shell, rc files and all, for a pane the user had
# just closed (docs/DECISIONS.md, "A pane the host retired is not re-dialled"). It was transient, so
# a live count could only ever be told to wait it out.
#
# `attached for pane <uuid>` is the host's own line for MINTING a shell, one per pane per lifetime;
# a second client fanning onto the same pane logs `joined live session … as subscriber` instead. So
# the same uuid appearing twice is a second shell for one pane, it is written down permanently, and
# no settle can make it go away. Asserted in BOTH modes: with the flag off the re-dial has no
# channel to happen on, which is a fact worth pinning rather than assuming.
DOUBLE_ATTACHED="$(awk '/attached for pane /{ print $NF }' "${HOSTD_LOG}" | sort | uniq -d)"
if [[ -n "${DOUBLE_ATTACHED}" ]]; then
  echo "--- panes the host minted a shell for more than once ---" >&2
  grep 'attached for pane ' "${HOSTD_LOG}" >&2 || true
  fatal "$(wc -l <<< "${DOUBLE_ATTACHED}" | tr -d ' ') pane(s) got a SECOND shell — a pane was
    re-dialled after the host retired its channel: ${DOUBLE_ATTACHED//$'\n'/ }"
fi
ATTACH_LINES="$(grep -c 'attached for pane ' "${HOSTD_LOG}" 2> /dev/null || true)"
echo "==> ${ATTACH_LINES} shell mint(s), no pane minted twice ✅"

# 7b. PTY fan-out — a SEPARATE claim, only when the flag asked for it.
#
# Asserted POSITIVELY, per pane. "No `attachedElsewhere` refusals" alone is satisfiable by a second
# client that never tried to attach at all, which is the reading a flag-ON gate must not accept — so
# every pane in the FINAL layout has to appear in a `joined live session … as subscriber` line, and
# only then does the absence of refusals mean anything.
if [[ "${FANOUT}" == "1" ]]; then
  while read -r pane_id; do
    grep -q "joined live session ${pane_id} as subscriber" "${HOSTD_LOG}" ||
      fatal "SLOPDESK_PANE_FANOUT=1 but no second subscriber ever joined pane ${pane_id} — the
    flag-ON JOIN route did not run for it"
  done < <(awk '/^pane /{ print $2 }' <<< "${FINAL_SIG}")
  REFUSALS="$(grep -c 'already attached on another connection' "${HOSTD_LOG}" 2> /dev/null || true)"
  [[ "${REFUSALS}" == "0" ]] ||
    fatal "SLOPDESK_PANE_FANOUT=1 but the host still refused ${REFUSALS} pane attach(es) as
    attachedElsewhere"
  echo "==> fan-out ON: all ${PANE_COUNT} pane(s) took a second subscriber, 0 refusals ✅"
else
  echo "==> fan-out OFF (default): B holds no PTY, which is expected — layout is the claim here."
fi

# ── 8. The picture a human reads ────────────────────────────────────────────────────────────────
# Side by side in one frame, plus one full-screen grab per client with that client raised, so the
# proof survives a window arrangement that did not take.
SCREEN_W="$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2> /dev/null || true)"
# Guarded rather than trusted: Finder scripting is a separate TCC grant, and an unparseable answer
# must not take the arithmetic (and with it the whole gate) down after every assertion has passed.
[[ "${SCREEN_W}" =~ ^[0-9]+$ ]] || SCREEN_W=1920
HALF="$((SCREEN_W / 2 - 30))"
if [[ "${HALF}" -lt 600 ]]; then HALF=600; fi
X=20
for pid in "${PID_A}" "${PID_B}"; do
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid}) to \
    set position of window 1 to {${X}, 60}" > /dev/null 2>&1 || true
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid}) to \
    set size of window 1 to {${HALF}, 760}" > /dev/null 2>&1 || true
  X=$((X + HALF + 20))
done
sleep 1
screencapture -x "${WORK}/both-clients.png"
for entry in "A:${PID_A}" "B:${PID_B}"; do
  osascript -e "tell application \"System Events\" to set frontmost of \
    (first process whose unix id is ${entry#*:}) to true" > /dev/null 2>&1 || true
  sleep 0.8
  screencapture -x "${WORK}/client-${entry%%:*}.png"
done

echo
echo "================================================================================"
echo " DONE — the two-client claim is ASSERTED above, not eyeballed. What is left is the picture."
echo " Read:  ${WORK}/both-clients.png     (both windows, side by side)"
echo "        ${WORK}/client-A.png         (A raised)"
echo "        ${WORK}/client-B.png         (B raised)"
echo " PASS = both windows show the SAME tab rail and the SAME split — one layout, two clients."
echo " hostd log:  ${HOSTD_LOG}"
echo "================================================================================"
