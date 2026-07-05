# 38 — Net-new DX features + tail hardening (2026-06-13, autonomous, continuation)

> **Historical session log (2026-06-13). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: shipped to `main`. Base `ffc0d22` → HEAD `812c701`. Full suite 2137 → 2153/0.** Continuation of the autonomous loop (after docs/37). Two phases: a fresh-surface bug pass that **converged** (2 LOW hardening), then a feature-ideation pivot shipping **3 net-new DX features + a self-review pass (4 fixes)**. Orchestration: workflows do discovery/ideation/review (parallel, read-heavy); the main agent does the sequential edit→build→test→commit surgery + verify-the-verifier calls.

## Phase A — fresh-surface bug pass (converged)

Discovery workflow `wk8qty1ar` (8 readers over the least-mined headless surfaces: host input, transcript parsers, video-decode logic, persistence, OUT-path concurrency) converged loop-until-dry: 8 of 10 raw findings dissolved on inspection (a HIGH "preset IDs not remapped" + 3 MED were correct-as-written), leaving 2 LOW survivors, both shipped:
- `c82a468` — `enqueueControl` bulk-append could overshoot `maxControlOutQueued` by one frame's control batch (a merged frame carries multiple sniffed messages); slot-limited the append.
- `07a3121` — the notification `UInt16` title-length used `truncatingIfNeeded`, which WRAPs and corrupts the body for a >64KiB title; clamp the title at a Character boundary via a shared `clampedNotificationTitle` used by both `encode()` and `wireByteCount()` (provably unreachable today — latent-footgun hardening matching the codebase's encoder discipline).

## Phase B — net-new DX features (ideation pivot)

Feature-ideation workflow `wax9doef7` (5 DX-lens generators grounded against real code) ranked a shortlist; verdict: high-value headless feature surface clusters in **navigation** and **snippet-automation**, and "one more focused pass likely exhausts it." Shipped the clean wins:

| Commit | Feature | Core |
|---|---|---|
| `a5d57aa` | **Recent-pane quick-switch (⌥⌘; / ⌥⇧⌘;)** | `focusHistory` MRU (records OUTGOING-then-incoming on user focus, deduped, capped, pruned on close); `switchToRecentPane` walks it WITHOUT reordering, deriving its position from the focused pane's ring index each call (no fragile persistent cursor). The "go to last pane" idiom. |
| `d699a98` | **Cycle focus within group (⌃⌘] / ⌃⌘[)** | `cycleFocusInGroup` feeds the group's members (or the ungrouped bucket) to the same `FocusResolver.cycle`; companion to whole-canvas ⌘]/⌘[. |
| `17870e3` | **Run Last Snippet (⌥⌘R)** | `lastRanSnippetID` recorded in `beginRunSnippet`, pruned on delete; re-fires the last macro (re-prompts a parameterized one). macOS chords are SwiftUI `.keyboardShortcut`, not a runtime `feed()`, so per-snippet chords need view-layer wiring; this delivers one-keystroke re-fire with a fully-testable store core. |

Each is the clean ranks-1-2 shape: pure store logic + a `WorkspaceCommand` + a ⌘/⌥-chord, consumed by the EXISTING command infra (no new view, no schema change) — fully headlessly testable.

### Down-scoped / deferred (grounded out)
- **Per-snippet chord binding** (rank 3): `CommandInterpreter.feed` isn't used at runtime on macOS (SwiftUI `.keyboardShortcut` is) — dynamic per-snippet chords need per-snippet hidden shortcut buttons + a chord-picker UI (unverifiable view-layer). Shipped the testable cousin (Run Last Snippet) instead.
- **Snippet auto-run on connect** (rank 4): needs a per-pane snippet assignment + a connect-edge latch in LivePaneSession (view/lifecycle-layer). Deferred.
- **"What's running where" summary** (rank 5): the sidebar already shows per-pane connection+running status (docs/36), so marginal value (aggregate + last-exit) was thinner than the nav wins.

## Self-review pass (`wytq3vo65`) — 1 real bug + 3 test-quality gaps, all fixed (`812c701`)

The review's tautology-hunt + focus-refactor-regression dimensions caught (all in this round's work):
- **BUG (LOW)**: `switchToLayoutPreset` / replace-import / app-launch-auto-switch re-mint every pane id but never update `focusHistory` → quick-switch silently no-op'd forever post-swap (every ring entry dead; the `focusing()` guard ate the walk). `reseedFocusHistory()` now reseeds at both swap sites. (The doc-comment wrongly claimed the derived-index was "robust to the many paths that set focusedPane directly" — true for not-crashing, false for ring-staleness.)
- **TEST ×3**: the singleton group-cycle + single-pane switch tests were non-discriminating (the inner `focus(self)` guard made them pass even with the `count > 1` guards removed). Extracted pure `recentPaneTarget` / `inGroupCycleTarget` helpers and assert they return `nil` for the no-op cases — now real regression nets (each verified by removing the guard). Added `interp.feed` routing assertions for ⌃⌘]/⌃⌘[/⌥⌘R (a transposed flag would otherwise slip past the cheat-sheet drift guard).

## Discipline notes

- **`git checkout -- <file>` nukes uncommitted work.** During a revert-to-confirm-fail check it reverted the whole file and lost the uncommitted fixes (had to re-apply). Revert ONE line via Edit, not the file.
- Every fix is backed by a test verified to FAIL when the fix is reverted (checked for the reseed bug and both guard helpers). The tautology-hunt dimension is worth its own agent — it caught three weak tests a behavior-only review would have passed.
- **The headless surface (bugs AND features) is now well-converged this session** across three rounds; the ideation's own verdict predicted this. Remaining work is HW-rig / view-feel (the docs/36+37 deferred lists).
