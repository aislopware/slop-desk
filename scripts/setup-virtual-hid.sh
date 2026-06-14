#!/usr/bin/env bash
#
# setup-virtual-hid.sh — install + activate the virtual-HID keyboard backend on the HOST so the remote
# client can type into a macOS SecurityAgent login/password dialog (Secure Event Input blocks synthetic
# CGEvents but NOT HID-device input — see Sources/AislopdeskVideoHost/VirtualHIDKeyboard.swift header).
#
# We use the pre-built, Apple-notarized Karabiner-DriverKit-VirtualHIDDevice package (Public Domain). It
# is signed with pqrs.org's Apple-approved DriverKit entitlements, so YOU DO NOT need to disable SIP or
# request your own entitlement.
#
# ⚠️ NEEDS YOUR HANDS — twice, by macOS design (cannot be scripted around):
#   1. sudo (this script calls `sudo installer`) — enter your admin password.
#   2. A one-time APPROVAL: System Settings → Privacy & Security → scroll to the system-extension prompt
#      "System software from pqrs.org was blocked" → Allow.  (On some builds it's Login Items &
#      Extensions → Driver Extensions → enable Karabiner.) THIS IS THE CONSENT GATE — it is the whole
#      point that the machine owner must approve installing a driver. No tool can click it for you.
#
# After this succeeds the virtual keyboard is live; aislopdesk-videohostd's keyboard injection will route
# through it for secure dialogs (the wiring lands once this is verified on-device).
#
set -uo pipefail
VER="6.14.0"
PKG_URL="https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${VER}/Karabiner-DriverKit-VirtualHIDDevice-${VER}.pkg"
PKG="/tmp/Karabiner-DriverKit-VirtualHIDDevice-${VER}.pkg"
MGR="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
DAEMON="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

echo "==> 1/4 downloading Karabiner-DriverKit-VirtualHIDDevice v${VER}"
curl -fL "${PKG_URL}" -o "${PKG}" || {
  echo "download failed"
  exit 1
}

echo "==> 2/4 installing (needs sudo) …"
sudo installer -pkg "${PKG}" -target / || {
  echo "install failed"
  exit 1
}

echo "==> 3/4 activating the system extension …"
[[ -x "${MGR}" ]] || {
  echo "manager not found at ${MGR} — check the installed path"
  exit 1
}
"${MGR}" activate || true
echo
echo "    ┌──────────────────────────────────────────────────────────────────────────┐"
echo "    │  NOW APPROVE in System Settings → Privacy & Security (or Login Items &      │"
echo "    │  Extensions → Driver Extensions) → Allow 'pqrs.org'. Then re-run with        │"
echo "    │  '$0 --verify' to confirm + start the daemon.                                │"
echo "    └──────────────────────────────────────────────────────────────────────────┘"

if [[ "${1:-}" == "--verify" ]]; then
  echo "==> 4/4 verify + start daemon"
  systemextensionsctl list | grep -i pqrs || echo "  (dext not listed yet — finish the System Settings approval)"
  echo "  starting daemon (root) in the background…"
  # shellcheck disable=SC2024 # debug log in world-writable /tmp; current-user ownership is fine
  sudo "${DAEMON}" > /tmp/karabiner-vhid-daemon.log 2>&1 &
  sleep 1
  echo "  daemon log: /tmp/karabiner-vhid-daemon.log"
  echo "  DONE if 'systemextensionsctl list' shows pqrs as [activated enabled]."
fi
