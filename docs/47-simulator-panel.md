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
| `/simulators/<udid>/location` | POST / **DELETE** | `{latitude,longitude}` / — | POST pins GPS, DELETE restores live |
| `/simulators/<udid>/files` | POST | `?name=<file>`, body = bytes | routed **by extension** server-side |
| `/simulators/<udid>/bezel.png` | GET | `?buttons=false` | body artwork |
| `/simulators/<udid>/chrome-button/<file>` | GET | — | one button's rest / pressed art |

`location` also accepts a `{waypoints:[…]}` route and a `{latitude,longitude,bearing,speed}` walk. The
panel sends neither: both are motion over time and want a map to draw the path on. An empty POST is
`400 location body must be a point {latitude,longitude}, a {waypoints:[…]} route, or a
{latitude,longitude,bearing,speed} walk`.

The **hardware-button set** is closed and is exactly: `home`, `lock`, `power`, `volume-up`,
`volume-down`, `action`, `digital-crown`, `side-button`, `left-side-button`, `app-switcher`,
`swipe-to-app-switcher`, `swipe-to-home`, `pull-down-to-lock-screen`, `pull-down-to-notification-center`.
There is **no control-centre token**, so nothing here may offer one. The toolbar sends two of this
set — `home` and `app-switcher` — and the panel's own gesture layer covers the rest; a verb existing
upstream has never been a reason to put a plate under the pointer.

`files` is deliberately not classified client-side: the server installs an `.app`/`.ipa` and drops an
image or video into Photos, and guessing that taxonomy locally would reject the one build someone
wanted. The upload uses its own long timeout (`SimulatorControlClient.uploadTimeout`, 300 s) — an
`.ipa` install is not a 15-second request.

### The log socket

`ws://<host>:<port>/simulators/<udid>/logs?level=<level>&style=compact` — **text down, nothing up**.
A second socket beside the frame stream, not a channel on it: the two have opposite lifetimes (the
console opens and closes while the stream stays up), and a log subscription that died with a video
reconnect would lose the output covering the moment being investigated.

```
{"type":"log_started"}
{"type":"log","lines":["2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [sub:cat] message"]}
```

The server **batches at ~50 ms** rather than emitting a message per line, so the socket's message rate
is bounded whatever the device is doing. `log_started` is its own message on purpose: it is the only
signal separating "connected and the device is quiet" from "connected and nothing works".

`--style compact`'s type column, counted off 10,244 real lines (2026-08-04): `Db` 7455, `Df` 958,
`E` 780, `I` 564, `A` 90, `F` 7. The panel inks fault/error/info/debug and leaves `Df` (default)
plain — default is the ordinary case and tinting it would light most of the console.

Still **not** surfaced, though the server offers them: `camera` / `camera-source`, `3d-model.json` /
`render-3d.png` / `stream.3d.*`. Each needs UI of its own (a camera-source picker, a 3D viewport)
rather than another toolbar plate.

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

**Down (text):** JSON. Errors and control, never pixels. Swallowing one is how a permanently blank
panel with no explanation happens — but it is only **one** of the two ways a stream fails to start,
and not the common one. See the trap below.

⚠️⚠️ **A stream that will never start is SILENT — the server does not say no.** Measured 2026-08-04
against the live server, twelve seconds per case:

| device state | what arrives |
| --- | --- |
| Booted | `101` → JPEG seed at **0.05 s**, avcC + first IDR at **0.09 s**, then ~13 delta/s |
| Shut down | `101` → **nothing at all.** No error text, no close frame, no bytes, indefinitely |

So there is no event to turn into a failure, and a client that waits for one waits forever. This is
exactly the reported bug: a row still showing Booted (the device list is up to 4 s stale), a click, an
indicator with no end. The **only** fix is client-side — `SimulatorSidebarModel.firstFrameDeadline`
(5 s, ~55× the measured healthy case) followed by a `/simulators.json` read-back, which separates the
two causes: device gone (say so, return to the list) versus running but not encoding (stay, offer a
retry). Reproduce either case with a bare websocket client; a `101` alone proves nothing.

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
family glyph as the leading mark, the live state as a subtitle while it is in transition, and an
**always-visible** trailing action (spinner while pending, stop when booted, play when not) — a
hover-only control in a list you are scanning is a control you cannot find. Clicking a row boots a
shut-down device and opens a booted one. The context menu carries Open / Boot / Shut Down plus Copy
UDID and Copy Name.

*The runtime is said once per group.* `SimulatorListEntry.group` computes the runtime every member of
a heading shares and hangs it on the **heading**; a row whose runtime differs is the only one that
still prints its own. An empty runtime counts as a disagreement rather than as a shared value, so a
server that omits the field cannot make a heading claim a runtime nobody has. Without this, a
thirty-device list repeated `iOS 26.5` thirty times in the one column the eye scans for difference.

**The stage.** Two lit surfaces, not four ruled bands: the header sits on `ground`, the device and
the toolbar that drives it share one `face`, and the console drawer opens as a third with its own
raised head. Four bands of equal tone read as a stack of unrelated strips; grouping the toolbar with
the device says at a glance that the verbs act on the thing above them (MERIDIAN L5).

*Identity* — `SimulatorDeviceHeader`: the back control (navigation belongs beside the device's name,
not in the surface strip), the device name at the `title` rung — the one size in the panel that
outranks the content under it — and a `SlateFactLine` of runtime, measured resolution, orientation
when it is not portrait, the pinned position when there is one, and the short UDID, each with its own
Copy. **Every figure is measured**: the resolution comes from the decoder's own format description via
`SimulatorScreenView.onContentSize`, not from a table. The one figure the reference designs show that
is deliberately absent is **uptime** — `/simulators.json` carries `name`, `runtime`, `state`, `udid`
and nothing else, so a "booted 3m ago" would be the panel timing its own first sighting and printing
it as the device's age.

*Device* — the stream seated in the real body, side buttons and all. Buttons swap to their pressed
artwork on touch-down and fire the envelope on **release**, which is what makes a long-press on Power
do what a long-press on Power does.

*Verbs* — the toolbar carries only what the body cannot offer AND what actually gets used: rotate
left/right; Home and App Switcher (gestures with no hardware to click); copy screenshot; the demo
status-bar toggle; then, right-aligned, the location popover and the console latch. Screenshots go to
the **clipboard**, not to a file — the client app is sandboxed, and a screenshot's next stop is a
message or a PR. Any file dropped on the stage is sent to `files`.

**Notification Centre and Lock were removed** (user-directed 2026-08-04). Both were there because the
server offers the verb, which is not a reason. Neither is reached for while driving an app, and both
are destructive to what you are doing — a mis-click beside Home blanks the device and costs a wake
and a swipe to undo. The verbs still exist upstream; a rail earns its width by what gets used.

*Output* — `SimulatorConsoleView`, a fixed-height drawer under the device rather than a tab. A console
that replaces the screen breaks the tap-watch-read loop it exists for. Its level menu **re-subscribes**
(the server takes `--level` at subscribe time and cannot change it on a live socket) and keeps the
rows already collected; its substring filter is client-side and must not, because narrowing the view
is the one thing that has to keep the history it is narrowing. Follow is an explicit **latch**, not an
inferred scroll position — `onScrollGeometryChange` is macOS 15 and the target is 14.

*Location* — `SimulatorLocationPopover`: a shortlist of places plus a coordinate field. A popover
rather than a drawer because it is set-and-forget; what stays visible afterwards is the header's
readout.

Without chrome — still loading, or a model the server cannot describe — the stage falls back to the
plain rectangle. A working screen with no bezel is a working screen; refusing to draw until the
artwork arrives makes a slow fetch look like a dead stream.

### A hue means something is wrong

Panel-wide, user-directed 2026-08-04, after four surfaces broke it independently. Healthy states ride
**luminance and weight**; colour is reserved for a fault. What this removed:

| Was | Now |
| --- | --- |
| Header: green dot captioned `Live` while streaming | nothing — the title line is facts only (see *Three states, all of them definite*) |
| List: booted device's family glyph in the accent | booted = primary ink at medium weight, shut down = tertiary |
| Console: `info` process names in green | grey; only `error`/`fault` are inked |
| Stage: success banner ringed in green | ringed in the neutral active border; only a failure is red |
| Any latched `PlateIconButton` glyph in the accent | primary ink one weight up (`.semibold`) — app-wide, not just here |

The rule follows the 07-30 round that reversed hue-as-status across the workspace, and the two before
it that deleted `ConnectionStatusPill` and rejected outcome dots. A live mirror is its own evidence —
the picture is moving. What deserves a caption is the moment it is *not* there, because a stalled
rectangle and a black screenshot look identical. Colour spent on the ordinary case teaches people to
stop reading the panel's colours at all, which is what made the handful of red lines the console
exists to surface no easier to find than the hundreds of green ones around them.

**No colour is left at rest.** A latched plate was the last holdout — it lit its glyph in the accent
— and that went too: latched is now primary ink at `.semibold` on a raised fill, three non-hue
channels for one state. The header's pinned-position fact is unaccented for the same reason: it
appears only when a position is pinned, so its presence already carries the state.

### One rule across the top, not two

The panel's top used to stack two hairlines a few points apart — the tab strip's, then the device
header's — and the head of the column read as a pile of bands. The **header's** rule is the one that
went (user-directed 2026-08-04): the stage below it opens on `face`, one step up in light, and that
tone change IS the edge (MERIDIAN L5).

The **strip's** rule stays, for every surface. A first pass made it conditional and that was wrong:
the tab row is chrome that outranks whatever it switches between, and chrome without an edge floats.

What the top bar looks like now, which is the shape of the reference design it was measured against:

```
[ ▤  ▣ Simulators  ▭ ]                    ↻  ▤     ← tab strip, one hairline under it
 ‹  iPhone 17 Pro  iOS 26.5                        ← name (title rung) + runtime (grey)
    Resolution 1206 × 2622 · UDID 01D1D359         ← labelled facts, grey label + brighter value
────────────────────────────────────────────       ← no rule: `face` starts, and the tone is the edge
```

Two changes make that read as designed rather than generated. The runtime moved **out of the facts
line and up beside the name** — it is half of what names a device, since two iPhone 17 Pros differ by
nothing else, and among four dot-separated figures it was where the thing you were looking for went
to hide. And every fact now **draws its label** (`SlateFact.showsLabel`): `1206 × 2622 · 01D1D359` is
a riddle at rest, correct and unreadable. Facts that appear only when abnormal — orientation, a
pinned position — opt out, because their presence is already the news and the width belongs to the
facts that are always there.

Pinned by `SimulatorDeviceTests` — the console and the test read the same `tint(for:)`, so the
rendered ink cannot drift from the rule.

### Three states, all of them definite

The stage resolves into exactly one of three things, and none of them is open-ended
(user-directed 2026-08-04):

| state | drawn |
| --- | --- |
| loading (`isAwaitingStream`) | opaque veil over the stage: spinner + `Starting the stream…` |
| streaming | the device |
| stalled (past the deadline, still no video) | veil: `No video from this device.` + **Try Again** |

Three details are load-bearing:

**The veil is delayed 400 ms.** A healthy stream's first keyframe lands in 0.09 s, so a veil with no
delay would flash grey over the bezel on *every* selection — drawing the failure onto the ordinary
case. The delay is the only reason the view keeps its own copy of the loading state.

**The veil stops at the header.** Covering the back control is what left the reported bug with no exit.

**The caption moved onto the stage.** It used to be a `Connecting…` in the header's title line, which
was wrong twice over: it captioned the state from *outside* the ambiguous object (an empty rectangle,
a black screenshot and a dead stream are pixel-identical), and it was drawn from "no frames yet" — a
condition that never expires. Both are fixed at the source; the header is facts again.

**The JPEG seed is not arrival.** Only `0x01`/`0x02`/`0x03` end the loading state. The seed is the
still the server sends while its encoder starts, so counting it would let a stream that never encodes
pass as live, wearing a screenshot as a disguise.

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
- **A stream for a non-booted device is SILENT, not refused** — `101` and then nothing, forever. No
  error text, no close frame. Any "why is it loading?" question about this panel starts here; the
  measurements and the client-side deadline are under *The stream socket*.
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
  2026-08-04, a device that booted moved up into Running still drawing the receded family glyph and
  the Boot button from its family group, and one that shut down moved down still drawing the lit glyph
  and Shut Down — position followed the state, content did not, from a single `isBooted` read.
  `SimulatorDeviceList.entries` flattens headings and rows into ONE `ForEach` over
  `SimulatorListEntry`, whose id is `section/udid`, so changing group is a remove and an insert.
- **The log socket upgrades whatever `level` you send.** An invented level (`verbose`, `warn`) gets a
  successful websocket handshake and then dies when the server's `log stream` child refuses it — which
  reads as a console that connects and never prints. `SimulatorLogLevel` is a closed set of the five
  the child accepts (`debug | info | notice | error | fault`) precisely because the handshake will not
  catch a bad one.
- **The device entry has no uptime and no resolution.** `/simulators.json` is four fields. Anything
  the header prints beyond them has to come from somewhere that actually measured it — the resolution
  from the decoder's format description, the position from the call that succeeded. A "booted N s"
  synthesized from first sighting reads as fact and is wrong after every client restart.
- **`app-switcher` is a TOGGLE, and it is silent when there is nothing to show.** Measured
  2026-08-04 against a booted iPhone 17 Pro: press once from an app or the home screen and the card
  stack appears; press again and it dismisses into the front app. `swipe-to-app-switcher` behaves
  identically — both are the swipe-up-and-hold gesture, so neither is an idempotent "show". On a
  freshly booted device with nothing backgrounded, the verb is accepted, returns no error on the
  socket, and changes nothing on screen, exactly like the hardware. Reported as a broken button; it
  is not one, and the tooltip now says "press again to dismiss" rather than promising a state.
- **`location` clears with a DELETE**, like `status-bar`. There is no `{clear:true}` and an empty POST
  is a 400 — a clear spelled as a POST fails rather than no-ops.
- **`SimulatorBezelView`/`SimulatorBareScreen` declare `onContentSize` AFTER `send`.** Swift's
  trailing-closure forward scan takes the first unfilled function-typed parameter, so putting the size
  callback earlier silently rebinds every existing call site's gesture handler to it.

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
| `Simulator/SimulatorStageView.swift` | the streaming surface: header + device + toolbar + drawer + banner + drop target |
| `Simulator/SimulatorDeviceHeader.swift` | what device this is: name, measured facts, back |
| `Simulator/SimulatorConsoleView.swift` | the log drawer: level menu, filter, follow latch, rows |
| `Simulator/SimulatorLogLine.swift` | pure: compact-line parse, log envelope decode, the level set |
| `Simulator/SimulatorLogConnection.swift` | the console's socket (`NWConnection` + websocket) |
| `Simulator/SimulatorPlace.swift` | pure: coordinate parse / body / readout + the preset shortlist |
| `Simulator/SimulatorLocationPopover.swift` | the location picker: presets, field, clear |
| `Simulator/SimulatorDeviceList.swift` | the device list — Running, then grouped by family |
| `Simulator/SimulatorSidebarModel.swift` | the two loops, the selection, the one live stream, the console, the first-frame deadline |

Two `Slate` components were added for this panel and belong to the whole system, not to it:

| File | Role |
| --- | --- |
| `DesignSystem/SlatePlateGroup.swift` | the tray that groups related plates into one instrument — a shared fill, which is a stronger grouping signal than a hairline. Sets `slateOnPlateTray`, which lifts a member plate's hover and latched fills a rung so they stay visible against it |
| `DesignSystem/SlateFactLine.swift` | a run of measured facts: a drawn grey label ahead of each value, figures in the instrument voice, named values in the system face, a middle dot between, and each fact separately hoverable and copyable |

`PlateIconButton` also gained the `.medium` glyph weight `SlatePlateButton` already used — the two
plate idioms were drawing the same symbols at two weights, and at 13pt a regular-weight SF Symbol goes
wispy on a light theme's paper.

All three runtime seams are injectable (`SimulatorControlling`, `SimulatorStreaming`,
`SimulatorLogStreaming`) so the model is tested end to end **without a socket** — the hang-safety
rule: no unit test builds an `NWConnection`, a display layer, an `SCStream`, a `VT*Session` or a Metal
device.

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
