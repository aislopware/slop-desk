# 47 — Simulators panel (the fourth path, and the foreign wire it speaks)

The right panel's **Simulators** tab mirrors one of the host's iOS Simulator devices and drives it —
frames down, gestures up. It is drawn **natively** (SwiftUI + `AVSampleBufferDisplayLayer`), not in a
web view.

Everything below the fold is **measured**, not read from a spec: `baguette` publishes no wire
document, so the dialect was recorded off a live `baguette serve` on 2026-08-04 and the byte-level
claims here are what the fixtures in `Tests/SlopDeskClientUITests/Simulator*Tests.swift` pin. If the
Homebrew formula moves, re-measure before changing the decoder.

---

## Shape

```
client (SlopDeskClientUI/Simulator)                     host
──────────────────────────────────────────────────────────────────────────────
metadata verb 21  ensureSimulatorServer  ────────────►  HostSimulatorPerformer
                  [state][UInt16 BE port] ◄──────────   SimulatorServerManager
                                                              │ spawns
GET  /simulators.json                    ────────────►  baguette serve --port 0
POST /simulators/<udid>/boot             ────────────►  (ONE host-global child)
POST /simulators/<udid>/shutdown         ────────────►
ws   /simulators/<udid>/stream?format=avcc&version=v2  ◄══► H.264 down, JSON up
```

The panel dials the server **directly at its mesh address**. The loopback relay
(`CodeSidebarProxy`) that the code workbench needs is deliberately not on this path: that relay
exists to give a *browser* a secure context and a stable origin for per-origin storage, and a native
panel has neither concern.

**No auth, by invariant.** The child binds `0.0.0.0` with no credential; security is the WireGuard
mesh (`docs/DECISIONS.md` — no app-layer crypto/auth).

### Not a fourth transport

This does **not** violate "three paths never merge". Terminal TCP / video UDP / inspector TCP are
SlopDesk's own wires, versioned `1`, golden-pinned, never negotiated. This is a **foreign** protocol
spoken to a third-party process that the user installed, over ordinary HTTP and websockets. It shares
no socket, no message set and no codec with the three, and `SlopDeskProtocol` never sees a byte of it.
Only the *discovery* step (verb 21) rides a SlopDesk wire, and that carries an address, not frames.

---

## The measured dialect

### Server discovery — verb 21

`ensureSimulatorServer`, 3-byte `ServiceEndpoint` response; see `docs/20-wire-protocol.md` for the
encoding. State `1` (ready) carries the port. The host **never waits** — readiness is client-side
polling, which is why `SimulatorSidebarModel` has an ensure loop at all.

### `GET /simulators.json`

```json
{ "running":   [ { "udid": "...", "name": "iPhone 17 Pro", "runtime": "iOS 26.0", "state": "Booted" } ],
  "available": [ … same shape … ] }
```

Folded into ONE list carrying `isBooted` (`SimulatorDevice.decodeList`). A malformed *device* is
skipped, not fatal; only a non-object root fails the parse. `state` is kept as the server's raw
string — simctl has more states than the two observed (`Booting`, `Shutting Down`, `Creating`), and a
closed enum would turn a transient state into a decode failure for the whole list.

### The stream socket

`ws://<host>:<port>/simulators/<udid>/stream?format=avcc&version=v2` — **input and control ride the
same socket**. There is no second connection to keep in sync.

**Down (binary): `[1 byte type][payload]`**

| type | payload |
| --- | --- |
| `0x01` | avcC decoder configuration record (SPS/PPS) |
| `0x02` | H.264 **IDR** — AVCC, 4-byte length-prefixed NALs (**not** Annex-B start codes) |
| `0x03` | H.264 delta — same framing |
| `0x04` | JPEG seed frame — painted before the first IDR, so the surface is never blank |

**Down (text):** JSON. Errors and control, never pixels. A device that refuses to stream says so
here and nowhere else — swallowing it is how a permanently blank panel with no explanation happens.

**Up (text):** JSON only — gestures, hardware buttons, keys, clipboard
(`SimulatorInputEnvelope`).

Measured codec: `avc1.640033` = H.264 **High 5.1**, ~350 kbit/s at 1206×2622 (iPhone 17 Pro).
**No HEVC is offered** — `format=avcc` is H.264 or nothing.

### Coordinates are NOT pixels

Every positional envelope carries the `width`/`height` of the surface the client measured the gesture
against, and the server rescales to the device. So the panel never needs to know the device's true
resolution to place a tap — it reports its own fitted rect and the point within it
(`SimulatorScreenLayout`).

---

## Traps

- **`baguette` CLI `stream` is unusable** — `avcc` emits 0 bytes, `h264` is rejected at runtime
  ("Unknown format: h264"), and `mjpeg` emits only a 76-byte HTTP multipart header. The websocket
  from `serve` is the ONLY working frame path. Do not "simplify" onto the CLI.
- **`NWProtocolWebSocket.Options.autoReplyPing` is inert here.** Measured: inserting an options
  object into `defaultProtocolStack.applicationProtocols` stores a **copy** (`stack.first === options`
  is `false`) and the copy reads the flag back at its default. Setting it looks like keepalive
  handling while providing none — the failure being a socket the server drops on its own idle timer,
  minutes in, for no visible reason. `SimulatorStreamConnection.replyToPing` answers explicitly
  instead; `SimulatorStreamParametersTests` pins the framework behaviour so a future refactor cannot
  quietly reintroduce the flag.
- **Dial `NWEndpoint.url(...)`, not host+port.** The handshake's request line comes from the URL, and
  `format`/`version` ride the query string. Host+port opens a socket to the right machine and asks it
  for the server's default dialect.
- **Booted devices die when Simulator.app quits** — baguette's own warning. `baguette lifetime
  --detach` is the fix, but it is a MACHINE-WIDE setting and is not flipped by SlopDesk.
- **Never `URLComponents.path` for a UDID route** — it re-escapes (`%2F` → `%252F`). Assign
  `percentEncodedPath`, and escape the component with `.urlPathAllowed` **minus** `/` so ordinary
  UDID dashes survive untouched.
- **Use `layer.sampleBufferRenderer`, not the layer's own `enqueue`/`flush`/`status`** — the latter
  are deprecated on macOS 15+, and mixing the two spellings on one layer is the documented way to get
  an inconsistent status.
- **A scroll event is already in the user's preferred direction — do not re-derive it from
  `NSEvent.isDirectionInvertedFromDevice`.** That flag reports the RAW device direction and is
  informational; AppKit has already applied the scroll-direction preference to `scrollingDeltaY`, so
  folding the flag in double-applies it, and a synthesized `CGEvent` reports it `false` whatever the
  setting says. Measured 2026-08-04 both ways against a live device: with the flag folded in, one
  gesture moved the device's list opposite to the way the same gesture moved a native scroll view in
  the same window. `swipeVector` passes the sign straight through, and `swipeEnd` is `origin + delta`.
- **A per-tick swipe does nothing.** One wheel notch is under iOS's own pan slop, so the device
  ignores it. `SimulatorScreenView` banks the travel and sends one swipe once it clears
  `swipeStep` — and `pointsPerLine` is deliberately ABOVE that step so a single physical detent still
  scrolls rather than banking against the next one. Isolated with the CLI while debugging: `baguette
  swipe --duration 0.05` over 32 pt DOES scroll, so a short fast swipe is not the problem; magnitude
  and sign were.

---

## Where the code lives

| File | Role |
| --- | --- |
| `Simulator/SimulatorWireProtocol.swift` | pure decoder: envelope + avcC record |
| `Simulator/SimulatorInputEnvelope.swift` | pure encoder: every upstream JSON envelope |
| `Simulator/SimulatorDevice.swift` | pure decoder: `/simulators.json` |
| `Simulator/SimulatorEndpoints.swift` | the whole route table, pure |
| `Simulator/SimulatorScreenLayout.swift` | fitted rect ↔ device point, pure |
| `Simulator/SimulatorVideoFormat.swift` | `CMFormatDescription` + `CMSampleBuffer` construction |
| `Simulator/SimulatorStreamConnection.swift` | the one socket (`NWConnection` + websocket) |
| `Simulator/SimulatorControlClient.swift` | list / boot / shutdown (`URLSession`) |
| `Simulator/SimulatorScreenView.swift` | `AVSampleBufferDisplayLayer` + mouse/scroll/key mapping |
| `Simulator/SimulatorDeviceList.swift` | the device list, on the Slate row shell |
| `Simulator/SimulatorSidebarModel.swift` | the two loops, the selection, the one live stream |

Both runtime seams are injectable (`SimulatorControlling`, `SimulatorStreaming`) so the model is
tested end to end **without a socket** — the hang-safety rule: no unit test builds an `NWConnection`,
a display layer, an `SCStream`, a `VT*Session` or a Metal device.

Host side: `SlopDeskHost/{HostSimulatorPerformer,SimulatorServerManager,HostServiceProcess}.swift`.

---

## Why native rather than a web view

`baguette serve` ships a perfectly good page, and the panel embedded it first. It was replaced
(user-directed 2026-08-04) because theming it meant re-scoping the page's CSS variables **and**
overriding the handful of rules that bake a literal hex — with every server update putting that back
in play. Drawn natively the question does not arise: the row shell, the section header and the search
plate are the same Slate components the navigator uses, so a theme swap repoints this panel with
everything else. The decode path got simpler too — one `AVSampleBufferDisplayLayer` instead of a
WKWebView with its own decoder, and gestures that reach the socket without a JS bridge.
