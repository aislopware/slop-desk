#!/usr/bin/env bash
#
# enable-macos-renderer.sh — wire the libghostty renderer into the macOS client app.
#
# WHY this exists (commit discipline): the committed `Apps/ClientApp-macOS/project.yml` is
# kept in its PLACEHOLDER state so the default macOS app builds on machines that do NOT have
# the (gitignored, 64 MB) `ThirdParty/ghostty/libghostty.xcframework`. xcodegen resolves the
# framework path at generate-time, so committing the renderer-enabled spec would break every
# checkout without the artifact. This script reproduces the renderer wiring ON DEMAND for a
# developer who HAS built the xcframework (see ThirdParty/ghostty/build-libghostty.sh).
#
# WHAT it does (idempotent — safe to re-run):
#   1. Preflight: the xcframework must exist (with a macos-arm64 slice). If absent, fail with
#      the exact build command.
#   2. Inject three things into Apps/ClientApp-macOS/project.yml (only if not already present):
#        a. sources:      += the integration/GhosttySurface dir (GhosttySurface.swift +
#                            GhosttyTerminalView.swift — they are NOT in any Package.swift target).
#        b. dependencies: += the libghostty.xcframework (embed: true) — the link-time C-ABI symbols.
#        c. settings.base: += SWIFT_INCLUDE_PATHS (CGhostty module map → `import CGhostty`
#                            resolves, `#if canImport(CGhostty)` flips true), ARCHS=arm64 +
#                            ONLY_ACTIVE_ARCH=NO (xcframework ships only macos-arm64), and
#                            OTHER_LDFLAGS (-lc++ + Carbon/CoreText/CoreGraphics/QuartzCore/Metal
#                            for libghostty's vendored C/C++ deps).
#   3. Run `xcodegen generate` to regenerate the (gitignored) .xcodeproj from the spec.
#
# AFTER running this, the project.yml is in the renderer-ENABLED state (modified vs HEAD).
# To restore the committed placeholder state (so `git status` is clean again):
#   git checkout -- Apps/ClientApp-macOS/project.yml
#   xcodegen generate --spec Apps/ClientApp-macOS/project.yml   # regen the placeholder .xcodeproj
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/Apps/ClientApp-macOS/project.yml"
XCFRAMEWORK="$REPO_ROOT/ThirdParty/ghostty/libghostty.xcframework"

# ── 1. Preflight: the xcframework must exist with a macos-arm64 slice ───────────────────────
if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "ERROR: $XCFRAMEWORK is missing." >&2
  echo "       Build it first on a macOS host with a <= 15.x SDK (or this 26.5 host via the" >&2
  echo "       SDK-shim recipe), then re-run:" >&2
  echo "         bash ThirdParty/ghostty/build-libghostty.sh" >&2
  exit 1
fi
# Accept either the native single slice (macos-arm64) or the universal build's macOS slice
# (macos-arm64_x86_64) — the app pins ARCHS=arm64 and both carry an arm64 slice.
if [[ ! -d "$XCFRAMEWORK/macos-arm64" && ! -d "$XCFRAMEWORK/macos-arm64_x86_64" ]]; then
  echo "ERROR: $XCFRAMEWORK has no macOS arm64 slice (macos-arm64 or macos-arm64_x86_64)." >&2
  echo "       The macOS app pins ARCHS=arm64 and needs that slice. Rebuild the xcframework:" >&2
  echo "         bash ThirdParty/ghostty/build-libghostty.sh                 # native (macos only)" >&2
  echo "         XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh  # + iOS" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen not found on PATH (install: brew install xcodegen)." >&2
  exit 1
fi

# ── 2. Inject the renderer wiring (idempotent) ──────────────────────────────────────────────
# We edit in Python (yaml round-trip would reorder/strip comments; a structural insert keyed on
# the placeholder anchors is precise and idempotent). Each insert is guarded by a presence check.
SPEC="$SPEC" python3 - <<'PY'
import os, sys

spec_path = os.environ["SPEC"]
with open(spec_path, "r") as f:
    text = f.read()

changed = False

# (a) sources: add the integration/GhosttySurface directory after the `- path: ../Shared` entry.
src_anchor = "    sources:\n      - path: ../Shared\n"
src_block = (
    "    sources:\n"
    "      - path: ../Shared\n"
    "      # PATH 1 (libghostty renderer): the gated renderer host + binding. This directory\n"
    "      # carries BOTH GhosttySurface.swift (the @MainActor TerminalSurface binding over the\n"
    "      # CGhostty C ABI) and GhosttyTerminalView.swift (the TerminalRenderingView conformer).\n"
    "      # They are NOT members of any Package.swift target — they join THIS app target so\n"
    "      # `import CGhostty` resolves and `#if canImport(CGhostty)` flips true.\n"
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
    "      # PATH 1 (libghostty renderer): the libghostty static binary (the link-time\n"
    "      # `ghostty` C-ABI symbols) packaged as an xcframework, built ON this macOS-26.5 host\n"
    "      # by ThirdParty/ghostty/build-libghostty.sh. The universal build also ships iOS\n"
    "      # slices (see scripts/enable-ios-renderer.sh); this macOS target links the macOS slice.\n"
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
    "        # libghostty.xcframework currently ships ONLY a macos-arm64 slice (built on this\n"
    "        # macOS-26.5 arm64 host; the x86_64/universal slice needs a separate build). Pin\n"
    "        # the macOS app to arm64 so the link resolves against that slice. (Apple-silicon\n"
    "        # is the target; Intel macOS is EOL for this project.)\n"
    "        ARCHS: arm64\n"
    "        ONLY_ACTIVE_ARCH: \"NO\"\n"
    "        # libghostty vendors C/C++ dependencies (Dear ImGui, spirv-cross, glslang,\n"
    "        # FreeType, sentry, oniguruma, …). The static lib references the C++ runtime and\n"
    "        # a handful of system frameworks (Carbon for TIS keyboard-layout APIs, CoreText/\n"
    "        # CoreGraphics for font rendering). Link them so the libghostty symbols resolve.\n"
    "        OTHER_LDFLAGS:\n"
    "          - -lc++\n"
    "          - -framework\n"
    "          - Carbon\n"
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
    print("==> project.yml: renderer wiring injected.")
else:
    print("==> project.yml: renderer wiring already present (idempotent no-op).")
PY

# ── 3. Regenerate the .xcodeproj from the now-enabled spec ───────────────────────────────────
echo "==> xcodegen generate --spec $SPEC"
xcodegen generate --spec "$SPEC"

cat <<EOF
==> macOS renderer ENABLED.
    Build:   xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj \\
               -scheme ClientApp-macOS -destination 'generic/platform=macOS' \\
               CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    Restore: git checkout -- Apps/ClientApp-macOS/project.yml && \\
               xcodegen generate --spec Apps/ClientApp-macOS/project.yml
EOF
