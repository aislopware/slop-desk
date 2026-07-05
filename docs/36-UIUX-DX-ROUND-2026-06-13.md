# 36 — UI/UX + DX round (2026-06-13, autonomous)

> **Historical session log (2026-06-13). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: 17 items + 1 self-review pass shipped to `main` (one commit each), test-first, suite 2071 → 2122/0.** Base `afdd1f9` → HEAD `c6ea64a`. A 9-agent research workflow surveyed every client UX/DX surface into a ranked 58-item backlog; the highest-value, headlessly-testable items shipped one-per-commit, each adversarially verified against the real code first. A 5-dimension review workflow then caught 4 defects (1 MED + 3 LOW, all in the new snippet/paste UI that SwiftUI presentation/focus tests can't catch), fixed in `c6ea64a`.

## Self-review pass (`c6ea64a`)
5 reviewers by dimension → adversarial verify each finding, over `afdd1f9..HEAD`:
- **MED** — snippet-manager "Run Now" on a parameterized snippet presented the value sheet while dismissing the manager in one transaction → macOS drops the 2nd sheet (stranded `pendingSnippetRun`). Fix: dismiss-then-defer-arm + `requestSnippetManager` clears a stranded flag.
- **LOW** — snippet name field churned (per-keystroke `snippetName` trim/substitute) → store verbatim, fallback at display only.
- **LOW** — `SnippetValuesSheet` self-referential `.focused($bool, equals:)` focused all fields for ≥2 placeholders → index-typed `@FocusState`.
- **LOW** — clean paste left a stale "skipped M" banner → `notePasteFeedback` clears on a clean paste.

Other 3 candidates adversarially rejected as not-real. Lesson: SwiftUI sheet/focus behaviour is the gap headless tests miss — a review pass over new view code earns its keep.

## The research

Workflow `w5jn5jzgq` (8 grounded surface readers → 1 synthesiser) produced `/tmp/uxdx-backlog.md` (58 ranked items). Standout themes:
- **Dead-wired features** — shipped power-features whose pure core was tested but no view consumed it (cheapest, highest-value wins).
- **Secret-redaction regressions** on high-stakes surfaces (clipboard previews, carousel title).
- **Command-palette / keyboard universality** gaps (missing verbs, no aliases, no cheat-sheet).
- **Pane groups half-built** (no group-from-selection, empty-group dead-end).

## What shipped (in commit order)

| Commit | Item | Core |
|---|---|---|
| `e4a965c` | **Broadcast input wired** (was dead) | `TerminalViewModel.broadcastTap` + `WorkspaceStore.fanBroadcastInput` (reentrancy-guarded); both macOS surface keys & iOS input bar funnel through `sendInput`, so one tap covers both. Top-centre "Broadcasting to N panes" pill. |
| `33aaac5` | **Snippet placeholder prompt** | `beginRunSnippet → SnippetRunOutcome`; `SnippetValuesSheet` resolves `{{slots}}` before injection (no literal leak). |
| `1d8a99e` | **In-app snippet manager** | `manageSnippets` command + `SnippetManagerView` (CRUD was JSON-only). |
| `f97d427` | **Group Selected Panes** | `groupSelection()`; ⌃⌘G groups the selection (no empty-group dead-end), ⌥⌘G explicit. |
| `d45d75f` | **Palette keyword aliases** | `CatalogItem.keywords` — "sync"/"fullscreen"/"split"/"mission control" now match. |
| `f6f02a5` | **Clipboard privacy** | redacted Paste-Recent previews + "don't record clipboard history" toggle (gate at `recordClip`). |
| `22d22c5` | **Palette align/distribute/save-layout + bookmark rows** | new `align`/`distribute`/`saveLayout` commands; dynamic `buildBookmarkEntries`. |
| `d68b5c8` | **Distribute overlap fix** | clamp negative gap → flush packing, never silent overlap. |
| `d11fdfb` | **Select All Panes** | `selectAllPanes` (⌥⌘A — NOT ⌘A, the terminal's select-all-text) + a live "N selected" chip. |
| `de606a0` | **Terminal bell badge** (was dead) | `PaneSessionHandle.bellPending`/`clearBell`; pill + sidebar badge on an unfocused pane; focus clears it. |
| `1de3b33` | **Paste-as-Keystrokes skip feedback** | `RemoteWindowModel.pasteFeedback` "typed N, skipped M" banner (incl. the all-skipped case). |
| `f1e1f92` | **⌘/ shortcut cheat sheet** | `KeyboardCheatSheet.sections()` generated from `defaultBindings` (drift-guarded) + overlay. |
| `26313d7` | **Carousel title redaction** | route the compact tab + top-bar through `displayTitle` (live + redacted). |
| `ebae9fb` | **Friendlier connection errors** | `friendlyFailure` covers handshake/version-mismatch + clean drops; unknowns still pass through. |
| `79d57fb` | **Sidebar running ring + last-command result** | sidebar dot carries `running`; `formatCommandResult` in the pill tooltip. |
| `d766d93` | **Smarter fuzzy ranking** | word-start bonus + gap penalty in `fuzzyScore`. |
| `5750d5f` | **Hide focused-pane verbs on an empty canvas** | `requiresFocusedPane` predicate + `visibleCommands`. |

## Verify-the-verifier (claims the research got wrong — skipped, not implemented)

Reading the real code before implementing caught three "findings" already done or wrong:
- **#14 "new panes land off-screen invisibly"** — `addPane`/`addRemoteWindowPane`/`duplicatePane` already all call `recenterIfOffscreen` (added in the docs/33 round).
- **#22 "reconnect countdown nextRetry always nil"** — `ReconnectManager` supplies a real `nextRetryAt` (line 206) and the pill renders live "retrying in Ns" via `TimelineView`. Fully wired.
- **#17 "loosen the Recenter trigger"** — the "zero panes visible" trigger is correct for "get back to the cluster" (`centerOnPane`/⌥⌘C handles the focused pane); loosening needs HW feel-tuning.
- **#12 ⌘A for Select All** — bare ⌘A is the focused terminal's select-all-text; the workspace table must never bind ⌘C/V/A, so it shipped as ⌥⌘A.

## Discipline notes worth keeping

- **One tap covers both platforms**: macOS surface keystrokes AND the iOS input-bar both funnel through `TerminalViewModel.sendInput` (the iOS `inputBar.sendSink` is wired to it), so broadcast needed ONE seam, not two. The macOS terminal has **no input bar** (removed in `d2d382f` — it stole focus and froze the renderer); type directly into the libghostty surface.
- **Type-checker budget**: the `WorkspaceRootView` body chain twice tripped "unable to type-check in reasonable time" as overlays/sheets accreted — extract groups into `ViewModifier`s (`SnippetModals`, `WorkspaceOverlayModals`) to keep each expression small.
- **Test-first caught a real bug**: Paste-as-Keystrokes feedback initially missed the all-unmappable case (`"é"` → strokes empty → early return before recording feedback); the test forced recording feedback before the empty-strokes guard.
- **Generated-from-source-of-truth** beats hand-maintained: the cheat sheet's drift guard test fails the moment a new bound command lacks a row.

## Deferred (HW-rig / gesture-feel — next session with the 2-machine rig)

Marquee/rubber-band selection (needs pan-vs-marquee gesture disambiguation + feel); iPad hardware command-combos swallowed by the focused terminal (#16, needs iPad); remote-window RTT/quality HUD; find-in-terminal (⌘F); OSC-133 jump-to-prompt; persistent minimap / radar; live-thumbnail overview; input-bar command history (iOS-only, duplicates shell history); host-window palette loading/offline states; keyboard nudge (step-size feel).
