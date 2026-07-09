# 07 — Roadmap

> **STATUS: SUPERSEDED.** Old *video-first* roadmap. Terminal PTY was built first; GUI video followed — both shipped as co-equal panes. See [00-overview.md](00-overview.md) · [12-coding-profile.md](12-coding-profile.md) · [DECISIONS.md](DECISIONS.md).

Principle: **validate risks first, polish later.** Phase 0 targets the two highest-risk areas (per-window input injection + encode/decode latency); don't invest in transport/UI before it passes.

---

## Phase 0 — Validation spike (mandatory first)

Throwaway code to prove there are no technical blockers.

| # | Task | Doc | Done when |
|---|------|-----|-----------|
| 0.1 | Capture 1 window via SCKit; log fps + idle-frame skip | [02](02-host-capture-encode.md) | `.complete` frames seen, idle frames skipped |
| 0.2 | HW-encode HEVC low-latency, **measure encode latency** | [02](02-host-capture-encode.md) | ms/frame on target machine |
| 0.2b | Verify LTR symbols (`EnableLTR`/`ForceLTRRefresh`) on target SDK | [10 §1](10-latency-optimization.md) | LTR API confirmed working |
| 0.3 | Decode back on host (encode→decode loop), display | [04](04-client-decode-render.md) | Window re-renders correctly |
| 0.4 | `AXRaise` the correct specific window (multi-window app) | [05](05-input-window-control.md) | Right window comes to front |
| 0.5 | `CGEventPostToPid` click at mapped coordinates | [05](05-input-window-control.md) | Click lands at the right spot |
| 0.6 | Activation from a simulated network callback | [05](05-input-window-control.md) | Activation success rate measured |

**Gate:** if 0.4–0.6 fail often → stop and revisit the model ([08-risks](08-risks-open-questions.md)).

---

## Phase 1 — Video MVP (Mac→Mac, one-way, 1 window)

View 1 host window on 1 Mac client over LAN.

- [ ] SPM scaffold ([01 §3](01-architecture.md#3-package-structure-swift-package-manager)).
- [ ] Core: packet format + packetizer/reassembler + loss/reorder unit tests ([03 §4–5](03-transport-protocol.md)).
- [ ] Bonjour discovery (same-LAN MVP): host advertises, client lists ([03 §1](03-transport-protocol.md)).
- [ ] Full pipeline: capture → encode → UDP → reassemble → decode → render.
- [ ] TCP control channel (`noDelay`) + recovery messages (LTR ack / request-IDR) ([03 §3](03-transport-protocol.md)).
- [ ] Render-on-arrival or pacer (CVDisplayLink) ([10 §2](10-latency-optimization.md)).
- [ ] **Instrument 6-stage latency** + host timestamp in the frame header ([10 §10](10-latency-optimization.md)).
- [ ] Window picker (host) + host list (client).
- [ ] **Measure glass-to-glass latency.**

**Done:** pick a host window → see it live on the Mac client, < 60 ms LAN latency, loss self-recovers (LTR, keyframe fallback).

---

## Phase 2 — Input / control (Mac→Mac)

- [ ] Client captures mouse/keyboard/scroll → control channel (normalized 0–1 coords).
- [ ] Batch motion at 1 ms / send buttons immediately; cursor drawn client-side ([10 §6–7](10-latency-optimization.md)).
- [ ] Host: activate-then-control — raise + map coords + `CGEventPostToPid` ([05](05-input-window-control.md)).
- [ ] Text via Unicode injection; shortcuts via keycodes.
- [ ] Handle drag, double-click, scroll. (Optional: AX actions for standard controls.)

**Done:** smoothly control 1 window — type, click, drag.

---

## Phase 3 — iOS / iPadOS client

- [ ] Client + render targets for iOS.
- [ ] Render on a real device (Simulator has no HW decode).
- [ ] Touch → input: **trackpad** (relative) + **direct-touch** (absolute) modes.
- [ ] Hardware + on-screen keyboard → Unicode injection.
- [ ] iPad: trackpad/pencil if present.

**Done:** control a Mac window from iPhone & iPad over LAN.

---

## Phase 4 — Polish & extensions

- [ ] Multiple windows / concurrent sessions.
- [ ] Automatic reconnect on network drop.
- [ ] Adaptive bitrate from loss/RTT ([03 §5](03-transport-protocol.md)).
- [ ] Metal rendering (vs AVSampleBufferDisplayLayer) if lower latency is needed.
- [ ] Adaptive FEC for Wi-Fi.
- [ ] Audio (optional — SCKit captures at app level, not per-window).
- [ ] Device pairing (PIN/QR).
- [ ] Developer-ID signing + notarization + auto-update ([06](06-permissions-distribution.md)).

---

## Condensed priority order

```
Phase 0 (spike) ──gate──> Phase 1 (video) ──> Phase 2 (input) ──> Phase 3 (iOS) ──> Phase 4 (polish)
   high risk               visible value        core               expansion          polish
```
