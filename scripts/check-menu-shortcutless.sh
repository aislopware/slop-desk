#!/usr/bin/env bash
# Menu-bar shortcut-LESS RATCHET (E1 N6).
#
# `WorkspaceCommands.swift` is a DISCOVERABILITY-ONLY menu over the binding registry. The app-level NSEvent
# `.keyDown` monitor (`WorkspaceKeyDispatcher`) OWNS chord dispatch — including the multi-key tmux/zellij
# prefix a `.keyboardShortcut` cannot express. A `.keyboardShortcut` on a menu item would (a) DOUBLE-FIRE
# alongside the monitor for a single-chord binding, and (b) SWALLOW a prefix sequence's follow-up key before
# the terminal first responder (libghostty) sees it. So the menu file must carry NO `.keyboardShortcut`.
#
# This gate fails on a `.keyboardShortcut(` appearing as CODE in `WorkspaceCommands.swift` (a doc comment
# that mentions the token is fine — the post-filter drops comment-only lines). Text-only (no compile);
# runs in `make lint` / CI swift-lint. See docs/DECISIONS.md (E1 menu-bar entry).
set -euo pipefail

file="Sources/AislopdeskClientUI/Commands/WorkspaceCommands.swift"

# Fail CLOSED: a missing file is a setup/cwd error (or the file was renamed without updating this gate),
# not "clean" — surface it rather than silently passing.
if [[ ! -f "${file}" ]]; then
  echo "check-menu-shortcutless: target file '${file}' not found — run from the repo root." >&2
  exit 2
fi

# `|| true`: grep exits 1 on no-match, which is the PASS case here. Comment-only lines (after `path:line:`,
# the content starts with `//` / `///` / `*`) are filtered out so the file's OWN docs that mention the token
# don't fail the gate.
hits="$(grep -nE '\.keyboardShortcut\(' "${file}" |
  grep -vE '^[0-9]+:[[:space:]]*(//|\*)' || true)"

if [[ -n "${hits}" ]]; then
  echo "check-menu-shortcutless: '.keyboardShortcut(' found in ${file} — the menu MUST stay shortcut-less:" >&2
  echo "  The NSEvent dispatcher (WorkspaceKeyDispatcher) owns chord dispatch. A menu shortcut double-fires" >&2
  echo "  alongside it / swallows a multi-key prefix tail before libghostty. Append the glyph as a hint Text" >&2
  echo "  instead (see menuTitle(for:))." >&2
  echo "" >&2
  echo "${hits}" >&2
  exit 1
fi

echo "check-menu-shortcutless: ${file} carries no .keyboardShortcut — menu stays discoverability-only."
