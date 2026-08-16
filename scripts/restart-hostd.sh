#!/usr/bin/env bash
# restart-hostd.sh — rebuild `slopdesk-hostd` and restart the running one, identically.
#
# WHY THIS EXISTS
# `docs/51` made the restart itself cheap: `slopdesk-superd` holds every pane's PTY master, both
# child-facing sockets and the panel backends, so stopping hostd costs a client reconnect instead of
# whatever `claude` was mid-way through. What stayed expensive was the RITUAL. Find the process —
# and `pkill` matching too much, or leaving a host on the port, is a trap this repo has written down.
# Wait long enough. Remember which flags it had. Notice that `--port 0` bound something else.
# A restart that is technically free but manually fiddly still gets postponed, which is the exact
# behaviour this whole subsystem set out to change.
#
# So the daemon states its own launch (`HostLaunchRecord`, written once the REAL bound port is known)
# and this reads it. Nothing here parses `ps` for a flag, guesses a port or retypes an argument.
#
#   scripts/restart-hostd.sh              # build, stop, start, verify — the whole loop
#   scripts/restart-hostd.sh --no-build   # skip the build (already built, or testing this script)
#   scripts/restart-hostd.sh --stop       # stop only, no build
#   scripts/restart-hostd.sh --status     # report and change nothing
#
# It reports the observed DOWNTIME and the number of children superd is holding on either side of
# it, because "the restart cost you nothing" is a claim, and a claim in this repo comes with the
# number behind it.
#
# docs/51-process-supervision.md §9, docs/46-gates-env-paths.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly RECORD="${SLOPDESK_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/SlopDesk}/hostd-launch.json"
readonly LOG_DIR="${HOME}/Library/Logs/SlopDesk"
readonly LOG_FILE="${LOG_DIR}/hostd.log"

DO_BUILD=1
DO_STOP=1
DO_START=1
for argument in "$@"; do
  case "${argument}" in
    --no-build) DO_BUILD=0 ;;
    --stop)
      DO_BUILD=0
      DO_START=0
      ;;
    --status)
      DO_BUILD=0
      DO_STOP=0
      DO_START=0
      ;;
    *)
      echo "usage: $0 [--no-build] [--stop] [--status]" >&2
      exit 2
      ;;
  esac
done

say() { printf 'restart-hostd: %s\n' "$1"; }
die() {
  printf 'restart-hostd: %s\n' "$1" >&2
  exit 1
}

command -v jq > /dev/null 2>&1 || die "jq is required to read the launch record (brew install jq)"

# ── Everything is read from the record UP FRONT ─────────────────────────────────────────────────
# Load-bearing, not tidiness: hostd DELETES the record on its orderly shutdown (an absent file means
# "no hostd", which is worth telling apart from "one died badly"). Anything read after the stop
# would be read from a file that is no longer there.
have_record=0
[[ -f "${RECORD}" ]] && have_record=1

pid=""
port=""
binary=""
cwd=""
version=""
started_at=""
declare -a launch_arguments=()
declare -a environment_arguments=()

if [[ "${have_record}" -eq 1 ]]; then
  jq -e . < "${RECORD}" > /dev/null 2>&1 || die "launch record is not valid JSON: ${RECORD}"
  pid="$(jq -r '.pid' < "${RECORD}")"
  port="$(jq -r '.port' < "${RECORD}")"
  binary="$(jq -r '.binary' < "${RECORD}")"
  cwd="$(jq -r '.workingDirectory' < "${RECORD}")"
  version="$(jq -r '.version' < "${RECORD}")"
  started_at="$(jq -r '.startedAt' < "${RECORD}")"
  # `@sh` + `eval` rather than a read loop. jq's `@sh` emits shell-safe single-quoted words, and
  # that is the one formulation that survives a value holding a space, a quote or a newline — the
  # environment is user-supplied, so "no flag will ever contain a space" is not a thing to assume.
  # `eval` is safe here precisely because `@sh` is what quoted it.
  eval "launch_arguments=($(jq -r '.arguments | @sh' < "${RECORD}"))"
  eval "environment_arguments=($(jq -r '.environment | to_entries | map("\(.key)=\(.value)") | @sh' < "${RECORD}"))"
fi

# ── Is the recorded daemon actually there? ──────────────────────────────────────────────────────
# `kill -0` is the existence probe, and it is not enough on its own: pids are recycled, so the
# executable is confirmed too. Signalling a reused pid is the failure mode that made `pkill` a trap.
#
# `lsof -d txt`, not `ps -o comm=`. `comm` is argv[0] as the caller typed it — the usual spelling is
# the relative `.build/release/slopdesk-hostd` — while `txt` is the vnode the kernel actually
# executed, which is what the record holds (`HostLaunchRecord.runningExecutablePath`, symlinks
# resolved on both sides so `.build/release` and `.build/arm64-apple-macosx/release` are one file).
alive=0
if [[ "${have_record}" -eq 1 ]] && kill -0 "${pid}" 2> /dev/null; then
  # `|| running_binary=""` is what makes the fallback below REACHABLE. Under `set -euo pipefail` a
  # declining lsof (a hardened process, a denied `txt` fd) exits non-zero, pipefail promotes it out
  # of the pipeline, and the assignment aborts the script — with no diagnostic, before hostd is
  # rebuilt, stopped or relaunched. The empty-string branch was written for exactly this case and
  # could never run, because reaching it required the assignment to have succeeded.
  running_binary="$(lsof -a -p "${pid}" -d txt -Fn 2> /dev/null | sed -n 's/^n//p' | head -1)" || running_binary=""
  if [[ "${running_binary}" = "${binary}" ]]; then
    alive=1
  elif [[ -z "${running_binary}" ]]; then
    # lsof declined (permissions, a hardened process). Fall back to the name, which is weaker but
    # is still stronger than signalling a pid on trust alone.
    if [[ "$(basename "$(ps -o comm= -p "${pid}" 2> /dev/null)")" = "$(basename "${binary}")" ]]; then
      alive=1
      say "could not read pid ${pid}'s executable — matched on name only"
    fi
  else
    say "record pid ${pid} is alive but runs '${running_binary}', not '${binary}' — pid reused, the record is stale"
  fi
fi

# superd's side of the story, so the downtime number has the thing it is a claim about.
#
# Counted by PARENTAGE rather than by asking superd: superd is the parent of every pane's shell and
# of both panel backends, which is the whole architecture in one number, and it needs no protocol,
# no client and no socket — all three of which are exactly what is unavailable mid-restart.
superd_children() {
  local superd_pid children
  superd_pid="$(pgrep -x slopdesk-superd | head -1)" || superd_pid=""
  [[ -n "${superd_pid}" ]] || {
    echo "superd not running"
    return 0
  }
  # Counted from the list rather than piped into `grep -c`: with no children, `pgrep` exits 1 AND
  # `grep -c .` prints its own `0` and exits 1, so the `|| echo 0` that was here fired on top of
  # that and the substitution came out as two lines — a restart of an idle superd reported
  # "0\n0 supervised children".
  children="$(pgrep -P "${superd_pid}" 2> /dev/null)" || children=""
  if [[ -z "${children}" ]]; then
    printf '0'
  else
    printf '%s' "$(printf '%s\n' "${children}" | wc -l | tr -d ' ')"
  fi
}

if [[ "${have_record}" -eq 0 ]]; then
  say "no launch record at ${RECORD} — no hostd has run since the last clean stop"
elif [[ "${alive}" -eq 1 ]]; then
  say "hostd pid ${pid} on port ${port} (v${version}), started ${started_at}"
else
  say "launch record names pid ${pid}, which is gone — hostd died without an orderly stop"
fi
children_before="$(superd_children)"
say "superd is holding ${children_before} child process(es)"

if [[ "${DO_BUILD}" -eq 0 ]] && [[ "${DO_STOP}" -eq 0 ]] && [[ "${DO_START}" -eq 0 ]]; then
  exit 0
fi

# ── Build, before stopping anything ─────────────────────────────────────────────────────────────
# Deliberately ahead of the stop: a build that fails must leave the running daemon alone rather than
# replace it with nothing. `--product` so this compiles hostd and the libraries it needs, not the
# client app, the video host or the iOS surfaces.
if [[ "${DO_BUILD}" -eq 1 ]]; then
  configuration="debug"
  case "${binary}" in
    */release/*) configuration="release" ;;
    *) ;; # any other path is a debug build, which is the default above
  esac
  say "swift build --product slopdesk-hostd -c ${configuration}"
  (cd "${REPO_ROOT}" && swift build --product slopdesk-hostd -c "${configuration}")
fi

# ── Stop ────────────────────────────────────────────────────────────────────────────────────────
# SIGTERM, never SIGKILL. hostd's handler runs the orderly drain — panes RELINQUISHED (superd keeps
# them), panel backends relinquished, clients told `bye`, journals flushed. A SIGKILL skips all of
# it. The panes would survive either way; it is the clients and the journals that would notice.
stopped_at=""
if [[ "${DO_STOP}" -eq 1 ]] && [[ "${alive}" -eq 1 ]]; then
  stopped_at="$(python3 -c 'import time; print(time.time())')"
  say "SIGTERM → pid ${pid}"
  kill -TERM "${pid}" 2> /dev/null || true

  deadline=$((SECONDS + 20))
  while kill -0 "${pid}" 2> /dev/null; do
    if [[ "${SECONDS}" -ge "${deadline}" ]]; then
      die "pid ${pid} did not exit within 20s of SIGTERM — investigate rather than forcing it; a SIGKILL here skips the orderly drain"
    fi
    sleep 0.05
  done
  say "pid ${pid} exited"

  # The port, separately. An exited process is not a freed listener, and launching into a port that
  # is not free yet is the "left a host on the port" failure arriving by another route.
  deadline=$((SECONDS + 20))
  while lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t > /dev/null 2>&1; do
    if [[ "${SECONDS}" -ge "${deadline}" ]]; then
      die "port ${port} is still listening 20s after pid ${pid} exited — something else holds it"
    fi
    sleep 0.05
  done
elif [[ "${DO_STOP}" -eq 1 ]]; then
  say "nothing running to stop"
fi

if [[ "${DO_START}" -eq 0 ]]; then
  say "stopped — superd is holding $(superd_children) child process(es), unchanged"
  exit 0
fi

# ── Start ───────────────────────────────────────────────────────────────────────────────────────
# Identically: the same binary, the same argv, the same cwd, and the same `SLOPDESK_*` variables the
# old process actually resolved — the set that shapes its behaviour, and the set a shell history
# gets wrong.
[[ "${have_record}" -eq 1 ]] || die "no launch record, so there is nothing to reproduce — start hostd once by hand and this takes over"
[[ -x "${binary}" ]] || die "recorded binary is not executable: ${binary}"
[[ -d "${cwd}" ]] || die "recorded working directory is gone: ${cwd}"

mkdir -p "${LOG_DIR}"
# `${array[@]+"${array[@]}"}` throughout, never a bare `"${array[@]}"`. macOS ships bash 3.2 as
# /bin/bash, and there `set -u` treats an EMPTY array's expansion as an unbound variable: a hostd
# started with no flags and no `SLOPDESK_*` overrides — the ordinary case — would abort the script
# here, after the stop, leaving no daemon running at all.
say "starting ${binary} ${launch_arguments[*]+${launch_arguments[*]}}"
(
  cd "${cwd}"
  # `nohup` + background: this script returns to a prompt, and the daemon must not go with it.
  # `env --` is not portable to macOS's `env`; the recorded pairs are `SLOPDESK_*=…` by construction
  # (`HostLaunchRecord.configVariables`), so none can be mistaken for an option.
  nohup env ${environment_arguments[@]+"${environment_arguments[@]}"} \
    "${binary}" ${launch_arguments[@]+"${launch_arguments[@]}"} \
    >> "${LOG_FILE}" 2>&1 &
)

# ── Which port is the NEW one going to be on? ───────────────────────────────────────────────────
# Usually the recorded one. Not for `--port 0`: that asks the OS for an ephemeral port, so the number
# the old process bound says nothing about the new one, and polling it would time out on a daemon
# that is up and well — reporting a failed restart and leaving the operator to hunt for the port.
requested_port=""
previous=""
for argument in ${launch_arguments[@]+"${launch_arguments[@]}"}; do
  case "${previous}" in
    --port | -p) requested_port="${argument}" ;;
    *) ;; # this argument is not a port's value
  esac
  case "${argument}" in
    --port=*) requested_port="${argument#--port=}" ;;
    *) ;; # not the joined spelling either
  esac
  previous="${argument}"
done

expected_port="${port}"
if [[ "${requested_port}" = "0" ]]; then
  # Only the new daemon knows. Wait for it to publish a record of its OWN — a live pid that is not
  # the one just stopped — which it writes after `listen(2)`, and take the bound port from there.
  say "launched with --port 0 — waiting for the new daemon to publish its bound port"
  expected_port=""
  deadline=$((SECONDS + 30))
  while [[ -z "${expected_port}" ]]; do
    if [[ -f "${RECORD}" ]]; then
      fresh_pid="$(jq -r '.pid // empty' < "${RECORD}" 2> /dev/null || true)"
      if [[ -n "${fresh_pid}" ]] && [[ "${fresh_pid}" != "${pid}" ]] && kill -0 "${fresh_pid}" 2> /dev/null; then
        expected_port="$(jq -r '.port' < "${RECORD}")"
      fi
    fi
    if [[ -z "${expected_port}" ]] && [[ "${SECONDS}" -ge "${deadline}" ]]; then
      die "the new daemon never published a launch record 30s after launch — see ${LOG_FILE}"
    fi
    [[ -n "${expected_port}" ]] || sleep 0.05
  done
  say "the new daemon bound port ${expected_port} (the old one had ${port})"
fi

# ── Verify ──────────────────────────────────────────────────────────────────────────────────────
# The readiness test is a real LISTENER, not the record file. `bind(2)` precedes `listen(2)` and the
# record is written after both, but a file a previous run left behind is exactly how a readiness
# check lies — the same lesson `SuperdFixture` learned (`docs/51` §6.5). (The `--port 0` branch above
# reads the record for the NUMBER only, and only from a record a live, different pid just wrote.)
deadline=$((SECONDS + 30))
while ! lsof -nP -iTCP:"${expected_port}" -sTCP:LISTEN -t > /dev/null 2>&1; do
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    die "nothing is listening on port ${expected_port} 30s after launch — see ${LOG_FILE}"
  fi
  sleep 0.05
done

if [[ -n "${stopped_at}" ]]; then
  downtime="$(python3 -c "import time; print(f'{time.time() - ${stopped_at}:.2f}')")"
  say "listening again on ${expected_port} — down for ${downtime}s"
else
  say "listening on ${expected_port}"
fi
say "superd is holding $(superd_children) child process(es) — was ${children_before} before the restart"
say "log: ${LOG_FILE}"
