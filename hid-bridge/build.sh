#!/usr/bin/env bash
# Builds aislopdesk-hid-bridge against the Karabiner-DriverKit-VirtualHIDDevice C++ client lib.
# We don't vendor the (large) pqrs dependency tree — instead fetch the pinned Karabiner release, drop our
# main.cpp into its example-client slot (which already wires every include path + the header-only deps),
# and build. Output: hid-bridge/build/aislopdesk-hid-bridge. No sudo needed to BUILD (only to RUN).
set -euo pipefail
VER="6.14.0" # keep in step with scripts/setup-virtual-hid.sh (client protocol must match the daemon)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="${HERE}/.build-deps/khid"
EX="${DEPS}/examples/virtual-hid-device-service-client"

echo "==> fetching Karabiner v${VER} (once)"
if [[ ! -d "${DEPS}/.git" ]]; then
  rm -rf "${DEPS}"
  mkdir -p "$(dirname "${DEPS}")"
  git clone --depth 1 --branch "v${VER}" --recursive \
    https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git "${DEPS}"
fi

echo "==> injecting bridge source"
cp "${HERE}/src/main.cpp" "${EX}/src/main.cpp"

echo "==> building"
(cd "${EX}" && make all > /dev/null)

mkdir -p "${HERE}/build"
cp "${EX}/build/Release/virtual-hid-device-service-client" "${HERE}/build/aislopdesk-hid-bridge"
echo "==> built: ${HERE}/build/aislopdesk-hid-bridge"
echo "    run as root:  sudo ${HERE}/build/aislopdesk-hid-bridge"
