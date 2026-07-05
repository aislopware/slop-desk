# E15 carry-over directives (REQUIRED — fold into the E15 plan)

E15 (Theming editor + custom/import themes + fonts parity) inherits **no behavioral fixes** — E12 closed all its review findings. This file carries only the **binding scope reductions** as hard exclusions. One (vertical-tabs-only) bites the theme editor's chrome-region work.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Vertical-tabs-only — the one that bites E15.** The theme editor exposes per-region chrome colours (M5/M6: "chrome regions", container tokens per theme). slopdesk is **vertical-tabs-only** (committed in `docs/DECISIONS.md`, encoded at E7-close — horizontal/top tab bar dropped per the user). So chrome regions must **NOT** add a "tab bar" region implying a horizontal/top tab strip, nor a theme key/swatch whose only purpose is colouring a top tab bar. Theme the **sidebar/vertical rail** tab chrome instead. If a reference screenshot shows a top-tab-bar region, map it to the vertical rail or omit it — never add the horizontal variant.
- **No SSH-host filter.** Standing exclusion (primary impact E11). Not relevant to theming/fonts, but do not add an SSH-host filter/pill in any settings surface E15 touches.
- **Agents = Claude Code only initially.** Standing exclusion (primary impact E13). Not relevant to theming/fonts; noted so no cross-reference reintroduces multi-agent UI.

## NOT for E15 (routed elsewhere — do not action here)

- **Recipes / snippets settings content** (deferred Recipes library) is **E16**. E15 owns Appearance→Theme/Font only; do not start the Recipes text-snippet library here.
- **Editor settings section population** (the other E7-deferred empty section) is a separate follow-up (needs a file-editor), not E15.
