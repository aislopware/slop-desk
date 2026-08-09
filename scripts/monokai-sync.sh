#!/usr/bin/env bash
# Upstream sync for the seeded workbench theme extension (CodeServerManager's
# `slopdesk.slopdesk-themes`, whose Monokai rows this script owns).
#
# scripts/monokai.pin records the Monokai Pro vsix version the vendored theme resources were
# generated from. The seeded extension carries the THEME DATA ONLY — none of the upstream
# extension's activation code rides along (that code is where the license prompt lives; a
# data-only seed never nags), which is why the marketplace extension is not installed directly.
#
# This script regenerates the resources from upstream:
#
#   1. download the pinned vsix from the VS Code Marketplace (or the newest one with --latest)
#   2. verify the vsix's theme contributions still match the eight variants EXPECTED below — an
#      upstream add/rename/removal fails loudly here and needs a matching Swift edit
#      (CodeServerManager.themeExtensionThemes). That Swift table is a SUPERSET: it also carries
#      the app's own themes (CodeServerManager.ownThemeResources), which have no upstream and
#      must never appear here
#   3. transform each theme: drop empty-string colour values (the workbench rejects them
#      per-key), retint the seven structural seam borders to the app's Slate divider token
#      (dark = foreground @ 0.10 = #fcfcfa1a, light = black @ 0.08 = #00000014) — the ONLY
#      colour departures from stock
#   4. write the minified results into Sources/SlopDeskHost/Resources/ under the slug names
#      the Swift manifest table references
#   5. with --latest: record the downloaded version in scripts/monokai.pin
#
# After a sync: review the git diff, run `make test-touched` (the theme-resource pins), commit.
# The host seeder drift-repairs the deployed extension folder byte-for-byte on the next
# hostd start — no version bump needed.
#
# Usage:
#   bash scripts/monokai-sync.sh            # regenerate from the pinned version
#   bash scripts/monokai-sync.sh --latest   # sync to the newest marketplace version + move the pin

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${REPO_ROOT}/scripts/monokai.pin"
RESOURCES_DIR="${REPO_ROOT}/Sources/SlopDeskHost/Resources"
PUBLISHER="monokai"
EXTENSION="theme-monokai-pro-vscode"
GALLERY="https://marketplace.visualstudio.com/_apis/public/gallery"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

VERSION="$(tr -d '[:space:]' < "${PIN_FILE}")"
UPDATE_PIN=0
if [[ "${1:-}" == "--latest" ]]; then
  UPDATE_PIN=1
  VERSION="$(curl -fsS -X POST "${GALLERY}/extensionquery" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json;api-version=3.0-preview.1' \
    -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${PUBLISHER}.${EXTENSION}\"}]}],\"flags\":529}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["extensions"][0]["versions"][0]["version"])')"
  echo "latest marketplace version: ${VERSION}"
fi

echo "syncing Monokai Pro themes @ ${VERSION}"
VSIX="${WORK_DIR}/monokai.vsix"
# The vspackage endpoint answers gzip-wrapped zip bytes; --compressed unwraps the gzip layer.
curl -fsSL --compressed -o "${VSIX}" \
  "${GALLERY}/publishers/${PUBLISHER}/vsextensions/${EXTENSION}/${VERSION}/vspackage"
unzip -qo "${VSIX}" -d "${WORK_DIR}/vsix"

python3 - "${WORK_DIR}/vsix/extension" "${RESOURCES_DIR}" << 'PYEOF'
import json
import pathlib
import sys

extension_dir = pathlib.Path(sys.argv[1])
resources_dir = pathlib.Path(sys.argv[2])

# Mirror of the VENDORED rows of CodeServerManager.themeExtensionThemes — label, dark?, resource
# slug. The app's own rows are deliberately absent: they come from no vsix. An upstream change to
# the theme SET must be folded into the Swift table by hand; this table (and the comparison below)
# makes that drift a loud failure instead of a silently dropped variant.
EXPECTED = [
    ("Monokai Pro", True, "monokai-pro"),
    ("Monokai Pro (Filter Octagon)", True, "monokai-pro-filter-octagon"),
    ("Monokai Pro (Filter Ristretto)", True, "monokai-pro-filter-ristretto"),
    ("Monokai Pro (Filter Spectrum)", True, "monokai-pro-filter-spectrum"),
    ("Monokai Pro (Filter Machine)", True, "monokai-pro-filter-machine"),
    ("Monokai Pro Light", False, "monokai-pro-light"),
    ("Monokai Pro Light (Filter Sun)", False, "monokai-pro-light-filter-sun"),
    ("Monokai Classic", True, "monokai-classic"),
]

SEAM_BORDER_KEYS = [
    "activityBar.border", "editorGroup.border", "panel.border", "sideBar.border",
    "statusBar.border", "statusBar.noFolderBorder", "titleBar.border",
]
DARK_SEAM = "#fcfcfa1a"   # Slate divider, dark: foreground #fcfcfa @ 0.10
LIGHT_SEAM = "#00000014"  # Slate divider, light: black @ 0.08

manifest = json.loads((extension_dir / "package.json").read_text())
contributed = [
    (theme["label"], theme["uiTheme"], theme["path"])
    for theme in manifest["contributes"]["themes"]
]
expected_pairs = sorted((label, "vs-dark" if dark else "vs") for label, dark, _ in EXPECTED)
contributed_pairs = sorted((label, ui) for label, ui, _ in contributed)
if expected_pairs != contributed_pairs:
    sys.exit(
        "upstream theme set changed — update CodeServerManager.themeExtensionThemes AND this "
        f"script's EXPECTED table.\n  vsix:     {contributed_pairs}\n  expected: {expected_pairs}"
    )

paths = {label: path for label, _, path in contributed}
for label, dark, slug in EXPECTED:
    theme = json.loads((extension_dir / paths[label]).read_text())
    if theme.get("name") != label:
        sys.exit(f"theme file for {label!r} names itself {theme.get('name')!r}")
    if not theme.get("tokenColors"):
        sys.exit(f"theme {label!r} lost its tokenColors")
    colors = theme["colors"]
    dropped = [key for key, value in colors.items() if value == ""]
    for key in dropped:
        del colors[key]
    for key in SEAM_BORDER_KEYS:
        colors[key] = DARK_SEAM if dark else LIGHT_SEAM
    out = resources_dir / f"{slug}.json"
    out.write_text(json.dumps(theme, separators=(",", ":")) + "\n")
    print(f"  {out.name}: {len(colors)} colors, {len(dropped)} empty dropped, seams -> "
          + (DARK_SEAM if dark else LIGHT_SEAM))
PYEOF

if [[ "${UPDATE_PIN}" == 1 ]]; then
  echo "${VERSION}" > "${PIN_FILE}"
  echo "pin advanced to ${VERSION}"
fi
echo "done — review the diff, run make test-touched, commit"
