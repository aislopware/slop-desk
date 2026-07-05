# UI-shell spec coverage matrix

**Source of truth:** the design spec under `docs/ui-shell/spec/` (47 pages) plus the reference screenshots under `docs/ui-shell/screenshots/`. This matrix is a **docs-driven coverage audit** (2026-06-29): it read every in-scope spec page and grepped the implementation for each documented feature — catching features the docs describe that the implementation audit (which only inspects what was built) cannot see.

Method: lean per-section sonnet agents read each spec page, cross-checked the reference screenshot, and reported only self-verified gaps. SlopDesk's terminal **emulation** is the embedded **libghostty** engine (the real ghostty), so the entire VT/Terminal-API section (C0/ESC/CSI/OSC *parsing*) comes from libghostty, not reimplemented — only the **app-level** OSC behaviours (7/8/9/52/133/9;4/1337) are slopdesk's own.

Spec sections audited: Getting Started, User Interface (9), Workflows (6), Terminal Features (16), Working with Agents (9), Customization (7), Terminal API/VT (~65, = libghostty), Reference (7), About. **All 47 spec pages in `docs/ui-shell/spec/` are covered.**

---

## A. Covered (slopdesk implements the documented feature)

Most of every spec page is implemented (epics E1–E21 + audit batches 1–5c). Representative: Window/Tab/Split (vertical tabs, groups, splits, float card, pin, window-size modes), Details Panel (Info/Outline/Git/Files), Status Bar, Find + Global Search (Aa/ab/.* + search-all-tabs), Open Quickly (+ Recipes pill, §B), Command Palette (full catalog + cwd pill), Jump-To/Hint-Mode, Selection/Copy/Paste/Scroll/Input (gated by Controls settings), Progress State + Notifications, Vi-Mode + Read-Only + Secure Input, Themes/Fonts/Keybindings/Config-File/Advanced/Import-Export settings, Agents (Composer + Prompt Queue + Send-to-Chat + Fork + History — Claude Code), CLI + watch:claude + first-launch, drag-and-drop + web pane, OSC 7/52/133/9;4 app behaviours, TERM identity. Per-epic detail: `BACKLOG.md` / `GAP-ANALYSIS.md` / git history.

## B. Fixed in the docs-coverage pass — commit `c9ac552`

Genuine gaps/bugs the audit surfaced, fixed immediately:

| Doc page | Gap | Fix |
|---|---|---|
| agents (overview/parallel-tasks) | **Bug:** tab badge did not auto-clear on tab focus (docs say it does) | `WorkspaceStore.selectTab` now clears the focused tab's agent badges (⌘1-9 + click) |
| user-interface/open-quickly | Recipes filter pill missing (store existed since E16) | added `.recipes` pill + `recipeItems` builder + ⌘E chord |
| agents/history | Send-to-Chat absent from transcript context menu | added `.contextMenu` (Copy + Send to Chat) wired to existing `openSendToChat` |
| vt/osc/osc-133 | OSC 133 **B** mark not emitted → command blocks had empty commandText, auto-progress never fired | zsh shim emits 133;B via `PROMPT+=`; sniffer surfaces a prompt-ready idle signal |
| customization/config-file | No CONFIG FILE section in Settings → Advanced | added path row + Open Config File + Reload Config (reusing the existing reload action) |

## C. Documented ceilings — surface/persist but don't fully actuate (libghostty ABI / renderer limits)

Pre-documented (`DECISIONS.md` + source comments). The setting/UI exists; full actuation awaits a libghostty hook the pinned fork doesn't expose. NOT bugs — the UI labels them "preference saved / not yet functional".

- Scroll-Past-Last/First-Line **rendering** (blank overscroll region) — no viewport hook
- Backspace-Deletes-Selection — no set-selection / cursor-geometry C API
- Smooth-Scroll **OFF** (row-snap) — no row-snap viewport hook
- Cursor Animation **Smooth** (gliding caret) — no cursor-animation hook
- Title-Report toggle (XTWINOPS) — libghostty owns XTWINOPS, no enable/disable hook
- Vi motion set: h/l, w/b/e, 0/$/^, H/M/L, visual anchor-swap `o`, Mark Mode — no programmatic cursor-move / set-selection action
- OSC-8 hyperlink runs not in Hint/Jump — C ABI exposes no per-cell hyperlink read
- Recipe **scrollback** capture — no libghostty scrollback-read seam
- Box-drawing arrow/triangle **stem-joining** (analytical glyph-join refinement) — deferred, not yet built

## D. Intentional exclusions (per the user's directive + the remote model)

- **Cloud/sync features:** Data Sync and third-party SSH/Remote-Development tooling are out of scope — slopdesk has its own remote model (host + client over a trusted WireGuard mesh). *(Recipes, Session-Recovery, CLI, and Frequent-Folders WERE implemented under other epics.)*
- **Agents other than Claude Code:** Codex / OpenCode hook cards, `watch:codex`/`watch:opencode`, OSC-88 third-party resume — agents scoped to Claude Code only (`AgentKind.codex` is documented-dead, never rendered).
- **Editor settings section** — needs a full file-editor; deferred (Task #14). Couples to the File/Folder panes in §E.
- **VT sequence emulation** (C0/ESC/CSI/OSC parsing) — provided by libghostty, not reimplemented.
- **App-store / marketing content** (installation, pricing, credits, performance pages) — N/A to a remote client tool.
- **`ipc` / `state:<agent>` CLI**, config `include` directive, multi-key `>` chord sequences, env-var expansion in config values — deferred in source (E20 backlog).

## E. INTENTIONALLY NOT BUILT — do NOT implement in future sessions ⛔

**Binding scope decision (user, 2026-06-29):** the large features below are **deliberately excluded**. They are documented-but-not-built ON PURPOSE — slopdesk's UI shell is the *foundation*; these are the user's own extension surface, to be built later **only on the user's explicit request**. **Future sessions / agents MUST NOT implement, scaffold, or "fix" these as coverage gaps** — each is a substantial subsystem; auto-building them is unwanted scope + cost. Treat them like §D.

| Feature | Doc page(s) | Size | Remote-model note |
|---|---|---|---|
| **Autocomplete** — inline ghost text + candidate panel + Fig spec DB (715+ tools) + frecency + auto-correction + `learn` pinning | terminal-features/autocomplete | **High** | needs host-side history + a bundled spec DB |
| **File pane / Folder pane** — built-in editor (syntax highlight, Markdown/SVG/HTML/image/PDF/hex/diff preview) + standalone folder browser | user-interface/files-and-links | **High** | needs host file read/write over the wire; overlaps the deferred Editor (§D) |
| **Quick Terminal** — system-wide global-hotkey drop-down terminal (`quick-terminal-*` config keys) | reference/configuration | Med-High | a host-connected dropdown in the remote model |
| **Cross-terminal config import/export** — ghostty/kitty/alacritty classification + preview/conflict dialog + `slopdesk import`/`export` CLI | customization/import-export, reference/cli | Med | slopdesk currently does only its own workspace-JSON transfer |
| **Theme catalog** — a wider built-in catalog including Nord (slopdesk ships 8: 6 Monokai Pro + Paper + Dark, vs. a ~24-theme target) | customization/themes | Med | slopdesk defaults to Monokai Pro; catalog breadth is the gap |
| **bash / fish shell integration** — OSC-133 injection for `~/.bashrc` + fish `vendor_conf.d` (slopdesk is zsh-only) | terminal-features/shell-integration | Med | bash/fish users currently get no blocks/badges/notify/auto-progress |

Smaller deferred niceties — **also intentionally not built (do NOT auto-implement)**, low priority: tab labeled dividers, tear-off pane → new window / cross-tab merge, agent-history standalone pane + Resume button, token/cost/LSP session sidebar (Claude Code doesn't emit cost over the wire), composer status-info strip, Restart-Agent button, GUI Provide-Shell-Integration toggle, Debug section, config hot-reload (FS watcher), zoxide history import, Manage-Jump-Folders editor, KKP user toggle, macOS Services menu, Insert-from-Device menu, custom CLI aliases, Privileges menu bar.

---

*Generated from the 2026-06-29 docs-coverage audit (lean sonnet, run `wj7db1mx1`). Cheap real gaps fixed in `c9ac552`. **§C/§D/§E are all INTENTIONAL non-builds — a future session must NOT treat them as gaps to close.** Build a §E feature only when the user explicitly asks for it by name.*
