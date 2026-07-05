# Custom Commands / Layouts / Snippets (Recipes)

> slopdesk implements custom commands, layouts, and snippets as one unified
> feature: **Recipes**.

## Summary

A **recipe** is a portable snapshot of repeatable work — from a text snippet
(alias → expanded text) up to a whole workspace (tabs, split panes, working
directories, optionally the exact commands run). Saved as a `.slopdeskrecipe`
TOML file that can be re-opened or shared.

Stored in `~/.config/slopdesk/recipes/`; surfaces in **Settings → Recipes**,
the **File → Recipe** menu, and the **command palette**.

## Behaviors

### Save Layout

- Arrange tabs/splits, press `⌘S` (or **File → Recipe → Save…**).
- Provide a name, choose scope (**Current Tab** or **Current Window**), set
  content to "Layout Only," save.
- **Current Tab**: saves only the focused tab with its split panes.
- **Current Window**: saves every tab in the window.

### Portable Paths

With "Make paths portable" enabled, absolute path prefixes are replaced with
template variables at save time and re-resolved at open time:

| Variable | Resolves to |
|----------|-------------|
| `{{current_folder}}` | Directory where the recipe opens |
| `{{home_folder}}` | Home directory (`~`) |
| `{{recipe_location}}` | Folder containing the `.slopdeskrecipe` file |

### Snapshot Workspace with Commands

- **Include Commands** captures recently-executed shell commands and replays
  them sequentially on open. Requires active shell integration (OSC 133 command
  marks).
- **Include Scrollback** (third content level) stores terminal output but is
  only available for internally-saved recipes, not exported `.slopdeskrecipe`
  files.
- Steps: `⌘S` → select scope → set Content to "Include Commands (replay on
  open)" → save.

### Custom Commands (Commands-only recipe)

Replay commands without any layout change:
  1. Focus the target pane.
  2. `⌘S`, select **Commands** as the scope.
  3. Recent commands appear oldest-first; tick the desired ones.
  4. **Select All** toggles all items.
  5. **Double-click** any item to edit its text inline before saving.
  6. Save is enabled only when at least one command is ticked.

On open, commands are injected into the focused pane without creating new tabs
or windows.

### Text Snippets

- A snippet maps a short alias (no spaces) to reusable text sent to the shell
  prompt when the alias is typed and expanded.
- Created in **Settings → Recipes → Add → Text Snippet** (or edit via the
  pencil icon on an existing entry).
- Fields:
  - **Name** — label shown in the command palette and the list.
  - **Alias** — trigger word typed at the shell prompt; no spaces allowed.
  - **Text** — body sent to the shell when the alias is expanded.
- Placeholders available in the Text body:

| Placeholder | Expands to |
|-------------|------------|
| `{{clipboard}}` | Current clipboard contents |
| `{{date}}` | Today's date in `YYYY-MM-DD` format |
| `{{time}}` | Current time in `HH:mm` (24-hour) |
| `{{cursor}}` | Final cursor position after the text is sent |

- Example: alias `gco`, body `git checkout {{cursor}}` — types the command and
  leaves the cursor positioned for the branch name.

### Opening a Recipe

| Method | Result |
|--------|--------|
| Double-click `.slopdeskrecipe` in Finder | Opens in a new window |
| `slopdesk open foo.slopdeskrecipe` (CLI) | Same result |
| **File → Open Recipe** menu | Pick from the internal recipe database |

### The `.slopdeskrecipe` File Format

- Plain TOML — human-readable, diffable, version-control-friendly.
- Exported files omit: scrollback, machine-local keybindings, agent sessions.

**Example:**
```toml
[recipe]
name = "deploy-prod-debug"
version = 1
scope = "window"          # "tab" | "window" | "commands"

[[window.tabs]]
title = "API"

[[window.tabs.panes]]
cwd = "{{current_folder}}/api"
commands = ["tail -F log/prod.log"]

[[window.tabs.panes]]
cwd = "{{current_folder}}/api"
split = "right"           # relative to the previous pane
size = 0.5                # 0.0–1.0 of the parent
commands = ["make deploy"]

[[window.tabs]]
title = "Web"

[[window.tabs.panes]]
cwd = "{{current_folder}}/web"
commands = ["npm run preview"]
```

### Security for Command Replay

Controlled in **Settings → Recipes → Command Replay** with separate dropdowns
for **Saved Recipes** (default: Auto) and **Recipe Files** (default: Ask Once).

| Mode | Behavior |
|------|----------|
| Auto | All commands run automatically in sequence |
| Ask Once | Commands are shown; press Enter once to run all |
| Manually | Commands are fed one at a time; press Enter for each |
| Skip | Layout opens; no commands execute |

- Opening an unfamiliar `.slopdeskrecipe` displays all commands before
  execution with three choices:
  - **Always Trust** — remember the file by SHA-256 hash; follow replay settings.
  - **Run Once** — execute this instance only; prompt again next time.
  - **Cancel** — open nothing.
- Editing the file changes its hash, triggering a fresh trust prompt.
- Trusted-file records live in `~/Library/Application Support/SlopDesk/trusted_recipes.json`.
- Self-saved recipes bypass the trust dialog entirely.

### Shell Handoff Recognition

SlopDesk recognizes interactive programs (`ssh`, `tmux attach`,
`docker exec -it`, `su`, etc.) and **pauses** sequential command replay after
such a command in Auto/Ask Once modes until the inner shell returns to a prompt
or the user manually continues.

## Keybindings

| Action | Keys |
|--------|------|
| Save recipe (save layout / commands / snippet) | `⌘S` |
| File → Recipe → Save… (menu equivalent) | `⌘S` |

> No dedicated recipe-management keybindings beyond `⌘S`. Snippet expansion is
> triggered by typing the alias at the shell prompt and pressing the expansion
> key (Tab or configured trigger — not documented on this page).

## Config Keys

| Key | Default | Effect |
|-----|---------|--------|
| `scope` (in `.slopdeskrecipe`) | — | `"tab"` \| `"window"` \| `"commands"` — determines what is saved/replayed |
| `split` (per pane in `.slopdeskrecipe`) | — | `"right"` (or other direction) — split direction relative to previous pane |
| `size` (per pane in `.slopdeskrecipe`) | — | `0.0`–`1.0` fraction of parent container |
| `version` (in `.slopdeskrecipe`) | `1` | Recipe format version |
| Command Replay — Saved Recipes | `Auto` | Replay mode for internally-saved recipes |
| Command Replay — Recipe Files | `Ask Once` | Replay mode for externally-opened `.slopdeskrecipe` files |

> Runtime paths:
> - Recipes directory: `~/.config/slopdesk/recipes/`
> - Trusted-recipe hashes: `~/Library/Application Support/SlopDesk/trusted_recipes.json`

## Visual Spec

### Screenshot 1: `textsnippet-setting.png` — "Edit Text Snippet" dialog

**Overall layout:** A modal sheet over a dimmed Settings window. Sheet is white,
large-radius rounded (≈12 px), centered, soft drop shadow. Settings window behind
shows macOS traffic-light buttons (red active, dark-gray inactive) top-left and a
left sidebar with navigation items.

**Dialog header:** Bold "Edit Text Snippet" at upper-left, dark/black system font
(~17 pt). An `×` close button top-right (gray circle, ~20 px).

**Form fields (top to bottom):**

1. **Name field** — label "Name" bold (~13 pt) dark gray; single-line
   rounded-rect input (~1 px light gray border, white bg), content `timenow`
   in regular monospace-ish font; helper "Shown in the command palette and this
   list." in light gray (~11 pt).
2. **Alias field** — label "Alias" bold; same-style input, content `timenow`;
   helper "Trigger word typed at the shell prompt to expand this snippet."
   (~11 pt).
3. **Text field** — label "Text" bold; multi-line textarea (≈4 lines visible,
   same border), content `{{date}} {{time}}` in monospace, top-left aligned;
   diagonal double-arrow resize handle at bottom-right; helper
   "Placeholders: {{cursor}} · {{clipboard}} · {{date}} · {{time}}" (~11 pt,
   dot-separated inline).

**Footer row:** Two right-aligned buttons: "Cancel" (plain, no fill, dark text)
and "Save Changes" (solid blue fill, white text, rounded-rect, primary action).

**Settings sidebar (dimmed):** General (⚠), Shell (>_), Controls (cursor),
Editor (document), Agents (plug), Appearance (palette), **Recipes** (book,
bold/selected — current section), Key Bindings (lightning), Advanced (wrench).
Each row also has pencil (edit) and trash (delete) icons at right, partially
obscured by the sheet.

**Color palette:** #FFFFFF dialog, ~#F5F5F5 settings behind. Input borders
~#D1D1D6. Helper text ~#8E8E93. Primary button ~#007AFF (iOS system blue).
Cancel text ~#1C1C1E.

---

### Screenshot 2: `textsnippet-apply.gif` — Snippet expansion in the terminal (first frame)

**Overall layout:** macOS terminal window, white bg (light theme), large-radius
rounded corners (~12 px), gray drop shadow on light-gray desktop. No tab bar or
toolbar — minimalist single-pane.

**Title bar:** Centered "abner@MacBook-AB: ~" in medium gray system font.
Traffic-light buttons (all inactive/gray) top-left.

**Terminal area:** Nearly all white. Only content at top-left: a tilde `~` in
vivid green (~#00C853, cwd indicator from shell integration), then a small solid
green right-pointing triangle (▶, prompt indicator). Cursor is after the prompt,
ready for input.

**State shown:** Idle shell prompt before alias expansion is typed. The GIF (not
visible in this still) presumably shows the alias being typed and expanded into
the full snippet text.

**Color palette:** Window bg #FFFFFF. Title bar text ~#8E8E93. cwd `~` and prompt
arrow vivid green (likely #34C759). Desktop surround light gray ~#E5E5EA.

## Screenshots

- `textsnippet-setting.png` — "Edit Text Snippet" modal dialog in Settings → Recipes
- `textsnippet-apply.gif` — Animated demo of snippet alias expansion at the shell prompt

## SlopDesk Mapping Notes

### What maps 1:1

- **Text snippets (alias → text expansion):** Alias-expansion runs entirely
  client-side, as an interceptor on the terminal input path before bytes reach
  `libghostty` or the PTY write path. `{{date}}`, `{{time}}`, `{{clipboard}}`
  resolve locally; `{{cursor}}` is a cursor-position marker on the injected text
  needing no host involvement.
- **Recipe file format (`.slopdeskrecipe` TOML):** Fully client-side. Parse/open
  logic, in-memory recipe database (`~/.config/…`), and trust-hash store
  (`~/Library/…`) all live on the **client** (macOS or iOS).
- **Layout (tabs + splits):** `WorkspaceStore` / `PaneKind` tree already models
  tabs and panes; opening a recipe maps to `reconcile()` calls to create the
  declared tree. `split` and `size` map to the existing divider/split geometry.
- **Security / trust dialog:** Standard client-side sheet; SHA-256 computed
  locally; no host involvement.
- **Replay mode settings (Auto / Ask Once / Manually / Skip):** Client-side
  preference via `Defaults`/`PreferencesStore`.
- **Shell handoff recognition (ssh, tmux, etc.):** Client monitors OSC 133 marks
  to know when a prompt is active; pausing replay until the next prompt is a
  client-side state machine over the existing shell integration.

### What needs adaptation or cannot map 1:1

- **`cwd` in recipe panes:** Working directory at open time must be set on the
  **host** (a PTY/subprocess concern). The client sends the desired `cwd` as
  part of session-open params. `{{current_folder}}` / `{{home_folder}}` /
  `{{recipe_location}}` resolve on the **client** first (the recipe file lives
  there), then the resolved absolute path is forwarded to the host's PTY launch.
  If client and host are different machines the resolved path is **host-side**;
  portability across heterogeneous machines needs a convention (shared `~`
  layout, or an explicitly host-known path).
- **`commands` replay:** Commands sent as PTY input over the existing slopdesk
  write path. Sequencing (wait for OSC 133 prompt mark before the next command)
  requires shell integration active on the host shell (the expected deployment).
  Feasible, but prompt marks traverse the full host→client wire path, so replay
  latency scales with RTT.
- **"Include Scrollback" content level:** Requires capturing scrollback from
  `libghostty`'s scroll buffer on the **client** (not host). The terminal surface
  is local, so this is feasible for the client's scrollback cache; scrollback is
  ephemeral and not persisted on the host. Internally-only (no export) matches
  slopdesk's architecture naturally.
- **OSC 133 dependency for command replay:** Shell integration must be installed
  in the remote host shell. SlopDesk already relies on OSC 133 (block output,
  Claude detection), so this is consistent but must be documented as a recipe
  command-replay prerequisite.
- **iOS client:** Recipe UI (Settings → Recipes, edit sheet) needs an iOS
  counterpart. The `textsnippet-setting.png` modal translates naturally to a
  `UINavigationController`-pushed form sheet. No fundamental blocker.
- **File system access for `.slopdeskrecipe` opening:** iOS lacks Finder
  double-click; the client would use `UIDocumentPickerViewController` or the
  share sheet to receive files and register a UTI for the extension.
- **`slopdesk open foo.slopdeskrecipe` CLI:** Maps to the existing
  `slopdesk-client` CLI. A `--recipe` flag or subcommand forwards the TOML to the
  client app. Straightforward addition.
