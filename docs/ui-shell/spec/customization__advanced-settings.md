# Advanced / All Settings

> ⚠️ **THE SECTION LIST IS OUT OF DATE.** Settings has **eight** sections — General, Shell, Controls,
> Editor (reserved and deliberately empty), Agents, Appearance, Key Bindings, Advanced
> (`Sources/SlopDeskClientCore/Settings/SettingsTaxonomy.swift:33-41`), and all eight appear on **both**
> halves. There is no **Recipes** section — Recipes were deleted 2026-07-03 (`d63e1274`) — and no theme
> choice to preserve across a reset, the theme system having been deleted 2026-08-08
> (`docs/DECISIONS.md` §"ONE appearance").
>
> Also worth knowing for a reset row: three verbs exist and they are not interchangeable —
> `resetAll()`, `resetAdvancedOnly()` and `resetEverySetting(deviceLocal:)`. Only the last reaches
> `device-prefs.json` (`PreferencesStore.swift:319,342-351,369`).

## Summary

The Advanced tab in SlopDesk Settings is the single-pane escape hatch for every config key the app
understands, including expert keys with no dedicated control on the standard tabs (General, Shell,
Controls, Appearance, Key Bindings). Three sections:

1. **Config File** — path to the TOML config, with Open Config File, Reload Config, and Import / Export.
2. **Debug** — a debug-logging toggle and a shortcut to open the log file.
3. **All Settings** — searchable, scrollable list of every config key, with inline live editing or a
   cross-tab navigation button for keys that have a richer dedicated UI elsewhere.

Open: Settings (`⌘,` or SlopDesk menu → Settings…) → **Advanced** tab (wrench icon, bottom of sidebar).

---

## Behaviors

- The All Settings list is **complete** — every SlopDesk config key, including expert-only keys with no
  counterpart on other tabs.
- A **Search box** (top-right of the content area, distinct from the sidebar search) filters in real
  time against key name, label, description, and keywords (e.g. `cursor`, `scrollback`, `blink`).
- Each row shows: **config key** (monospace), **short description**, **default value**, and a
  **"Learn more →"** link into the Configuration Reference.
- Keys that **only exist in Advanced** (no dedicated tab UI): an inline control (toggle, dropdown, color
  picker, number field, text field) appears in-row; changes apply **live**, no save step, identical to
  hand-editing the config file.
- Keys that **already have a richer UI on another tab**: a button showing the current value with a ✎
  icon; clicking navigates to that tab and **highlights the relevant control**.
- Every edit (inline or cross-tab jump) writes immediately to `~/.config/slopdesk/config.toml`.
- **Reset All Settings** (above the list): restores every setting to default. Confirms first. Cannot be undone.
- **Reset Advanced Only** (next to Reset All): restores only advanced-only keys (those not reachable from
  General, Shell, Appearance, or Key Bindings), leaving font, theme, and keybinding choices intact.
  Confirms first. Cannot be undone.
- Both resets are irreversible within the app — advise committing the config under version control first.
- The Advanced tab is marked by a **wrench icon** at the bottom of the sidebar tab list.

---

## Keybindings

| Action | Keys |
|--------|------|
| Open Settings | `⌘,` |

---

## Config keys

No dedicated config keys govern the Advanced tab UI itself; the tab is the UI surface for browsing and
editing **all** other keys. See the
[SlopDesk Configuration Reference](reference__configuration.md) for the full list. Key rows visible in
the screenshot:

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `JetBrains Mono` | Terminal font family |
| `font-family-fallback` | `[]` (empty list) | Comma-separated fallback fonts tried in order when the primary font can't render a codepoint (CJK, emoji, Nerd Font icons) |
| `font-family-bold` | `–` (empty) | Optional separate family for bold cells; empty falls back to Font Family with bold traits |
| `font-family-italic` | `–` (empty) | Optional separate family for italic cells; empty falls back to Font Family with italic traits |
| `font-family-bold-italic` | `–` (empty) | Optional separate family for bold-italic cells (description cut off in screenshot) |

---

## Visual spec

### Screenshot: `all-settings.png`

**Overall layout:** macOS floating panel, rounded corners (~12 pt radius), light `#F5F5F5` off-white
background, subtle drop shadow. Traffic-light buttons top-left. Two columns split by a 1 px `#E0E0E0`
vertical divider.

**Left sidebar (~310 px wide):**
- Background: ~`#EBEBEB` (slightly darker than content).
- Top: rounded search pill (`#E0E0E0` fill, magnifying-glass icon, "Search" placeholder), near-full
  width, ~12 px horizontal margin.
- Below (no separators, ~20 px top padding): tab items with icons + labels:
  - General — circle-with-exclamation; Shell — `>_` prompt; Controls — cursor/pointer; Editor —
    document; Agents — plug/connector; Appearance — palette; Recipes — book; Key Bindings — lightning.
  - **Advanced** — wrench (currently selected: filled `#EBEBEB` pill spanning full width, bold text).
- Label typography: system sans-serif ~14 pt, normal weight except the bold selected tab. Icon + label
  left-aligned, ~40 px left indent. Icon ~18×18 px, muted gray (darker when selected). No scrollbar.

**Main content column (right of divider):** background white `#FFFFFF`.
- **Header bar** (~50 px tall):
  - Left: "ALL SETTINGS" label, uppercase tracking ~11 pt, `#999999`, ~20 px from top.
  - Right: rounded search field (~200×28 px), `#CCCCCC` border, white fill, blinking cursor, "Search"
    placeholder — distinct from the sidebar pill.
- **Reset buttons row** (~40 px below header, ~50 px tall): "Reset All Settings" and "Reset Advanced
  Only" side by side, ~8 px gap, identical styling (white fill, `#CCCCCC` border, ~6 pt corners, ~14 pt
  system font, black label), left-aligned, ~20 px left margin.
- **Config key rows** (below resets, separated by 1 px `#EBEBEB` horizontal dividers):
  - ~80–100 px tall (taller when the description wraps to two lines).
  - **Left region:** key name (monospace ~14 pt, black, first line); description (system sans-serif
    ~13 pt, `#888888`, below, wraps up to 2 lines).
  - **Right region** (~60 px wide, vertically centered): a **dash/minus** `–` current-value indicator
    (~18×18 px) and a **pencil** `✎` icon (~16×16 px, muted gray). Keys with a richer tab UI show a
    button with current value + ✎ instead. For `font-family-fallback` the default indicator shows `[]`
    rather than `–`.
  - Row left/right margins: ~20 px.
- **Spacing:** moderate — ~12 px top+bottom row padding; no icon decorations except the right-action region.
- **Color palette** (inferred): background `#FFFFFF`, sidebar `#EBEBEB`, dividers `#E0E0E0`, description
  `#888888`, key name `#111111`, section header `#999999`, button borders `#CCCCCC`.
- **Scrolling:** key list scrolls vertically (top ~5 rows visible); scroll indicator appears on hover only.

---

## Screenshots

- `all-settings.png` (1624×1144 px)

---

## Implementation notes

**Architecture context:** SlopDesk runs a macOS host (slopdesk-hostd) and macOS/iOS clients. The
terminal is rendered by libghostty behind the `TerminalSurface` seam. Settings live in `PreferencesStore`
(injected, not a global singleton) plus `Defaults`-backed `SettingsKey` values for UI preferences, with
the TOML config file for expert keys.

### Direct implementation

- **Settings window with sidebar tab list** — standard `NSWindowController` + `NSSplitView` (sidebar +
  content). SlopDesk already has a settings UI; add Advanced as a new sidebar tab (wrench icon).
- **All Settings searchable list** — a `List`/`LazyVStack` of all `PreferencesStore` / `SettingsKey`
  entries, filtered by a SwiftUI `TextField`; each row shows key, description, default, inline control.
- **Inline live editing** — `PreferencesStore` already applies changes live; bind an inline
  toggle/text field to the store's backing value.
- **Cross-tab jump button** — a shared `SelectedTab` state via the settings window environment; the ✎
  button sets the selected tab and scrolls/highlights the relevant control.
- **Reset All / Reset Advanced Only** — expose `PreferencesStore.reset()` and `resetAdvancedOnly()`,
  gated by a confirmation `Alert`.
- **Config File section** — config lives at `~/.config/slopdesk/config.toml`; "Open Config File" uses
  `NSWorkspace.open(_:)`.
- **Debug logging toggle** — maps to `SLOPDESK_VIDEO_DEBUG` / existing debug flags; log file path is known.
- **Search box** — SwiftUI `TextField` + `@State var searchQuery` driving a `.filter` over the key list
  (matches key name, label, description, keywords).

### Platform / architecture constraints

- **iOS client** — the full settings window is macOS-native; on iOS it becomes a pushed
  `UINavigationController` stack screen. Searchable list and inline controls still work; the two-column
  sidebar layout does not apply on compact width.
- **Cross-tab highlight animation** — the ✎ jump needs a shared highlight state. Works on macOS
  `NSTabViewController` / SwiftUI `TabView`; iOS navigation-stack settings need a different pattern
  (navigate, scroll to row, briefly highlight).
- **"Learn more →" links** — link to slopdesk's own `reference__configuration.md` (in-app: a bundled
  reference view or a web view onto the built docs site).
- **Remote host config keys** — some keys (e.g. `SLOPDESK_FEC_M`, `SLOPDESK_VIDEO_DEBUG`) are host-side
  env vars, not client-side TOML keys. The UI should distinguish client-side preferences from host-side
  parameters, or surface only client-side keys here.
- **Reload Config** — `PreferencesStore` has no concept of an externally hand-edited TOML file to reload;
  it uses `Defaults` + injected store. "Reload Config" would need to re-read the backing file and
  reconcile with the in-memory store.
- **Import / Export** — covered in `customization__import-export.md`; the Config File section links to it.
