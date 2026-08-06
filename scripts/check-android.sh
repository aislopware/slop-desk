#!/usr/bin/env bash
#
# Android panel — the hardware gate.
#
# `make test` covers everything about this panel that is PURE: the scrcpy stream reassembler, the
# control-message encoder, the layout, the scroll machine, the logcat parser, the device decode and
# the bridge's ack/stream split. None of that opens a socket (hang-safety), which is exactly why it
# proves nothing about the two things that can only be wrong against a real device: whether the
# `scrcpy-server` handshake still completes at the pinned version, and whether the bridge's own
# line-JSON-then-bytes framing survives a real `adb`.
#
# This script is that proof. It needs a booted emulator or an attached phone; the `adb` and the
# `scrcpy-server` jar are vendored (`make provision`). Nothing here is destructive: it lists, screenshots,
# reads logcat and opens ONE mirror session, which it closes.
#
# Dialect, measurements and traps: docs/48-android-panel.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Same order production uses (HostServiceProcess.searchDirectories): override, then the vendored
# prefix, then PATH. A gate that proved the handshake against a different `adb` than the panel runs
# would be proving the wrong thing.
ADB="${SLOPDESK_ADB_BIN:-}"
if [[ -z "${ADB}" ]] && [[ -x "${REPO_ROOT}/ThirdParty/tools/.prefix/bin/adb" ]]; then
  ADB="${REPO_ROOT}/ThirdParty/tools/.prefix/bin/adb"
fi
if [[ -z "${ADB}" ]]; then
  ADB="$(command -v adb || true)"
fi
if [[ -z "${ADB}" ]]; then
  echo "ERROR: no adb found (provision it: make provision)," >&2
  echo "       or set SLOPDESK_ADB_BIN to one." >&2
  exit 1
fi
echo "==> adb: ${ADB}"

# A device in any state other than `device` cannot be mirrored: `unauthorized` in particular means a
# dialog is waiting on the device's own screen, and every shell below would fail with a message that
# does not say so.
READY_COUNT="$("${ADB}" devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ')"
if [[ "${READY_COUNT}" -eq 0 ]]; then
  echo "ERROR: no device in state 'device'. Boot an emulator or plug a phone in and accept the" >&2
  echo "       USB-debugging prompt, then re-run." >&2
  "${ADB}" devices >&2
  exit 1
fi
echo "==> ${READY_COUNT} device(s) ready"

JAR="${SLOPDESK_ANDROID_SERVER_JAR:-}"
if [[ -z "${JAR}" ]]; then
  for candidate in \
    "${REPO_ROOT}/ThirdParty/tools/vendor/scrcpy-server" \
    /opt/homebrew/share/scrcpy/scrcpy-server /usr/local/share/scrcpy/scrcpy-server; do
    if [[ -f "${candidate}" ]]; then
      JAR="${candidate}"
      break
    fi
  done
fi
if [[ -z "${JAR}" ]]; then
  echo "ERROR: no scrcpy-server jar found — it is committed at ThirdParty/tools/vendor/, so this" >&2
  echo "       means a broken checkout. Restore it, or set" >&2
  echo "       SLOPDESK_ANDROID_SERVER_JAR to one." >&2
  exit 1
fi
echo "==> scrcpy-server: ${JAR}"
export SLOPDESK_ANDROID_SERVER_JAR="${JAR}"

# The gate the tests themselves read. Without it every case in the bundle returns early, which is
# what keeps a clean checkout green on a machine that has never seen the Android SDK.
export SLOPDESK_ANDROID_HW=1

echo "==> swift test --filter AndroidBridgeHardwareTests"
swift test --filter AndroidBridgeHardwareTests

echo "==> Android hardware gate OK"
