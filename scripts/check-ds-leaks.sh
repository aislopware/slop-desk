#!/usr/bin/env bash
# Design-token leak RATCHET for the client UI design system (REBUILD-V2).
#
# The client UI (`Sources/AislopdeskClientUI`) drives every font size + corner radius through the `Slate`
# token layer (`DesignSystem/SlateDesign.swift`: `Slate.Typeface.*`, `Slate.Metric.radius*`). This gate fails
# on a NEW raw literal in that view tree, so a dimension can't silently bypass the scale. Text-only (no
# compile); runs in `make lint` / CI swift-lint.
#
# (History: an earlier ratchet was retired in the native-SwiftUI rewrite when the token target was deleted;
# a later rebuild re-introduced a token layer, so the ratchet is back — now enforcing the `Slate.*` scale.)
#
# Banned raw-literal shapes (both spellings of each, so a leak can't dodge the regex):
#   * font:   `.font(.system(size: N…))`           — `size: ?` tolerates the canonical + unspaced forms.
#   * radius: `cornerRadius: N` (labeled arg, incl. `.rect(cornerRadius: N)` / `RoundedRectangle(...)`)
#             AND `.cornerRadius(N)` (the SwiftUI `View` modifier) — `[(:]` covers the `(` and `:` spellings.
# Not matched (the legitimate token system): `.font(.system(size: size))` / `size: someVar` (no digit), and
# the token DEFINITIONS (`static let radiusCard: CGFloat = 8` is not `cornerRadius`-prefixed).
#
# Comment/string safety: this is a plain-text grep, so a doc comment that SHOWS a banned shape as an example
# (this repo's heavy comment style — e.g. the sibling comment in SlateDesign.swift) would otherwise false-fail
# a merge-gating check. The post-filter drops comment-ONLY lines (content starts with `//`, `///`, or a `*`
# block-comment body); real code with a trailing comment still matches on its code half. (SwiftFormat
# `--lint` runs FIRST in `make lint` and normalizes spacing, so only canonical spellings reach this gate.)
set -euo pipefail

root="Sources/AislopdeskClientUI"

# Fail CLOSED: a missing target dir is a setup/cwd error, not "clean". (The old script reported
# "intact" + exit 0 when $root was unreachable — a silent pass that could mask the whole gate.)
if [[ ! -d "${root}" ]]; then
  echo "check-ds-leaks: target dir '${root}' not found — run from the repo root." >&2
  exit 2
fi

font_pat='\.font\(\.system\(size: ?[0-9]'
radius_pat='cornerRadius[(:] *[0-9]'

# `|| true`: grep exits 1 on no-match, which is the PASS case here. Comment-only lines (after `path:line:`,
# the content starts with `//` / `///` / `*`) are filtered out so docs that mention the shape don't fail.
hits="$(grep -rnE "${font_pat}|${radius_pat}" "${root}" --include='*.swift' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || true)"

if [[ -n "${hits}" ]]; then
  echo "check-ds-leaks: RAW design-token literals found in ${root} — use the Slate token scale instead:" >&2
  echo "  font size    → Slate.Typeface.{display,body,base,footnote,small}" >&2
  echo "  cornerRadius → Slate.Metric.radius{Card,Tab,Control,Item,Small,Pill}" >&2
  echo "" >&2
  echo "${hits}" >&2
  exit 1
fi

echo "check-ds-leaks: no raw font/radius literals in ${root} — Slate token scale intact."
