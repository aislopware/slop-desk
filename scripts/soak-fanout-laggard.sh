#!/usr/bin/env bash
# soak-fanout-laggard.sh — the PTY fan-out under a REAL slow subscriber (docs/45 §8.6, §10 Q2).
#
# Real processes only: one `slopdesk-hostd` with SLOPDESK_PANE_FANOUT=1, several `slopdesk-client`s,
# a real PTY, and a laggard made slow the way a backgrounded phone is slow — SIGSTOP, so it stops
# reading its socket AND stops acking at the same instant. Nothing here is mocked or in-memory: the
# in-memory loopback provably misses the open-order and credit-window races this exists to catch.
#
# Four properties, in order:
#   P1 retention  — a laggard under the threshold loses NOTHING: both members receive every line
#                   exactly once, in order, when the slow one resumes.
#   P2 eviction   — a laggard past SLOPDESK_SUB_LAG_BYTES is evicted, and it is the LAGGARD that
#                   goes, not the session: the fast member keeps every byte and the shell survives.
#   P3 no head-of-line — the fast member receives the whole stream WHILE the slow one is frozen, so
#                   neither the drain nor the read loop is serialised behind the laggard.
#   P4 producer bound — a pane that fanned out and then shrank back to ONE member still
#                   backpressures the PTY when that member stops consuming, exactly like a pane that
#                   never fanned out. Run as an A/B in one host process: the control pane's shell and
#                   the test pane's shell must BOTH still be blocked at the end.
#
# Deterministic enough to gate: every assertion is a count or a liveness check, not a timing
# threshold. It is NOT a CI gate — it needs a real PTY and ~80 seconds of wall clock (like
# check-macos.sh). Run it after touching the fan-out, the subscriber set, the out-FIFO, the queue
# gate, or the ReplayBuffer's retention.
#
#   bash scripts/soak-fanout-laggard.sh
#   SLOPDESK_SUB_LAG_BYTES=$((32 * 1024 * 1024)) bash scripts/soak-fanout-laggard.sh   # the shipped default
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTD="${ROOT}/.build/debug/slopdesk-hostd"
CLIENT="${ROOT}/.build/debug/slopdesk-client"
THRESH="${SLOPDESK_SUB_LAG_BYTES:-$((4 * 1024 * 1024))}"
LINE_BYTES=74 # "L%07d" + 64 dots + CR + LF, as the PTY emits it

# ~4x the threshold, so eviction is reached with margin rather than by a lucky rounding.
EVICT_LINES=$(((THRESH * 4) / LINE_BYTES))
# Comfortably UNDER the threshold, so P1 exercises retention and not eviction.
HOLD_LINES=$(((THRESH / 4) / LINE_BYTES))
# P4 only has to exceed the 64 KiB queue bound by a lot; a CORRECT host finishes none of it, so the
# assertion is "the generator is still alive", not a byte count.
BOUND_LINES=600000

WORK="$(mktemp -d "${TMPDIR:-/tmp}/slopdesk-soak.XXXXXX")"
# Every pid this run spawns, appended to a FILE rather than a shell array: `start_client` is called
# through command substitution (it echoes its pid), so an array assignment inside it lands in a
# subshell and the parent's cleanup would miss every client — a SIGSTOPped orphan holding a port.
PIDFILE="${WORK}/pids"
: > "${PIDFILE}"
FAILURES=0

# shellcheck disable=SC2329 # invoked indirectly, by the EXIT trap below
cleanup() {
  local pids
  pids="$(cat "${PIDFILE}" 2> /dev/null)"
  for pid in ${pids}; do
    kill -CONT "${pid}" 2> /dev/null
    kill -TERM "${pid}" 2> /dev/null
  done
  sleep 1
  for pid in ${pids}; do kill -KILL "${pid}" 2> /dev/null; done
  rm -rf "${WORK}"
}
# INT/TERM as well as EXIT: a bash EXIT trap does NOT run when the shell is killed by an untrapped
# signal, and a SIGSTOPped client that outlives this script keeps a port and a shell alive.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}
note() { printf '     %s\n' "$1"; }

if [[ ! -x ${HOSTD} ]] || [[ ! -x ${CLIENT} ]]; then
  echo "soak: build products missing under ${ROOT}/.build/debug — run 'swift build' first" >&2
  exit 2
fi

echo "== fan-out laggard soak: SLOPDESK_SUB_LAG_BYTES=${THRESH} =="

# The daemon's container. `${WORK}` is a mktemp dir the cleanup trap removes, so everything this soak
# writes goes with it.
#
# HOME is not the container and never was: it moves neither Application Support nor
# `NSHomeDirectory()` (Core Foundation reads the account record unless `CFFIXED_USER_HOME` is set).
# This soak pushes MEGABYTES through several sessions by design, and without the redirect all of it
# was journaled into the developer's own `~/Library/Application Support/SlopDesk/scrollback/` — where
# `ScrollbackJournalStore.sweep` then unlinked their oldest transcripts to hold the directory at 256.
# The same daemon also wrote their `workspace-state.json` and resolved their `~/Downloads` as its
# file-drop directory.
#
# `GuiGateLaunchContractTests` pins this set onto every daemon launch in every gate, this one
# included. It is here because it was not: the rule lived in check-macos.sh's comments, the three
# gates that look like check-macos.sh copied it, and the one that looks like a soak did not.
mkdir -p "${WORK}/home" "${WORK}/state/scrollback" "${WORK}/state/drop"
HOME="${WORK}/home" SLOPDESK_APP_SUPPORT_DIR="${WORK}/state" \
  SLOPDESK_SCROLLBACK_DIR="${WORK}/state/scrollback" \
  SLOPDESK_FILE_DROP_DIR="${WORK}/state/drop" \
  SLOPDESK_WORKSPACE_STATE_DIR="${WORK}/state" \
  SLOPDESK_PANE_FANOUT=1 SLOPDESK_SUB_LAG_BYTES="${THRESH}" \
  "${HOSTD}" --port 0 --shell /bin/sh > "${WORK}/hostd.out" 2> "${WORK}/hostd.err" &
HOSTD_PID=$!
echo "${HOSTD_PID}" >> "${PIDFILE}"

PORT=""
for _ in $(seq 1 60); do
  PORT="$(sed -n 's/.*listening on 0\.0\.0\.0:\([0-9]*\) (shell.*/\1/p' "${WORK}/hostd.err")"
  [[ -n ${PORT} ]] && break
  sleep 0.25
done
if [[ -z ${PORT} ]]; then
  echo "soak: hostd never reported a bound port" >&2
  cat "${WORK}/hostd.err" >&2
  exit 2
fi
note "hostd pid ${HOSTD_PID} on port ${PORT}"

# Launches one shipped client on `sid`, holding its stdin FIFO open for the whole run. Echoes the
# client pid.
start_client() {
  local name="$1" sid="$2" pid
  mkfifo "${WORK}/${name}.in"
  sleep 100000 > "${WORK}/${name}.in" &
  echo "$!" >> "${PIDFILE}"
  HOME="${WORK}/home" "${CLIENT}" --host 127.0.0.1 --port "${PORT}" --no-raw --session-id "${sid}" \
    < "${WORK}/${name}.in" > "${WORK}/${name}.out" 2> "${WORK}/${name}.err" &
  pid=$!
  echo "${pid}" >> "${PIDFILE}"
  echo "${pid}"
}

# Waits (bounded) for `text` to appear in a client's stdout capture.
await_text() {
  local name="$1" text="$2" secs="${3:-25}"
  for _ in $(seq 1 $((secs * 4))); do
    grep -q -- "${text}" "${WORK}/${name}.out" && return 0
    sleep 0.25
  done
  return 1
}

# Writes a numbered-line generator into a client's stdin: prefix, first index, count.
generate() {
  local name="$1" prefix="$2" first="$3" count="$4" dots
  dots="$(printf '.%.0s' $(seq 1 64))"
  printf "awk 'BEGIN{for(i=%d;i<%d;i++) printf \"%s%%07d%%s\\\\n\", i, \"%s\"}'; echo %s_DONE\n" \
    "${first}" "$((first + count))" "${prefix}" "${dots}" "${prefix}" > "${WORK}/${name}.in"
}

# Asserts a client's capture holds exactly `count` lines of `prefix`, contiguous from `first`, with
# no duplicates. A gap is a LOST byte; a duplicate is a byte delivered twice. Neither is allowed.
assert_stream() {
  local label="$1" name="$2" prefix="$3" first="$4" count="$5" seqfile got uniq
  seqfile="${WORK}/${name}.${prefix}.seq"
  grep -o "${prefix}[0-9]\{7\}" "${WORK}/${name}.out" | sed "s/^${prefix}//" > "${seqfile}"
  got="$(wc -l < "${seqfile}" | tr -d ' ')"
  uniq="$(sort -u "${seqfile}" | wc -l | tr -d ' ')"
  if [[ ${got} != "${count}" ]]; then
    fail "${label}: expected ${count} lines, got ${got}"
    return
  fi
  if [[ ${uniq} != "${count}" ]]; then
    fail "${label}: $((got - uniq)) DUPLICATE line(s) — a subscriber received a byte twice"
    return
  fi
  if ! awk -v first="${first}" 'NR == 1 && $1 + 0 != first + 0 { exit 1 }
       NR > 1 && $1 + 0 != prev + 1 { exit 1 } { prev = $1 + 0 }' "${seqfile}"; then
    fail "${label}: the sequence has a GAP — a subscriber lost a byte"
    return
  fi
  ok "${label}: ${count} lines, contiguous from ${first}, no duplicates"
}

# The pid of the generator still running under the shell serving `pane`, if any.
generator_pid() {
  local pane="$1" shell_pid
  shell_pid="$(sed -n "s/.*shell \/bin\/sh (pid \([0-9]*\)) attached for pane ${pane}/\1/p" "${WORK}/hostd.err")"
  [[ -n ${shell_pid} ]] || return 0
  pgrep -P "${shell_pid}" awk 2> /dev/null | head -1
}

# ---------------------------------------------------------------- P1 / P2 / P3: the shared pane

SHARED="$(uuidgen)"
FAST="$(start_client fast "${SHARED}")"
sleep 2
SLOW="$(start_client slow "${SHARED}")"
sleep 3
printf 'stty -echo; PS1=""\n' > "${WORK}/fast.in"
sleep 1
printf 'echo JOINED\n' > "${WORK}/fast.in"
await_text fast JOINED || {
  echo "soak: the fast client never saw its own echo" >&2
  exit 2
}
await_text slow JOINED || {
  echo "soak: the slow client never joined the live pane" >&2
  exit 2
}
grep -q 'joined live session' "${WORK}/hostd.err" || {
  echo "soak: the host never logged a JOIN — is SLOPDESK_PANE_FANOUT honoured?" >&2
  exit 2
}
note "two clients share pane ${SHARED} (fast ${FAST}, slow ${SLOW})"

echo "-- P1 retention: a laggard under the threshold loses nothing"
kill -STOP "${SLOW}"
generate fast L 1 "${HOLD_LINES}"
await_text fast L_DONE 120 || fail "P1: the generator never finished for the fast member"
kill -CONT "${SLOW}"
await_text slow L_DONE 120 || fail "P1: the resumed laggard never caught up"
assert_stream "P1 fast member" fast L 1 "${HOLD_LINES}"
assert_stream "P1 laggard" slow L 1 "${HOLD_LINES}"

echo "-- P2 eviction + P3 no head-of-line: a laggard past the threshold goes, the pane does not"
kill -STOP "${SLOW}"
generate fast M 1000000 "${EVICT_LINES}"
await_text fast M_DONE 300 || fail "P3: the fast member was starved while the laggard was frozen"
assert_stream "P3 fast member" fast M 1000000 "${EVICT_LINES}"

if grep -q 'evicted — more than' "${WORK}/hostd.err"; then
  ok "P2: the host evicted a laggard ($(grep -m1 'evicted — more than' "${WORK}/hostd.err" | sed 's/.*hostd: //'))"
else
  fail "P2: nothing was evicted after $((EVICT_LINES * LINE_BYTES)) bytes past a ${THRESH} threshold"
fi
if grep -q 'pane subscriber 1: evicted' "${WORK}/hostd.err"; then
  ok "P2: the member evicted is the LAGGARD (subscriber 1), not the fast one"
else
  fail "P2: the evicted member is not the laggard: $(grep 'evicted' "${WORK}/hostd.err")"
fi

printf 'echo SURVIVED\n' > "${WORK}/fast.in"
if await_text fast SURVIVED 30; then
  ok "P2: the shell survives its laggard's eviction and still answers the fast member"
else
  fail "P2: the pane died with its laggard — eviction took the session, not the subscriber"
fi
kill -CONT "${SLOW}"

# ------------------------------------------------------- P4: the producer bound after a shrink

echo "-- P4 producer bound: a pane that shrank back to one member still backpressures the PTY"
CTRL="$(uuidgen)"
TEST="$(uuidgen)"
C1="$(start_client c1 "${CTRL}")"
sleep 2
T1="$(start_client t1 "${TEST}")"
sleep 2
T2="$(start_client t2 "${TEST}")"
sleep 3
printf 'stty -echo; PS1=""\n' > "${WORK}/c1.in"
printf 'stty -echo; PS1=""\n' > "${WORK}/t1.in"
sleep 1
printf 'echo READY\n' > "${WORK}/c1.in"
printf 'echo READY\n' > "${WORK}/t1.in"
await_text c1 READY || {
  echo "soak: the control pane never came up" >&2
  exit 2
}
await_text t1 READY || {
  echo "soak: the test pane never came up" >&2
  exit 2
}

# The test pane SHRINKS back to one member while LIVE — a second client closing its lid, or the
# laggard eviction above. The control pane never fanned out at all.
kill -TERM "${T2}"
sleep 4

# The leading `sleep 4` gives the harness time to freeze both clients before either generator
# produces a byte, so the two panes are frozen at the SAME point in their streams.
printf 'sleep 4; ' > "${WORK}/c1.in"
printf 'sleep 4; ' > "${WORK}/t1.in"
generate c1 B 1 "${BOUND_LINES}"
generate t1 B 1 "${BOUND_LINES}"
sleep 1
kill -STOP "${C1}"
kill -STOP "${T1}"
sleep 45

CTRL_GEN="$(generator_pid "${CTRL}")"
TEST_GEN="$(generator_pid "${TEST}")"
if [[ -n ${CTRL_GEN} ]]; then
  ok "P4 control (never fanned out): the shell is still blocked on a full PTY (awk ${CTRL_GEN})"
else
  fail "P4 control: the never-fanned-out pane swallowed $((BOUND_LINES * LINE_BYTES)) bytes with nobody reading"
fi
if [[ -n ${TEST_GEN} ]]; then
  ok "P4 test (fanned out, then shrank to one): the shell is still blocked on a full PTY (awk ${TEST_GEN})"
else
  fail "P4 test: a pane that shrank back to one member buffered $((BOUND_LINES * LINE_BYTES)) bytes into host RAM — the queue gate stopped bounding the producer"
fi

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "== soak PASSED =="
else
  echo "== soak FAILED (${FAILURES}) =="
  echo "-- hostd log --"
  cat "${WORK}/hostd.err"
fi
exit "${FAILURES}"
