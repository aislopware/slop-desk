#!/usr/bin/env bash
#
# Web panel — the browser gate.
#
# `make test` covers everything about this panel that is PURE: the launch flags, the announce-line
# parse, the browser locator, the profile resolution, the manager's lifecycle against fake seams and
# the verb-23 routing. None of that starts a browser or binds a socket (hang-safety), which is
# exactly why it proves nothing about the two things only a real run can settle: whether Chrome
# still opens a debugging port on the flags we send it — it has changed those rules twice, with
# `--remote-allow-origins` in 111 and the default-profile refusal in 136 — and whether the relay
# carries Chrome's own bytes untouched.
#
# This script is that proof. It needs a Chrome-family browser installed. Nothing here is
# destructive: the browser it starts is headless, runs on a THROWAWAY profile under the temp
# directory, and is terminated at the end — a Chrome the user has open is never touched.
#
# Dialect, measurements and traps: docs/49-web-panel.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BROWSER="${SLOPDESK_WEB_BROWSER_BIN:-}"
if [[ -z "${BROWSER}" ]]; then
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
    if [[ -x "${candidate}" ]]; then
      BROWSER="${candidate}"
      break
    fi
  done
fi
if [[ -z "${BROWSER}" ]]; then
  echo "ERROR: no Chrome-family browser found (install: brew install --cask google-chrome)," >&2
  echo "       or set SLOPDESK_WEB_BROWSER_BIN to one." >&2
  exit 1
fi
echo "==> browser: ${BROWSER}"
"${BROWSER}" --version || true

# The gate the tests themselves read. Without it every case in the bundle returns early, which is
# what keeps a clean checkout green on a machine with no browser.
export SLOPDESK_WEB_HW=1

echo "==> swift test --filter WebBrowserHardwareTests"
swift test --filter WebBrowserHardwareTests

echo "==> Web browser gate OK"
