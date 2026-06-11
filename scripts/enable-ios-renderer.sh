#!/usr/bin/env bash
#
# enable-ios-renderer.sh — wire the libghostty renderer into the iOS client app.
#
# The iOS sibling of scripts/enable-macos-renderer.sh. The committed
# `Apps/ClientApp-iOS/project.yml` now ships with the renderer ENABLED (it references the
# gitignored `ThirdParty/ghostty/libghostty.xcframework`, so that UNIVERSAL xcframework — carrying
# the ios-arm64 device + ios-arm64-simulator slices — must be built FIRST or the iOS build fails to
# link). This script is IDEMPOTENT: it (re-)asserts the renderer wiring in project.yml and
# regenerates the .xcodeproj — a no-op if the wiring is already present. It is how that wiring was
# authored, and remains the way to restore it after a revert:
#
#     XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh
#     bash scripts/enable-ios-renderer.sh
#
# WHAT it does (idempotent — safe to re-run):
#   1. Preflight: the xcframework must exist with BOTH ios-arm64 and ios-arm64-simulator slices.
#   2. Inject into Apps/ClientApp-iOS/project.yml (guarded — only if not already present):
#        a. sources:      += integration/GhosttySurface (GhosttySurface.swift + GhosttyTerminalView.swift).
#        b. dependencies: += libghostty.xcframework (embed: true) — the link-time C-ABI symbols.
#        c. settings.base: += SWIFT_INCLUDE_PATHS (CGhostty module map → `import CGhostty`
#                            resolves, `#if canImport(CGhostty)` flips true) + OTHER_LDFLAGS
#                            (the iOS system frameworks libghostty's vendored C/C++ deps need —
#                            NO Carbon, which is macOS-only). ARCHS is NOT pinned: the
#                            xcframework auto-selects the device vs. simulator slice by platform.
#   3. Run `xcodegen generate` to regenerate the (gitignored) .xcodeproj from the spec.
#
# Restore the committed placeholder state afterwards:
#   git checkout -- Apps/ClientApp-iOS/project.yml
#   xcodegen generate --spec Apps/ClientApp-iOS/project.yml
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/Apps/ClientApp-iOS/project.yml"
XCFRAMEWORK="$REPO_ROOT/ThirdParty/ghostty/libghostty.xcframework"

# ── 1. Preflight: the xcframework must exist with both iOS slices ────────────────────────────
if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "ERROR: $XCFRAMEWORK is missing." >&2
  echo "       Build the UNIVERSAL xcframework first (it carries the iOS slices):" >&2
  echo "         XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh" >&2
  exit 1
fi
for slice in ios-arm64 ios-arm64-simulator; do
  if [[ ! -d "$XCFRAMEWORK/$slice" ]]; then
    echo "ERROR: $XCFRAMEWORK has no '$slice' slice." >&2
    echo "       The iOS app needs both ios-arm64 (device) and ios-arm64-simulator. Build the" >&2
    echo "       UNIVERSAL xcframework (the default 'native' target is macOS-only):" >&2
    echo "         XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh" >&2
    exit 1
  fi
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen not found on PATH (install: brew install xcodegen)." >&2
  exit 1
fi

# ── 2. Inject the renderer wiring (idempotent) ──────────────────────────────────────────────
SPEC="$SPEC" python3 - <<'PY'
import os, sys

spec_path = os.environ["SPEC"]
with open(spec_path, "r") as f:
    text = f.read()

changed = False

# (a) sources: add the integration/GhosttySurface directory after `- path: ../Shared`.
src_anchor = "    sources:\n      - path: ../Shared\n"
src_block = (
    "    sources:\n"
    "      - path: ../Shared\n"
    "      # PATH 1 (libghostty renderer): the gated renderer host + binding (GhosttySurface.swift\n"
    "      # + GhosttyTerminalView.swift). NOT members of any Package.swift target — they join THIS\n"
    "      # app target so `import CGhostty` resolves and `#if canImport(CGhostty)` flips true.\n"
    "      - path: ../../ThirdParty/ghostty/integration/GhosttySurface\n"
)
if "integration/GhosttySurface" not in text:
    if src_anchor not in text:
        sys.exit("ERROR: could not find the `- path: ../Shared` sources anchor in project.yml")
    text = text.replace(src_anchor, src_block, 1)
    changed = True

# (b) dependencies: add the xcframework after the AislopdeskVideoClient product dependency.
dep_anchor = (
    "      - package: Aislopdesk\n"
    "        product: AislopdeskVideoClient\n"
)
dep_block = (
    "      - package: Aislopdesk\n"
    "        product: AislopdeskVideoClient\n"
    "      # PATH 1 (libghostty renderer): the libghostty static binary (link-time `ghostty`\n"
    "      # C-ABI symbols) as an xcframework. The UNIVERSAL build ships ios-arm64 (device) +\n"
    "      # ios-arm64-simulator slices, both built on this host against the iOS 26.5 SDK; the\n"
    "      # xcframework auto-selects the right slice per destination.\n"
    "      - framework: ../../ThirdParty/ghostty/libghostty.xcframework\n"
    "        embed: true\n"
)
if "libghostty.xcframework" not in text:
    if dep_anchor not in text:
        sys.exit("ERROR: could not find the AislopdeskVideoClient dependency anchor in project.yml")
    text = text.replace(dep_anchor, dep_block, 1)
    changed = True

# (c) settings.base: add the renderer build settings after CODE_SIGN_STYLE: Automatic.
set_anchor = "        CODE_SIGN_STYLE: Automatic\n"
set_block = (
    "        CODE_SIGN_STYLE: Automatic\n"
    "        # PATH 1 (libghostty renderer): point the Swift importer at the CGhostty clang\n"
    "        # module map (module.modulemap + vendored ghostty.h) so `import CGhostty` resolves\n"
    "        # and `#if canImport(CGhostty)` flips true → GhosttyTerminalView/GhosttySurface\n"
    "        # compile into this target and link against libghostty.xcframework.\n"
    "        SWIFT_INCLUDE_PATHS: $(SRCROOT)/../../ThirdParty/ghostty/integration/CGhostty\n"
    "        # The xcframework ships ios-arm64 (device) + ios-arm64-simulator — both arm64\n"
    "        # only (Apple-silicon target). Pin ARCHS=arm64 so a generic 'iOS Simulator'\n"
    "        # destination does NOT also demand an x86_64 slice (which would fail to link).\n"
    "        ARCHS: arm64\n"
    "        ONLY_ACTIVE_ARCH: \"NO\"\n"
    "        # libghostty vendors C/C++ deps (Dear ImGui, spirv-cross, glslang, FreeType,\n"
    "        # sentry, oniguruma, …) referencing the C++ runtime + a few iOS system frameworks\n"
    "        # (CoreText/CoreGraphics for fonts, QuartzCore/Metal for the layer). NO Carbon —\n"
    "        # it is macOS-only; the iOS slice does not reference it.\n"
    "        OTHER_LDFLAGS:\n"
    "          - -lc++\n"
    "          - -framework\n"
    "          - CoreText\n"
    "          - -framework\n"
    "          - CoreGraphics\n"
    "          - -framework\n"
    "          - QuartzCore\n"
    "          - -framework\n"
    "          - Metal\n"
)
if "SWIFT_INCLUDE_PATHS" not in text:
    if set_anchor not in text:
        sys.exit("ERROR: could not find the CODE_SIGN_STYLE settings anchor in project.yml")
    text = text.replace(set_anchor, set_block, 1)
    changed = True

if changed:
    with open(spec_path, "w") as f:
        f.write(text)
    print("==> project.yml: iOS renderer wiring injected.")
else:
    print("==> project.yml: iOS renderer wiring already present (idempotent no-op).")
PY

# ── 3. Regenerate the .xcodeproj from the now-enabled spec ───────────────────────────────────
echo "==> xcodegen generate --spec $SPEC"
xcodegen generate --spec "$SPEC"

cat <<EOF
==> iOS renderer ENABLED.
    Build (simulator, unsigned; ARCHS=arm64 is pinned in the spec):
      xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj -scheme ClientApp-iOS \\
        -destination 'generic/platform=iOS Simulator' \\
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    Restore: git checkout -- Apps/ClientApp-iOS/project.yml && \\
               xcodegen generate --spec Apps/ClientApp-iOS/project.yml
EOF
