# Keybindings

## Summary

SlopDesk rebinds almost any action from a **Key Bindings** settings pane or by editing `~/.config/slopdesk/config.toml` directly. GUI and config stay in sync — GUI changes are written back to `config.toml` automatically. Three sub-sections: the main bindable-action list (grouped by category), **Text / Sequence** (send literal byte sequences to the terminal), and **Commands / Recipe** (mirrors recipe shortcuts).

## Behaviors

- **Settings → Key Bindings** lists every bindable action grouped by category (General, Tabs, Pane, …). Top search box filters by action name or chord (e.g. `cmd+t` finds what's on that combo).
- Each row: action name on the left, current chord as keycap chips on the right; unbound shows a dash (`—`).
- **Rebind**: clicking a row highlights it and shows "Press a key combination…"; pressing the new chord updates the chips immediately.
- **Conflict detection**: if the chord is taken, a "Conflicts with: …" note appears below the row — choose another or overwrite.
- **Unbind**: click the row, press Backspace to clear. Press Esc to cancel.
- **Search by chord**: typing a chord (e.g. `cmd+t`) in search shows the action it's assigned to.
- **Reset to Default**: after any customization, a "Reset to Default" button appears top-right; it shows a "Reset all key bindings?" confirmation, then clears all customizations at once. No per-row revert in the GUI — to reset one binding, delete its `keybind` line from `config.toml` or restore the default chord in the GUI.
- **Text / Sequence**: binds a chord to send literal bytes to the focused terminal (escape sequences a program expects, or text snippets). Action prefixes:
  - `text:<string>` — sends the literal string (`text:hi` types `hi`)
  - `csi:<payload>` — sends ESC [ + payload (`csi:17~` sends F6)
  - `esc:<payload>` — sends ESC + payload (`esc:O`)
  - Add: click **+ Add**, click the trigger button to record a chord, type the action string. Delete: trash icon on the row.
- **Commands / Recipe**: read-only mirror of recipes with a shortcut assigned; shortcuts are edited in the Recipes tab. When none, shows "No recipes have a shortcut assigned yet." **Open Recipes →** navigates to the Recipes tab.
- **Config file syntax**: `keybind = <modifier-chord>:<action>`. Repeat `keybind` for multiple bindings.
  - Modifiers: `cmd`, `ctrl`, `alt` (or `opt`), `shift`, combined with `+`.
  - Multi-key sequences use `>`: e.g. `cmd+b>cmd+v`.
  - Unbind a default with `unbind:<chord>` (e.g. `unbind:cmd+q`).

## Keybindings

### General

| Action | Keys |
|--------|------|
| Command Palette | `⌘⇧P` |
| Open Quickly | `⌘⇧O` |
| Jump to | `⌘J` |
| Settings | `⌘,` |

### Window

| Action | Keys |
|--------|------|
| New window | `⌘N` |
| Close window | `⌘⇧W` |
| Minimize | `⌘M` |
| Toggle fullscreen | `⌃⌘F` |

### Tab

| Action | Keys |
|--------|------|
| New tab | `⌘T` |
| Close tab | `⌘W` |
| Reopen last closed | `⌘⇧T` |
| Previous tab | `⌘⇧[` |
| Next tab | `⌘⇧]` |
| Jump to tab N | `⌘1` … `⌘9` |
| Toggle tabs panel | `⌘⇧L` |
| Toggle details panel | `⌘⇧R` |
| Show next unread tab | `⌘⇧U` |

### Pane (splits)

| Action | Keys |
|--------|------|
| Split right | `⌘D` |
| Split left | `⌘⌥D` |
| Split down | `⌘⇧D` |
| Split up | `⌘⌥⇧D` |
| Zoom / unzoom split | `⌘⇧↩` |
| Equalize splits | `⌃⌘=` |
| Focus next pane | `⌘]` |
| Focus previous pane | `⌘[` |
| Focus pane up | `⌃⌘↑` |
| Focus pane down | `⌃⌘↓` |
| Focus pane left | `⌃⌘←` |
| Focus pane right | `⌃⌘→` |
| Move divider up | `⌃⌘⇧↑` |
| Move divider down | `⌃⌘⇧↓` |
| Move divider left | `⌃⌘⇧←` |
| Move divider right | `⌃⌘⇧→` |

### Clipboard and selection

| Action | Keys |
|--------|------|
| Copy | `⌘C` |
| Cut | `⌘X` |
| Paste | `⌘V` |
| Select all | `⌘A` |
| Undo | `⌘Z` |
| Redo | `⌘⇧Z` (also `⌘Y`) |
| Select word | Double-click |
| Select line | Triple-click |
| Rectangular select | `⌥` + drag |

### Find and search

| Action | Keys |
|--------|------|
| Find in pane | `⌘F` |
| Find next | `⌘G` |
| Find previous | `⌘⇧G` |
| Global search | `⌘⇧F` |

### Scrolling

| Action | Keys |
|--------|------|
| Page up | `⌘PageUp` |
| Page down | `⌘PageDown` |
| Scroll up (few lines) | `⌘⌥↑` (also `⌘⌥PageUp`) |
| Scroll down (few lines) | `⌘⌥↓` (also `⌘⌥PageDown`) |
| Top of buffer | `⌘Home` |
| Bottom of buffer | `⌘End` |
| Half page up (Vi Mode) | `⌃U` |
| Half page down (Vi Mode) | `⌃D` |

### Text editing

| Action | Keys |
|--------|------|
| Cursor to line start | `⌘←` |
| Cursor to line end | `⌘→` |
| Cursor one word left | `⌥←` |
| Cursor one word right | `⌥→` |
| Delete word left | `⌥⌫` |
| Delete word right | `⌥⌦` |
| Delete to line start | `⌘⌫` |
| Delete to line end | `⌘⌦` |

### View

| Action | Keys |
|--------|------|
| Increase font size | `⌘=` |
| Decrease font size | `⌘−` |
| Reset font size | `⌘0` |

### Composer and Vi mode

| Action | Keys |
|--------|------|
| Open Composer overlay | `⌘⇧E` |
| Add to prompt queue | `⌘⇧M` |
| Toggle Vi mode | `⌃⇧Space` |

### Recipes

| Action | Keys |
|--------|------|
| Save recipe | `⌘S` |
| Export `.slopdeskrecipe` | `⌘⇧S` |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `keybind` | (built-in defaults) | Adds a key binding. Syntax: `keybind = <modifier-chord>:<action>`. Repeat the key for multiple bindings. Use `unbind:<chord>` as the action to disable a default. Multi-key sequences use `>` separator (e.g. `cmd+b>cmd+v`). Modifier names: `cmd`, `ctrl`, `alt`/`opt`, `shift`; combined with `+`. |

**Example config.toml entries:**
```toml
keybind = cmd+t:new_tab
keybind = cmd+w:close_pane
keybind = cmd+shift+t:reopen_closed
keybind = cmd+1:goto_tab:1
keybind = ctrl+shift+c:copy_to_clipboard
keybind = unbind:cmd+q
```

## Visual spec

### Screenshot: keybindings.png — Key Bindings main list

**Layout**: macOS Preferences-style window, rounded corners, drop shadow on light gray. Two columns: narrow left sidebar (~310px) + wider right content panel.

**Left sidebar**:
- macOS traffic-light buttons (red filled, gray outlined) top-left.
- Rounded pill "Search" field below, gray magnifier icon, light gray background (#EBEBEB approx).
- Nav items with monoline SF Symbol-style icons, dark gray labels: General (circle-i), Shell (>_), Controls (cursor), Editor (document), Agents (plug), Appearance (palette), Recipes (book), **Key Bindings** (lightning bolt) — SELECTED with near-black rounded-rect pill (#1C1C1E-ish), white label, filling full sidebar width; Advanced (wrench).
- Sidebar background light gray.

**Right content panel**:
- Full-width rounded search field at top: "Search key bindings" placeholder, gray magnifier left, white/very-light background, subtle border.
- Section heading "GENERAL" in small-caps light gray uppercase (~11pt, #8A8A8E).
- Action rows separated by hairline dividers:
  - **Command Palette** — chips `⌘` `⇧` `P` (separate rounded-rect chips, light gray ~#F0F0F0, dark text, ~28×28px each)
  - **Open Quickly...** — `⌘` `⇧` `O`
  - **Jump to Current Pane...** — `⌘` `J`
  - **Workspace Commands** — `—` (unbound, gray)
  - **Open Recent...** — `—`
  - **Switch Open Tab...** — `—`
  - **Open Agent...** — `—`
  - **Open Folder...** — `—`
  - **Theme...** — `—` (partially visible at bottom)
- Labels in macOS body weight (~15pt, near-black); unbound rows show an em-dash in gray at the right margin.
- Chips are per-modifier-key (each modifier and each letter gets its own): rounded-rect border (radius ~6px), light gray fill, symbol/letter in dark text.
- Row height ~44px. No visible scroll indicator.

### Screenshot: keybindings-text.png — Text / Sequence and Commands / Recipe sections

**Top (partially visible)**: two recipe rows — **Recipe: Save...** (`⌘` `S`), **Recipe: Save As...** (`⌘` `⇧` `S`).

**TEXT / SEQUENCE section**:
- Heading "TEXT / SEQUENCE" in the small-caps gray uppercase style.
- Gray sub-text (~13pt): "Bind a key to send literal bytes to the focused terminal. Action prefixes: `text:hi` · `csi:17~` · `esc:O`" — code snippets inline in monospace, separated by middle-dots (`·`).
- Binding row: **Left** three chips `⌘` `⇧` `H` with a small gap before the input; **Right** a rounded text input holding `text:hi` (blinking cursor after "hi"), white background, dark border; **Far right** an outlined trash-can icon button (~22px).
- Below: a **+ Add** button right-aligned — light-bordered pill, "+" prefix, macOS secondary button style.

**COMMANDS / RECIPE section**:
- Heading "COMMANDS / RECIPE" in the same style.
- Empty state: "No recipes have a shortcut assigned yet." in gray body text, center-left.
- Footer: left-aligned "Edit shortcuts and create new recipes in the Recipes tab." followed by a right-aligned **Open Recipes →** button (near-black filled rounded-rect, white label).

### Screenshot: keybindings-recipe.png — Commands / Recipe populated state

**Close-cropped** (content area only, no sidebar/traffic lights):

- Heading "COMMANDS / RECIPE" in small-caps light gray uppercase.
- One recipe binding row: label "**simplify**" (bold/semibold dark) on the left; chips `⌘` `⇧` `S` on the right (same style); hairline divider below.
- Footer: "Edit shortcuts and create new recipes in the Recipes tab." (gray, left-aligned) + **Open Recipes →** button (dark rounded-rect, white text; arrow is part of the label).

## Screenshots

- `keybindings.png` — Key Bindings pane, GENERAL section with action list and keycap chips
- `keybindings-text.png` — Text / Sequence section with a `text:hi` entry and Commands / Recipe empty state
- `keybindings-recipe.png` — Commands / Recipe section with a populated "simplify" binding

## SlopDesk mapping notes

### Maps cleanly

- **Action-list UI with search + keycap chips**: a SwiftUI List in the Settings window (SettingsView / PreferencesStore); chip style is a custom SwiftUI view, no AppKit dependency.
- **Rebind by click + press**: an NSEvent global monitor captures the next key event after a row enters edit mode. SlopDesk already has an NSEvent monitor for the prefix chord — reuse it.
- **Conflict detection**: maintain a reverse index `[KeyChord: ActionID]` in `PreferencesStore`; look up on every chord entry.
- **Unbind via Backspace**: same NSEvent monitor path — if the captured key is Backspace, clear the binding.
- **Config file sync** (`~/.config/slopdesk/config.toml`): slopdesk uses `Defaults`/`PreferencesStore`; persist keybindings there and write out a TOML/plist representation if config-file editing is exposed.
- **Text / Sequence bindings** (`text:`, `csi:`, `esc:`): entirely client-side. Inject the resolved byte sequence into the focused terminal's PTY input channel (same path as keyboard injection). Works for local and remote alike because the client owns the keystroke → PTY write path.
- **+ Add / trash-icon row**: a SwiftUI dynamic list with an `@State` array of `(KeyChord?, String)` pairs.
- **Reset to Default**: clear the `keybind` array in `PreferencesStore` and write defaults back; the confirmation is a standard `Alert`.

### Requires adaptation

- **Commands / Recipe section** ("Open Recipes →"): slopdesk has recipes/commands via the agent-control and workspace system, but no exact "Recipes tab" equivalent yet. Stub as empty-state with a nav link to where custom commands are configured. **Deferred** until a Recipes analog exists.
- **Multi-key sequence chords** (`cmd+b>cmd+v`): the existing prefix-chord NSEvent monitor (used for `⌘B` prefix) supports recording and dispatching `>` sequences. But the GUI needs a two-phase recording flow (record first key, then second) — non-trivial, follow-up.
- **`unbind:` directive**: slopdesk must suppress an unbound chord from its default handler — the NSEvent monitor must check the keybind table before passing events to AppKit/SwiftUI default responders.
- **iOS client**: pane is macOS-only (hardware keyboard assumed). On iOS the equivalent is absent or a reduced set for an external Bluetooth keyboard. `csi:`/`esc:` text-sequence works on iOS as long as the PTY injection path is available (it is — same `SlopDeskTransport` channel). Chord recording can't map 1:1 (no modifiers on the software keyboard); **not supported** on the iOS software keyboard, supported only with an external keyboard.
- **`goto_tab:N` parameterized actions**: `cmd+1:goto_tab:1` uses a colon-separated parameter — the keybind parser must support parameterized actions (action name + optional argument), not just bare identifiers.
- **"Jump to Current Pane…" (`⌘J`)**: maps to the in-pane pane chooser (`openChooserPane`) via `WorkspaceStore` focus logic; direct mapping, but relabel to slopdesk's pane vocabulary.
- **Workspace Commands / Open Agent / Open Folder** (unbound by default): correspond to slopdesk concepts (session open, agent launch, folder mount). Stub as unbound actions in the registry with correct labels, wire up as those features mature.
