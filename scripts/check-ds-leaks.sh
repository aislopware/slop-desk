#!/usr/bin/env bash
# Design-token MIGRATION RATCHET for the client UI (native-SwiftUI migration, 2026-07-03).
#
# The client UI is migrating from the custom `Slate` token layer to NATIVE SwiftUI design
# (system semantic colors, text styles, materials — see docs/DECISIONS.md "Native SwiftUI chrome
# migration"). The old ratchet banned raw font/radius literals to PROTECT the token scale; that
# polarity is now inverted: native idioms are the TARGET, and what must not grow is `Slate.*`
# usage itself. This gate counts `Slate.` references in `Sources/AislopdeskClientUI` and fails
# when the count EXCEEDS the recorded baseline — so the migration only moves forward (a PR can
# remove Slate usage, never add net-new). Text-only (no compile); runs in `make lint` / CI swift-lint.
#
# When a change legitimately LOWERS the count, refresh the baseline in the same commit:
#     scripts/check-ds-leaks.sh --update-baseline
# Raising the baseline by hand is the "I really mean it" escape hatch — it shows up in review.
#
# (History: ratchet v1 was retired in the first native-SwiftUI rewrite; v2 enforced the rebuilt
# `Slate` scale by banning raw literals; v3 — this one — inverts v2 for the native migration.)
set -euo pipefail

root="Sources/AislopdeskClientUI"
baseline_file="scripts/ds-migration-baseline.txt"

# Fail CLOSED: a missing target dir / baseline is a setup error, not "clean".
if [[ ! -d "${root}" ]]; then
  echo "check-ds-leaks: target dir '${root}' not found — run from the repo root." >&2
  exit 2
fi

# `\bSlate\.` catches every token read (Slate.Surface/Text/Line/State/Metric/Typeface/Anim/theme/
# colorScheme) without matching type DEFINITIONS (`enum Slate`, `SlateTheme`, `SlateTabRow`, …).
# `-o` counts every occurrence, not just matching lines, so a one-line cleanup still moves the number.
count="$(grep -rE '\bSlate\.' "${root}" --include='*.swift' -o | wc -l | tr -d ' ')"

if [[ "${1:-}" == "--update-baseline" ]]; then
  echo "${count}" > "${baseline_file}"
  echo "check-ds-leaks: baseline updated to ${count} Slate.* references."
  exit 0
fi

if [[ ! -f "${baseline_file}" ]]; then
  echo "check-ds-leaks: baseline file '${baseline_file}' missing — run scripts/check-ds-leaks.sh --update-baseline." >&2
  exit 2
fi
baseline="$(tr -d '[:space:]' < "${baseline_file}")"

if ((count > baseline)); then
  echo "check-ds-leaks: Slate.* usage GREW: ${count} references (baseline ${baseline})." >&2
  echo "  The client UI is migrating to native SwiftUI design (docs/DECISIONS.md, 2026-07-03):" >&2
  echo "  style new chrome with system semantic colors / .font text styles / materials," >&2
  echo "  not Slate tokens. If the increase is genuinely intended, raise ${baseline_file}." >&2
  exit 1
fi

if ((count < baseline)); then
  echo "check-ds-leaks: ${count} Slate.* references (baseline ${baseline}) — nice, ratchet down:" >&2
  echo "  run scripts/check-ds-leaks.sh --update-baseline and commit the new baseline." >&2
  exit 1
fi

echo "check-ds-leaks: ${count} Slate.* references — at baseline (${baseline}); migration holds."
