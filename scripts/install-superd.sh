#!/usr/bin/env bash
# Installs (or reinstalls) `slopdesk-superd` as a launchd LaunchAgent.
#
# superd is the process that holds every pane's PTY master, so that editing hostd stops costing you
# every running `claude` (docs/51). It must therefore outlive hostd's *build*, which is what a
# LaunchAgent gives: started at login, restarted if it dies, and completely unaware that hostd was
# rebuilt three times this afternoon.
#
#   scripts/install-superd.sh            # build, install the plist, load, verify
#   scripts/install-superd.sh --uninstall
#
# ⚠️ Reinstalling RESTARTS superd, and restarting superd kills every supervised pane — the exact
# thing this daemon exists to prevent. The script says so and asks, unless --force is passed.
set -euo pipefail

readonly LABEL="com.slopdesk.superd"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOG_DIR="${HOME}/Library/Logs/SlopDesk"
readonly BINARY_SOURCE="${REPO_ROOT}/rust/slopdesk-superd/target/release/slopdesk-superd"
# Installed OUT of the build tree on purpose: launchd re-execs this path, and a `cargo clean` (or a
# rebuild replacing the inode mid-flight) must not be able to leave the agent pointing at nothing.
readonly BINARY_INSTALLED="${HOME}/Library/Application Support/SlopDesk/bin/slopdesk-superd"

FORCE=0
UNINSTALL=0
for argument in "$@"; do
  case "${argument}" in
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *)
      echo "usage: $0 [--force] [--uninstall]" >&2
      exit 2
      ;;
  esac
done

domain="gui/$(id -u)"

supervised_pane_count() {
  # Children of superd, which is one process per live pane. `pgrep -P` is enough here; a precise
  # count is not the point, "you are about to kill N shells" is.
  #
  # Every step below swallows its own failure, and that is not defensive noise. Under
  # `set -euo pipefail`, `pgrep` finding NOTHING exits 1, pipefail promotes that to the pipeline,
  # and the caller's `count="$(...)"` assignment then aborts the whole installer — silently, since
  # `set -e` prints nothing. The state that triggers it is superd running with ZERO panes, which is
  # exactly the state this script's own banner tells you to get into before upgrading: the build
  # would succeed, nothing would be installed, and the developer would go on debugging a fix that
  # never loaded.
  local pid children
  pid="$(launchctl print "${domain}/${LABEL}" 2> /dev/null | awk '/^\tpid = /{print $3}')" || pid=""
  if [[ -z "${pid}" ]]; then
    echo 0
    return 0
  fi
  children="$(pgrep -P "${pid}" 2> /dev/null)" || children=""
  if [[ -z "${children}" ]]; then
    echo 0
    return 0
  fi
  printf '%s\n' "${children}" | wc -l | tr -d ' '
}

confirm_restart() {
  local count
  count="$(supervised_pane_count)" || count=0
  [[ -n "${count}" ]] || count=0
  [[ "${count}" -eq 0 ]] && return 0
  [[ "${FORCE}" -eq 1 ]] && {
    echo "⚠️  --force: restarting superd and killing ${count} live pane(s)"
    return 0
  }
  echo "⚠️  superd is currently supervising ${count} live pane(s)."
  echo "    Restarting it sends SIGHUP to every one of them — including any running agent."
  read -r -p "    Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || {
    echo "aborted"
    exit 1
  }
}

if [[ "${UNINSTALL}" -eq 1 ]]; then
  confirm_restart
  launchctl bootout "${domain}/${LABEL}" 2> /dev/null || true
  rm -f "${PLIST}"
  echo "✓ ${LABEL} unloaded and ${PLIST} removed"
  echo "  (the binary at ${BINARY_INSTALLED} was left in place)"
  exit 0
fi

echo "→ building slopdesk-superd (release)"
(cd "${REPO_ROOT}/rust/slopdesk-superd" && cargo build --release)
[[ -x "${BINARY_SOURCE}" ]] || {
  echo "build produced no binary at ${BINARY_SOURCE}" >&2
  exit 1
}

confirm_restart

mkdir -p "$(dirname "${BINARY_INSTALLED}")" "${LOG_DIR}" "$(dirname "${PLIST}")"
# Replace by rename, not by overwrite: `cp` onto a running binary is ETXTBSY, and a partial write
# would leave launchd re-execing a truncated file.
install -m 755 "${BINARY_SOURCE}" "${BINARY_INSTALLED}.new"
mv -f "${BINARY_INSTALLED}.new" "${BINARY_INSTALLED}"

# `TMPDIR` is deliberately NOT set here: launchd already gives an agent the per-user, 0700
# `$TMPDIR` that makes superd's un-suffixed socket names safe, and hardcoding one would put superd
# and hostd in different directories — which is the pid-in-the-path bug wearing a new hat.
cat > "${PLIST}" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_INSTALLED}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart if superd ever dies. Its death costs every pane, so coming back fast is the
         difference between "the next pane you open works" and "nothing works until you notice". -->
    <key>KeepAlive</key>
    <true/>
    <!-- No throttle below the default 10s: a superd crash-looping on a bad build should be
         visible in the log, not hidden behind a tight respawn. -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/superd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/superd.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "${domain}/${LABEL}" 2> /dev/null || true
launchctl bootstrap "${domain}" "${PLIST}"
launchctl kickstart "${domain}/${LABEL}" > /dev/null

# Verify it is actually up, rather than trusting bootstrap's exit code — a job that exits
# immediately still bootstraps "successfully".
for _ in $(seq 1 30); do
  if launchctl print "${domain}/${LABEL}" 2> /dev/null | grep -q "state = running"; then
    echo "✓ ${LABEL} is running"
    echo "  binary: ${BINARY_INSTALLED}"
    echo "  log:    ${LOG_DIR}/superd.log"
    echo "  socket: \$TMPDIR/slopdesk-superd.sock"
    exit 0
  fi
  sleep 0.2
done

echo "✗ ${LABEL} did not reach 'running'. Last log lines:" >&2
tail -20 "${LOG_DIR}/superd.log" >&2 || true
exit 1
