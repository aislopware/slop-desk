# Custom Commands / Layouts / Snippets (Recipes)

> This page covers custom commands, layouts, and snippets together, since
> slopdesk implements them as a single unified feature. The name for this
> feature set is **Recipes**.

## Summary

A **recipe** is a portable snapshot of repeatable work. It ranges from a simple
text snippet (alias → expanded text) up to a whole workspace: tabs, split panes,
working directories, and optionally the exact commands that were run — saved as a
`.slopdeskrecipe` TOML file that can be re-opened later or shared with a teammate.

Recipes are stored in `~/.config/slopdesk/recipes/` and surface in:
- **Settings → Recipes**
- **File → Recipe** menu
- The **command palette**

## Behaviors

### Save Layout

- Arrange tabs and splits as desired, then press `⌘S` (or **File → Recipe → Save…**).
- Provide a name, choose a scope (**Current Tab** or **Current Window**), set content
  to "Layout Only," and save.
- **Current Tab** scope: saves only the focused tab with its split panes.
- **Current Window** scope: saves every tab in the window.

### Portable Paths

When "Make paths portable" is enabled, absolute path prefixes are replaced with
template variables at save time and re-resolved at open time:

| Variable | Resolves to |
|----------|-------------|
| `{{current_folder}}` | Directory where the recipe opens |
| `{{home_folder}}` | Home directory (`~`) |
| `{{recipe_location}}` | Folder containing the `.slopdeskrecipe` file |

### Snapshot Workspace with Commands

- Enabling **Include Commands** captures recently-executed shell commands and
  replays them sequentially on recipe open. Requires active shell integration
  (OSC 133 command marks).
- A third content level, **Include Scrollback**, stores terminal output but is
  only available for internally-saved recipes (not exported `.slopdeskrecipe` files).
- Steps: press `⌘S` → select scope → set Content to "Include Commands (replay on
  open)" → save.

### Custom Commands (Commands-only recipe)

- For replaying commands without any layout change:
  1. Focus the target pane.
  2. Press `⌘S` and select **Commands** as the scope.
  3. A list of recent commands appears oldest-first; tick the desired ones.
  4. **Select All** button toggles all items in the list.
  5. **Double-click** any item to edit its text inline before saving.
  6. Save is enabled only when at least one command is ticked.
- On open, commands are injected into the currently-focused pane without
  creating new tabs or windows.

### Text Snippets

- A snippet maps a short alias (no spaces) to reusable text that is sent to the
  shell prompt when the alias is typed and expanded.
- Created in **Settings → Recipes → Add → Text Snippet** (or edit via the pencil
  icon on an existing entry).
- Fields:
  - **Name** — human-readable label shown in the command palette and the list.
  - **Alias** — trigger word typed at the shell prompt; no spaces allowed.
  - **Text** — body content sent to the shell when the alias is expanded.
- Available placeholders in the Text body:

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
- Exported files omit: scrollback, machine-local keybindings, and agent sessions.

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

- Controlled in **Settings → Recipes → Command Replay** with separate dropdowns
  for **Saved Recipes** (default: Auto) and **Recipe Files** (default: Ask Once).

| Mode | Behavior |
|------|----------|
| Auto | All commands run automatically in sequence |
| Ask Once | Commands are shown; press Enter once to run all |
| Manually | Commands are fed one at a time; press Enter for each |
| Skip | Layout opens; no commands execute |

- Opening an unfamiliar `.slopdeskrecipe` displays all commands before execution with
  three choices:
  - **Always Trust** — remember the file by SHA-256 hash; follow replay settings.
  - **Run Once** — execute this instance only; prompt again next time.
  - **Cancel** — open nothing.
- Editing the file changes its hash, triggering a fresh trust prompt.
- Trusted-file records live in `~/Library/Application Support/SlopDesk/trusted_recipes.json`.
- Self-saved recipes bypass the trust dialog entirely.

### Shell Handoff Recognition

- SlopDesk recognizes interactive programs (`ssh`, `tmux attach`, `docker exec -it`,
  `su`, etc.) and **pauses** sequential command replay after such a command in
  Auto/Ask Once modes until the inner shell returns to a prompt or the user
  manually continues.

## Keybindings

| Action | Keys |
|--------|------|
| Save recipe (save layout / commands / snippet) | `⌘S` |
| File → Recipe → Save… (menu equivalent) | `⌘S` |

> No additional dedicated keybindings are documented for recipe management beyond
> `⌘S` for saving. Snippet expansion is triggered by typing the alias at the shell
> prompt and pressing the expansion key (Tab or configured trigger — not explicitly
> documented on this page).

## Config Keys

| Key | Default | Effect |
|-----|---------|--------|
| `scope` (in `.slopdeskrecipe`) | — | `"tab"` \| `"window"` \| `"commands"` — determines what is saved/replayed |
| `split` (per pane in `.slopdeskrecipe`) | — | `"right"` (or other direction) — split direction relative to previous pane |
| `size` (per pane in `.slopdeskrecipe`) | — | `0.0`–`1.0` fraction of parent container |
| `version` (in `.slopdeskrecipe`) | `1` | Recipe format version |
| Command Replay — Saved Recipes | `Auto` | Replay mode for internally-saved recipes |
| Command Replay — Recipe Files | `Ask Once` | Replay mode for externally-opened `.slopdeskrecipe` files |

> Runtime configuration paths:
> - Recipes directory: `~/.config/slopdesk/recipes/`
> - Trusted-recipe hashes: `~/Library/Application Support/SlopDesk/trusted_recipes.json`

## Visual Spec

### Screenshot 1: `textsnippet-setting.png` — "Edit Text Snippet" dialog

**Overall layout:** A modal sheet rendered over a dimmed (grayed-out) Settings
window. The sheet is white, large-radius rounded (≈12 px), centered, and floats
with a soft drop shadow. The Settings window behind it shows the macOS traffic-
light buttons (red active, dark-gray stopped/inactive) at top-left and a left
sidebar with navigation items.

**Dialog header:** Bold label "Edit Text Snippet" at upper-left of the sheet, in
dark/black system font (~17 pt). An `×` close button sits at the top-right corner
of the sheet (gray circle, ~20 px).

**Form fields (top to bottom):**

1. **Name field**
   - Section label: "Name" in bold system font (~13 pt), dark gray.
   - Text input: single-line, rounded-rect border (~1 px light gray), white
     background. Content shown: `timenow` in regular-weight monospace-ish font.
   - Helper text below: "Shown in the command palette and this list." in light
     gray (~11 pt).

2. **Alias field**
   - Section label: "Alias" in bold system font.
   - Text input: same style as Name field. Content: `timenow`.
   - Helper text: "Trigger word typed at the shell prompt to expand this snippet."
     in light gray (~11 pt).

3. **Text field**
   - Section label: "Text" in bold system font.
   - Multi-line text area: taller (≈4 lines visible), same rounded-rect border.
     Content shown: `{{date}} {{time}}` in monospace font, top-left aligned.
   - A resize handle icon (diagonal double-arrow) at the bottom-right corner of
     the textarea.
   - Helper text below the textarea: "Placeholders: {{cursor}} · {{clipboard}} ·
     {{date}} · {{time}}" in light gray (~11 pt), dot-separated inline list.

**Footer row (bottom of sheet):**
- Two buttons right-aligned: "Cancel" (plain, no fill, dark text) and
  "Save Changes" (solid blue fill, white text, rounded-rect). "Save Changes" is
  the primary action.

**Settings sidebar (dimmed in background):**
- Visible left-sidebar items: General (⚠ icon), Shell (>_ icon), Controls (cursor
  icon), Editor (document icon), Agents (plug icon), Appearance (palette icon),
  **Recipes** (book icon, bold/selected — highlighted in bold indicating current
  section), Key Bindings (lightning bolt icon), Advanced (wrench icon).
- Each row in the sidebar also has a pencil (edit) icon and trash (delete) icon
  visible to the right of rows, partially obscured by the modal sheet.

**Color palette:** Near-white background (#FFFFFF dialog, ~#F5F5F5 settings
behind). Input borders: ~#D1D1D6. Helper text: ~#8E8E93. Primary button: solid
blue (~#007AFF iOS system blue). Cancel text: dark gray (~#1C1C1E).

---

### Screenshot 2: `textsnippet-apply.gif` — Snippet expansion in the terminal (first frame)

**Overall layout:** A macOS terminal window, white background (light theme),
large-radius rounded corners (~12 px), gray outer drop shadow on light-gray
desktop. No visible tab bar or toolbar — minimalist single-pane view.

**Title bar:** Centered text "abner@MacBook-AB: ~" in medium gray, system font.
Traffic-light buttons (all inactive/gray circles) at top-left.

**Terminal area:** Nearly all white. The only content is at the very top-left:
- A tilde `~` in vivid green (~#00C853 or similar bright green), representing
  the cwd indicator from shell integration.
- Immediately to the right: a small solid green right-pointing triangle (▶),
  representing the shell prompt indicator/arrow.
- The cursor is positioned after the prompt indicator, ready for input.

**State shown:** Idle shell prompt before alias expansion is typed. The GIF
animation (not visible in this still frame) presumably shows the alias being typed
and then expanded into the full snippet text.

**Color palette:** Window background #FFFFFF. Title bar text ~#8E8E93. Shell cwd
`~` and prompt arrow: vivid green (likely #34C759 or similar). Desktop surround:
light gray ~#E5E5EA.

## Screenshots

- `textsnippet-setting.png` — "Edit Text Snippet" modal dialog in Settings → Recipes
- `textsnippet-apply.gif` — Animated demo of snippet alias expansion at the shell prompt

## SlopDesk Mapping Notes

### What maps 1:1

- **Text snippets (alias → text expansion):** The alias-expansion logic runs
  entirely client-side in the terminal app. SlopDesk can implement this as a
  client-side interceptor on the terminal input path before bytes reach
  `libghostty` or the PTY write path. The `{{date}}`, `{{time}}`, and
  `{{clipboard}}` placeholders resolve locally. `{{cursor}}` is a cursor-position
  marker applied to the injected text and needs no host involvement.

- **Recipe file format (`.slopdeskrecipe` TOML):** Fully client-side concern. The
  parse-and-open logic, the in-memory recipe database (`~/.config/…`), and the
  trust-hash store (`~/Library/…`) all live on the **client** (macOS or iOS).

- **Layout (tabs + splits):** The `WorkspaceStore` / `PaneKind` tree already
  models tabs and panes. Opening a recipe maps to `reconcile()` calls to create
  the declared tab/pane tree. The `split` and `size` fields map to the existing
  divider/split geometry model.

- **Security / trust dialog:** A standard client-side sheet. SHA-256 hash
  computed locally. No host involvement.

- **Replay mode settings (Auto / Ask Once / Manually / Skip):** Client-side
  preference stored via `Defaults`/`PreferencesStore`.

- **Shell handoff recognition (ssh, tmux, etc.):** The client monitors OSC 133
  command marks to know when a prompt is active. Pausing replay until the next
  prompt is a client-side state machine on top of the existing shell integration
  layer.

### What needs adaptation or cannot map 1:1

- **`cwd` in recipe panes:** The working directory at recipe-open time must be
  set on the **host** (it is a PTY/subprocess concern). The client sends the
  desired `cwd` to the host as part of session-open parameters. The
  `{{current_folder}}` / `{{home_folder}}` / `{{recipe_location}}` variables
  must be resolved on the **client** first (since the recipe file lives there),
  then the resolved absolute path is forwarded to the host's PTY launch. If the
  client and host filesystems are different machines, the resolved path is a
  **host-side** path — recipe portability across heterogeneous machines is not
  possible without a convention (e.g. both machines share the same `~` layout or
  the path is explicitly set to a host-known path).

- **`commands` replay:** Commands are sent as PTY input over the existing
  slopdesk write path. The sequencing logic (wait for OSC 133 prompt mark
  before injecting the next command) requires shell integration to be active on
  the host shell, which is the expected deployment mode. This is feasible but the
  client must wait for prompt marks that traverse the full host→client wire path,
  so replay latency scales with RTT.

- **"Include Scrollback" content level:** Storing terminal scrollback in a recipe
  requires capturing it from `libghostty`'s scroll buffer on the **client** side
  (not the host). For slopdesk the terminal surface is local, so this is
  technically feasible for the client's scrollback cache. However, the scrollback
  is ephemeral and not persisted on the host. Internally-only restriction (no
  export) matches slopdesk's architecture naturally.

- **OSC 133 dependency for command replay:** Shell integration must be installed
  in the remote shell on the host. SlopDesk already relies on OSC 133 for other
  features (block output, Claude detection), so this is consistent but must be
  documented as a prerequisite for recipe command replay.

- **iOS client:** Recipe management UI (Settings → Recipes, the edit sheet) needs
  an iOS-adapted counterpart. The modal sheet shown in `textsnippet-setting.png`
  translates naturally to a `UINavigationController`-pushed form sheet on iOS. No
  fundamental blocker.

- **File system access for `.slopdeskrecipe` opening:** On iOS, Finder-style
  double-click is unavailable. The iOS client would use a `UIDocumentPickerViewController`
  or the share sheet to receive `.slopdeskrecipe` files and register a UTI for the
  extension.

- **`slopdesk open foo.slopdeskrecipe` CLI:** Maps to the existing `slopdesk-client`
  CLI. A `--recipe` flag or subcommand would forward the TOML to the client app
  for processing. Straightforward addition.
