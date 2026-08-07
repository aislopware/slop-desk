#!/usr/bin/env bash
# Measures the code panel backend's spawn → "HTTP server listening" latency — the half of
# panel-open cost the HOST owns (the other half, the workbench boot inside the client's webview,
# is browser-side and measured with the workbench's own `code/*` performance marks).
#
# Why this exists: until the 2026-08-07 startup-latency pass nothing in-repo had ever measured
# this chain — the numbers behind the prewarm decision (spawn→listen ~0.4 s warm FS / ~1.2 s cold)
# lived in one session's scratchpad. This script makes the measurement repeatable, so a
# code-server pin bump (docs/46 — "bumping a pin has a tail") can check the boot didn't regress.
#
# Each run spawns the binary against a THROWAWAY HOME (mktemp) — the seed/extension state of the
# real profile is deliberately out of frame; this measures the server bootstrap, not the profile.
# The binary resolves like the host does: SLOPDESK_CODE_SERVER_BIN → vendored prefix → PATH.
#
# Usage: scripts/measure-code-server-start.sh [runs]   # default 3

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${1:-3}"

resolve_binary() {
  if [[ -n "${SLOPDESK_CODE_SERVER_BIN:-}" ]]; then
    echo "${SLOPDESK_CODE_SERVER_BIN}"
    return
  fi
  local vendored="${REPO_ROOT}/ThirdParty/tools/.prefix/bin/code-server"
  if [[ -x "${vendored}" ]]; then
    echo "${vendored}"
    return
  fi
  command -v code-server || true
}

BINARY="$(resolve_binary)"
if [[ -z "${BINARY}" || ! -x "${BINARY}" ]]; then
  echo "measure-code-server-start: no code-server binary (run 'make provision')" >&2
  exit 1
fi
echo "binary: ${BINARY}"
echo "version: $("${BINARY}" --version | head -1)"

measure_once() {
  local fixture_home log pid start end
  fixture_home="$(mktemp -d /tmp/sd-cs-measure.XXXXXX)"
  log="${fixture_home}/out.log"
  start="$(python3 -c 'import time; print(time.time())')"
  HOME="${fixture_home}" "${BINARY}" \
    --auth none --bind-addr 127.0.0.1:0 \
    --disable-telemetry --disable-update-check \
    --disable-workspace-trust --disable-getting-started-override \
    > "${log}" 2>&1 &
  pid=$!
  local waited=0
  while ! grep -q 'HTTP server listening' "${log}" 2> /dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [[ ${waited} -gt 1200 ]]; then
      echo "measure-code-server-start: no listen line after 60s (log: ${log})" >&2
      kill "${pid}" 2> /dev/null || true
      exit 1
    fi
  done
  end="$(python3 -c 'import time; print(time.time())')"
  kill "${pid}" 2> /dev/null || true
  wait "${pid}" 2> /dev/null || true
  rm -rf "${fixture_home}"
  python3 -c "print('%.2f' % (${end} - ${start}))"
}

echo "spawn → listening, ${RUNS} runs (throwaway HOME each):"
for i in $(seq 1 "${RUNS}"); do
  echo "  run ${i}: $(measure_once)s"
done

# Live state of the real host, if one is up: a prewarmed hostd should already show a code-server
# child here — a missing child right after a hostd restart is the regression this section catches.
LIVE_PID="$(pgrep -f 'code-server.*--bind-addr 0.0.0.0:0' | head -1 || true)"
if [[ -n "${LIVE_PID}" ]]; then
  echo "live host child: pid ${LIVE_PID} up since $(ps -o lstart= -p "${LIVE_PID}" | sed 's/^ *//')"
  if ps -o command= -p "${LIVE_PID}" | grep -q -- '--idle-timeout-seconds'; then
    echo "  WARNING: live child still runs with --idle-timeout-seconds (pre-prewarm build?)" >&2
  fi
else
  echo "live host child: none (no hostd running, or its prewarm failed)"
fi
