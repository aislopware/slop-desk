# UI-shell spec coverage matrix

> **Live status for UI-shell.** Prefer this over [GAP-ANALYSIS.md](GAP-ANALYSIS.md) / [BACKLOG.md](BACKLOG.md) (both historical). Index: [README.md](README.md).

**Source of truth:** the tree, checked against `docs/ui-shell/spec/` + `docs/ui-shell/screenshots/`.
Re-verified against code on **2026-08-22**; the previous revision was a docs-driven audit dated 2026-06-29
and it had gone badly stale — see §0. SlopDesk's terminal **emulation** is still ghostty's, so the
entire VT/Terminal-API section (C0/ESC/CSI/OSC *parsing*) comes from it, not reimplemented — only the
**app-level** OSC behaviours (7/8/9/52/133/9;4/1337) are slopdesk's own. What changed since this
re-verification: `docs/68-terminal-surface-in-rust.md` swapped the embedded full **surface** for
`libghostty-vt` through `rust/slopdesk-vterm` and put the renderer in this repo, and deleted the
embedder Swift under `ThirdParty/ghostty/integration/` with it. So the old warning — a `Sources/`-only
search calls the whole paste/clipboard/selection cluster dead — no longer applies, and any row below
citing a `Ghostty*` file is naming what that row's behaviour used to be implemented by.

Spec sections: Getting Started, User Interface (9), Workflows (6), Terminal Features (16), Working with
Agents (9), Customization (7), Terminal API/VT (~65, = libghostty), Reference (7), About. All 47 spec pages
in `docs/ui-shell/spec/` are still present as DESIGN material; several of them now describe features the
app deliberately does not have (§B).

---

## 0. Why this file was wrong

The 2026-06-29 matrix was accurate the day it was written. Five later waves invalidated it and nobody
re-ran the audit, so it kept asserting shipped features that had been deleted:

| Wave | When | What it took out |
|---|---|---|
| **Feature prune** | 2026-07-02 / 07-03 | Details/Inspector panel · web pane · multi-session switcher · Composer + Prompt Queue + Send-to-Chat + Fork + agent input footer · Recipes + Snippets · floating panes · theme editor/import · workspace export/import |
| **Re-scopes** | 2026-07-10 / 07-22 | sidebar grouping+sort options · per-pane status bar · tab drag-reorder · `PaneKind.remoteGUI` (remote-window mode) |
| **Settings shipped ahead of their renderer** | 2026-07-30 | Scroll-Past-First/Last-Line and Smooth Scroll, with `ScrollPastPolicy`. ⚠️ **All three came BACK 2026-09-02** once the renderer was ours — see §F |
| **ONE APPEARANCE** | 2026-08-08 | the theme picker itself, the built-in catalogue, the dual light/dark slots, per-theme font scopes, the `theme` config key |
| **The canvas is deleted** | 2026-08-17 | the second layout model and everything downstream: `Canvas*`, `PaneGroup`, the canvas `Workspace`, `CompactLayoutResolver`, `CommandInterpreter`, the `liveModel` switch, ~40 store members, 22 suites, 27 FFI doors — plus layout save/restore (⌘S), which was canvas-only |

A row here that names a feature is a claim about the tree. If you cannot find the symbol, believe the tree.

⚠️ **Two search traps produce false "deleted" verdicts here.** (1) The terminal embedder's Swift lives under
`ThirdParty/`, not `Sources/` — a `Sources/`-only grep calls the whole live paste / clipboard / selection /
copy-mode cluster dead, and it is how the scroll-past row in §F was first mis-filed as never-built. (2) Much
of the domain moved to Rust; a Swift symbol's absence often means it is now in `rust/slopdesk-tree`,
`rust/slopdesk-settings`, `rust/slopdesk-terminal` or `rust/slopdesk-workspace`, not that the feature went.

The old revision also carried a table of five gaps the 2026-06-29 pass fixed in `c9ac552`. Three still
hold and have been folded into §A: `WorkspaceStore.selectTab` clears the focused tab's agent badges; the
zsh shim emits OSC 133 `B` via `PROMPT+=` (`rust/slopdesk-superd/src/shellintegration.rs:528`) so command
blocks carry `commandText` and auto-progress fires; Settings ▸ Advanced has a CONFIG FILE section (macOS
only — see §C). The other two — the Open-Quickly Recipes pill and Send-to-Chat in the transcript context
menu — were deleted four days later in the feature prune, along with the features behind them (§B).

## A. Covered (slopdesk implements the documented feature)

Verified present, both platforms unless a row in §C says otherwise:

Window/Tab/Split (vertical sidebar rail, By-Project sections, splits, pin, window-size modes), Command
Palette (full catalog + cwd pill) and cheat sheet, Find + Global Search (`Aa`/`ab`/`.*` + search-all-tabs),
Open Quickly (six pills: All/Opened/Recent/Folders/Agents/Current) with the `⌘K` Actions popover, Jump-To
and Hint Mode, Selection/Copy/Paste/Scroll/Input gated by the Controls settings, drag-and-drop onto a pane
(five zones), Progress State + Notifications + the Dock tile, Vi-Mode + Read-Only + Secure Input,
Settings (eight sections on both platforms, searchable All-Settings, Config-File, Keybindings editor incl.
the phone's recorder), Fonts (family picker, specimens, fallback list, ligature/line-height/style/blending),
Agent supervision for Claude Code (hook install card, status badges, attention jump `⌘⇧U`, Peek & Reply
`⌘⌥J`, prevent-sleep, resume-on-recovery), CLI + `watch:claude` + first-launch, host metadata RPC
(processes/ports/git/dir/agent-sessions), OSC 7/52/133/9;4 app behaviours, TERM identity, the CODE panel.

Per-story detail with file:line evidence: [USER-STORIES.md](USER-STORIES.md).

## B. REMOVED AFTER SHIPPING — do NOT "restore" as a coverage gap ⛔

These are the rows the old §A claimed. Each was built, shipped, and then deleted on purpose. A spec page
under `spec/` still designs most of them; that page is now historical.

| Feature | Epic | Removed | Ruling |
|---|---|---|---|
| **Details / Inspector panel** (Info · Outline · Git · Files) | E9 | 2026-07-02 `6de70aae` | "remove the right sidebar (inspector / Details panel) — keyboard-centric". Outline had merged into Info ▸ Commands (`e483ec75`) and Git into a summary row + popup (`c930f050`) the same day. Pinned negatively in `OverlayCoordinatorMountTests`. **The removal has no `DECISIONS.md` entry of its own** — it is only referenced retroactively there ("the chord the removed Details panel freed"). |
| **Web pane** (`PaneKind.web`, local WKWebView) | E18 | 2026-07-02 `65da3c0d` | `DECISIONS.md` §Web pane REMOVED. A dragged URL now only pastes. The WKWebView that DOES ship is the CODE panel (2026-08-02), a different feature. |
| **Multi-session switcher** | E19 | 2026-07-02 `d1d4398b` | `DECISIONS.md` §Multi-session switcher UI REMOVED. The `Session` domain type and the store's multi-session internals STAY. |
| **Composer · Prompt Queue · Send-to-Chat · Fork-in · agent input footer** | E12, E13 | 2026-07-03 `92472b0a` | `DECISIONS.md` §Agent input surfaces REMOVED — they "duplicated typing straight into the terminal". KEPT: `InputBarModel`/`InputBoxModel`/`InputDedupRing`. |
| **Recipes · Snippets** | E16 | 2026-07-03 `d63e1274` | `DECISIONS.md` §Recipes + Snippets REMOVED. KEPT: `SendKeysParser`, which backs launch presets, templates, block re-run, drops and `pane send-keys`. |
| **Floating panes** | E12, E21 | 2026-07-03 `231f1398` | `DECISIONS.md` §Floating panes REMOVED. The tiled split tree is the only pane layout. |
| **Theme editor / import · workspace export-import** | E15, E7 | 2026-07-03 `0166057c` | `DECISIONS.md` §Theme editor/import + workspace export/import REMOVED. |
| **Sidebar grouping + sort options · tab drag-reorder** | E6, E18 | 2026-07-10 | `DECISIONS.md` §Sidebar grouping … group/sort options REMOVED. Always By-Project; sections A→Z (2026-08-10); rows in creation order. `reorderTabs` (wire type 8) survives as a dormant verb. |
| **Per-pane status bar** (cwd · exit code · pane kind · host) | E10 | 2026-07 | A USER ruling recorded in code, not in `DECISIONS.md`: `TerminalLeafView.swift:98-102` — "the user judged the terminal pane footer low-value and asked to drop it … host + connection status now live ONCE in the connection island". The ⌘-hover full-path seam is marked DORMANT with it. |
| **Remote-window mode** (`PaneKind.remoteGUI`) | E21 | 2026-07-22 | `DECISIONS.md` §Remote desktop is a DEDICATED OS WINDOW. Full-desktop is the only remote-viewing mode and it opens as its own OS window. The wire types go dormant, not deleted — golden byte-identical. |
| **Themes, entirely** (picker, catalogue, light/dark slots, per-theme fonts, `theme` config key) | E15 | 2026-08-08 | `DECISIONS.md` §"ONE appearance — the theme picker is deleted, not defaulted (user-directed)". Stated in the type at `AppearancePreferences.swift:9-13`. |

## C. Platform splits — macOS only

Per `docs/56-client-ui-split.md:144` ("Layout diverges; capability does not. A feature landing on one
platform is owed to the other"), each row is either a platform fact or an open gap. Both kinds are listed.

⚠️ This section was established on 2026-08-22 against the **working tree**, which several agents were
editing at the time. Two rows moved while it was being written: Config File turned out to be a ruled
platform fact rather than a gap, and the literal-byte keybinding gap was being closed as it was
recorded. Re-check a GAP row before planning against it.

**Both GAP-verdict rows are now closed (2026-09-02)** — the literal-byte/`unbind:` row and the sidebar
`#N` readout. What is left below is platform FACT, except the tab strip, whose verdict is still "needs a
phone answer": it is an open question of what the phone's shape should BE, not a port waiting to be
written. The re-check warning above stays because the practice is what caught these two, not because a
GAP row is outstanding.

| Feature | Why | Verdict |
|---|---|---|
| Dock progress / error tint (`DockProgressController`) | iOS has no Dock | platform fact |
| Pin Window (`NSWindow.level = .floating`) | iOS has no window level; the registry says so in place | platform fact |
| Window-size modes grid/frame/remember | iOS has no resizable app window; the keys round-trip inert | platform fact |
| Secure Keyboard Entry + SECURE-INPUT pill | `EnableSecureEventInput` is a macOS-only API; the detection half (wire type 31) is cross-platform | platform fact |
| ⌘-hold link underline | no ⌘ modifier on iOS; the iOS affordance is tap / long-press | platform fact |
| Detach pane into its own window (⌥⌘P) + drag `tearOff` to a satellite | it produces an `NSWindow`; the enum case says so in place — "macOS only — a no-op routing on iOS (no NSWindow)" (`WorkspaceBindingRegistry.swift:23-24`) | platform fact |
| Horizontal titlebar tab strip (`MacTabStrip`) | AppKit titlebar band | needs a phone answer |
| Settings ▸ Advanced ▸ CONFIG FILE (path row, Open Config File, Reload Config) | gated `Platform::Mac` by the settings layout table, reason stated at `Sources/SlopDeskClientCore/Settings/SettingsConfigFile.swift:4-5` — "`~/.config` is a path iOS has none of" | platform fact (corrected 2026-08-22 — first filed as a GAP) |
| Settings ▸ Advanced ▸ raw `SLOPDESK_*` editor, and the Video host-flag group | gated `Platform::Mac` as data; they edit flags the phone's device never reads (`SettingsSheet.swift:22-24`) | platform fact |
| `text:` / `csi:` / `esc:` literal-byte keybindings, and general `unbind:` | — | **CLOSED — both halves, verified 2026-09-02.** The literal-byte rung is `TerminalLeafView.swift`'s `swallowsAsWorkspaceChord(_:)`, which answers `WorkspaceBindingRegistry.textBinding(for:)` on the PANE's rung ahead of the interceptor — bytes are terminal input, so they belong to the pane holding the keyboard. `unbind:` is honoured GENERALLY, and in shared code rather than per-shell: `WorkspaceStore+Keybinding.swift`'s interceptor factory refuses an unbound chord before it reaches the action table, which is the one resolve both the phone's rungs and the Mac's pane surface share, so an unbound ⌘D falls through to the PTY on both. ⚠️ The file this row named (`SlopDeskPhoneUI/Pane/TerminalInputHost.swift`) no longer exists |
| Sidebar `#N` shortcut number | — | **CLOSED — verified 2026-09-02.** `NavigatorRowCell.swift:315` reads `reading.shortcutHint`, so the phone prints the number the shared code was already producing. ⌘1…⌘9 on an iPad with a hardware keyboard now says which pane is which; the ⌘-HOLD trigger remains a platform fact |

## D. Intentional exclusions (per the user's directive + the remote model)

- **Cloud/sync features:** Data Sync and third-party SSH/Remote-Development tooling are out of scope — slopdesk has its own remote model (host + client over a trusted WireGuard mesh).
- **The Open-Quickly SSH pill:** a deliberate product cut (user reduction 2026-06-26). No `~/.ssh/config` parse, no `⌘S` chord, no SSH Actions row; there is no `.ssh` enum case, so nothing can route to a dead pill.
- **Agents other than Claude Code:** Codex / OpenCode hook cards, `watch:codex`/`watch:opencode`, OSC-88 third-party resume — agents scoped to Claude Code only.
- **Editor settings section:** the section EXISTS and is reachable on both platforms, but it is deliberately empty — `settings_catalog.rs:451`, "Editor — reserved, deferred". It needs a file editor, which §E rules out.
- **VT sequence emulation** (C0/ESC/CSI/OSC parsing) — provided by libghostty, not reimplemented.
- **App-store / marketing content** (installation, pricing, credits, performance pages) — N/A to a remote client tool.
- **`open` / `import` / `export` / `features` / `state:claude` / `ipc` / `theme` CLI verbs** — `Availability::Planned` in `rust/slopdesk-cli/src/vocabulary.rs`: `--help` lists them, no shell completes them, typing one exits 2 as designed-but-unbuilt. Also deferred in source: config `include`, multi-key `>` chord sequences, env-var expansion in config values.

## E. INTENTIONALLY NOT BUILT — do NOT implement in future sessions ⛔

**Binding scope decision (user, 2026-06-29):** the large features below are **deliberately excluded**. They
are documented-but-not-built ON PURPOSE — slopdesk's UI shell is the *foundation*; these are the user's own
extension surface, to be built later **only on the user's explicit request**. **Future sessions / agents
MUST NOT implement, scaffold, or "fix" these as coverage gaps.** Treat them like §B and §D.

| Feature | Doc page(s) | Size | Remote-model note |
|---|---|---|---|
| **Autocomplete's DATA half** — Fig spec DB (715+ tools) + frecency + auto-correction + `learn` pinning | terminal-features/autocomplete | **High** | needs a bundled spec DB. ⚠️ The SURFACE half of this row — inline ghost text and the candidate panel — was listed here as not built and **is built**: `prompt/complete.rs` ranks, `TerminalPromptBand` draws both the panel and the ghost, and both platforms wire Tab/⌃N/⌃P/Esc. Only the DB and the ranking-memory over it are still absent. |
| **File pane / Folder pane** — built-in editor (syntax highlight, Markdown/SVG/HTML/image/PDF/hex/diff preview) + standalone folder browser | user-interface/files-and-links | **High** | needs host file read/write over the wire; overlaps the reserved Editor section (§D). The CODE panel covers the *editing* use case a different way. |
| **Quick Terminal** — system-wide global-hotkey drop-down terminal (`quick-terminal-*` config keys) | reference/configuration | Med-High | a host-connected dropdown in the remote model |
| **Cross-terminal config import/export** — ghostty/kitty/alacritty classification + preview/conflict dialog + `slopdesk import`/`export` CLI | customization/import-export, reference/cli | Med | slopdesk now transfers NOTHING — its own workspace-JSON transfer was removed 2026-07-03 (§B) |
| **Theme catalog** | customization/themes | — | superseded: there is no catalog and no picker at all (§B, 2026-08-08). The app ships ONE appearance by user directive. |
| **bash / fish shell integration** — OSC-133 injection for `~/.bashrc` + fish `vendor_conf.d` (slopdesk is zsh-only: `rust/slopdesk-superd/src/shellintegration.rs`) | terminal-features/shell-integration | Med | bash/fish users currently get no blocks/badges/notify/auto-progress |

Smaller deferred niceties — **also intentionally not built (do NOT auto-implement)**, low priority: tab
labeled dividers, tear-off pane → new window / cross-tab merge, token/cost/LSP session sidebar (Claude Code
doesn't emit cost over the wire), Restart-Agent button, GUI Provide-Shell-Integration toggle, Debug section,
config hot-reload (FS watcher), zoxide history import, Manage-Jump-Folders editor, KKP user toggle, macOS
Services menu, Insert-from-Device menu, custom CLI aliases, Privileges menu bar.

## F. Claims the old matrix made that were never true

Rows the 2026-06-29 audit listed as "documented ceilings — the setting/UI exists but doesn't fully
actuate". Re-checked against the tree: for these there is no setting and no UI, so they are not ceilings.
Two turned out to be **removals** rather than absences, and the distinction matters — a removal comes with
a reason, and the reason is the condition for bringing it back.

| Old ceiling row | Now |
|---|---|
| Scroll-Past-Last/First-Line rendering | **REBUILT 2026-09-02**, on the hook the removal named. They shipped ahead of a renderer that could actuate them and were removed 2026-07-30 with `ScrollPastPolicy`, on a condition recorded at `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift:2161-2165`: "the fork exposes no row-snap hook and no overscroll-margin API … Add the settings back with the viewport hook that actuates them, not before." §5.1's block layout put `Surface::scroll_y` and `PlacedBlock::row_y` in this repo, which IS that hook. The settings are `controls.scroll-past-last-line` / `controls.scroll-past-first-line`; the arithmetic is `slopdesk_termrender::layout::scroll_bounds`. See `docs/68` §5.13 |
| Backspace-Deletes-Selection | no `backspaceDeletesSelection` key anywhere — **superseded**, not merely dropped: Cut (⌘X) is the shipped verb (`Sources/SlopDeskWorkspaceCore/Terminal/CutSelectionPolicy.swift`) |
| Smooth-Scroll OFF (row-snap) | **REBUILT 2026-09-02** with scroll-past, same pass and same hook. It was removed 2026-07-30 because `smoothScroll` OFF rendered exactly like ON; `controls.smooth-scroll` now means "snap every step" against ON's "snap once the momentum is over", so the two settle alike and differ kinetically — `BlockLayout::nearest_row_top` is the snap |
| Cursor Animation Smooth | no animation field on `TerminalPreferences` |
| Title-Report toggle (XTWINOPS) | does not exist. The toggle that DOES ship is `controls.titleShellControlled` — "may the shell SET the title" — which is a different privilege |
| Recipe scrollback capture | moot; Recipes deleted 2026-07-03 (§B) |
| Vi motion set (h/l, w/b/e, 0/$/^, visual anchor-swap `o`) | ceiling **LIFTED** 2026-07-14 once the fork exposed `ghostty_surface_set_selection` — these are real motions now. The table is `TerminalViewModel.handleCopyModeKey(_:)` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:769-885`): count digits, `h j k l`, `0 ^ $`, `w b e`, `⌃d ⌃u`, `⌃f ⌃b`, `g G`, `[ ]`, `v V ⌃v o`, `f`, `/ ?`, `n N`, `y Y`, `q`. **`H`/`M`/`L` and Mark Mode are NOT in it** — settled 2026-08-22, they do not exist |

⚠️ **box-drawing arrow/triangle stem-joining is BUILT** — 2026-09-02, and this paragraph called it a
standing ceiling until then. Same falsification as the hyperlink one below: the reason on record was
"not a libghostty feature; would require a ghostty patch", which stopped being a constraint the moment
the fork left. `rust/slopdesk-termrender/src/sprite/arrow.rs` draws it, `paint.rs`'s `join_mask` decides
when, and `terminal.arrow-box-drawing-join` (default ON) turns it off. The whole sprite face came with
it — box drawing, block elements, Braille and Powerline are drawn from the cell now rather than asked
of the font. See GAP-ANALYSIS J8/J9 and `docs/68` §5.14.

⚠️ **OSC-8 hyperlink runs ARE Hint/Jump targets** — this paragraph claimed otherwise until 2026-09-02, on a
reason the fork's exit falsified. "The C ABI exposes no per-cell hyperlink read" was true of the fork; the
engine is `slopdesk-vterm` now and `Frame::hyperlink_spans` / `Screen::hyperlink_runs` are ours, so
`slopdesk_term_surface_hyperlink_runs` reads the URI and `slopdesk_hint_scan` takes the runs as a fourth
input beside `rows`/`schemes`/`patterns`. They are handed in rather than scanned for, and are exempt from
`max_scan_columns`: an authored link's display text is not what it points at, so a regex over the row
would miss `click here` entirely and re-clustering it would move the badge off the link.

---

*Re-verified against the tree on 2026-08-22, story by story, after an audit found the previous revision
asserting five whole epics that do not exist. **§B, §D and §E are all INTENTIONAL non-builds — a future
session must NOT treat them as gaps to close.** Build a §E feature only when the user explicitly asks for it
by name. The three rows marked **GAP** in §C are the only real capability gaps this pass found.*
