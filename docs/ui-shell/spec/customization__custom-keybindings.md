# Keybindings

## Summary

SlopDesk lets users rebind almost any action from a dedicated **Key Bindings** settings pane, or by editing `~/.config/slopdesk/config.toml` directly. The GUI and the config file stay in sync — changes made in the GUI are written back to `config.toml` automatically. The pane has three sub-sections: the main bindable-action list (grouped by category), a **Text / Sequence** section for sending literal byte sequences to the terminal, and a **Commands / Recipe** section that mirrors recipe shortcuts.

## Behaviors

- **Settings → Key Bindings** lists every bindable action grouped by category (General, Tabs, Pane, …). A search box at the top filters the list by action name or by chord (e.g. type `cmd+t` to find what's on that combo).
- Each row shows the action name on the left and the current chord as keycap chips on the right. An unbound action shows a dash (`—`) instead of chips.
- **Rebind**: clicking a row highlights it and shows a "Press a key combination…" prompt in the chord area. The user then presses the new chord; the chips update immediately.
- **Conflict detection**: if the new chord is already taken, a "Conflicts with: …" note appears below the row so the user can choose something else or overwrite the existing binding.
- **Unbind**: click the row then press Backspace to clear the binding. Press Esc to cancel without making a change.
- **Search by chord**: typing a chord string (e.g. `cmd+t`) in the search box shows the action that chord is currently assigned to.
- **Reset to Default**: once any binding has been customized, a "Reset to Default" button appears in the top-right corner of the Key Bindings pane. Clicking it shows a "Reset all key bindings?" confirmation dialog. Confirming clears all customizations at once — there is no per-row revert in the GUI. To reset a single binding, delete its `keybind` line from `config.toml` or restore the default chord in the GUI.
- **Text / Sequence** sub-section: binds a chord to send literal bytes to the focused terminal. Useful for emitting escape sequences a program expects or for typing text snippets. Supported action prefixes:
  - `text:<string>` — sends the literal string (e.g. `text:hi` types `hi`)
  - `csi:<payload>` — sends ESC [ + payload (e.g. `csi:17~` sends the F6 key sequence)
  - `esc:<payload>` — sends ESC + payload (e.g. `esc:O`)
  - To add: click **+ Add**, click the trigger button to record a chord, type the action string, and it is saved.
  - To delete: click the trash icon on the row.
- **Commands / Recipe** sub-section: read-only mirror of any recipe that has a shortcut assigned. Recipe shortcuts are assigned and edited in the Recipes tab, not here. When no recipe has a shortcut, shows "No recipes have a shortcut assigned yet." An **Open Recipes →** button navigates to the Recipes tab.
- **Config file syntax**: `keybind = <modifier-chord>:<action>`. Repeat the `keybind` key to add multiple bindings.
  - Modifier names: `cmd`, `ctrl`, `alt` (or `opt`), `shift`. Combined with `+`.
  - Multi-key sequences (chords in sequence) use `>`: e.g. `cmd+b>cmd+v`.
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

**Overall layout**: macOS Preferences-style window with rounded corners and a drop shadow on a light gray background. Two-column layout: a narrow left sidebar (~310px wide) and a wider right content panel.

**Left sidebar**:
- macOS traffic-light close/minimize/fullscreen buttons (red filled, gray outlined) at top-left.
- A rounded pill search field ("Search") below the traffic lights, with a gray magnifier icon. Background is light gray (#EBEBEB approx).
- Navigation list items with small icons (monoline SF Symbol-style) and labels in dark gray:
  - General (circle-i icon)
  - Shell (>_ icon)
  - Controls (cursor/pointer icon)
  - Editor (document icon)
  - Agents (plug icon)
  - Appearance (palette icon)
  - Recipes (book icon)
  - **Key Bindings** (lightning bolt icon) — SELECTED, shown with a dark rounded-rect highlight (#1C1C1E or similar near-black pill), white label text
  - Advanced (wrench icon)
- Sidebar background is light gray, selected row fills the full sidebar width with a near-black rounded pill.

**Right content panel**:
- A full-width rounded search field at the top: "Search key bindings" placeholder text, gray magnifier icon on left. White/very light background, subtle border.
- Section heading "GENERAL" in small-caps light gray uppercase tracking (~11pt, #8A8A8E).
- List of action rows, each separated by a hairline divider:
  - **Command Palette** — keycap chips on right: `⌘` `⇧` `P` (three separate rounded-rect chips, light gray background ~#F0F0F0, dark text, ~28×28px each)
  - **Open Quickly...** — chips: `⌘` `⇧` `O`
  - **Jump to Current Pane...** — chips: `⌘` `J` (two chips)
  - **Workspace Commands** — dash `—` (unbound, gray)
  - **Open Recent...** — dash `—`
  - **Switch Open Tab...** — dash `—`
  - **Open Agent...** — dash `—`
  - **Open Folder...** — dash `—`
  - **Theme...** — dash `—` (partially visible at bottom)
- Action labels are in standard macOS body text weight (~15pt, near-black). Unbound rows show a single em-dash in gray at the right margin.
- Keycap chips are individual per-modifier-key: each modifier and each letter key gets its own chip. Chips have a rounded-rect border (radius ~6px), light gray fill, and contain a symbol or letter in dark text.
- Row height is approximately 44px. The list has no visible scroll indicator in this view.

### Screenshot: keybindings-text.png — Text / Sequence and Commands / Recipe sections

**Top portion (partially visible)**: shows two recipe rows at the top of the scroll area:
- **Recipe: Save...** — chips: `⌘` `S`
- **Recipe: Save As...** — chips: `⌘` `⇧` `S`

**TEXT / SEQUENCE section**:
- Section heading "TEXT / SEQUENCE" in same small-caps gray uppercase style as other section headers.
- Explanatory sub-text below the heading (gray, ~13pt): "Bind a key to send literal bytes to the focused terminal. Action prefixes: `text:hi` · `csi:17~` · `esc:O`" — the code snippets appear inline in monospace within the gray description text, separated by middle-dots (`·`).
- A binding row below the description, showing:
  - **Left side**: three keycap chips `⌘` `⇧` `H` arranged horizontally with a small gap between the chord group and the text input.
  - **Right side**: a text input field with rounded corners containing the typed action string `text:hi` (with a blinking cursor visible after "hi"), white background, dark border.
  - **Far right**: a trash/delete icon button (outlined trash-can icon, ~22px).
- Below the binding row: a **+ Add** button aligned to the right margin. Light-bordered pill shape, "+" prefix label, standard macOS secondary button style.

**COMMANDS / RECIPE section**:
- Section heading "COMMANDS / RECIPE" in same small-caps gray uppercase style.
- Empty-state message: "No recipes have a shortcut assigned yet." in gray italic/regular body text, center-left aligned.
- Footer row: left-aligned text "Edit shortcuts and create new recipes in the Recipes tab." followed by a **Open Recipes →** button — dark filled rounded-rect button (near-black background, white label text, ~"Open Recipes →"), right-aligned within the row.

### Screenshot: keybindings-recipe.png — Commands / Recipe populated state

**Close-cropped view** (no sidebar visible, no traffic lights — just the content area):

- Section heading "COMMANDS / RECIPE" in small-caps light gray uppercase.
- One recipe binding row:
  - Label "**simplify**" in bold/semibold dark text on the left.
  - Three keycap chips on the right: `⌘` `⇧` `S` — same rounded-rect chip style as main list.
  - Hairline divider below the row.
- Footer row below the divider: "Edit shortcuts and create new recipes in the Recipes tab." (gray body text, left-aligned) followed by **Open Recipes →** button (dark rounded-rect, white text, no arrow glyph in the button itself — arrow is part of the label "Open Recipes →").

## Screenshots

- `keybindings.png` — Settings window showing Key Bindings pane, GENERAL section with action list and keycap chips
- `keybindings-text.png` — Text / Sequence section with a `text:hi` binding entry and Commands / Recipe empty state
- `keybindings-recipe.png` — Commands / Recipe section with a populated "simplify" recipe binding

## SlopDesk mapping notes

### Maps cleanly

- **Action-list UI with search + keycap chips**: implementable as a SwiftUI List in the macOS Settings window (SettingsView / PreferencesStore). The chip style (individual rounded-rect per modifier key) is a custom SwiftUI view — no AppKit dependency.
- **Rebind by click + press**: use an NSEvent global monitor to capture the next key event after a row enters edit mode. SlopDesk already has an NSEvent monitor for the prefix chord; the same mechanism can serve here.
- **Conflict detection**: maintain a reverse index `[KeyChord: ActionID]` in `PreferencesStore`; look up on every chord entry attempt.
- **Unbind via Backspace**: handled in the same NSEvent monitor path — if the captured key is Backspace, clear the binding.
- **Config file sync** (`~/.config/slopdesk/config.toml`): slopdesk uses `Defaults`/`PreferencesStore`; keybindings should be persisted there and also written out to a TOML/plist representation if the project exposes config-file editing.
- **Text / Sequence bindings** (`text:`, `csi:`, `esc:` prefixes): entirely client-side. On action, inject the resolved byte sequence into the focused terminal's PTY input channel (the same path as keyboard injection). Works identically for local and remote terminals because the client owns the keystroke → PTY write path.
- **+ Add / trash-icon row**: standard SwiftUI dynamic list with an `@State` array of `(KeyChord?, String)` pairs.
- **Reset to Default**: clear the `keybind` array in `PreferencesStore` and write defaults back. The "Reset all key bindings?" confirmation is a standard `Alert`.

### Requires adaptation

- **Commands / Recipe section** ("Open Recipes →"): slopdesk has recipes/commands via the agent-control and workspace system, but the exact "Recipes tab" equivalent does not exist as of the current UI. This section can be stubbed as empty-state with a navigation link to wherever custom commands are configured. Mark as **deferred** until a Recipes analog is built.
- **Multi-key sequence chords** (`cmd+b>cmd+v` prefix chains): slopdesk already has a prefix-chord NSEvent monitor (used for `⌘B` prefix). The same mechanism supports recording and dispatching `>` sequences. However, the GUI for displaying and recording a two-step chord requires a two-phase recording UI — record first key, then second key — which is non-trivial and should be a follow-up.
- **`unbind:` directive in config**: when a user unbinds a default action, slopdesk must suppress that chord from its default handler. The NSEvent monitor must check the keybind table before passing events to AppKit/SwiftUI default responders.
- **iOS client**: the Key Bindings settings pane is macOS-only (hardware keyboard assumed). On iOS the equivalent is either absent or limited to a reduced set that makes sense for an external Bluetooth keyboard. The `csi:` / `esc:` text-sequence feature works on iOS as long as the PTY injection path is available (it is — same `SlopDeskTransport` channel). The GUI for recording chords on iOS (no modifier keys on the software keyboard) cannot map 1:1; flag as **not supported** on iOS software keyboard, supported only with external keyboard.
- **`goto_tab:N` parameterized actions**: the action syntax `cmd+1:goto_tab:1` uses a colon-separated parameter. SlopDesk's keybind parser must support parameterized actions (action name + optional argument), not just bare action identifiers.
- **"Jump to Current Pane…" (`⌘J`)**: slopdesk has `WorkspaceStore` pane focus logic; this action maps to the in-pane pane chooser (`openChooserPane`). The mapping is direct but the label should be adapted to slopdesk's pane vocabulary.
- **Workspace Commands / Open Agent / Open Folder** (unbound by default): these correspond to slopdesk workspace concepts (session open, agent launch, folder mount). They can be stubbed as unbound actions in the registry with the correct labels, to be wired up as those features mature.
