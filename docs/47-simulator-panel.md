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

**The frame rate is content-driven, and it is high.** Measured 2026-08-04: a static screen emits
~13 frames/s (p50 gap 78 ms, ~1.6 KB each); a device under a continuous drag emits **69.5 frames/s**
(p50 gap 12.1 ms, 2.1 Mbit/s). That number is why frames do not travel as `@Observable` state —
see `SimulatorFrameSink`. **`fps`, `scale` and `bitrate` are `baguette stream` flags and are NOT
honoured on the websocket**: measured with each appended to the query, the seed still came back
1206×2622 and the rate was unchanged. Do not add them to the URL expecting an effect.

### ⚠️⚠️ The upstream verbs are NOT equally priced

Measured 2026-08-04 by feeding `baguette input` back-to-back envelopes and timing its per-envelope
acks. The spread is three orders of magnitude, and it decides the whole input design:

| verb | server time per envelope |
| --- | --- |
| `swipe` (duration 0.01 / 0.05 / 0.25) | **275 / 281 / 744 ms** |
| `type`, one character | 147 ms |
| `button` | 147 ms |
| `key` | 131 ms |
| `tap` (duration 0.05) | 73 ms |
| `touch2-move` | 25 ms |
| **`touch1-down` / `-move` / `-up`** | **0.0–0.1 ms** |

`swipe`'s 275 ms is a FIXED cost, not the interpolation — it barely moves between a 10 ms and a 50 ms
nominal duration — and it occupies the server's main actor, so nothing else is serviced while it runs.
The consequence, measured end to end: **two seconds of scrolling built on `swipe` left the device
still moving 5.29 s after the user stopped.** The same two seconds as a `touch1` stream: **0.00 s**.

So the panel's scroll is one contact that moves (`SimulatorScrollGesture`), never a run of flicks, and
`swipe`/`tap` appear nowhere on the interactive path. `touch2-*` is used only for pinch, where 25 ms
is affordable because the gesture is rate-limited to 25 Hz.

The one ceiling this side cannot lift: **typing is ~7 characters per second**, and batching does not
help (10 envelopes of one character and one envelope of ten characters both cost ~140 ms/char). That
is inside the server's HID key dispatch.

### The gesture surface

Every pointer gesture is a `touch1` stream, for the cost reason above and because it is what iOS
recognisers are built for:

| what the user does | what goes on the wire |
| --- | --- |
| click / press-and-hold | `touch1-down` … `touch1-up` — the timing is the user's own, so a hold opens a context menu |
| drag | the same, with a `touch1-move` per `mouseDragged` |
| drag starting in an edge band | the same, `edge: "bottom"` / `"top"` on every envelope of the sequence |
| trackpad scroll | one contact, planted under the cursor, moved per event, lifted on `.ended` |
| wheel scroll | the same, closed by a 120 ms idle timer — a wheel reports no phase |
| trackpad pinch (`magnify`) | `touch2-*` around the pointer, rate-limited to 25 Hz |

The **edge hint** is what lets a drag reach the home indicator and the pull-down shades at all —
without it those gestures exist only as toolbar buttons. The bands are `baguette`'s own (bottom 7 %,
top 7 %), copied rather than re-derived because the server interprets the hint against them; only
`portrait-upside-down` swaps them onto the other axis.

A scroll gesture can travel further than the device is tall, and a finger cannot leave the screen and
keep going, so the contact **re-grips**: lift at the boundary, plant again at the far side, inside a
24 pt margin — planting on the edge itself would land in iOS's own system-gesture band and summon the
app switcher instead of continuing.

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
Watch, TV, Vision) in a fixed rank, so the order cannot reshuffle between polls. Each row carries the
live state as a subtitle while it is in transition and an **always-visible** trailing action (spinner
while pending, stop when booted, play when not) — a hover-only control in a list you are scanning is
a control you cannot find. Clicking a row boots a shut-down device and opens a booted one. The
context menu carries Open / Boot / Shut Down plus Copy UDID and Copy Name.

*A row never repeats what its heading already said* (user-directed 2026-08-04). Two columns were
saying it twice, and repetition down a scanned column is what made the list read as generated:

- **The family glyph is drawn only under RUNNING.** RUNNING is the one group not cut by family, so it
  is the one group where a leading mark carries information. Under `IPHONE` a phone glyph on every
  row is a thirty-times-repeated restatement of the word directly above it — and worse, it pushed the
  names off the left rail the headings sit on, so nothing in the column lined up.
  `SimulatorListEntry.group` decides this once, per group, and `SimulatorDeviceTests` pins it.
- **The runtime is said once per group, in the heading's own cluster.** `group` computes the runtime
  every member shares and hangs it on the **heading** as `SlateSectionHeader(caption:)` — immediately
  after the title, one ink quieter, same engraved register. It is deliberately not the header's
  `accessory` slot: that slot is pinned to the far trailing edge where a *control* belongs, and at
  panel width a qualifier sent there becomes a lone readout marooned across an empty rule. A row
  whose runtime differs is the only one that still prints its own. An empty runtime counts as a
  disagreement rather than as a shared value, so a server that omits the field cannot make a heading
  claim a runtime nobody has.

*State rides weight, presence stays constant.* The booted device's name is one weight up (`.medium`
against `.regular`) — the same non-hue channel the rest of the panel uses. The play/stop action is
always drawn, but at `Slate.Text.tertiary` until the row is hovered, when it goes to primary: the
**weight** of the affordance changes on hover, never its presence. A control that appears on hover
cannot be found by scanning; a control at full contrast on every row of a thirty-row list is thirty
competing calls to action.

**The stage.** Two lit surfaces, not a stack of ruled bands: one top bar on `ground`, the device
alone on `face` below it, and the console drawer as a third with its own raised head. Bands of equal
tone read as a stack of unrelated strips (MERIDIAN L5).

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

They live **in the top bar**, right-aligned, as of 2026-08-04 (user-directed). Two problems went at
once. The identity band was half empty at panel width — a name, a fact line, and then several hundred
points of nothing out to the trailing edge — while the verbs sat in a strip along the stage floor,
under the device they act on, in the reading order of a footer. Folding them into the bar spends the
empty half on the controls and puts the verbs above the thing they drive. This is **not** the
previously-rejected "give the toolbar its own band": no band is added, one is removed. The identity
takes `layoutPriority(-1)` so the name truncates before any plate does — the verbs are fixed-size and
a clipped name is still a name, while a clipped icon rail is a missing control.

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
| Stage: success banner ringed in green | the panel draws no banner at all — see *Reports leave through the app's notification* |
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

### Reports leave through the app's notification

User-directed 2026-08-04. The panel used to carry **two** alert chromes of its own: a bordered capsule
floating at the top of the stage (`failure` or `notice`), and a differently-shaped warning row ruled in
above the device list for a failed poll. Neither matched anything else in the window — the capsule in
particular read as an alert raised by some other application — and the window already has exactly one
surface for "something happened": `ToastStackView`.

Both are gone. `SimulatorSidebarModel` still holds `failure` / `notice`; what changed is who draws them.
`CodeSidebarColumn.announce(_:isFailure:)` watches both and pushes one card:

- **fixed id `simulator`**, so a newer report replaces the older rather than stacking three cards about
  one panel (the warp `object_id` discipline the other window-level notices use);
- **`source: .command`, no `paneKey`** — an event at a device, with nowhere to jump, so the card renders
  as a plain notice rather than a door;
- **the device is the subject, the sentence is the detail.** A toast headline is one middle-truncated
  line at ~35 characters and every one of these messages is longer, so a sentence put there loses its
  middle — which is where the verb is. `headline`/`title` = the device name (or `Simulators` when the
  selection has already been cleared), `body` = the sentence.

**It listens on the SURFACE, not on the stage.** The "no longer running" verdict sets the text and
clears the selection in one write, so an `.onChange` living on `SimulatorStageView` would be torn down
by the same transaction that fired it. That verdict is also the only one of the three that still names
the device in its own sentence — it is the one that sends the reader back to the list, where nothing
else is left saying which device it was about.

**What did NOT move: state.** A notification is an event and expires; the stalled stream is a condition,
and it stays drawn on the stage where the ambiguous empty rectangle is, with its retry beside it. The
same split is why a failed poll leaves the rows alone — the last-known devices are still the best
information available, and blanking them would make a flaky link look like a device set that vanished.

### One rule across the top, not two

The panel's top used to stack two hairlines a few points apart — the tab strip's, then the device
header's — and the head of the column read as a pile of bands. The **header's** rule is the one that
went (user-directed 2026-08-04): the stage below it opens on `face`, one step up in light, and that
tone change IS the edge (MERIDIAN L5).

The **strip's** rule stays, for every surface. A first pass made it conditional and that was wrong:
the tab row is chrome that outranks whatever it switches between, and chrome without an edge floats.

What the top bar looks like now, which is the shape of the reference design it was measured against:

```
[ ▤  ▣ Simulators  ▭ ]                              ↻  ▤   ← tab strip, one hairline under it
 ‹  iPhone 17 Pro  iOS 26.5            ↺ ↻ | ⌂ ▤ | ⎘ ▦   ⌖ ▤
    Resolution 1206 × 2622 · UDID 01D1D359          ← labelled facts, grey label + brighter value
──────────────────────────────────────────────────────────  ← no rule: `face` starts; tone is the edge
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

### Frames do not travel as state

At the 69.5 frames/s measured above, publishing each access unit as `@Observable` state rebuilt the
whole stage — header, toolbar, bezel artwork, and the console's up-to-600 rows — seventy times a
second, on the same main thread that has to dispatch the mouse events the user is making at that
moment. The frames were not the point of that work; the panel was being rebuilt as a side effect of
them arriving.

So `SimulatorFrameSink` carries them: the model writes into it, the mounted screen view registers
itself with it, and each access unit goes straight to the display layer. What stays observable is
`hasVideo` and `resolution` — things that change twice a stream, not seventy times a second.

Two details are load-bearing:

- **The replay is not optional.** The view mounts a beat after the socket opens, and `.id(selection)`
  builds a fresh one on every device switch; the parameter sets and the last keyframe arrive in that
  gap. So the sink holds exactly what a cold decoder needs — avcC, the seed, the most recent
  keyframe — and hands them over on attach. Without it a panel opened onto a quiet device sits black
  until the next IDR, which was measured at **one per eight-second idle window**.
- **Delta frames are never replayed**, and new parameter sets drop the held keyframe. Both are only
  meaningful against a reference the new layer never had.

An `@Observable` one-slot mailbox was measured before this change and does NOT lose frames at 70 Hz
in a trivial view tree (0 of 355; 2 of 461 at 120 Hz). Cost, not correctness, is the reason — do not
"restore" the old shape on the grounds that nothing was being dropped.

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

## A panel that is not on screen holds no sockets

Measured 2026-08-04, host mac-studio ↔ client macbook-pro, device idle at the springboard:

| with the Simulators tab hidden behind Files | before | after |
| --- | --- | --- |
| `baguette` TCP sockets to the client (`lsof -sTCP:ESTABLISHED`) | 2 (stream + log) | 0 |
| egress on those sockets (`nettop`) | 33 KB/s | 0 |
| client CPU | 5.4% of a core | idle |
| host `baguette` CPU | 2.3% of a core | idle |

Those are **floors**: a device at rest still re-encodes its idle screen, and a driven one was measured
earlier in this document at 2.1 Mbps. The cost was paid for a surface nobody could see.

The leak came from an asymmetry that is easy to rebuild: SwiftUI cancels a `.task` when its view
unmounts, but `SimulatorSidebarModel` is `@State` on `CodeSidebarColumn` and **survives the unmount by
design** — that is what keeps the selection and the poll cache warm across a tab switch. The polling
tasks stopped on their own; the two websockets, owned by the surviving model, did not.

So the model gets an explicit pair, driven from `.onAppear` / `.onDisappear` on `simulatorSurface`:

- `park()` drops the stream and log connections and clears `isLogStarted`, **keeping** `selection`,
  `isConsoleOpen` and the frame sink. The last keyframe stays in the sink on purpose — it is what
  `resume()` hands a cold decoder so the stage comes back with a picture instead of black.
- `resume()` re-dials the same device and, if the console was latched, its log socket. Idempotent by
  a `stream == nil` guard, and a no-op with no selection or no `.ready` address.

**A known-good address survives the remount.** `poll(...)` used to reset `phase` to `.starting`
unconditionally, so every return to the tab replaced the whole surface with *Starting simulator
server…* for one round-trip — a flash of a cold-start state on a server that had been up for hours.
It now keeps a `.ready` phase and only re-announces starting when it does not have one.

Pinned by four tests in `SimulatorSidebarModelTests` (both sockets dropped, device kept; console
re-latched on return; `resume` idempotent and selection-gated; `.ready` survives a remount).

### Two things that were measured and left alone

Both looked like obvious wins and both were false. They are recorded so the next sweep does not spend
the same hours:

- **Per-frame `@Observable` writes are not rebuilding the panel.** The worry was that writing an
  unchanged value (e.g. a resolution that has not moved) still wakes observers. It does not:
  `withObservationTracking` fired **20/20** on genuine changes and **0/20** on same-value writes to an
  `Equatable` property. A first probe reported 0 for both and was wrong — it re-armed tracking
  asynchronously, so a tight write loop slipped past the scope entirely. Any future probe here needs a
  fresh tracking scope per write plus a control arm that alternates values.
- **Input encoding is not on the critical path.** The gesture envelope encoder costs **5.31 µs**; at
  the 120 Hz ceiling of a trackpad that is **0.06% of a core**. Rewriting it buys nothing measurable
  and the latency it would chase lives in the network and the server.

---

## Motion

Added 2026-08-04 (user-directed). The panel had the design system's hover fades and nothing else: every
structural change in it — a device opening, a drawer arriving, a boot moving a row into another group —
happened between two frames. MERIDIAN spends its artistry budget on structure, typography and
**transient** motion, so the rule applied here is that **anything that changes the panel's structure
animates, and anything at rest does not**. No springs, no scale, no motion on text; every beat is one of
the `Slate.Anim` curves.

**The drill.** The list and the device are one surface at two depths, so the swap between them is a
navigation move rather than a cut. Both live in a `ZStack` in `CodeSidebarColumn.simulatorReadyContent`
— in a plain `if`/`else` inside the column's `VStack` the two would be laid out as stacked bands and the
outgoing view would squeeze the arriving one for the length of the fade. Each declares ONE symmetric
transition (offset + opacity), the stage's toward the trailing side and the list's toward the leading
one, so "in" and "out" are legible without either knowing which way the last move went. The shift is a
nudge (`space4`), not a page slide: a full-width push of a live H.264 surface spends 200 ms compositing
a video layer across the panel to say what a few points of parallax already say.

The animation is a **transaction at the call site** — `withAnimation(Slate.Anim.standard)` around the
selection write in `SimulatorDeviceList.enter(_:)` and in the header's back action — matching the tab
strip's `selectSurface`. The views declare transitions; they do not declare animations.

**⚠️ A flush on the way out costs the transition its picture.** The outgoing stage stays mounted for the
length of the drill, so `select(_:)` calling `SimulatorFrameSink.reset()` — which flushes the display
layer with `removingDisplayedImage: true` — spent that 200 ms fading out a device with its screen
switched off. `select(_:)` now calls `discard()`: same forgetting of the replay (parameter sets, seed,
keyframe), no flush. It is safe precisely because the stage keys its screen on the selection, so the
next device mounts a **new** layer that this sink has nothing to replay into. `reset()` stays for
`retry()`, where the same surface is reused and blanking it is the point. Verified frame-by-frame from a
`screencapture -v` recording: the device fades out holding its home screen while the list fades in over
it, ~0.2 s, no black frame.

**What else moves, and why each one is structural rather than decorative:**

| beat | curve | what would happen without it |
| --- | --- | --- |
| list ⇄ device drill | `standard` | a cut between two full surfaces |
| device list reflow (boot/shutdown/filter) | `standard` | a booting device teleports into `RUNNING` and every row below jumps |
| console drawer open/close | `standard` | the drawer already had `.transition(.move(edge: .bottom))` and **no animation to ride it** — it arrived in one frame and took the device's height with it |
| phase swap (`starting` → `ready` → …) | `standard` | server-boot → devices cuts hard |
| pending spinner ⇄ boot/stop verb | `smallFade` | the one acknowledgement a click gets, delivered as a redraw |
| banner / failure arrival | `smallFade` | *(retired the same day — reports moved to the app's notification; the rule it taught is below)* |
| header band appearing or leaving | `smallFade` | a device removed from the host takes the stage's top edge in one frame |
| plate press | `smallFade` | see below |

The reflow is keyed on the entry **identities**, not on the device array: a device whose `state` ticks
through `Booting` is the same row saying something new, and re-running a thirty-row reflow for it would
animate the list every second while nothing moved.

**⚠️ An inserted view cannot animate its own arrival.** Two of these were already written as
`.transition(...)` plus an `.animation` **inside** the conditional branch, which animates a text swap
between two live values and nothing else — every appearance and every dismissal stayed a hard cut. The
animation has to sit on a container that outlives the change: `headerLayer` in `SimulatorStageView`
exists for exactly that and for no other reason (its sibling `bannerLayer` did too, until the banner
itself was retired). The same rule is why the drawer's
long-standing `.transition` did nothing until a `withAnimation` transaction was put around
`toggleConsole()`.

**⚠️ `.move(edge:)` on an unclipped overlay travels the view's whole height.** The stage banner was an
overlay over the top bar, and a move transition climbed it out of the panel and across the tab strip on
its way in; `.offset(y:)` + opacity is the arrival cue without the trip. The banner is gone, the trap is
not — the drop highlight and any future overlay sit in the same unclipped position.

**The press beat.** `SlatePlateStyle` (in `SlateKit.swift`) draws the plate fill from the *button style*
rather than the label, because `isPressed` reaches a style and nothing else — and the alternatives, a
zero-distance `DragGesture` or a long-press sensor, take the events the row shells and scroll views
underneath these plates need. A press moves the plate one rung in the direction the click is about to
take it: a loose plate lights toward "on", a latched one drops toward "off" (`active != pressed`). Every
verb on these plates acts on a **remote** device, so without it the only acknowledgement of a click was
the device changing a round trip later. Both plate idioms and the stage's `Try Again` — until now the
one control in the panel with no response to the pointer at all — share it.

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
- ⚠️⚠️ **`swipe` and `tap` are not interactive verbs — see the cost table above.** Anything that can
  be expressed as `touch1-*` must be. This is not an optimisation; a scroll built on `swipe` accrues
  seconds of lag per second of use, and it looked like a network problem for a week.
- **A scroll event is already in the user's preferred direction — do not re-derive it from
  `NSEvent.isDirectionInvertedFromDevice`.** That flag reports the RAW device direction and is
  informational; AppKit has already applied the scroll-direction preference to `scrollingDeltaY`, so
  folding the flag in double-applies it, and a synthesized `CGEvent` reports it `false` whatever the
  setting says. Measured 2026-08-04 both ways against a live device: with the flag folded in, one
  gesture moved the device's list opposite to the way the same gesture moved a native scroll view in
  the same window. `scrollVector` passes the sign straight through.
- **A scroll DELTA needs the orientation; a scroll POINT does not.** SwiftUI hit-tests a rotated view
  in its unrotated local space, so a click already arrives in framebuffer coordinates — but a
  `scrollingDeltaY` never passed through the view's geometry, and the framebuffer never turns. Before
  `scrollVector` took `orientation`, a device held sideways scrolled sideways.
- **Do not replay macOS scroll MOMENTUM as finger movement.** The deltas that keep arriving after the
  fingers lift are the Mac's own inertia; iOS computes its own from the touch history at the moment of
  the `touch1-up`. Sending both scrolls twice. `SimulatorScreenView` drops every event with a
  non-empty `momentumPhase`.
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
  `SimulatorDeviceHeader` declares its `actions` view builder after `onBack` for the same reason.
- **A `.task` dies with its view; a `@State` model does not.** Everything the surface owns through a
  `.task` stops itself on unmount, so a socket held by the surviving model looks stopped and is not.
  Anything long-lived that the panel opens needs an explicit counterpart in `park()`/`resume()` — see
  *A panel that is not on screen holds no sockets* for what that cost while it was missing.
- **A view being INSERTED cannot animate its own arrival, and a view being REMOVED cannot either.** An
  `.animation` written inside the conditional branch covers value changes within a mounted view and
  nothing else; the transition needs an animation on a container that outlives the change. Two banners
  and a drawer in this panel each looked animated and each cut hard. See *Motion*.
- **Do not flush the frame sink on a device SWITCH.** The outgoing stage is still on screen for the
  length of the navigation transition. `select(_:)` uses `SimulatorFrameSink.discard()`; `reset()` — the
  one that blanks the layer — is for `retry()`, where the surface is reused.

---

## Where the code lives

| File | Role |
| --- | --- |
| `Simulator/SimulatorWireProtocol.swift` | pure decoder: envelope + avcC record |
| `Simulator/SimulatorInputEnvelope.swift` | pure encoder: every upstream JSON envelope |
| `Simulator/SimulatorDevice.swift` | pure decoder: `/simulators.json` |
| `Simulator/SimulatorEndpoints.swift` | the whole route table, pure |
| `Simulator/SimulatorScreenLayout.swift` | fitted rect ↔ device point, scroll vector, edge bands, pinch pair — pure |
| `Simulator/SimulatorVideoFormat.swift` | `CMFormatDescription` + `CMSampleBuffer` construction |
| `Simulator/SimulatorStreamConnection.swift` | the one socket (`NWConnection` + websocket) |
| `Simulator/SimulatorChrome.swift` | pure decoder: `definition.json` — body geometry + button boxes |
| `Simulator/SimulatorDeviceKind.swift` | product name → family (glyph, heading, sort rank), pure |
| `Simulator/SimulatorOrientation.swift` | the quarter-turn cycle + wire spelling + demo status bar, pure |
| `Simulator/SimulatorControlClient.swift` | every HTTP route (`URLSession`) |
| `Simulator/SimulatorChromeAssets.swift` | fetches the body + button art into `NSImage`s |
| `Simulator/SimulatorScrollGesture.swift` | scroll → ONE continuous `touch1` contact, with re-grip; pure |
| `Simulator/SimulatorFrameSink.swift` | the video path with SwiftUI taken out of it: direct delivery + cold-start replay, `reset` vs `discard` |
| `Simulator/SimulatorScreenView.swift` | `AVSampleBufferDisplayLayer` + mouse/scroll/pinch/edge/key mapping |
| `Simulator/SimulatorBezelView.swift` | the device: art, screen clipped into `screen.rect`, live buttons |
| `Simulator/SimulatorStageView.swift` | the streaming surface: top bar + device + drawer + drop target |
| `Simulator/SimulatorDeviceHeader.swift` | the panel's one top bar: back, name, measured facts, and the verbs |
| `Simulator/SimulatorConsoleView.swift` | the log drawer: level menu, filter, follow latch, rows |
| `Simulator/SimulatorLogLine.swift` | pure: compact-line parse, log envelope decode, the level set |
| `Simulator/SimulatorLogConnection.swift` | the console's socket (`NWConnection` + websocket) |
| `Simulator/SimulatorPlace.swift` | pure: coordinate parse / body / readout + the preset shortlist |
| `Simulator/SimulatorLocationPopover.swift` | the location picker: presets, field, clear |
| `Simulator/SimulatorDeviceList.swift` | the device list — Running, then grouped by family |
| `Simulator/SimulatorSidebarModel.swift` | the two loops, the selection, the one live stream, the console, the first-frame deadline, `park`/`resume` |

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
