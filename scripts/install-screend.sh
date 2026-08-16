#!/usr/bin/env bash
# Installs (or reinstalls) `slopdesk-screend` as a launchd LaunchAgent.
#
# screend is the VT screen engine (docs/52): the terminal parser, the snapshot renderer and the
# overprint collapser that hostd used to run in-process at 17.9 MiB/s.
#
#   scripts/install-screend.sh            # build, install the plist, load, verify
#   scripts/install-screend.sh --uninstall
#
# Unlike superd, restarting this one costs NOTHING durable: screend holds no children and no
# durable state — its per-pane grids are a cache the next repaint refills, and hostd starts one
# itself if none is listening. The LaunchAgent exists so the first cold reattach of the day does
# not pay the spawn, and so a crashed engine comes back without a hostd restart. There is no
# confirmation prompt here for exactly that reason.
set -euo pipefail

readonly LABEL="com.slopdesk.screend"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOG_DIR="${HOME}/Library/Logs/SlopDesk"
readonly BINARY_SOURCE="${REPO_ROOT}/rust/slopdesk-screend/target/release/slopdesk-screend"
# Installed OUT of the build tree, for the same reason superd is: launchd re-execs this path, and a
# `cargo clean` must not be able to leave the agent pointing at nothing.
readonly BINARY_INSTALLED="${HOME}/Library/Application Support/SlopDesk/bin/slopdesk-screend"

UNINSTALL=0
for argument in "$@"; do
  case "${argument}" in
    --uninstall) UNINSTALL=1 ;;
    # Accepted and ignored: `--force` means "kill live panes anyway" for superd, and screend has
    # none. Taking the flag keeps the two installers callable the same way.
    --force) ;;
    *)
      echo "usage: $0 [--uninstall]" >&2
      exit 2
      ;;
  esac
done

domain="gui/$(id -u)"

if [[ "${UNINSTALL}" -eq 1 ]]; then
  launchctl bootout "${domain}/${LABEL}" 2> /dev/null || true
  rm -f "${PLIST}"
  echo "✓ ${LABEL} unloaded and ${PLIST} removed"
  echo "  (the binary at ${BINARY_INSTALLED} was left in place; hostd will start it on demand)"
  exit 0
fi

echo "→ building slopdesk-screend (release)"
(cd "${REPO_ROOT}/rust/slopdesk-screend" && cargo build --release)
[[ -x "${BINARY_SOURCE}" ]] || {
  echo "build produced no binary at ${BINARY_SOURCE}" >&2
  exit 1
}

mkdir -p "$(dirname "${BINARY_INSTALLED}")" "${LOG_DIR}" "$(dirname "${PLIST}")"
# Replace by rename, not by overwrite: `cp` onto a running binary is ETXTBSY, and a partial write
# would leave launchd re-execing a truncated file.
install -m 755 "${BINARY_SOURCE}" "${BINARY_INSTALLED}.new"
mv -f "${BINARY_INSTALLED}.new" "${BINARY_INSTALLED}"

# `TMPDIR` is deliberately NOT set here, for the reason spelled out in install-superd.sh: launchd
# already gives an agent the per-user 0700 `$TMPDIR` that makes an un-suffixed socket name safe,
# and hardcoding one would put screend and hostd in different directories.
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
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- Never exit on idleness: this copy's lifetime belongs to launchd, and KeepAlive would
             relaunch it seconds later anyway — an exit/respawn loop for as long as nobody uses it.
             An engine hostd started for itself keeps the default timeout and goes away with it. -->
        <key>SLOPDESK_SCREEND_IDLE_EXIT</key>
        <string>0</string>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/screend.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/screend.log</string>
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
    echo "  log:    ${LOG_DIR}/screend.log"
    echo "  socket: \$TMPDIR/slopdesk-screend.sock"
    exit 0
  fi
  sleep 0.2
done

echo "✗ ${LABEL} did not reach 'running'. Last log lines:" >&2
tail -20 "${LOG_DIR}/screend.log" >&2 || true
exit 1
