# 24 — Code-Hardening Pass Handoff

> **STATUS: CURRENT.** This records the autonomous code-hardening pass (2026-06-03) on branch
> **`feat/rwork-code-hardening`** (15 commits over `main`), which resolved every deferred
> followup from [`23-workspace-ui-handoff.md`](23-workspace-ui-handoff.md), the known video-host
> reconnect bug, the missing host-side inspector serving, the flaky-test infra, and 12
> adversarially-found bugs — all build- and unit-test-gated headlessly. The runtime/GUI/device
> verification gap is unchanged from docs/23: it is the same hardware checklist, now with fewer
> code-level unknowns in front of it. Architecture authority stays [`22`](22-workspace-architecture.md);
> the proven byte-pipeline/transport/video/inspector cores stay [`21`](21-HANDOFF.md).

## Headless verification (this branch tip)

- `swift build` and `swift build --build-tests` — **warning- and error-clean**.
- `scripts/check-ios.sh` — **`** BUILD SUCCEEDED **` / iOS typecheck OK**.
- **633 XCTest tests, 0 failures** across the HostServer-free suites: RworkClientUITests 281,
  RworkVideoHostTests 58, RworkVideoClientTests 63, RworkInspectorTests 41, RworkHostTests 64,
  RworkProtocolTests 24, RworkTransportTests 41, RworkClaudeCodeTests 58, HostServerE2EGuardTests 3.
- The HostServer E2E suites (`RworkClientE2ETests`, `RworkReconnectE2ETests`,
  `RworkReconnectSuppressionTests`) are **deliberately not run headlessly** (the documented
  pool-deadlock/wedge risk) but are now **CI-safe** — see #10. Run them in a controlled CI pass.

## What shipped — 10 deferred-followup specs

| # | Item | Resolution | Commit |
|---|------|-----------|--------|
| 1 | Terminal-surface liveness across tab switch / compact flip | Bounded **replay byte-ring** in `TerminalViewModel` (option C) — DECSTR-prefixed FIFO replay into a freshly-attached surface; `===` re-attach guard; 8 ring tests via a RecordingSurface seam | 845ec0a |
| 2 | Reactive auto-promote of gated video panes | `WorkspaceStore.videoPromotionGeneration` nudge on slot-free; view re-attempts admission via `.onChange` | 4b566fe |
| 3 | reconcile() ceiling protection | **NOT made async** (that ripples through 13 mutators + init + every view closure). Minimal-ripple: `tearingDownVideo: Set<PaneID>` counts in-flight `.remoteGUI` teardown against `liveVideoCap` so a same-tick close+reopen can't transiently exceed the ceiling | 80a7538 |
| 4 | Keyboard-binding duplication | Menu `.keyboardShortcut`s **derived from `CommandInterpreter.defaultBindings`** via a `KeyChord→KeyboardShortcut` adapter (one source of truth); dropped the unused `clock` seam | efd2a93 |
| 5 | Per-device `liveVideoCap` | `VideoCapPolicy` (phone 1 / pad 2 / mac 3), resolved **once at launch** in `RworkClientApp` (cap is a launch-time ceiling, not live-resizing) | 80a7538 |
| 6 | Outer-window compact breakpoint | macOS NSWindow-width reader feeds a `windowWidth` overload (`compactWindowWidthThreshold` 680); detail-width path keeps 460 byte-for-byte; iOS stays size-class-primary | 61c47bb |
| 7 | Schema `migrate(from:to:)` seam | `WorkspaceSchemaMigration` step-table (identity / reject-newer / per-version upgrade); load() forward-migrates instead of discarding | 2782cfd |
| 8 | Video-host reconnect-after-bye | SM `.bye` returns to re-armable `.listening` (only local `stop()` stays terminal) so a fresh `hello` re-arms capture with a new streamID | dc0d3fe |
| 9 | Host-side inspector serving | `InspectorReplayLog` (actor, atomic snapshot+attach replay-then-live fan-out) + `InspectorServer` (NWListener on `terminalPort+1`, loopback-tested). **PIECE C deferred**: live transcript-path discovery via the SessionStart-hook HTTP listener — server takes an injected `--transcript` until then | b06b6b1 |
| 10 | HostServer E2E CI-safe | `HostServerE2ECase` base: `executionTimeAllowance` ceiling + **awaited `addTeardownBlock`** (replaces fire-and-forget `defer { Task { stop() } }`) + a `withTimeout`-wrapped bring-up; a hung test now **fails its own method instead of wedging the process**. No new HostServer/PTY instance, no parallelization. Guard self-test in the HostServer-free target | 8a46681 |

## What shipped — 12 adversarially-found bugs + 9 review findings + 1 symmetric residual

Initial hunt (folded into the commits above): **BUG-A** unconfigured remote pane was dead-stuck on
the cap placeholder; **BUG-C** `resume()` faked `.connected` for idle panes; **BUG-D** save-race;
**BUG-E** compact carousel two-first-responder; **BUG-F** stale zoomed layout focus; **BUG-G**
one corrupt inspector frame killed the channel; **BUG-H** LTR→IDR escalation starved under sustained
loss; **BUG-I** decoder rebuilt the VTDecompressionSession every keyframe; **BUG-J** `quiesce()`
drain-loop hole; **BUG-K** tab-switch focus-reclaim race; **BUG-L** UDP receive loop died on a
transient datagram error; **BUG-B** inspector replay (folded into #9).

Adversarial review of the 15 commits then found and fixed 9 confirmed-real issues:

| Fix | Sev | Issue | Commit |
|-----|-----|-------|--------|
| F1 | high | **BUG-A regression** — the entry form vanished to the cap placeholder the instant a valid endpoint was typed. Now: form stays until the pane is live; `.gated` only on a *real* cap refusal (`hasFreeVideoSlot` mirror); reactive retry on `configured` | ed8fd4a |
| F2 | high | **#8 exposed a latent actor race** — `bye→hello` let a stale `teardownLiveComponents` nil fresh components → wedged streaming-but-dead. Compare-and-clear (`self.x === snapshotX`) | 70a75b8 |
| F3 | high | **BUG-L busy-loop** — re-arm with no backoff spun at 100% CPU on sustained ECONNREFUSED. Consecutive-error exponential backoff (5ms→250ms), reset on first clean datagram, both transports | d8af582 |
| F4 | high | **InspectorServer.serve leak** — task/keep-alive/subscriber leaked on client disconnect. `withTaskGroup` event-pump + inbound-drain, cancel on either; regression test | 81ed7ad |
| F5 | med | BUG-D save-race not fully closed — gen-check + write are now one main-actor critical section | ed8fd4a |
| F6 | low | compact nil-window fallback compared detail width against 680 (one-frame compact flash). Now 460 | ed8fd4a |
| F7 | low | redundant post-escalation IDR requests coalesced | d8af582 |
| F8 | low | frameTooLarge "recovery" comment was unwired — softened to match reality (PIECE C) | 81ed7ad |
| F9 | low | cap-comment overclaimed a live re-tighten — corrected to launch-time | ed8fd4a |
| — | low | **symmetric residual of F2** — `startLiveComponents` started SCStream/timers post-await with no identity guard. Symmetric identity guard | 4f6b9a5 |

A completeness critic confirmed all 21 items delivered (20 full, #9 partial-by-design), **no test
weakened/deleted to mask a regression**, and all new `@unchecked Sendable` types NSLock-safe.

## Still needs a GUI / device runtime pass (unchanged gap from docs/23)

Everything above is proven at the **pure-logic / ViewModel / state-machine** layer. The SwiftUI
views, live render/decode pipelines, and on-device interaction are **compiled + reviewed, not run**.
Confirm on hardware (the runtime is the only thing left between this and end-user use):

1. **macOS GUI smoke** (`scripts/check-macos.sh`) + **#1 the load-bearing check**: type in tab A,
   switch to B and back, assert A's prior output is still on screen (the replay ring's visual proof).
2. **PATH-2 video** (`scripts/check-video.sh`, from a real unlocked GUI session — `CGS_REQUIRE_INIT`):
   the `liveVideoCap` gate, **#2** reactive auto-promote on slot-free, **F1** the entry-form-vs-gated
   behavior, **#8 + F2 + symmetric** rapid `bye/hello/bye` (frames resume, no orphaned SCStream/timers/VT
   sessions), **F3** transient-error survival without a CPU spin.
3. **iPad-regular** multi-pane first-responder (**BUG-E/BUG-K**) + **iOS compact carousel** flip survival.
4. **Live inspector e2e** — needs **#9 PIECE C** (SessionStart-hook transcript discovery) before a real
   `claude` host serves the JSONL stream; the replay-then-live core is loopback-proven.
5. **HostServer E2E suite** — run once in CI to confirm **#10** fails a hung test under its ceiling
   instead of wedging the process.

## Merge

The branch is committed, not pushed, not merged. Recommended: merge `feat/rwork-code-hardening` →
`main` (mirrors how the workspace-UI branch landed at `e7c9c43`), then schedule the hardware pass above.
