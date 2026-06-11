# 07 — Roadmap

> **STATUS: SUPERSEDED** — replaced; see [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Overridden** by [12 §"Revised phased roadmap"](12-coding-profile.md). New order for the hybrid architecture: **terminal PTY text-path = Phase 1** (simpler, higher value, sidesteps the injection problem); the GUI video path moves back to **Phase 4**. The content below is kept as a detailed reference for the **GUI video-path**.

Principle: **validate the risks first, polish later.** Phase 0 concentrates on the 2 highest-risk areas (per-window input injection + encode/decode latency). Don't invest in transport/UI before Phase 0 passes.

---

## Phase 0 — Validation spike (MANDATORY first)

**Goal:** prove there are no technical blockers. Throwaway code, doesn't need to be pretty.

| # | Task | Doc | Done when |
|---|------|-----|----------|
| 0.1 | Capture 1 window via SCKit, log fps + idle-frame skip | [02](02-host-capture-encode.md) | `.complete` frames observed, idle frames skipped |
| 0.2 | HW-encode HEVC low-latency, **measure encode latency** | [02](02-host-capture-encode.md) | ms/frame numbers on the target machine |
| 0.2b | Verify the LTR symbols (`EnableLTR`/`ForceLTRRefresh`) on the target SDK | [10 §1](10-latency-optimization.md) | Confirmed the LTR API exists & works |
| 0.3 | Decode back locally on the host (encode→decode loop), display | [04](04-client-decode-render.md) | The window re-renders correctly |
| 0.4 | `AXRaise` the correct specific window (multi-window app) | [05](05-input-window-control.md) | The right window comes to front |
| 0.5 | `CGEventPostToPid` click at mapped coordinates | [05](05-input-window-control.md) | Click lands at the right spot in the window |
| 0.6 | Test activation from a simulated network callback (target macOS) | [05](05-input-window-control.md) | Activation success rate measured |

**Gate:** if 0.4–0.6 fail often → stop, revisit the model ([08-risks](08-risks-open-questions.md)) before continuing.

---

## Phase 1 — Video MVP Mac→Mac, one-way, 1 window

**Goal:** view 1 host window on 1 Mac client over LAN.

- [ ] SPM scaffold per [01 §3](01-architecture.md#3-package-structure-swift-package-manager).
- [ ] `PaneCastCore`: packet format + packetizer/reassembler + unit tests for loss/reordering ([03 §4–5](03-transport-protocol.md)).
- [ ] Bonjour discovery: host advertises, client lists ([03 §1](03-transport-protocol.md)).
- [ ] Full pipeline: capture → encode → UDP → reassemble → decode → render.
- [ ] TCP control channel with `noDelay` + recovery messages (LTR ack / request-IDR) ([03 §3](03-transport-protocol.md)).
- [ ] Render-on-arrival or Pacer (CVDisplayLink) ([10 §2](10-latency-optimization.md)).
- [ ] **Instrument 6-stage latency** + host timestamp in the frame header ([10 §10](10-latency-optimization.md)).
- [ ] Window picker UI (host) + host list UI (client).
- [ ] **Measure glass-to-glass latency.**

**Done:** pick a window on the host → see it live on the Mac client, latency < 60ms on LAN, packet loss self-recovers (LTR, keyframe fallback).

---

## Phase 2 — Input / control (Mac→Mac)

**Goal:** control the window from the client.

- [ ] Client captures mouse/keyboard/scroll in the view → sends over the control channel (normalized 0–1 coordinates).
- [ ] Input: batch motion at 1ms / send buttons immediately; cursor drawn client-side ([10 §6–7](10-latency-optimization.md)).
- [ ] Host: activate-then-control — raise + map coordinates + `CGEventPostToPid` ([05](05-input-window-control.md)).
- [ ] Text via Unicode injection; shortcuts via keycodes.
- [ ] (Optional) AX actions for standard buttons/text fields.
- [ ] Handle drag, double-click, scroll.

**Done:** smoothly control 1 window from the Mac client; typing text + clicking + dragging all work.

---

## Phase 3 — iOS / iPadOS client

**Goal:** view & control from iPhone/iPad.

- [ ] Build `PaneCastClientKit` + `PaneCastRender` for iOS.
- [ ] Render on a real device (Simulator has no HW decode).
- [ ] Touch → input mapping: **trackpad** mode (relative) + **direct-touch** mode (absolute).
- [ ] Hardware keyboard + on-screen keyboard → Unicode injection.
- [ ] iPad: support trackpad/pencil if present.

**Done:** control a Mac window from iPhone & iPad over LAN.

---

## Phase 4 — Polish & extensions

- [ ] Multiple windows / multiple concurrent sessions.
- [ ] Automatic reconnect on network drop.
- [ ] Adaptive bitrate based on loss/RTT ([03 §5](03-transport-protocol.md)).
- [ ] Metal rendering instead of AVSampleBufferDisplayLayer if lower latency is needed.
- [ ] Adaptive FEC for Wi-Fi.
- [ ] Audio (optional — SCKit captures audio at app level, not per-window).
- [ ] Security/pairing: PIN/QR device pairing (LAN should still have auth).
- [ ] Developer-ID signing + notarization + auto-update ([06](06-permissions-distribution.md)).

---

## Condensed priority order

```
Phase 0 (spike) ──gate──> Phase 1 (video) ──> Phase 2 (input) ──> Phase 3 (iOS) ──> Phase 4 (polish)
   high risk               visible value        core               expansion          polish
```
