# E15 carry-over directives (REQUIRED — fold into the E15 plan)

E15 (Theming editor + custom/import themes + fonts parity) inherits **no behavioral fixes from
earlier epics** — E12 (the immediately-prior epic) closed all of its review findings before this
point. This file carries forward only the **binding scope reductions** as hard exclusions. Most do
not constrain theming/fonts, but one (vertical-tabs-only) bites the theme editor's chrome-region
work, so read it carefully.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Vertical-tabs-only — the one that bites E15.** The theme editor exposes per-region chrome
  colours (M5/M6: "chrome regions", container tokens per theme). slopdesk is **vertical-tabs-only**
  (a committed product decision in `docs/DECISIONS.md`, encoded at E7-close — the horizontal/top tab
  bar was deliberately dropped per the user). So the theme editor's chrome regions must
  **NOT** introduce a "tab bar" region that implies a horizontal/top tab strip, and must not add a
  theme key or swatch whose only purpose is colouring a top tab bar. Theme the **sidebar/vertical
  rail** tab chrome instead. If a theme's reference screenshot shows a top-tab-bar region, map it to the
  vertical rail or omit it — never add the horizontal variant.
- **No SSH-host filter.** Standing exclusion (primary impact E11). Not relevant to theming/fonts, but
  do not add an SSH-host filter/pill in any settings surface E15 touches.
- **Agents = Claude Code only initially.** Standing exclusion (primary impact E13). Not relevant to
  theming/fonts; noted so no cross-reference reintroduces multi-agent UI.

## NOT for E15 (routed elsewhere — do not action here)

- **Recipes / snippets settings content** (the deferred Recipes library) is **E16**, not E15. E15
  owns Appearance→Theme/Font only; do not start the Recipes text-snippet library here.
- **Editor settings section population** (the other E7-deferred empty section) is a separate
  follow-up (needs a file-editor), not E15.
