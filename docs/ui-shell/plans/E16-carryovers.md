# E16 — Recipes + Snippets — carry-overs (REQUIRED acceptance criteria)

**Read BEFORE planning. Every MUST/NEVER is an acceptance gate.**

Epic goal: Recipes subsystem (save/restore layouts + command replay) + surface the snippet engine.
Acceptance (all **"both"** — macOS + iOS):
- **ES-E16-1** — ⌘S saves current tab/window layout as a `.slopdeskrecipe`, layout-only or include-commands.
- **ES-E16-2** — open a recipe → restores pane tree + cwds, replays commands per mode Auto/Ask-Once/Manually/Skip, pauses on shell handoffs.
- **ES-E16-3** — unfamiliar recipe file shows its commands before run with Always-Trust / Run-Once / Cancel; editing re-prompts.
- **ES-E16-4** — create a text snippet Name/Alias/Text with `{{date}}`/`{{time}}`/`{{clipboard}}`/`{{cursor}}`; typing its alias at the prompt expands it.

Spec: `spec/customization__custom-commands.md` (authoritative — `.slopdeskrecipe` TOML example, replay-mode table, trust rules, snippet placeholder table), `spec/user-interface__window-tab-split.md`.

---

## 0. SCOPE — Recipes IS in scope (NOT the skipped Workflows runner)

The spec notes custom-commands overlaps a broader "workflows/recipes" idea — **do not conflate E16 with the skipped Workflows feature.** Recipes is IN scope:
- Numbered epic in the user-approved backlog; topo order `…→E13→**E16**→E21→E20`.
- E7 scaffolded **Settings → Recipes** as a reserved-empty placeholder to keep the settings navigator's section list stable (SettingsView.swift ~107-150, `case recipes`, SF Symbol `book`). E16 POPULATES it.
- Deferred Task #14 ("populate Recipes (text-snippet library)") is **subsumed by E16** — close that half here. The Editor settings section (Task #14's other half) needs a file-editor and stays deferred; do NOT build it.

The "skip Workflows entirely" directive targets a **standalone command-/workflow-runner** (Warp-Workflows-style searchable parameterized-command library), NOT an epic. Recipes (layout snapshots + snippets + command replay) is a customization feature, built here.

**Storage:** recipe files `~/.config/slopdesk/recipes/*.slopdeskrecipe` (alongside `~/.config/slopdesk/themes/`); trust store `~/Library/Application Support/SlopDesk/trusted_recipes.json`; internal recipe DB persists in the workspace (LayoutPreset already does this).

**Wire posture: `touchesWire:false`.** Everything is CLIENT-side. Recent commands come from the EXISTING client-side OSC-133 block model; replay injects through the EXISTING terminal input seam (verbatim UTF-8); cwd/`cd` uses the EXISTING safe-literal builder. **No new wire message, no metadata verb → golden MUST stay zero-diff (33 emitted byte-identical + 13 frozen intact).** `touchesIOS:true`, `touchesFloatCodec:false`.

---

## 1. VERIFY-NOT-REBUILD — these engines ALREADY EXIST (read them; do not rebuild — E9 stale-map lesson)

Most substrate is built — do not assume greenfield.

### Snippets (value substrate complete)
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/Snippet.swift` — `Snippet { id, name, body }` (Codable/Sendable/Identifiable). Body supports **`{{placeholder}}`** slots AND **`<Token>`** control keys.
- `SnippetExpander` (same file) — pure `{{name}}` resolver: `expand(_:values:) -> (text, missing)` and `placeholders(in:)`. Names are `[A-Za-z0-9_.-]+`; **EVERY `{{x}}` is currently a USER-PROMPT slot** (reported in `missing` when no value). Key divergence to fix — see gap C.
- `SendKeysParser` (same file) — pure `<Token>`→bytes (`<Enter>`/`<Tab>`/`<C-c>`/`<Up>`…). For snippet BODIES only — **never** for recipe cwd/commands.
- `WorkspaceStore`: `addSnippet(name:body:)` / `updateSnippet(_:name:body:)` / `deleteSnippet(_:)` + `var snippets: [Snippet]` (WorkspaceStore.swift ~1479-1510). CRUD done.

### Layout presets (save/restore substrate built — recipes layer ON TOP)
- `LayoutPreset` domain — `{ id, name, canvas, groups, focusedPane, triggerAppName }` (persisted on `Workspace`).
- `WorkspaceStore.saveLayoutPreset(name:triggerAppName:)` (~2014) — snapshots the live canvas (strips ephemeral panes via `strippingEphemeral`), overwrite-by-name, `reconcile()` persists. `switchToLayoutPreset(name:)` restores. `layoutPresetNames`.
- **Save-layout request flow** exists: `requestSaveLayout()` / `pendingSaveLayout` / `clearSaveLayoutRequest()` (root view presents a name-entry alert) + `CommandInterpreter.saveLayout` ("Save Current Layout…") + `case .saveLayout:` routing (~4362).
- App-trigger auto-switch: `presetForLaunchedApp` / `autoSwitchForLaunchedApp` / `clearAutoSwitchLatch`.

### Session templates (reuse the SAFE command/cwd builder — do NOT hand-roll cd)
- `SessionTemplate` + `SessionTemplateEngine` + `.builtIns` + `seedingBuiltInSessionTemplatesIfEmpty` (TreeWorkspace).
- **`SessionTemplateEngine.launchBytes(cwd:command:)`** — SAFE-literal `cd` + command builder (single-quote-escaped cwd). **REUSE for recipe pane cwd + command injection. NEVER build `cd` by hand, NEVER route cwd/commands through SendKeysParser** (literal user text → verbatim UTF-8; SendKeysParser is snippet `<Token>` bodies only).

### TOML (reuse the PARSER PATTERN + discipline, not the schema)
- `Sources/SlopDeskVideoProtocol/Settings/ThemeTOMLParser.swift` — validate-then-drop TOML-subset parser for `.slopdesktheme` (nil on malformed; E15 fix made it handle single-quoted literal strings). `ThemeLibrary` scans `~/.config/slopdesk/themes/*`; `ThemeImporters`. **Reuse the parse DISCIPLINE** (validate-then-drop, nil-on-malformed) for a NEW `.slopdeskrecipe` codec. Recipe TOML has **arrays-of-tables** (`[[window.tabs]]`, `[[window.tabs.panes]]`) the flat theme parser can't handle — prefer a dedicated `RecipeTOMLCodec` (same discipline) so you don't risk the frozen theme path.

### Command replay + recent-commands source
- `Sources/SlopDeskWorkspaceCore/Terminal/BlockReRunEncoder.swift` + `reRunCommandInActivePane` (E11) + the OSC-133 block model (E9 Outline / `TerminalBlockModel`) — **the "recently-executed shell commands" source** for Include-Commands (client-side). Inject via verbatim `TerminalViewModel.sendInput`.

### Restore + settings + clipboard
- `reconcile()` / reconcileTree + `strippingEphemeral` + canvas/groups snapshot model = the restore substrate.
- **Settings → Recipes** reserved-empty placeholder (POPULATE it). `SlopDeskClientApp.ClipboardMonitor` is the `{{clipboard}}` source (macOS NSPasteboard / iOS UIPasteboard, behind the existing clipboard-agnostic seam — keep tests off the real pasteboard).

---

## 2. GENUINE GAPS — what E16 must actually BUILD

**A. Snippets settings UI** — Settings → Recipes → **Add → Text Snippet** + pencil-edit; editor fields **Name / Alias / Text**; list of existing snippets. CRUD store exists; this is the missing view layer filling the reserved-empty Recipes section. Surface snippets in the ⌘K palette too.

**B. Snippet `alias` + at-prompt expansion** — add an `alias` field to `Snippet` (trigger word, **no spaces**; bump schema, decode-fail-to-default per no-backcompat). Spec: "typing its alias at the prompt expands it." SAFE baseline = explicit expansion (palette / a key by alias or name). True type-at-prompt auto-expand needs prompt-aware input interception (risky — could mangle typing); if implemented, gate behind OSC-133;A prompt-state + word-boundary trigger + a setting, with an honest fallback. **Pick the most faithful LOW-RISK path; do not ship something that corrupts ordinary typing.**

**C. Dynamic auto-resolving template vars** `{{clipboard}}` / `{{date}}` (`YYYY-MM-DD`) / `{{time}}` (`HH:mm` 24h) / `{{cursor}}` (final caret position; text after it is positioned, NOT auto-Entered). DISTINCT from user-prompt `{{name}}` slots — must **NOT** prompt and **NOT** appear in `missing`/`placeholders`. Add a **reserved-var resolver layer ABOVE** the user-prompt layer in `SnippetExpander` (reserved names resolved first; everything else stays user-prompt). Keep it **pure** — inject resolved clipboard/date/time strings as parameters (no `Date()`/pasteboard reads inside pure code → deterministic + testable). `{{cursor}}` is a caret-placement marker, not text.

**D. `.slopdeskrecipe` TOML codec (NEW)** — emit (LayoutPreset → TOML) + parse (TOML → recipe model). Schema per spec: `[recipe] name/version/scope("tab"|"window"|"commands")`, `[[window.tabs]] title`, `[[window.tabs.panes]] cwd/commands/split("right"…)/size(0.0–1.0)`. **Validate-then-drop** (untrusted file): malformed → nil, validate tab/pane counts before allocating, never force-unwrap, clamp `size` to 0–1. **Exported files OMIT scrollback, machine-local keybindings, and agent sessions.**

**E. Portable paths** — `{{current_folder}}` (dir the recipe opens in) / `{{home_folder}}` (`~`) / `{{recipe_location}}` (folder containing the file). Opt-in "Make paths portable": replace abs-path prefixes at SAVE, re-resolve at OPEN. Pure path-template fn, unit-tested. RECIPE-cwd templates resolved at recipe-open — **do NOT route through SnippetExpander** (different domain, different resolve time).

**F. Save sheet — scope + content levels** — extend the name-entry alert into a fuller save flow: **scope** = Current Tab / Current Window / **Commands**; **content** = Layout Only / Include Commands (replay-on-open; requires OSC-133) / Include Scrollback (**internal-only**, not exported). Commands-only recipe: list recent OSC-133 commands oldest-first, **Select All** toggle, **double-click to edit** inline, save enabled only when ≥1 ticked; on open, inject into the focused pane (no new tabs/windows).

**G. Command-replay modes** — Auto / Ask-Once / Manually / Skip, with **SEPARATE** Settings dropdowns: **Saved Recipes** (default Auto) and **Recipe Files** (default Ask-Once). New SettingsKeys + a pure replay state machine. Inject via `launchBytes` / verbatim `sendInput` (NEVER SendKeysParser).

**H. Trust store (NEW)** — `.slopdeskrecipe` opened from a FILE: show its commands first with **Always-Trust** (remember by **SHA-256 of the file bytes**) / **Run-Once** / **Cancel**. **Editing the file changes its hash → fresh trust prompt. Self-saved recipes bypass the trust dialog.** Persist `trusted_recipes.json` (schema-versioned, decode-fail-to-default). Pure hash + trust-decision model.
> **This SHA-256 is NOT the forbidden app-layer crypto/auth.** It is a local trust-on-first-use **checksum** for the replay-safety prompt — no peer authentication, pairing, or tokens, no relation to the WireGuard security boundary. Document this in code so a reviewer doesn't flag it against the "no app-layer crypto" rule.

**I. Shell-handoff pause** — recognize interactive programs (`ssh`, `tmux attach`, `docker exec -it`, `su`, …) and **PAUSE** sequential replay after such a command in Auto/Ask-Once until the inner shell returns to a prompt (OSC-133;A) or the user continues. Pure interactive-command prefix-matcher + replay-pause coordinated on the OSC-133 prompt mark.

---

## 3. BINDING CONSTRAINTS / TRAPS (acceptance gates)

- **`⌘S` binding** — the Save-Recipe chord. Verify no collision (terminal apps have no default ⌘S). Route through the binding registry / NSEvent dispatcher, NOT a SwiftUI `.keyboardShortcut` — **`WorkspaceCommands.swift` must stay shortcut-less** (`make lint` check-menu-shortcutless gates this).
- **Command injection = VERBATIM UTF-8** via `TerminalViewModel.sendInput`; cwd `cd` via `SessionTemplateEngine.launchBytes`. **NEVER SendKeysParser** for recipe commands/cwd (that's snippet `<Token>` bodies only). re-run/cd is verbatim — the standing directive.
- **Validate-then-drop** on `.slopdeskrecipe` and `trusted_recipes.json` parse: nil-on-malformed, validate counts before allocating, never force-unwrap, clamp `size`.
- **No new wire** — confirm golden zero-diff (33 emitted byte-identical + 13 frozen). Adding a metadata verb = STOP; recent commands + replay are entirely client-side.
- **No backcompat / schema-version** — bump `Snippet` (new `alias`) and any recipe/trust schema; decode-fail-to-default. Recipe files + trust store are NEW.
- **Float-math / codec rules** N/A (no codec/controller touched) — but keep ordered comparisons and no FMA if any numeric `size` math appears.
- **iOS (`touchesIOS:true`)** — Settings→Recipes editor is shared ClientUI → run `bash scripts/check-ios.sh` (BUILD SUCCEEDED). `{{clipboard}}` via UIPasteboard on iOS. Finder-double-click / `.slopdeskrecipe` document association / CLI-open are macOS-only `#if`; iOS uses the internal DB + a share/file picker.
- **Hang-safety** — no NSWindow / WKWebView / SCStream / VT in tests. Unit-test the PURE parts headlessly: RecipeTOMLCodec, portable-path fn, replay state machine, trust-hash + decision, interactive-command matcher, reserved-var resolver, alias model, save-scope/content model. File-picker / Finder-open / NSPasteboard glue is app-target-only.
- **Test-first** — every fix/feature needs a test that FAILS on the un-built code (revert-to-confirm-fail); no tautological tests.

---

## 4. PINNED DEFERRALS / SCOPE DECISIONS (document honestly — do NOT ship dead UI)

- **CLI `slopdesk open foo.slopdeskrecipe`** → **DEFER to E20** (CLI parity epic). E16 ships File→Open-Recipe (in-app picker) + palette + (best-effort) Finder double-click. Pin the CLI handoff to E20.
- **Finder double-click → new window** needs `CFBundleDocumentTypes` registration (app-target packaging). If it can't be wired cleanly in E16, ship File→Open-Recipe as baseline and note Finder association as follow-up — do not claim it works if it doesn't.
- **Include Scrollback** content level is internal-only per spec. Client-side scrollback serialization across the libghostty seam is non-trivial — if DEFERRED, **omit/grey the option honestly** (no dead toggle). Layout-Only + Include-Commands are the must-haves for ES-E16-1/2.
- **at-prompt auto-expand** (gap B): if full prompt-interception is too risky, ship alias as a first-class field + explicit expand (palette/key) and note auto-expand as best-effort/gated — honesty over a typing-corruption bug.
- Apply the **E5 hard-stop discipline**: each remediation pass must catch a REAL acceptance-story bug; convert oscillating subjective fidelity into a LOCKED screenshot-cited comment rather than infinite passes.

**Self-saved recipes bypass the trust dialog. Editing a file re-prompts. The seven snippet/recipe surfaces (Settings→Recipes, File→Recipe, palette, ⌘S, alias-at-prompt, replay dropdowns, trust prompt) must all reach a live, non-lying control.**
