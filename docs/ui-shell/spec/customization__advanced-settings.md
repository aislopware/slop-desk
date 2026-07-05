# Advanced / All Settings

## Summary

The Advanced tab in SlopDesk Settings is the single-pane escape hatch for every configuration key
the app understands, including the "expert" ones that have no dedicated control on the standard
tabs (General, Shell, Controls, Appearance, Key Bindings). It hosts three distinct sections:

1. **Config File** — displays the path to the TOML config, with Open Config File, Reload Config,
   and Import / Export buttons.
2. **Debug** — a debug-logging toggle and a shortcut to open the log file.
3. **All Settings** — a searchable, scrollable list of every config key, with inline live editing
   or a cross-tab navigation button for keys that have a richer dedicated UI elsewhere.

Opening the Advanced tab: Settings (`⌘,` or SlopDesk menu → Settings…) → click the **Advanced** tab
(wrench icon, bottom of the sidebar).

---

## Behaviors

- The All Settings list is **complete**: it contains every SlopDesk configuration key, including
  expert-only keys with no counterpart on the other settings tabs.
- A **Search box** (top-right of the content area, not the sidebar search) filters the list in
  real time, matching against key name, label, description, and keywords. Examples: typing
  `cursor`, `scrollback`, or `blink` narrows the list fast.
- Each row displays: the **config key** in monospace, a **short description**, its **default
  value**, and a **"Learn more →"** link into the Configuration Reference.
- For keys that **only exist in Advanced** (no dedicated tab UI): an inline control (toggle,
  dropdown, color picker, number field, or text field) appears in-row. Changes apply **live**
  with no save step, identical to hand-editing the config file.
- For keys that **already have a richer UI on another tab**: a button shows the current value
  with a ✎ icon. Clicking the button navigates to that other tab and **highlights the relevant
  control** so the user doesn't have to hunt for it.
- Every edit — whether inline or via the cross-tab jump — is written immediately to
  `~/.config/slopdesk/config.toml`.
- **Reset All Settings** button (above the list): restores every setting to its default value.
  Asks for confirmation. Cannot be undone.
- **Reset Advanced Only** button (above the list, next to Reset All): restores only the
  advanced-only keys (those not reachable from General, Shell, Appearance, or Key Bindings),
  leaving font, theme, and keybinding choices intact. Asks for confirmation. Cannot be undone.
- Both reset buttons present a confirmation dialog before acting; the action is irreversible
  within the app (users are advised to commit their config under version control first).
- The sidebar search field (top of the left sidebar) is a **different** control from the
  All Settings search box; the All Settings search box is positioned at the top right of the
  main content region.
- The Advanced tab is identified in the sidebar by a **wrench icon** and is listed at the
  bottom of the sidebar tab list.

---

## Keybindings

| Action | Keys |
|--------|------|
| Open Settings | `⌘,` |

---

## Config keys

No dedicated config keys govern the Advanced tab UI itself. The tab is the UI surface for
browsing and editing **all** other config keys. See the
[SlopDesk Configuration Reference](reference__configuration.md) for the full
key list. The screenshot shows the following key rows (visible portion):

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `JetBrains Mono` | Terminal font family |
| `font-family-fallback` | `[]` (empty list) | Comma-separated list of fallback fonts tried in order when the primary font can't render a codepoint (e.g. CJK, emoji, Nerd Font icons) |
| `font-family-bold` | `–` (empty) | Optional separate family for bold cells; empty falls back to the regular Font Family with bold traits |
| `font-family-italic` | `–` (empty) | Optional separate family for italic cells; empty falls back to the regular Font Family with italic traits |
| `font-family-bold-italic` | `–` (empty) | Optional separate family for bold-italic cells (visible in screenshot, description cut off) |

---

## Visual spec

### Screenshot: `all-settings.png`

**Overall layout:**
The window is a macOS-style floating panel with rounded corners (~12 pt radius), a light
(`#F5F5F5` off-white) background, and a subtle drop shadow. Standard traffic-light buttons
(red/yellow/green) appear at top-left. The window is divided into two columns by a crisp 1 px
`#E0E0E0` vertical divider.

**Left sidebar column (~310 px wide):**
- Background: slightly darker than the main content — approximately `#EBEBEB`.
- Top item: a rounded search pill (`#E0E0E0` fill, magnifying glass icon, placeholder text
  "Search") spanning nearly the full sidebar width with ~12 px horizontal margin.
- Below the search pill: a vertical list of tab items with icons and labels, no separator lines,
  generous top padding (~20 px between search and first tab):
  - General — circle with exclamation icon
  - Shell — `>_` prompt icon
  - Controls — cursor/pointer icon
  - Editor — document icon
  - Agents — plug/connector icon
  - Appearance — palette icon
  - Recipes — book icon
  - Key Bindings — lightning bolt icon
  - **Advanced** — wrench icon (currently selected, shown with a filled `#EBEBEB` pill/highlight
    background spanning full sidebar width, text rendered in bold weight)
- Tab label typography: system sans-serif (~14 pt), normal weight except for the selected tab
  which is bold. Icon + label are left-aligned with ~40 px left indent. Icon is ~18×18 px,
  muted gray for non-selected, darker gray for selected.
- The sidebar has no visible scrollbar; tab list fits without scrolling.

**Main content column (right of divider):**
- Background: white (`#FFFFFF`).
- **Header bar** (top of content, ~50 px tall):
  - Left: section label "ALL SETTINGS" in small-caps or uppercased tracking, ~11 pt, medium
    gray (`#999999`), positioned ~20 px from the top of the content area.
  - Right: a rounded-rectangle search field (~200 px wide, ~28 px tall), border `#CCCCCC`,
    white fill, blinking text cursor visible inside, placeholder "Search". This is distinct
    from the sidebar search pill.
- **Reset buttons row** (~40 px below the header, ~50 px tall):
  - Two buttons side by side with ~8 px gap:
    - "Reset All Settings" — white fill, `#CCCCCC` border, rounded corners (~6 pt), ~14 pt
      system font, black label.
    - "Reset Advanced Only" — identical styling.
  - Buttons are left-aligned in the content area with ~20 px left margin.
- **Config key rows** (below the reset buttons, separated by 1 px `#EBEBEB` horizontal
  dividers):
  - Each row is approximately 80–100 px tall (taller when the description wraps to two lines).
  - **Left region of each row:**
    - Key name: monospace font (`JetBrains Mono` or similar), ~14 pt, black, on the first line.
    - Description: system sans-serif, ~13 pt, medium gray (`#888888`), below the key name,
      wraps up to 2 lines.
  - **Right region of each row** (~60 px wide, vertically centered):
    - Two icons stacked or side by side: a **dash/minus** `–` icon (current value indicator
      when empty/default, ~18×18 px box) and a **pencil/edit** `✎` icon (~16×16 px, muted
      gray). For rows where the key already has a richer tab UI, a button with the current
      value and ✎ appears here instead.
    - For `font-family-fallback`, the default indicator shows `[]` (empty array) rather than `–`.
  - Row left margin: ~20 px; right margin: ~20 px from window edge.
- **Typography summary**: key names in monospace (~14 pt bold-ish weight), descriptions in
  system sans-serif regular ~13 pt gray, section header in uppercase tracking ~11 pt gray.
- **Spacing density**: moderate — rows have generous vertical padding (~12 px top+bottom), no
  icon decorations on rows themselves (icons are only in the right-action region).
- **Color palette** (inferred): background white `#FFFFFF`, sidebar `#EBEBEB`, dividers
  `#E0E0E0`, description text `#888888`, key name text `#111111`, section header `#999999`,
  button borders `#CCCCCC`.
- **Scrolling**: the key list scrolls vertically; only the top ~5 rows are visible in the
  screenshot. No scroll indicator visible, suggesting it appears on hover only.

---

## Screenshots

- `all-settings.png` (1624×1144 px)

---

## Implementation notes

**Architecture context:** SlopDesk runs a macOS host (slopdesk-hostd) and macOS/iOS clients.
The terminal is rendered by libghostty behind the `TerminalSurface` seam. Settings are stored in
`PreferencesStore` (injected, not a global singleton) plus `Defaults`-backed `SettingsKey` values
for UI preferences, with the TOML config file for expert keys.

### Direct implementation

- **Settings window with sidebar tab list** — fully implementable on macOS as a standard
  `NSWindowController` + `NSSplitView` (sidebar + content). SlopDesk already has a settings
  UI; the Advanced tab can be added as a new sidebar tab with the wrench icon.
- **All Settings searchable list** — a `List`/`LazyVStack` of all `PreferencesStore` /
  `SettingsKey` entries, filtered by a SwiftUI `TextField`. Each row shows the key, description,
  default, and an inline control. Fully implementable.
- **Inline live editing** — `PreferencesStore` already applies changes live; binding an inline
  toggle/text field to the store's backing value replicates the behavior.
- **Cross-tab jump button** — implementable via a shared `SelectedTab` state passed through the
  settings window environment; clicking the ✎ button sets the selected tab and scrolls/highlights
  the relevant control.
- **Reset All / Reset Advanced Only** — `PreferencesStore` can expose `reset()` and
  `resetAdvancedOnly()` methods; a confirmation `Alert` precedes the action.
- **Config File section** — the config file lives at slopdesk's own
  `~/.config/slopdesk/config.toml` path; an "Open Config File" button can use `NSWorkspace.open(_:)`.
- **Debug logging toggle** — maps to `SLOPDESK_VIDEO_DEBUG` / existing debug flags; the log
  file path is already known.
- **Search box** — standard SwiftUI `TextField` with a `@State var searchQuery` driving a
  `.filter` over the key list. Matches key name, label, description, and keywords.

### Platform / architecture constraints

- **iOS client** — the Advanced tab as a full settings window is macOS-native. On iOS it would
  need to be a pushed `UINavigationController` stack screen rather than a sidebar panel. The
  searchable list and inline controls are still doable; the two-column sidebar layout is not
  applicable on compact width.
- **Cross-tab highlight animation** — the ✎ jump button that highlights the target control on
  another tab requires a shared highlight state. On macOS with `NSTabViewController` or SwiftUI
  `TabView` this works; on iOS navigation-stack-based settings it requires a different pattern
  (navigate to the screen, scroll to the row, briefly highlight it).
- **"Learn more →" links into Configuration Reference** — should link to slopdesk's own `reference__configuration.md` doc (in-app, this could be a bundled reference view or a web view onto the built docs site).
- **Remote host config keys** — some slopdesk config keys (e.g. `SLOPDESK_FEC_M`,
  `SLOPDESK_VIDEO_DEBUG`) are host-side env vars, not client-side TOML keys. The Advanced
  settings UI should clearly distinguish client-side preferences from host-side parameters, or
  surface only client-side keys in this panel.
- **Reload Config** — slopdesk's `PreferencesStore` does not have a concept of a TOML file
  that can be hand-edited externally and then reloaded; it uses `Defaults` + injected store.
  A "Reload Config" button would need to re-read the backing file and reconcile with the
  in-memory store.
- **Import / Export** — covered in a separate spec
  (`customization__import-export.md`); flag here that the Config File section links to it.
