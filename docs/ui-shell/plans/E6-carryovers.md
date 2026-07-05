# E6 carry-overs (required acceptance criteria)

Fold into E6's acceptance criteria; design + implementation MUST honor them.

## Scope reduction (BINDING — user directive, do NOT build)

**Horizontal tab bar is DROPPED.** slopdesk is **vertical-tabs-only** (already encoded in E7 Settings → Appearance → Tabs, and in `e7-close` commit `f3ea994`).

For E6:

- Render tab rows (`SlateTabRow`: status dot, `#N` number badge, cwd subtitle, shell/process trailing label) in the **VERTICAL left sidebar ONLY**. No horizontal/top tab strip, tab-bar layout selector, or "Tabs Top / Tabs Bottom" variant.
- The **grouping/sort hamburger** (None/By-Project/By-Date grouping; Created/Updated/Manual sort) lives in the **vertical sidebar header** and must mutate the **store order** (not a local `@State`) — single source of truth for row order.
- The **tab search/filter** field also lives in the vertical sidebar (reuse `RailRowsBuilder.filtered`).
- The absent horizontal-tab-bar option is an intentional exclusion, not a gap. Reference screenshots showing a horizontal bar are out of scope; match only the vertical-sidebar presentation.

## No earlier-epic fidelity mediums route to E6

E1's and E3's carry-over mediums were consumed by E7 (`e3a0594c` … `f3ea994`); E4's 4 mediums route to **E9** (`E9-carryovers.md`). E5's residual mediums are find/search-surface only (whole-word toggle deferred as an engine gap) and do not touch the sidebar. E6 carries only the scope-reduction guardrail above.

## Deferred (honest gap — recorded, not silently missed): sidebar hamburger DIVIDER section

⏸️ The sort/group hamburger (`SlateSortMenuButton`, `Chrome/SlateTabRow.swift`) spec documents a THIRD menu section — **DIVIDER: "Insert Divider" + "Remove All Dividers"** (`user-interface__window-tab-split.md:191-194`, `group-tabs.png`) — dropping a visual section separator between sidebar tab rows. Current build ships only **GROUP** and **ORDER**.

This is a **deferred scope item**, recorded like the horizontal-tab-bar exclusion above. Unlike GROUP/ORDER (pure enum writes into the already-persisted `WorkspaceStore.tabGrouping`/`tabSort`), a faithful divider needs a **net-new store-side divider model**, materially larger/riskier than a menu restyle:

- a positioned, stably-identified, **persisted** divider marker list (divider sits BETWEEN two tabs);
- correct reconciliation as tabs are **reordered / closed / grouped** (must not orphan or drift when its neighbour moves/closes; must interact with manual-reorder drag in `ReorderableRow` and with By-Project / By-Date grouping that already re-sections the rail);
- new rail rendering of divider rows between `RailRowsBuilder` rows in `NavigatorColumn`.

Half-building it (a marker that does not survive reorder/close/persist) would be worse than the honest gap. When picked up, it lands as its own work item: a `TabDivider` domain model on the store (TabID-keyed insertion anchor, pruned in `pruneTreeSidebarMirrors`), the two `SlateSortMenuButton` rows ("Insert Divider" after the active tab; "Remove All Dividers"), and a divider row type emitted by `RailRowsBuilder`/rendered in `NavigatorColumn`. NOT a wire change (client-side sidebar state only). Tracked also in `docs/DECISIONS.md` (E6 cluster).
