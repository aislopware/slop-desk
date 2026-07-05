# Command Palette

## Summary

VSCode-style palette for _running an action_ (counterpart to Open Quickly, which _jumps to a thing_). ⌘⇧P from anywhere exposes every SlopDesk action — including ones without keyboard shortcuts — in a searchable, categorised list. Each action is tagged with its scope (pane, window, or app).

## Behaviors

- ⌘⇧P opens from anywhere; Esc dismisses.
- Search field is pre-focused, placeholder "Search for commands…". A magnifying-glass icon sits left of the field; the caret is blue (accent) when active.
- Every registered action is listed, including those with no keyboard shortcut.
- Actions are grouped under capitalized section headers (e.g. "WORKING DIRECTORY", "VIEW"), rendered small-caps/uppercase gray, separated from action rows. Headers are not selectable.
- Selected row: light gray background fill only — no border or accent stripe.
- A checkmark (✓) left of the label marks an active/toggled-on action (e.g. "Toggle Tabs Panel" when the tabs panel is visible).
- Actions with a shortcut show keycap chips right of the label (e.g. ⇧⌘L "Toggle Tabs Panel", ⇧⌘R "Toggle Details Panel"), one rounded-rectangle badge per key symbol.
- Actions with a submenu show a right-facing chevron "›" at the far right (e.g. "Open in…").
- Context-aware top content: under "WORKING DIRECTORY" the focused pane's cwd shows as a tinted badge (folder icon + path like `~/Workplace/project/`) in the top-right of the header row.
- Actions cover all scopes: pane (Find, Toggle Bold Brightens), window (Close Window, Toggle Tabs Panel), app (About SlopDesk). Scope is tagged internally (shown via grouping/section headers).
- Example action categories:
  - Window: New Tab, Close Tab, Reopen Closed Tab, Move Tab to New Window
  - Pane: Open Folder Pane, Split Right (planned), Swap Panes
  - Theme: Switch Theme, Reload Theme, Open Theme File
  - Recipes: Save Recipe, Export Recipe, Open Recipe
  - Shell: Send to All Panes, Send Bell, Toggle Mouse Reporting
  - Settings: Open Settings, Reload Config
- ⌘↩ runs the selected action AND keeps the palette open, enabling command chaining without re-opening.
- Save/replay command sequences via Recipes (palette "Save Recipe" action captures them).
- Distinct from Open Quickly: Open Quickly jumps to "things" (tabs, files, recent items, shell commands); Command Palette executes "verbs" (actions). Separate triggers (⌘⇧O vs ⌘⇧P).

## Keybindings

| Action | Keys |
|--------|------|
| Open Command Palette | ⌘⇧P |
| Move selection up | ↑ |
| Move selection down | ↓ |
| Run selected action | ↩ |
| Run and keep palette open | ⌘↩ |
| Close / dismiss | Esc |

## Config keys

No dedicated config keys for the palette itself. Actions can be bound to custom shortcuts via the Keybindings system (see Keybindings reference). Command sequences can be captured as Recipes.

## Visual spec

### command-palette.png

**Overall layout:** Floating panel/sheet centered over the terminal window, soft drop shadow, large rounded corners (~12–14 pt radius). Background very light warm gray (`#F2F1EF` approx.), distinct from terminal bg. ~900–1000 px wide (2× retina), tall enough for ~6–7 rows without scrolling; NOT full-height.

**Search bar (top region):**
- Fixed-height row at the top, ~48 pt tall.
- Left: gray magnifying-glass icon (~16 pt, `#8A8A8A` approx.).
- Center/right: text field, placeholder "Search for commands…" in medium gray. When active, a blue text cursor (macOS accent, ~`#007AFF`) at the insertion point is the only active-state indicator — no border ring or glow.
- 1 px hairline separator below.

**Section headers:**
- Short ALL-CAPS labels, small light gray uppercase (`#8A8A8A` approx., ~11 pt, wide tracking). Examples: "WORKING DIRECTORY", "VIEW".
- Not selectable / interactive.
- May carry a right-side contextual badge: in "WORKING DIRECTORY", a pill with a folder icon (dark gray, ~12 pt) + cwd path (e.g. `~/Workplace/project/`) in dark gray, on a slightly darker gray pill, flush right.

**Action rows:**
- ~36–38 pt height.
- Left gutter (~24 pt) for optional checkmark (✓) — the Unicode check character in dark gray, not a filled badge.
- Label: action name, regular-weight system font (~14 pt), near-black (`#1C1C1E` approx.).
- Right (optional): keycap chips — rounded-rectangle badges, each ~20×22 pt, light gray fill (`#D1D1D6` approx.), dark gray symbol, spaced 4 pt. Examples: ⇧+⌘+L "Toggle Tabs Panel"; ⇧+⌘+R "Toggle Details Panel".
- Right (submenu): a single gray `›` chevron when the action opens a submenu (e.g. "Open in…").

**Selection state:**
- Selected row: solid light gray fill (`#E5E5EA` approx.) spanning full panel width, corners ~6 pt rounded. No border/accent — fill only.
- Non-selected rows: transparent (panel bg).

**Typography:** SF Pro; ~14 pt regular action labels, ~11 pt uppercase tracking section headers, ~14 pt placeholder. No bold in the list.

**Spacing / density:** Compact. Section headers add ~8 pt vertical padding above/below text. Rows tightly packed ~36–38 pt. No per-row dividers — only section headers group visually.

**Color palette (inferred):**
- Panel background: `#F2F1EF` (light warm off-white)
- Selected row: `#E5E5EA` (light gray)
- Section header text: `#8A8A8A` (medium gray, uppercase)
- Action label text: `#1C1C1E` (near-black)
- Keycap chip fill: `#D1D1D6` (light gray)
- Keycap chip text/icons: `#3C3C43` (dark gray)
- Search caret: `#007AFF` (macOS blue accent)
- Folder icon in CWD badge: dark gray
- CWD badge background: slightly darker than panel bg, pill-shaped

## Screenshots

- `command-palette.png`

## SlopDesk mapping notes

### Maps cleanly
- **Search field + fuzzy filtering:** Reuse the vendored FuzzyMatchV2 (`FuzzyMatcher`) already powering the sidebar chooser.
- **Action registry / command list:** `WorkspaceBindingRegistry` + keybinding infra can enumerate all registered actions for the palette.
- **Keycap badges:** Pure SwiftUI, no platform dependency.
- **Checkmark for toggled state:** Query each action's boolean state (e.g. panel visible) at open time.
- **⌘↩ "keep open" chaining:** Standard SwiftUI/AppKit — suppress dismiss on ⌘↩.
- **Esc to dismiss:** Standard.
- **Section grouping:** Static grouping by action category.

### Requires attention
- **Working directory badge (CWD context):** Palette shows the focused pane's CWD via OSC 7 / shell integration. In slopdesk the CWD lives on the REMOTE HOST; the client receives it via the OSC 7 wire path (if the shell emits it and the host forwards it). Impl: host relays OSC 7 CWD updates over the mux, cache per-pane in `WorkspaceStore`/pane state; badge reads the cached value. Flag: badge may be RTT-stale — acceptable for display.
- **Pane- vs window-scope routing:** Pane-scoped actions affecting the remote PTY (Send Bell, Toggle Mouse Reporting) must be forwarded to the host over the control channel, not run locally. Window-scoped UI actions (Toggle Tabs Panel) are fully local.
- **"Split Right":** Pane splitting exists in `WorkspaceStore`; exposing it is straightforward.
- **"Open in…" submenu:** Submenu navigation (↩ on a `›` row) needs a secondary list state — not complex but explicit; the basic palette only does flat dispatch.
- **Recipes integration:** No Recipes system yet, so "Save/Export/Open Recipe" can't map 1:1. Future work.
- **"Send to All Panes":** Feasible via the mux by iterating pane channels; implement as a pane-level action over the `WorkspaceStore` pane list.
- **iOS client:** ⌘⇧P needs a hardware keyboard. Without one, provide a touch entry point (toolbar "..." menu or dedicated button).
- **"Open Settings" / "Reload Config":** "Settings" may be local client prefs (local) vs remote host config (control-channel message). Distinguish the two classes clearly.
- **Theme actions (Switch Theme, Reload Theme, Open Theme File):** Theme is local client state (ThemeStore) — all local, no remote dependency. Clean mapping.
