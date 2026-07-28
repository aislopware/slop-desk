#!/usr/bin/env bash
#
# check-launch-restore.sh — the launch a USER performs, which no other gate can reach.
#
# WHY this exists: `check-macos.sh --connect`, `check-video.sh` and `check-multiclient.sh` all set
# `SLOPDESK_AUTOCONNECT_HOST` (or its video twin), so `SlopDeskClientApp.hasAutomationEnvironment()`
# is true in all three and the app takes the AUTOMATION branch at launch — `persistence` is nil (no
# `workspace.json` is read or written), `bootstrapFromEnvironment()` REPLACES the layout with a lone
# synthetic terminal, `pendingLaunchAdopt` is cleared, and the auto-reconnect task is skipped in
# favour of `connection.connect()`. Every one of those is the opposite of what a real launch does.
#
# So the shipping launch — restore the saved tree from disk, offer it to the host, silently
# re-connect to the MRU host — has never had a gate. The commit that fixed its first-connect churn
# (`8ce5a7cb`, "a first connect keeps the shells it already dialled") said so in its own message:
# "the launch-adopt path itself is proven headlessly only: no gate can reach it, because both force
# the automation bootstrap." That bug blanked every restored terminal on first connect and left a
# PTY running on the host with nobody attached. This gate is what would have caught it.
#
# WHAT IT PROVES on success:
#   PHASE A — cold launch against a PRISTINE host:
#     - the client restores `scripts/fixtures/launch-restore-workspace.json` (2 tabs, 3 panes) and
#       PROJECTS it: the pane ids it renders are the fixture's own ids, not replacements,
#     - the host spawns exactly one shell per restored pane — three shells for three panes, each
#       attached for the pane id the fixture names,
#     - and it STAYS that way: the counts are re-checked every second for a full watch window, so a
#       churn one turn wide (materialize → host frame lands → tear down → re-materialize) cannot
#       hide behind a settle,
#     - the layout the app then autosaves still carries those same pane ids.
#   PHASE B — relaunch against the SAME host, which is now NON-pristine:
#     - the client's `adoptWorkspace` is refused as stale and it projects host truth, which is the
#       same layout with the same ids,
#     - and the three shells are REATTACHED, not respawned: zero new `attached for pane` lines and
#       the very same PTY pids as phase A. A relaunch that respawns is a relaunch that abandoned
#       three agents mid-run.
#   PHASE C — relaunch with a layout whose pane ids DIVERGE from host truth:
#     The case phases A and B cannot reach, because in both of them the client and the host agree on
#     the ids. A client's `workspace.json` can name panes this host has never heard of — a schema
#     bump that decode-fails to the default, a layout restored from a backup, the same client meeting
#     a second host. The client shows that layout optimistically, offers it, and is refused.
#     - the client must project HOST truth (the same signature phases A and B assert), and
#     - the host must spawn NOTHING for the divergent ids. Not "the fixture's panes were not
#       respawned" — the whole log's `attached for pane` count must still be three. Measured before
#       the launch dial hold: three panes on screen, SIX shells, three of them abandoned. Every one
#       of those runs a real login shell — rc files, Starship, agent `SessionStart` hooks — before
#       it is killed.
#
# HOW IT REACHES THE SHIPPING PATH WITH NO NEW CLIENT SEAM — the design constraint, decided out loud:
#   The temptation is an env pair that seeds a layout and fires the reconnect. That would be a second
#   automation bootstrap, and the whole point of this gate is that it drives the path a user drives.
#   Everything below is a FIXTURE — state a returning user already has — placed where the shipping
#   code already looks for it:
#     - the LAYOUT is a `workspace.json` in the client's own Application Support dir, which
#       `CFFIXED_USER_HOME` redirects per instance (`WorkspacePersistence.defaultFileURL`),
#     - the SAVED HOST is `connection.recentTargets` in the ARGUMENT DOMAIN. Cocoa parses `-key value`
#       argv pairs into `NSArgumentDomain`, which outranks the persistent domain, and an old-style
#       plist `<hex>` value arrives as `Data` — exactly what `AppConnection.loadRecentTargets` reads.
#       This is load-bearing for DETERMINISM, not convenience: `CFFIXED_USER_HOME` does NOT redirect
#       UserDefaults (cfprefsd resolves the real home), so the persistent MRU is shared with the
#       developer's own app and with the other three gates, which have each left a loopback entry in
#       it (47420, 47421, 47422). Without the override this gate would dial whichever port ran last.
#     - `-hasCompletedFirstLaunch YES` is the same kind of fixture: a user with a saved layout AND a
#       saved host has by definition finished the first-launch sheet.
#   No `SLOPDESK_AUTOCONNECT_*` is set anywhere, so `hasAutomationEnvironment()` is FALSE and the app
#   runs `WorkspacePersistence.launchTree` + `connection.connectIfSavedTarget()` — the daily-driver
#   pair. That is also self-proving: under the automation branch the restored tree is replaced by a
#   ONE-pane shape, so the 3-pane assertion below can only pass on the restore path.
#
# THE FIXTURE is committed, generated by the real encoder, and pinned headlessly by
# `LaunchRestoreGateContractTests` — it is decoded there with the shipping `WorkspacePersistence` and
# asserted to be exactly 2 tabs / 3 terminal panes with these ids. A schema drift that made the file
# unreadable would otherwise show up here as a mystery 1-pane default; instead it goes red in
# `swift test`, where it can be read in seconds.
#
# SIDE EFFECT, stated rather than hidden: a successful connect pushes `127.0.0.1:47423` onto the
# developer's real `connection.recentTargets` (`AppConnection.recordRecentTarget` writes the
# persistent domain). The other three gates already do this with their own ports. It cannot affect
# THIS gate's reads — the argument domain outranks it — and it is why the override exists.
# Clipboard sync runs on this path (automation skips it): host and client are the same machine over
# loopback, so both ends read one pasteboard and the sync is a no-op on the developer's clipboard.
#
# ⚠️ MUST RUN FROM A REAL, UNLOCKED GUI LOGIN SESSION (Terminal.app/iTerm in your Aqua session): it
# opens an app window. It drives NO menus and needs no Accessibility TCC, and every claim is read off
# the client's control socket rather than off pixels — so Screen Recording TCC is optional too and
# the closing desktop grab is a bonus, not evidence.
#
# USAGE: bash scripts/check-launch-restore.sh
#
# EXIT: non-zero if a build fails, the client dies, it never answers its control socket, it projects
# anything but the restored layout, the shell count ever leaves the pane count, the autosaved layout
# loses the restored pane ids, a relaunch respawns a shell instead of reattaching, or a relaunch with
# divergent ids puts one of them on the wire.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-macOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
WORK="${REPO_ROOT}/.work/launch-restore-verify"
DD="${WORK}/DD"
APP="${DD}/Build/Products/Debug/SlopDesk.app"
APP_BIN="${APP}/Contents/MacOS/SlopDesk"
CLI="${REPO_ROOT}/.build/debug/slopdesk"
HOSTD_LOG="${WORK}/hostd.log"
FIXTURE="${REPO_ROOT}/scripts/fixtures/launch-restore-workspace.json"
CONNECT_PORT=47423 # 47420 check-macos.sh · 47421 check-video.sh · 47422 check-multiclient.sh

# AF_UNIX paths cap at ~104 bytes and `${WORK}` is already long — keyed by this script's pid, removed
# on the way out (the check-multiclient.sh discipline).
SOCK="/tmp/slopdesk-lr-$$.sock"

# The client's container. `CFFIXED_USER_HOME` redirects `NSHomeDirectory()`/Application Support, so
# the seeded `workspace.json`, the workspace cache and the device prefs are all this run's own — the
# developer's real workspace is never read and never written.
CONTAINER="${WORK}/client-home"
SEEDED_WORKSPACE="${CONTAINER}/Library/Application Support/SlopDesk/workspace.json"

# The watch window each phase holds the invariant for. A churn on this path is ONE TURN wide (a host
# frame lands, the projection drives the registry, the adopt lands a turn later), so it resolves in
# well under a second — but it is triggered by a wire round trip, and the point of watching rather
# than settling is that a late one cannot slip in behind the assertion.
WATCH_SECONDS=30

APP_PROC_PAT="launch-restore-verify/DD.*MacOS/SlopDesk"
HOSTD_PID=""
CLIENT_PID=""

mkdir -p "${WORK}"

# SIGTERM, then VERIFY, then SIGKILL. A gate that leaves a daemon holding :47423 costs the next run
# its bind.
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
  rm -f "${SOCK}"
}
# INT/TERM as well as EXIT: a bash EXIT trap does not run for an untrapped signal, so a Ctrl-C would
# otherwise strand the daemon and the app instance.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# `2> /dev/null >&2` would be the obvious spelling and is WRONG — redirections apply left to right,
# so fd2 is already /dev/null by the time `>&2` clones it (check-multiclient.sh's first red run
# printed three empty sections that way).
dump() {
  local label="$1" path="$2" lines="${3:-0}"
  echo "--- ${label} ---" >&2
  if [[ ! -s "${path}" ]]; then
    echo "(empty or missing: ${path})" >&2
    return 0
  fi
  if [[ "${lines}" -gt 0 ]]; then tail -"${lines}" "${path}" >&2; else cat "${path}" >&2; fi
}

fatal() {
  echo "==> FAIL: $*" >&2
  dump "hostd log" "${HOSTD_LOG}"
  dump "client stderr" "${WORK}/client.log" 40
  exit 1
}

await() {
  local what="$1" tries="$2"
  shift 2
  for _ in $(seq 1 "${tries}"); do
    if "$@"; then return 0; fi
    sleep 0.5
  done
  fatal "timed out waiting for ${what}"
}

# ── 0. What the fixture says the launch must restore ────────────────────────────────────────────
# Derived from the committed file, so the fixture is the ONE source of truth for the ids the
# assertions use — and then bounded by an explicit shape check below, so a fixture quietly reduced to
# a single default pane cannot leave this gate green by agreeing with itself.
[[ -f "${FIXTURE}" ]] || fatal "the committed layout fixture is missing: ${FIXTURE}"
FIXTURE_PANES="$(
  python3 - "${FIXTURE}" << 'PY'
import json, sys

def leaves(node):
    if "leaf" in node:
        return [node["leaf"]["raw"]]
    out = []
    for child in node["split"]["children"]:
        out += leaves(child["node"])
    return out

doc = json.load(open(sys.argv[1]))
ids = []
for session in doc["sessions"]:
    for tab in session["tabs"]:
        ids += leaves(tab["root"])
print("\n".join(ids))
PY
)" || fatal "the layout fixture ${FIXTURE} is not readable as a workspace tree"
FIXTURE_TABS="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(sum(len(s["tabs"]) for s in doc["sessions"]))
' "${FIXTURE}")" || fatal "the layout fixture ${FIXTURE} has no readable tab count"
# `|| true`: `grep -c` exits 1 on zero matches, which `set -e` would turn into a silent abort right
# before the check that exists to explain it.
PANE_COUNT="$(grep -c . <<< "${FIXTURE_PANES}" || true)"
# The shape this gate is ABOUT: more than one tab (so a pane in a tab the window is not showing must
# still get its shell) and more than one pane per tab (so a restored SPLIT must survive). Pinned here
# as well as in `LaunchRestoreGateContractTests` because a fixture is the easiest thing to weaken.
if [[ "${PANE_COUNT}" != "3" || "${FIXTURE_TABS}" != "2" ]]; then
  fatal "the layout fixture must be 3 panes across 2 tabs (a split plus a second tab); it is
    ${PANE_COUNT} pane(s) across ${FIXTURE_TABS} tab(s). Update this gate's assertions deliberately."
fi
echo "==> fixture: ${PANE_COUNT} panes across ${FIXTURE_TABS} tabs"

# ── 0b. The DIVERGENT layout phase C relaunches with ─────────────────────────────────────────────
# Derived from the committed fixture rather than committed alongside it, and that is deliberate: the
# claim is "the SAME shape under ids this host has never seen", so it must track the fixture
# automatically. A second checked-in file would be a second thing to keep in step, and the day it
# drifted this gate would go on passing while testing a different shape.
#
# Every UUID in the file is rewritten through a stable derivation (uuid5 of the original), so the run
# is reproducible; the disjointness of the two pane sets is then ASSERTED rather than assumed.
DIVERGENT="${WORK}/divergent-workspace.json"
python3 - "${FIXTURE}" "${DIVERGENT}" << 'PY' || fatal "could not derive the divergent layout"
import re, sys, uuid

NS = uuid.UUID("5D0D5DE5-0000-4000-8000-000000000001")
text = open(sys.argv[1]).read()
pattern = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
seen = {}
def rewrite(match):
    original = match.group(0)
    if original not in seen:
        seen[original] = str(uuid.uuid5(NS, original)).upper()
    return seen[original]
out = pattern.sub(rewrite, text)
if not seen:
    sys.exit("the fixture carries no UUIDs — nothing to diverge")
open(sys.argv[2], "w").write(out)
PY
DIVERGENT_PANES="$(
  python3 - "${DIVERGENT}" << 'PY'
import json, sys

def leaves(node):
    if "leaf" in node:
        return [node["leaf"]["raw"]]
    out = []
    for child in node["split"]["children"]:
        out += leaves(child["node"])
    return out

doc = json.load(open(sys.argv[1]))
ids = []
for session in doc["sessions"]:
    for tab in session["tabs"]:
        ids += leaves(tab["root"])
print("\n".join(sorted(ids)))
PY
)" || fatal "the derived divergent layout is not readable as a workspace tree"
# Self-check: a derivation that quietly produced the SAME ids would make phase C assert nothing.
if [[ -n "$(comm -12 <(sort <<< "${FIXTURE_PANES}") <(sort <<< "${DIVERGENT_PANES}"))" ]]; then
  fatal "the divergent layout shares a pane id with the fixture — phase C would test nothing"
fi
if [[ "$(grep -c . <<< "${DIVERGENT_PANES}" || true)" != "${PANE_COUNT}" ]]; then
  fatal "the divergent layout must have the same ${PANE_COUNT} panes as the fixture"
fi
echo "==> divergent layout derived: $(tr '\n' ' ' <<< "${DIVERGENT_PANES}")"

# ── The two observables ─────────────────────────────────────────────────────────────────────────
# What the CLIENT says it is rendering. The shipping client-control socket answers it off
# `WorkspaceStore.tree` — the projection of `workspaceMirror.topology`, the exact value the window
# paints — so no test seam is needed to read it. Pane ids SORTED: the claim is identity + membership,
# and DFS order is already pinned by the tab/pane counts on the lines above it.
signature() {
  {
    "${CLI}" --socket "${SOCK}" tabs --json
    "${CLI}" --socket "${SOCK}" panes --json
  } | python3 -c '
import json, sys
raw = sys.stdin.read()
decoder, index, docs = json.JSONDecoder(), 0, []
while index < len(raw):
    while index < len(raw) and raw[index].isspace():
        index += 1
    if index >= len(raw):
        break
    value, index = decoder.raw_decode(raw, index)
    docs.append(value)
if len(docs) != 2:
    sys.exit("expected 2 JSON documents, got %d" % len(docs))
tabs, panes = docs
out = ["tabs=%d" % len(tabs), "panes=%d" % len(panes)]
out += sorted("pane %s kind=%s" % (p["id"].upper(), p["kind"]) for p in panes)
print("\n".join(out))
'
}

# The signature the fixture demands — built once, compared against every sample.
WANT_SIG="$(
  {
    echo "tabs=${FIXTURE_TABS}"
    echo "panes=${PANE_COUNT}"
    while read -r pane; do echo "pane ${pane} kind=terminal"; done <<< "${FIXTURE_PANES}" | sort
  }
)"

# How many shells the host has spawned for the fixture's panes, in total. CUMULATIVE by design: a
# live-child count cannot see a pane that was materialized, dialled, torn down and re-dialled — the
# churn this gate exists to catch leaves the live count at 3 and the spawn count at 6.
spawned_shells() {
  local total=0 pane n
  while read -r pane; do
    n="$(grep -c "attached for pane ${pane}" "${HOSTD_LOG}" 2> /dev/null || true)"
    total=$((total + n))
  done <<< "${FIXTURE_PANES}"
  echo "${total}"
}
spawned_shells_are() { [[ "$(spawned_shells)" == "$1" ]]; }

# How many shells the host has spawned for ANY pane. Distinct from `spawned_shells` above, and phase
# C is the reason: a client dialling ids the host has never seen spawns a PTY per id, and every one
# of those is invisible to a per-fixture-pane count. This is the number that went to six.
total_spawned_shells() { grep -c "attached for pane" "${HOSTD_LOG}" 2> /dev/null || true; }

# Every fixture pane must have been reattached (phase B) — asserted per pane, positively. "No new
# spawns" alone is also satisfied by a client that never picked its panes back up at all.
reattached_all() {
  local pane
  while read -r pane; do
    grep -q "reattached session ${pane}" "${HOSTD_LOG}" || return 1
  done <<< "${FIXTURE_PANES}"
  return 0
}
# How many times the host has parked each fixture pane, as `<pane> <count>` lines. Snapshotted into
# `${DETACH_BASELINE}` immediately BEFORE a client is stopped, and compared against by
# `detached_all_since` immediately after.
#
# The baseline is the whole point. `${HOSTD_LOG}` is never truncated — the spawn counts above are
# CUMULATIVE by design — so a bare "has the host parked these?" is satisfied FOR EVER by the first
# phase's parking, and every later phase's wait returns on its first poll having proven nothing. A
# relaunch that then dials while the previous phase's sessions are still bound is answered `already
# attached on another connection`: the panes come up on screen with DEAD terminals, and not one
# assertion downstream can see it — they read the workspace document, which is host truth whether or
# not anything is attached to it, plus a live-PTY count the refusal leaves untouched.
detach_counts() {
  local pane
  while read -r pane; do
    echo "${pane} $(grep -c "detached session ${pane}" "${HOSTD_LOG}" 2> /dev/null || true)"
  done <<< "${FIXTURE_PANES}"
}

# Every fixture pane parked at least once MORE than `${DETACH_BASELINE}` recorded — i.e. the host has
# observed THIS phase's link go down, not some earlier one's.
detached_all_since() {
  local pane before now
  while read -r pane before; do
    now="$(grep -c "detached session ${pane}" "${HOSTD_LOG}" 2> /dev/null || true)"
    [[ "${now}" -gt "${before}" ]] || return 1
  done <<< "${DETACH_BASELINE}"
  return 0
}

projects_the_restored_layout() { [[ "$(signature 2> /dev/null || true)" == "${WANT_SIG}" ]]; }

# Whether the app has REPLACED the seeded `workspace.json` with one of its own (phase A). `.atomic`
# saves rename a fresh file into place, so a real autosave changes the inode as well as the mtime —
# an observation that stays honest even if the fixture is one day regenerated from the app's own
# encoder and the two files' BYTES coincide.
autosave_replaced_the_seed() { [[ "$(file_stamp "${SEEDED_WORKSPACE}")" != "${SEEDED_STAMP}" ]]; }

# Whether the autosaved layout has become HOST TRUTH (phase C). Content alone is the whole verdict
# here, and it cannot be tautological the way phase A's is: this file was seeded with the DIVERGENT
# ids, so naming the fixture's three and none of the divergent three is a state only the app can have
# written. A client that shows host truth but keeps offering its refused layout from disk relaunches
# into the same refusal for ever.
autosaved_host_truth() {
  local pane
  while read -r pane; do
    grep -qi "${pane}" "${SEEDED_WORKSPACE}" || return 1
  done <<< "${FIXTURE_PANES}"
  while read -r pane; do
    if grep -qi "${pane}" "${SEEDED_WORKSPACE}"; then return 1; fi
  done <<< "${DIVERGENT_PANES}"
  return 0
}

# Waits for exactly one shell per restored pane, and on timeout says what the host actually DID.
# The interesting failure here is an OVERSHOOT, not an absence: a restored pane that is torn down and
# re-dialled gets a SECOND shell while the first is abandoned, and a bare "timed out" cannot tell that
# apart from a client that never connected. Proven by the revert-to-fail run: with the launch-adopt
# hold removed, pane 3333… was attached twice and this is the check that saw it.
await_spawns() {
  local want="$1" tries="$2" pane
  for _ in $(seq 1 "${tries}"); do
    if spawned_shells_are "${want}"; then return 0; fi
    kill -0 "${CLIENT_PID}" 2> /dev/null || fatal "the client died before its panes had shells"
    sleep 0.5
  done
  echo "==> shells the host spawned, per restored pane:" >&2
  while read -r pane; do
    echo "    ${pane}: $(grep -c "attached for pane ${pane}" "${HOSTD_LOG}" 2> /dev/null || true)" >&2
  done <<< "${FIXTURE_PANES}"
  fatal "the host must spawn exactly ${want} shell(s), one per restored pane; it spawned
    $(spawned_shells). More than one for a pane means that pane was torn down and re-dialled — the
    first PTY left running on the host with nobody attached."
}

# Waits for the projection, and on timeout says WHAT it saw instead. A bare `await` here would report
# only "timed out", which is the least useful sentence available: every interesting failure on this
# path — the host's default pane projected instead, a fourth pane, panes with fresh ids — arrives as
# a signature that is simply not this one.
await_projection() {
  local what="$1" tries="$2"
  for _ in $(seq 1 "${tries}"); do
    if projects_the_restored_layout; then return 0; fi
    kill -0 "${CLIENT_PID}" 2> /dev/null || fatal "${what}: the client died before it projected anything"
    sleep 0.5
  done
  echo "==> the client projects:" >&2
  awk '{ print "    " $0 }' <<< "$(signature 2> /dev/null || true)" >&2
  echo "==> the restored layout is:" >&2
  awk '{ print "    " $0 }' <<< "${WANT_SIG}" >&2
  fatal "${what}"
}

# Holds the whole claim steady for `WATCH_SECONDS`, re-reading everything each second. This is the
# assertion that a settle-then-check cannot make: the defect class here is a REPLACEMENT that lands a
# wire round trip after the panes are already up and looking right.
hold_steady() {
  local label="$1" want="$2" sig second spawns total live
  for second in $(seq 1 "${WATCH_SECONDS}"); do
    sig="$(signature 2> /dev/null || true)"
    if [[ "${sig}" != "${WANT_SIG}" ]]; then
      echo "==> at second ${second} the client projects:" >&2
      awk '{ print "    " $0 }' <<< "${sig}" >&2
      echo "==> the restored layout is:" >&2
      awk '{ print "    " $0 }' <<< "${WANT_SIG}" >&2
      fatal "${label}: the projection left the restored layout ${second}s in"
    fi
    # Read ONCE per sample: interpolating the helper twice into one message can print two different
    # numbers for one observation, which reads as a gate that cannot count.
    spawns="$(spawned_shells)"
    if [[ "${spawns}" != "${want}" ]]; then
      fatal "${label}: the host had spawned ${want} shell(s) for these panes and now has ${spawns} —
    a restored pane was torn down and re-dialled ${second}s in, abandoning its PTY"
    fi
    # …and the count over EVERY pane id, which is a strictly stronger claim: a shell spawned for an
    # id that is not one of the fixture's is invisible to the line above, and that is exactly what a
    # divergent-id launch produces (phase C).
    total="$(total_spawned_shells)"
    if [[ "${total}" != "${want}" ]]; then
      echo "==> every pane the host has spawned for:" >&2
      grep -o "attached for pane [0-9A-Fa-f-]*" "${HOSTD_LOG}" | sort | uniq -c | sed 's/^/    /' >&2
      fatal "${label}: the host has spawned ${total} shell(s) in total for ${want} pane(s) ${second}s
    in — it was asked for a session id that is not in the layout on screen"
    fi
    # …and the LIVE count, which is a different claim from the cumulative one and fails differently:
    # a churn whose re-dial the host REFUSES (`already attached on another connection`) leaves the
    # spawn count untouched and the panes DEAD. The revert-to-fail run hit exactly that on its first
    # pass — three ✅ lines, then zero live shells.
    live="$(wc -w <<< "$(live_shell_pids)" | tr -d ' ')"
    if [[ "${live}" != "${want}" ]]; then
      echo "--- live children of hostd ---" >&2
      pgrep -P "${HOSTD_PID}" -l >&2 || true
      fatal "${label}: ${want} pane(s) in the layout but ${live} live shell(s) ${second}s in — the
    panes are still on screen and their terminals are dead"
    fi
    kill -0 "${CLIENT_PID}" 2> /dev/null || fatal "${label}: the client died ${second}s in"
    sleep 1
  done
  echo "==> ${label}: layout, spawn count and live shells held for ${WATCH_SECONDS}s ✅"
}

# The host's live PTY children. hostd forks nothing but PTYs, so its child set IS the shell set.
#
# `|| true` around `pgrep` is load-bearing, not defensive noise. `pgrep` exits 1 when it matches
# NOTHING, and under `set -euo pipefail` that non-zero propagates out of the command substitution and
# kills the script — so the single most important failure this gate can observe ("the host has no
# shells at all") would end the run with exit 1 and NOT ONE LINE saying why. Found by running the
# gate against a deliberately reverted launch-adopt hold: phase A ended with zero live children, and
# the gate died silently one line after printing a ✅.
live_shell_pids() { { pgrep -P "${HOSTD_PID}" || true; } | sort -n | tr '\n' ' '; }

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

# ── 2. A host daemon with no workspace of its own ───────────────────────────────────────────────
# FRESH state dir, for CORRECTNESS as much as hygiene: phase A's whole claim is that a PRISTINE host
# takes the layout this client restored, and `adoptWorkspace` answers `rejectedStale` to a host that
# already has one. A reused dir would silently turn phase A into phase B.
#
# The daemon's HOME goes with it, and that is the same argument rather than tidiness. The scrollback
# JOURNAL lives at `<Application Support>/SlopDesk/scrollback/` — resolved off HOME — and the fixture
# pins the pane ids, so a second run inherits the first run's transcripts and phase A's cold launch
# replays bytes from a session it never had. It is the one input that differs between two otherwise
# identical runs of this gate, which is exactly what a flake is made of.
pkill -f "slopdesk-hostd --port ${CONNECT_PORT}" 2> /dev/null || true
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK}"
sleep 0.5
if [[ -z "${WORK}" ]]; then
  echo "==> FAIL: WORK is empty — refusing to run a daemon against an unpinned state dir" >&2
  exit 1
fi
HOSTD_HOME="${WORK}/hostd-home"
HOSTD_WORKSPACE="${WORK}/hostd-workspace"
rm -rf "${HOSTD_WORKSPACE}" "${HOSTD_HOME}"
mkdir -p "${HOSTD_HOME}" "${HOSTD_WORKSPACE}"
: > "${HOSTD_LOG}"
echo "==> starting slopdesk-hostd on 127.0.0.1:${CONNECT_PORT}"
HOME="${HOSTD_HOME}" SLOPDESK_WORKSPACE_STATE_DIR="${HOSTD_WORKSPACE}" \
  "${REPO_ROOT}/.build/debug/slopdesk-hostd" \
  --port "${CONNECT_PORT}" --shell /bin/sh > "${HOSTD_LOG}" 2>&1 &
HOSTD_PID=$!
await "slopdesk-hostd to bind :${CONNECT_PORT}" 20 \
  grep -q "listening on .*:${CONNECT_PORT}" "${HOSTD_LOG}"
kill -0 "${HOSTD_PID}" 2> /dev/null || fatal "slopdesk-hostd did not stay up"
echo "==> hostd up (pid ${HOSTD_PID}), with no workspace document of its own"

# ── 3. A returning user's container ─────────────────────────────────────────────────────────────
rm -rf "${CONTAINER}"
mkdir -p "$(dirname "${SEEDED_WORKSPACE}")"
cp "${FIXTURE}" "${SEEDED_WORKSPACE}"
# The stamp the app has to move. `WorkspacePersistence.save` writes `.atomic` — write-aside-then-
# rename — so a real autosave replaces this file with a different INODE at a later mtime, whatever it
# decides to put inside. Captured at the one moment the file's contents are known to be nobody's
# output but this script's, and used in §4 to tell "the app rewrote it" from "nobody wrote anything".
file_stamp() { stat -f '%i:%Fm' "$1" 2> /dev/null || echo "missing"; }
SEEDED_STAMP="$(file_stamp "${SEEDED_WORKSPACE}")"
echo "==> seeded the saved layout at ${SEEDED_WORKSPACE}"

# The MRU entry the auto-reconnect reads, as an argument-domain `Data` (see the header). Assembled
# here so the port appears exactly once in this script.
MRU_JSON="[{\"host\":\"127.0.0.1\",\"port\":${CONNECT_PORT},\"mediaPort\":9000,\"cursorPort\":9001}]"
MRU_HEX="$(printf '%s' "${MRU_JSON}" | xxd -p | tr -d '\n')"

# NO `SLOPDESK_AUTOCONNECT_*` — that is the entire point (see the header). The app therefore restores
# `workspace.json` and runs `connectIfSavedTarget()`.
# `-ApplePersistenceIgnoreState YES` is load-bearing exactly as in the other gates: without it AppKit
# comes up on its persistence path with ZERO windows, no scene mounts, and every `.task` seam this
# gate depends on silently never runs.
launch_client() {
  local phase="$1"
  CFFIXED_USER_HOME="${CONTAINER}" HOME="${CONTAINER}" \
    SLOPDESK_CLIENT_SOCKET="${SOCK}" \
    "${APP_BIN}" -ApplePersistenceIgnoreState YES \
    -connection.recentTargets "<${MRU_HEX}>" \
    -hasCompletedFirstLaunch YES >> "${WORK}/client.log" 2>&1 &
  CLIENT_PID=$!
  echo "==> ${phase}: launched the client (pid ${CLIENT_PID}) with NO autoconnect env"
}

await_client() {
  for _ in $(seq 1 60); do
    kill -0 "${CLIENT_PID}" 2> /dev/null || fatal "the client (pid ${CLIENT_PID}) died during launch"
    if "${CLI}" --socket "${SOCK}" windows --json > /dev/null 2>&1; then
      echo "==> client answering on ${SOCK} ✅"
      return 0
    fi
    sleep 0.5
  done
  fatal "the client never answered on its control socket ${SOCK}"
}

# ── 4. PHASE A — a cold launch against a pristine host ──────────────────────────────────────────
: > "${WORK}/client.log"
launch_client "phase A"
await_client

# The projection is the claim, and it is also the proof that this is the RESTORE path: the automation
# bootstrap replaces the tree with a ONE-pane shape, so three fixture-owned pane ids can only come
# from `workspace.json`.
await_projection "phase A: the client never projected the layout it restored from disk" 80
echo "==> phase A: the client projects the layout it restored from disk ✅"

await_spawns "${PANE_COUNT}" 80
echo "==> phase A: the host spawned ${PANE_COUNT} shells, one per restored pane ✅"

hold_steady "phase A" "${PANE_COUNT}"

LIVE_PIDS_A="$(live_shell_pids)"
LIVE_COUNT_A="$(wc -w <<< "${LIVE_PIDS_A}" | tr -d ' ')"
if [[ "${LIVE_COUNT_A}" != "${PANE_COUNT}" ]]; then
  echo "--- live children of hostd ---" >&2
  pgrep -P "${HOSTD_PID}" -l >&2 || true
  fatal "phase A: ${PANE_COUNT} restored panes but ${LIVE_COUNT_A} live shell(s) on the host"
fi
echo "==> phase A: ${LIVE_COUNT_A} live shells for ${PANE_COUNT} panes (pids: ${LIVE_PIDS_A}) ✅"

# The layout the app AUTOSAVES has to still be the user's. A client that churned to host truth with
# fresh ids would look identical on the wire and quietly rewrite `workspace.json` with panes the user
# never made — the layout survives the launch, but its identity does not.
#
# THE OBSERVATION HAS TO MOVE FIRST. Reading the pane ids alone proves nothing here: this file was
# `cp`'d from the fixture at §3, so it ALREADY names all three, and a build whose restore path never
# autosaves at all (`WorkspacePersistence` nil off the automation branch, a projection-driven
# `reconcileTree` that stops arming `scheduleSave`) leaves the byte-identical fixture on disk and
# every grep below still matches. That build ships a client that loses every layout edit the user
# makes, under a gate printing ✅. So the app must be shown to have REPLACED the file — a different
# inode at a later mtime, which is what `.atomic` write-aside-then-rename produces — and only then
# does what the file says mean anything.
await "the client to autosave over the layout this gate seeded" 80 autosave_replaced_the_seed
echo "==> phase A: the client REWROTE workspace.json itself (${SEEDED_STAMP} → $(file_stamp "${SEEDED_WORKSPACE}")) ✅"
while read -r pane; do
  grep -qi "${pane}" "${SEEDED_WORKSPACE}" ||
    fatal "phase A: the autosaved layout no longer names restored pane ${pane} — the client kept the
    SHAPE but replaced the panes, so every reattach after this is a respawn"
done <<< "${FIXTURE_PANES}"
echo "==> phase A: the layout the client autosaved still names all ${PANE_COUNT} restored panes ✅"

# ── 5. PHASE B — a relaunch against the same, now NON-pristine, host ────────────────────────────
# The host now holds this layout as its own document, so the relaunching client's `adoptWorkspace` is
# refused as stale and it must project HOST truth. Host truth is the same layout — so the visible
# claim is unchanged and the interesting one is underneath it: the three PTYs must be picked back up,
# not replaced.
echo "==> phase B: stopping the client"
DETACH_BASELINE="$(detach_counts)"
reap "${CLIENT_PID}" "client"
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK}"
# Waited on the HOST's own observation of the dropped link, not slept through: until hostd parks the
# sessions they are still "attached on another connection" and the relaunch's reattach would be
# refused — a race that would make this gate flaky for a reason that has nothing to do with the claim.
await "the host to park all ${PANE_COUNT} sessions" 60 detached_all_since
echo "==> phase B: the host parked all ${PANE_COUNT} sessions ✅"

launch_client "phase B"
await_client
await_projection "phase B: the relaunched client never projected the layout host truth holds" 80
echo "==> phase B: the client projects the same layout, now from host truth ✅"

await "every parked session to be reattached" 80 reattached_all
echo "==> phase B: all ${PANE_COUNT} sessions reattached ✅"

# Still ${PANE_COUNT} spawns TOTAL, counting both phases: a relaunch that respawns is a relaunch that
# abandoned three running agents.
hold_steady "phase B" "${PANE_COUNT}"

LIVE_PIDS_B="$(live_shell_pids)"
if [[ "${LIVE_PIDS_B}" != "${LIVE_PIDS_A}" ]]; then
  echo "--- live children of hostd ---" >&2
  pgrep -P "${HOSTD_PID}" -l >&2 || true
  fatal "phase B: the relaunch did not keep the SAME shells.
    phase A pids: ${LIVE_PIDS_A}
    phase B pids: ${LIVE_PIDS_B}"
fi
echo "==> phase B: the very same ${PANE_COUNT} shells (pids: ${LIVE_PIDS_B}) ✅"

# ── 5b. PHASE C — a relaunch whose saved layout names panes this host has never seen ────────────
# The one shape phases A and B cannot reach: client and host DISAGREE about which panes exist. The
# client shows its own layout optimistically and offers it; the host already has a workspace, so the
# offer comes back `rejectedStale` and host truth wins. The visible outcome is the same signature as
# before — and the claim underneath it is that nothing was dialled in the meantime.
echo "==> phase C: stopping the client"
DETACH_BASELINE="$(detach_counts)"
reap "${CLIENT_PID}" "client"
pkill -f "${APP_PROC_PAT}" 2> /dev/null || true
rm -f "${SOCK}"
await "the host to park all ${PANE_COUNT} sessions again" 60 detached_all_since
cp "${DIVERGENT}" "${SEEDED_WORKSPACE}"
echo "==> phase C: seeded a layout whose panes the host has never seen"

launch_client "phase C"
await_client
await_projection "phase C: the client never projected host truth over its divergent layout" 80
echo "==> phase C: the client projects HOST truth, not the ids it restored ✅"

# The assertion this phase exists for, stated per divergent id so a failure names the pane. A single
# `attached for pane <divergent id>` line is a login shell the host forked, ran and then killed for a
# pane the user never sees.
while read -r pane; do
  if grep -q "attached for pane ${pane}" "${HOSTD_LOG}"; then
    echo "==> every pane the host has spawned for:" >&2
    grep -o "attached for pane [0-9A-Fa-f-]*" "${HOSTD_LOG}" | sort | uniq -c | sed 's/^/    /' >&2
    fatal "phase C: the host spawned a shell for ${pane} — an id that is not in any layout on
    screen. The client dialled a pane the document was about to replace, and that PTY is abandoned."
  fi
done <<< "${DIVERGENT_PANES}"
echo "==> phase C: not one of the ${PANE_COUNT} divergent ids reached the host ✅"

hold_steady "phase C" "${PANE_COUNT}"

# The autosave again — and this time the CONTENT alone is the discriminator, because the file on disk
# says the opposite of the claim. Phase C seeded it with the divergent ids; a client that autosaves
# what it projects must have replaced every one of them with host truth. A build that never writes
# leaves the refused layout there and offers it again on the next launch, for ever.
await "the client to autosave host truth over the divergent layout" 80 autosaved_host_truth
echo "==> phase C: the autosaved layout is now HOST truth — the ${PANE_COUNT} divergent ids are gone ✅"

LIVE_PIDS_C="$(live_shell_pids)"
if [[ "${LIVE_PIDS_C}" != "${LIVE_PIDS_A}" ]]; then
  echo "--- live children of hostd ---" >&2
  pgrep -P "${HOSTD_PID}" -l >&2 || true
  fatal "phase C: the divergent relaunch did not keep the SAME shells.
    phase A pids: ${LIVE_PIDS_A}
    phase C pids: ${LIVE_PIDS_C}"
fi
echo "==> phase C: still the very same ${PANE_COUNT} shells (pids: ${LIVE_PIDS_C}) ✅"

# ── 6. The evidence a human reads ───────────────────────────────────────────────────────────────
# The client's own final projection, read back off the shipping control socket: the value the window
# paints, in text. This is the artefact worth printing, and unlike a screenshot it is the same thing
# the assertions above compared.
echo
echo "==> the layout the client reports rendering, at the end:"
awk '{ print "    " $0 }' <<< "$(signature 2> /dev/null || true)"

# A full-screen grab as a bonus, labelled for what it actually is. This gate deliberately does NOT
# raise the client window: coming to the front at launch is automation-only behaviour
# (`automationBringToFrontOnce`), faking it would need Accessibility TCC, and no assertion depends on
# it — so the window is wherever the window manager left it, quite possibly behind everything else.
# Calling this "the restored window" would be the kind of small lie that makes a gate's output stop
# being read.
SHOT="${WORK}/desktop-at-exit.png"
if command -v screencapture > /dev/null 2>&1; then
  screencapture -x "${SHOT}" 2> /dev/null || true
fi

echo
echo "================================================================================"
echo " DONE — the shipping launch path is ASSERTED above, not eyeballed."
echo " A cold launch restored ${PANE_COUNT} panes across ${FIXTURE_TABS} tabs, the pristine host took"
echo " that layout and gave it ${PANE_COUNT} shells, a relaunch against the now non-pristine host"
echo " picked the SAME ${PANE_COUNT} PTYs back up rather than respawning them, and a relaunch whose"
echo " saved layout named ${PANE_COUNT} panes the host has never seen put none of them on the wire."
[[ -f "${SHOT}" ]] && echo " Desktop grab (window NOT raised — see above):  ${SHOT}"
echo " hostd log:  ${HOSTD_LOG}"
echo "================================================================================"
