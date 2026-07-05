# 37 — Bug-hunt + DX hardening round (2026-06-13, autonomous, continuation)

> **Historical session log (2026-06-13). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: 9 backlog items + a self-review pass (3 fixes) shipped to `main`, one commit each, test-first;
base `077acce` → HEAD `54f84f3`. Full suite 2122 → 2137/0.** A continuation of the autonomous loop
(after docs/36). A fresh 8-reader discovery workflow (`w5k83m7d5`) produced a ranked 15-item backlog;
the highest-value, headlessly-verifiable items were implemented one-per-commit, each adversarially
verified against the real code first; then a review workflow (`wb9t7om3n` — 4 dimension reviewers + a
rejection-audit agent → adversarial verify) scrutinised the whole diff and **earned its keep three
times over** (below).

The orchestration model the user asked for: **main agent is the orchestrator** — workflows do the
parallel read-heavy phases (discovery, review); the main agent does the sequential surgery (edit →
build → test → commit, one green commit per item) and the verify-the-verifier judgement calls.

## What shipped (in commit order)

| Commit | Rank | Item | Core |
|---|---|---|---|
| `2b5f27f` | 1 (HIGH) | **Group resize can't overflow members outside the box** | `resizingGroup` floors the box to `minItemSize` then clamps each sanitized member inside it via new `Canvas.clamping(_:into:)`. Was: `sanitize` floored members LARGER than a sub-floor box → spilled out, fed the non-overlap solver overlapping input. |
| `79b5296` | 2 (HIGH) | **One reconnect give-up cap** | `ReconnectManager.maxReconnectAttempts` (20) is the single source of truth (lower module); `ConnectionPresenter` mirrors it. Was 30 vs a displayed 20 → "attempt 25 of 20". Both loops already made exactly N attempts — **no operator flipped** (the finding's "reversed operators" claim was overstated). |
| `c80dd47` | 3 (MED) | **Menu verbs hit the recents ring** | Group / Save-Layout / Arrange routed through `apply(_:to:)` (the one `recordRecentCommand` chokepoint). |
| `497cf86` | 4+7 (MED) | **Import DoS caps** | `decode` bounds `bookmarks.count <= maxItems` + filters to slots 1…9; `mergeAppend` rejects when `live + imported > maxItems`. |
| `6d3eeb9` | 6+12+13 | **Settings-key hygiene** | 11 raw `@AppStorage("canvas.*")` literals → `SettingsKey` constants; deleted dead `nonOverlapEnabled`; pinned the canvas wire values + covered the privacy/layout gates. |
| `e52b3de` | 15 (LOW) | **Actionable picker empty-message** | `windowFilterEmptyMessage` — names the filter, says windows exist behind it, points at the fix. |
| `df9a354` | review | **Output epoch snapshot BEFORE the take** | (see Self-review) the reconnect wipe bug my rank-8 rejection wrongly dismissed. |
| `ea234fa` | review | **resizingGroup tests made real regression nets** | my two rank-1 tests were tautologies. |
| `54f84f3` | review | **Commit (not discard) an in-flight scroll pan on a possible import bail** | rejected over-cap merge no longer snaps the canvas back. |

## Self-review pass (`wb9t7om3n`) — the review caught 3 real issues, all fixed

A dimension-review + **rejection-audit** workflow over `077acce..e52b3de` surfaced 3 candidates,
adversarially confirmed all 3 (each with a runnable repro):

1. **MED — fresh-session wipe consumed by a dead batch (`df9a354`).** The rejection-audit agent broke my
   own rank-8 rejection: the output pump read `sessionEpoch` *after* `takeOutputBatch()` resumed. A
   reconnect (`markReconnecting`) on the same MainActor can interleave while the pump is suspended in the
   take, so the dead session's in-hand bytes got tagged with the *new* epoch, defeated the ingestBatch
   guard, and consumed the fresh-session RIS wipe (stale output under the new prompt). My rejection had
   assumed the guard ran before the wipe could be reached — true on the snapshot-*before* timeline, but
   the pump used snapshot-*after*. **Fix:** capture the epoch before the take. New gated-transport test
   drives the real pump and FAILS pre-fix.
2. **MED — my rank-1 resizingGroup tests were tautologies (`ea234fa`).** They asserted members lay within
   `out.groupBoundingBox(gid)` — the *union of those same members* — so they passed even against the
   un-fixed code. Rewritten to assert against the *floored proposed box*; both now FAIL pre-fix (member
   spills to maxX 248.9 / box width 166).
3. **LOW — rejected merge dropped an in-flight scroll pan (`54f84f3`).** `importWorkspace` ran
   `discardLiveScroll()` before the mergeAppend cap could bail, snapping the canvas back. Switched to
   `commitScrollPan()` (folds the pan in); harmless on the replace path (camera overwritten anyway).

**Lesson:** the most valuable agent in the review was the one told to *break my own rejections*. Two of
the three findings were in MY work (a wrong rejection + two tautological tests I wrote) — exactly the
blind spots a self-review misses. A finding's confidence should scale with how hard someone tried to
disprove it.

## Verify-the-verifier (findings REJECTED after reading the real code — and that held up)

3 of the lower-ranked discovery findings were dismissed with grounded reasons; the review's
rejection-audit re-examined all four of my rejections and confirmed these three held:

- **Rank 5 — TerminalModeTracker OSC over-cap → `.ground` (proposed `.oscDiscard`)**: a behavioral no-op
  here. The finding pattern-matched `HostOutputSniffer` (whose `.ground` rings a `.bell` on a lost OSC
  terminator) — but `TerminalModeTracker.ground` *ignores* BEL, and both states reclassify embedded ESCs
  identically. No input produces a different event list. Implemented then reverted.
- **Rank 9 — oversized paste truncates silently**: `SecretPasteClassifier.assess` returns `.tooLarge`
  for `text.count > KeystrokeReplay.maxLength` (the same constant `encode` truncates at); the dialog
  gives no "Paste Anyway" for `.tooLarge`; every paste path routes through the guard. No silent partial paste.
- **Rank 10 — `resume()` doesn't re-validate the target**: re-establishing the *committed* `target`
  (always valid) is correct; adopting an uncommitted form edit on iOS foreground would hijack staging.

(**Rank 8 was the rejection that did NOT hold** — see Self-review #1.)

## Deferred

- **Rank 11 — AppConnection supervisor campaign tests**: `isConnectionAlive` is driven by the real
  `MuxNWConnection` state with no fakeable seam; rank 2's fix already has a regression net (ReconnectManager
  give-up count + the presenter-constant pin). Deferred over building heavy scaffolding for a simple guard.
- **Rank 14 — zero-interval paste cancellation**: tests-only path (production paste interval is 6ms,
  which already yields each stroke); a deterministic test would be flaky.

## Discipline notes

- **A test that passes against the un-fixed code is not a regression net.** Two of my own tests this round
  were tautologies (asserting against a value derived from the output). Every fix here is now backed by a
  test verified to FAIL when the fix is reverted (checked by temporarily reverting each).
- **Layering decides the single-source-of-truth site**: the reconnect cap had to live in the LOWER module
  (`SlopDeskClient`) — `ConnectionPresenter` (UI) can depend down but not up. The finding's "make
  ReconnectManager read ConnectionPresenter" was backwards.
- **Concurrency rejections need a runnable repro, not a static read.** My rank-8 rejection reasoned
  correctly about the guard but missed the actor-hop timing of *when* `sessionEpoch` is sampled. The
  review's repro test exposed it.
