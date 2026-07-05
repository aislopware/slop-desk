# Command Palette

## Summary

The VSCode-style command palette for _running an action_. Counterpart to Open Quickly, which is for _jumping to a thing_. Opened with ⌘⇧P from anywhere, it exposes every SlopDesk action — including ones without keyboard shortcuts — in a searchable, categorised list. Actions are tagged with their scope (pane, window, or app level).

## Behaviors

- Triggered from anywhere in the app with ⌘⇧P; dismissed with Esc.
- Search field is pre-focused on open with placeholder text "Search for commands…".
- A magnifying-glass icon sits to the left of the search field; the caret is blue (accent color) when active.
- Every registered action is listed, including actions that have no assigned keyboard shortcut.
- Actions are grouped under capitalized section headers (e.g. "WORKING DIRECTORY", "VIEW"). Section headers are rendered in small-caps / uppercase gray text, visually separated from action rows.
- The currently selected row is highlighted with a light gray background fill; no border or accent stripe — just a subtle background change.
- Some actions show a checkmark (✓) to the left of the label, indicating the action is currently active / toggled on (e.g. "Toggle Tabs Panel" with ✓ when the tabs panel is visible).
- Actions that have a keyboard shortcut show keycap chips to the right of the label (e.g. ⇧⌘L for "Toggle Tabs Panel", ⇧⌘R for "Toggle Details Panel"). Keycap chips are rendered as individual rounded-rectangle badges per key symbol.
- Actions that have a submenu show a right-facing chevron "›" at the far right (e.g. "Open in…").
- The palette shows context-aware content at the top: under "WORKING DIRECTORY" it shows the focused pane's current working directory as a tinted badge (folder icon + path like `~/Workplace/project/`). This badge appears in the top-right of the section header row.
- Actions cover all scope levels: pane-scoped (e.g. Find, Toggle Bold Brightens), window-scoped (e.g. Close Window, Toggle Tabs Panel), and app-scoped (e.g. About SlopDesk). Each action is tagged with its scope internally (the reference screenshot shows this through grouping/section headers).
- Example action categories from the docs:
  - Window: New Tab, Close Tab, Reopen Closed Tab, Move Tab to New Window
  - Pane: Open Folder Pane, Split Right (planned), Swap Panes
  - Theme: Switch Theme, Reload Theme, Open Theme File
  - Recipes: Save Recipe, Export Recipe, Open Recipe
  - Shell: Send to All Panes, Send Bell, Toggle Mouse Reporting
  - Settings: Open Settings, Reload Config
- ⌘↩ runs the selected action AND keeps the palette open, enabling command chaining (run multiple actions in sequence without re-opening).
- To save and replay sequences of commands, use Recipes (the palette's "Save Recipe" action captures them).
- Distinct from Open Quickly: Open Quickly is for jumping to "things" (tabs, files, recent items, shell commands), Command Palette is for executing "verbs" (actions). They have separate triggers (⌘⇧O vs ⌘⇧P).

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

No dedicated config keys are documented for the Command Palette itself. Actions surfaced in the palette can be bound to custom shortcuts via the Keybindings system (see Keybindings reference). Custom command sequences can be captured as Recipes.

## Visual spec

### command-palette.png

**Overall layout:** A floating panel / sheet centered over the terminal window, with a soft drop shadow and large rounded corners (approximately 12–14 pt radius). The panel background is a very light warm gray (`#F2F1EF` approx.), distinct from the terminal background. The panel is roughly 900–1000 px wide (at 2× retina) and tall enough to show ~6–7 rows without scrolling; it is NOT full-height.

**Search bar (top region):**
- Fixed-height row at the very top of the panel, roughly 48 pt tall.
- Left: a gray magnifying-glass icon (~16 pt, medium gray `#8A8A8A` approx.).
- Center/right: text field with placeholder "Search for commands…" in medium gray. When active, a blue text cursor (macOS accent blue, approximately `#007AFF`) is shown at the insertion point — the caret is the only active-state indicator; there is no border ring or glow on the field itself.
- A 1 px hairline separator divides the search bar from the results list below.

**Section headers:**
- Short ALL-CAPS labels in small, light gray uppercase text (`#8A8A8A` approx., ~11 pt, tracking wide). Examples: "WORKING DIRECTORY", "VIEW".
- Not selectable / not interactive.
- May carry a contextual badge on the right side: in the "WORKING DIRECTORY" section, a pill-shaped badge shows a folder icon (dark gray, ~12 pt) followed by the cwd path string (e.g. `~/Workplace/project/`) in dark gray text, on a slightly darker gray pill background. The badge sits flush right inside the row.

**Action rows:**
- Height approximately 36–38 pt per row.
- Left edge: reserved gutter (~24 pt wide) for optional checkmark (✓). The checkmark is a standard dark-gray check (not a filled circle or badge) — simply the Unicode check character in the gutter.
- Label: action name in regular-weight system font (~14 pt), dark near-black (`#1C1C1E` approx.).
- Right side (optional): keycap chips — individual rounded-rectangle badges, each ~20×22 pt, light gray fill (`#D1D1D6` approx.) with dark gray symbol inside. Chips are spaced 4 pt apart. Examples shown: ⇧ chip + ⌘ chip + L chip for "Toggle Tabs Panel"; ⇧ chip + ⌘ chip + R chip for "Toggle Details Panel".
- Right side (submenu indicator): a single `›` chevron in gray when the action opens a submenu (e.g. "Open in…").

**Selection state:**
- Selected row has a solid light gray fill spanning the full width of the panel (`#E5E5EA` approx.). Corners are slightly rounded on the highlighted row (approximately 6 pt). No border, no accent color on the row background — purely a fill change.
- Non-selected rows have transparent background (showing the panel background).

**Typography summary:** System font (SF Pro), ~14 pt regular for action labels, ~11 pt uppercase tracking for section headers, ~14 pt placeholder text. No bold weight used in the list.

**Spacing / density:** Comfortable but compact. Section headers add ~8 pt vertical padding above/below their text. Action rows are tightly packed with ~36–38 pt height. No dividers between individual rows — only the section header creates visual grouping.

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
- **Search field + fuzzy filtering:** SlopDesk already has a vendored FuzzyMatchV2 (`FuzzyMatcher`) used in the sidebar chooser. The same matcher can power command-palette filtering.
- **Action registry / command list:** SlopDesk has `WorkspaceBindingRegistry` and keybinding infrastructure. All registered actions can be enumerated and exposed in a palette.
- **Keycap badges:** Pure SwiftUI rendering; no platform dependency.
- **Checkmark for toggled state:** Each action's current boolean state (e.g. panel visible) can be queried at open time and shown as a checkmark.
- **⌘↩ "keep open" chaining:** Standard SwiftUI / AppKit event handling — suppress dismiss on ⌘↩.
- **Esc to dismiss:** Standard.
- **Section grouping:** Static grouping by action category is straightforward.

### Requires attention
- **Working directory badge (CWD context):** The palette shows the focused pane's CWD via OSC 7 / shell integration. In slopdesk the CWD lives on the REMOTE HOST, not the local client. The client receives it via the OSC 7 wire path (if the shell emits it and the host forwards it). Implementation: ensure the host relays OSC 7 CWD updates over the mux to the client, and cache it per-pane in `WorkspaceStore`/pane state. The CWD badge then reads from that cached value. Flag: CWD badge may be stale by RTT; acceptable for display purposes.
- **Pane-scope vs window-scope action routing:** Some actions (e.g. "Split Right") operate on the focused pane; others (e.g. "Close Window") operate on the window. In slopdesk's remote architecture, pane-scoped actions that affect the remote PTY (e.g. Send Bell, Toggle Mouse Reporting) must be forwarded to the host over the control channel rather than executed locally. Window-scoped UI actions (e.g. Toggle Tabs Panel) are fully local.
- **"Split Right":** SlopDesk has pane splitting in `WorkspaceStore`. Exposing it in the palette is straightforward.
- **"Open in…" submenu:** Submenu navigation within the palette (pressing ↩ on a row with ›) requires a secondary list state. Not complex but needs explicit implementation — the basic palette only handles flat action dispatch.
- **Recipes integration:** SlopDesk does not yet have a Recipes system equivalent. The "Save Recipe" / "Export Recipe" / "Open Recipe" actions cannot map 1:1 until Recipes are implemented. Flag as future work.
- **"Send to All Panes":** SlopDesk supports multiple panes; broadcasting a shell command to all is feasible via the mux by iterating pane channels. Implement as a pane-level action that iterates `WorkspaceStore` pane list.
- **iOS client:** The palette trigger ⌘⇧P maps to a hardware keyboard shortcut. On iOS without a keyboard, the palette must be reachable via a toolbar button or swipe gesture. Flag: need a touch-accessible entry point for iOS (e.g. a toolbar "..." menu or dedicated button).
- **"Open Settings" / "Reload Config":** On slopdesk, "settings" could mean local client preferences (handled locally) vs remote host config (requires a control-channel message). Distinguish these two action classes clearly.
- **Theme actions (Switch Theme, Reload Theme, Open Theme File):** Theme is local client state in slopdesk (ThemeStore). These are all local actions with no remote dependency. Clean mapping.
