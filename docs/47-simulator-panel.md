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

### `GET /simulators/<udid>/definition.json` — the device body

The panel draws the **real device**, not a rectangle on grey, and this route is where the geometry
and the artwork come from. It is DeviceKit model data, so it **answers for a shut-down device too**.

```json
{ "identity": { "model": "iPhone 17 Pro" },
  "screen": {
    "viewport":    { "width": 436, "height": 908 },
    "rect":        { "x": 18, "y": 18, "width": 400, "height": 872 },
    "clipRadius":  62,
    "bezelImage":  { "bare": "/simulators/U/bezel.png?buttons=false",
                     "rest": "/simulators/U/bezel.png" } },
  "buttons": [
    { "id": "power",
      "box":      { "leftPct": 97.0, "topPct": 28.8, "widthPct": 3.6, "heightPct": 11.1 },
      "images":   { "rest": "…/chrome-button/power.png", "pressed": "…/chrome-button/power-down.png" },
      "envelope": { "button": "power", "type": "button" },
      "z": "below" } ] }
```

**Percentages, not points.** Every button box is a fraction of the *viewport*, so one decode scales to
any panel width without a second layout pass. Boxes legitimately fall **outside 0–100**: side buttons
protrude from the body (`leftPct` negative on the left rail, past 100 on the right). That is what
`SimulatorChrome.bleed` accounts for, and why the panel lays out to the bleed rather than to the
viewport — laying out to the viewport clips the buttons off at the panel's edge.

`z: "below"` is why the panel fetches `bezelImage.bare` (`?buttons=false`) and draws the buttons
*under* it: the bezel's own edge is what makes a protruding button read as seated rather than pasted
on. The `rest` body with buttons baked in is kept for a still preview where nothing is pressable.

Measured 2026-08-04: iPad Pro 13-inch (M5) → viewport 1124×1468, rect {46,46,1032,1376},
clipRadius 29, three buttons.

### The control routes

| route | method | argument | what it does |
| --- | --- | --- | --- |
| `/simulators/<udid>/orientation` | POST | `?value=landscape-left` | kebab-case; the four quarter turns |
| `/simulators/<udid>/screenshot.jpg` | GET | `?t=<nonce>` | JPEG of NOW — the nonce is the cache-buster |
| `/simulators/<udid>/status-bar` | POST / **DELETE** | JSON body / — | POST sets overrides, DELETE restores |
| `/simulators/<udid>/files` | POST | `?name=<file>`, body = bytes | routed **by extension** server-side |
| `/simulators/<udid>/bezel.png` | GET | `?buttons=false` | body artwork |
| `/simulators/<udid>/chrome-button/<file>` | GET | — | one button's rest / pressed art |

`files` is deliberately not classified client-side: the server installs an `.app`/`.ipa` and drops an
image or video into Photos, and guessing that taxonomy locally would reject the one build someone
wanted. The upload uses its own long timeout (`SimulatorControlClient.uploadTimeout`, 300 s) — an
`.ipa` install is not a 15-second request.

Deliberately **not** surfaced yet, though the server offers them: `logs`, `location`, `camera` /
`camera-source`, `3d-model.json` / `render-3d.png` / `stream.3d.*`. Each needs UI of its own (a log
console, a map picker, a 3D viewport) rather than another toolbar plate.

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

## The two surfaces

Rebuilt 2026-08-04 (user-directed: the list and the control surface were too sparse to work with).

**The list.** Running devices come first as one un-split group — a device that just booted must not
slide under the cursor into a family heading. Everything else is grouped by family (iPhone, iPad,
Watch, TV, Vision) in a fixed rank, so the order cannot reshuffle between polls. Each row carries its
family glyph tinted by state as the leading mark, the live state as a subtitle while it is in
transition, and an **always-visible** trailing action (spinner while pending, stop when booted, play
when not) — a hover-only control in a list you are scanning is a control you cannot find. Clicking a
row boots a shut-down device and opens a booted one. The context menu carries Open / Boot / Shut Down
plus Copy UDID and Copy Name.

**The stage.** The stream is seated in the real body, side buttons and all. Buttons swap to their
pressed artwork on touch-down and fire the envelope on **release**, which is what makes a long-press
on Power do what a long-press on Power does. The toolbar carries only what the body cannot offer:
rotate left/right, Home and App Switcher (gestures with no hardware to click), Lock, copy screenshot,
and the demo status-bar toggle. Screenshots go to the **clipboard**, not to a file — the client app is
sandboxed, and a screenshot's next stop is a message or a PR. Any file dropped on the stage is sent
to `files`.

Without chrome — still loading, or a model the server cannot describe — the stage falls back to the
plain rectangle. A working screen with no bezel is a working screen; refusing to draw until the
artwork arrives makes a slow fetch look like a dead stream.

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
- **A button box outside 0–100 % is not a bad decode.** Side buttons protrude from the body on
  purpose. Clamping the box, or laying out to the viewport instead of `SimulatorChrome.bleed`, shaves
  them off at the panel's edge and looks like missing artwork.
- **Never upsample the bezel art.** `SimulatorBezelView` caps its fit scale at 1. Past that the body
  goes soft while the video stays sharp, which reads as a broken render rather than a big device.
- **A server-supplied reference already carries its query and its escaping.** `bezelImage.bare` is
  `bezel.png?buttons=false`. Putting it through the UDID route builder escapes the `?` into the path
  — the double-encoding trap from the other side. `SimulatorEndpoints.resolve` uses
  `URL(string:relativeTo:)` for exactly these.
- **`visionpro` is deprecated as an SF Symbol on macOS 15** — the spelling is `visionPro`.
- **The status bar clears with a DELETE, and rejects the whole body on one bad field.** There is no
  `{"clear": true}`: an empty or flag-only POST answers `400 set at least one status-bar field`, so a
  clear spelled as an override fails rather than no-ops. And `batteryState` is
  `charging | charged | discharging` — "unplugged" reads like the right word and 400s the entire
  preset. Both measured 2026-08-04 against a live server; `SimulatorControlClient.statusBarMethod`
  and the demo-preset test pin them.
- **A device row's identity has to carry its SECTION, not just its UDID.** The device list was first
  drawn as a heading plus a nested `ForEach` per group. Two sibling `ForEach`es inside one
  `LazyVStack` whose elements share an id let the stack reuse the row it already built: measured
  2026-08-04, a device that booted moved up into Running still drawing the grey family glyph and the
  Boot button from its family group, and one that shut down moved down still drawing the accent glyph
  and Shut Down — position followed the state, content did not, from a single `isBooted` read.
  `SimulatorDeviceList.entries` flattens headings and rows into ONE `ForEach` over
  `SimulatorListEntry`, whose id is `section/udid`, so changing group is a remove and an insert.

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
| `Simulator/SimulatorChrome.swift` | pure decoder: `definition.json` — body geometry + button boxes |
| `Simulator/SimulatorDeviceKind.swift` | product name → family (glyph, heading, sort rank), pure |
| `Simulator/SimulatorOrientation.swift` | the quarter-turn cycle + wire spelling + demo status bar, pure |
| `Simulator/SimulatorControlClient.swift` | every HTTP route (`URLSession`) |
| `Simulator/SimulatorChromeAssets.swift` | fetches the body + button art into `NSImage`s |
| `Simulator/SimulatorScreenView.swift` | `AVSampleBufferDisplayLayer` + mouse/scroll/key mapping |
| `Simulator/SimulatorBezelView.swift` | the device: art, screen clipped into `screen.rect`, live buttons |
| `Simulator/SimulatorStageView.swift` | the streaming surface: device + toolbar + banner + drop target |
| `Simulator/SimulatorDeviceList.swift` | the device list — Running, then grouped by family |
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
