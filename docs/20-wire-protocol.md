# 20 — Aislopdesk wire protocol (PATH 1 terminal + PATH 2 GUI video)

> **STATUS: CURRENT.** §1–8 document the **PATH 1** terminal byte pipeline implemented in
> `Sources/AislopdeskProtocol` (WF-1) over TCP. **§9 documents the PATH 2 GUI video path** (WF-9):
> a separate, plain-UDP protocol implemented in `Sources/AislopdeskVideoProtocol` (pure, cross-
> platform, unit-tested) and driven by `AislopdeskVideoHost` / `AislopdeskVideoClient`. PATH 2 is an
> entirely distinct protocol from PATH 1 — different transport (UDP vs TCP), different
> message set, its own version constant — and does **not** share PATH 1's `WireMessage`,
> `FrameDecoder`, or `Channel`.
>
> The PATH 1 description below begins with the original framing contract. Binding
> decisions it realizes: dual data/control channel + plain TCP + `TCP_NODELAY` + ET-style
> replay-buffer reconnect ([DECISIONS.md](DECISIONS.md), [17](17-native-feel-synthesis.md) §2,
> [18](18-risk-resolutions.md) H). The protocol module is **pure Swift, zero platform
> dependency** (no `Network`, no `Darwin`) so it builds for macOS + iOS and is unit-testable
> in isolation.

## 1. Channels (dual TCP)

A session uses **two** TCP connections, not one:

| `Channel` | Carries | Why separate |
|-----------|---------|--------------|
| `.data`   | `output`, `exit` (host→client); `input` (client→host) | The PTY byte hot path. |
| `.control`| `hello`/`resize`/`ack`/`bye` (client→host); `helloAck`/`title`/`bell` (host→client) | Lifecycle + sizing. |

**Rationale (Zellij lesson, [DECISIONS.md]):** a burst of PTY `output` on the data channel
must not delay a `resize`-ack or a disconnect intent. Putting control messages on their own
TCP connection keeps them head-of-line-independent from output bursts.

`TCP_NODELAY` is set on **both** sockets immediately after connect — this happens in
`AislopdeskTransport`, not in the protocol layer. (Nagle can add up to ~200 ms to single-keystroke
writes.) The framing and decoder are identical on both channels; `WireMessage.channel` is
advisory metadata stating where each message is expected to travel.

## 2. Framing

Every message on either channel is a single length-prefixed frame:

```
[ UInt32 big-endian: payloadLength ][ payload bytes ]
```

- `payloadLength` **excludes** the 4 prefix bytes — it counts only the payload.
- `payload = [ UInt8 messageType ][ message body... ]`.
- A `payloadLength` greater than **16 MiB** (`16 * 1024 * 1024`, `Aislopdesk.maxFramePayloadLength`)
  is rejected with `AislopdeskError.frameTooLarge(_:)` — we never allocate or wait for an
  implausibly large frame.

The body uses **manual binary encoding**. The keystroke/output hot path must **not** use
JSON or `Codable`.

### Streaming decode (`FrameDecoder`)

TCP is a byte stream with no message boundaries: one read may deliver half a frame, three
frames, or a frame split across many reads. `FrameDecoder`:

1. Buffers raw bytes via `append(_:)`.
2. On `nextMessage()`, reads the 4-byte prefix (waiting if fewer than 4 bytes are buffered).
3. Validates the prefix against the 16 MiB cap (throws `frameTooLarge` otherwise).
4. Waits — returning `nil`, **not** an error — until the full payload has arrived.
5. Slices out and decodes exactly one frame, leaving any trailing bytes buffered for the
   next call.

A partial frame is never an error; only a body that is too short for its declared message
type (`truncated`), an unknown type byte (`unknownMessageType`), or invalid contents
(`malformedBody`) are.

## 3. Endianness

**All** multi-byte integers are big-endian ("network byte order") on the wire:
`UInt32` length prefix, `Int64` seq, `Int32` exit code, `UInt16` cols/rows/pixels, `UInt16`
protocol version. The protocol provides its own tiny big-endian read/write helpers
(`BigEndian.swift`); no third-party dependency.

UUIDs (`sessionID`) are sent as their **16 raw bytes** in canonical order (not a string).

## 4. Message table

`messageType` is the first payload byte. Bodies are listed after the type byte.

| Type | Name | Direction | Channel | Body |
|------|------|-----------|---------|------|
| 1  | `output`   | host → client | data    | `Int64 seq` (BE) + remaining bytes = PTY output payload |
| 2  | `exit`     | host → client | data    | `Int32 code` (BE) |
| 3  | `input`    | client → host | data    | remaining bytes = bytes to write to PTY stdin |
| 10 | `hello`    | client → host | control | `UInt16 protocolVersion` + 16-byte `sessionID` (all-zero = NEW) + `Int64 lastReceivedSeq` |
| 11 | `resize`   | client → host | control | `UInt16 cols` + `UInt16 rows` + `UInt16 pxWidth` + `UInt16 pxHeight` |
| 12 | `ack`      | client → host | control | `Int64 seq` (highest contiguous output seq durably received) |
| 13 | `bye`      | client → host | control | (empty) |
| 20 | `helloAck` | host → client | control | 16-byte `sessionID` + `Int64 resumeFromSeq` + `UInt8 returningClient` (0/1) |
| 21 | `title`    | host → client | control | remaining bytes = UTF-8 window/title string |
| 22 | `bell`     | host → client | control | (empty) |

`protocolVersion` is currently **1** (`Aislopdesk.protocolVersion`). There is **no version
negotiation**: the host accepts **only** `protocolVersion == 1`. Any `hello` whose
`protocolVersion` differs is rejected outright with a generic `handshakeFailed`
(`HostTransport`); the host never offers or falls back to another version.

### Field notes

- **`output.seq`** is a **monotonic per-message index starting at 1** — *not* a byte offset.
  See §5.
- **`hello.sessionID`** all-zero (`WireMessage.newSessionID`) requests a brand-new session; a
  non-zero UUID requests resume of that session.
- **`resize`** pixel dimensions are `0` when unknown (cell-only resize); the host maps the
  fields to `TIOCSWINSZ`.
- **`helloAck.returningClient`** is decided **by the host** (see §5), not asserted by the
  client.
- **`title`** payload must be valid UTF-8; a non-UTF-8 body decodes to
  `AislopdeskError.malformedBody`.
- **`title` (21) and `bell` (22) are PRODUCED by the host**, by a non-destructive OSC/BEL
  sniffer (`HostTitleBellSniffer` in `AislopdeskHost`, wired into `HostSession`'s output relay).
  As the host relays the raw PTY byte stream it ALSO observes a copy of those exact bytes
  and emits these control messages:
  - **`title`** ← **OSC 0** (`ESC ] 0 ; <text> <term>`, icon + window title) or **OSC 2**
    (`ESC ] 2 ; <text> <term>`, window title), where `<term>` is `BEL` (`0x07`) **or** `ST`
    (`ESC \`). **OSC 1** (icon-name only) is deliberately ignored — it never sets the window
    title. Identical consecutive titles are coalesced (de-duped).
  - **`bell`** ← a **standalone** `BEL` (`0x07`) seen outside any escape sequence. A `BEL`
    that *terminates* an OSC string is the OSC's terminator and fires `title` (if OSC 0/2),
    **never** `bell` — the sniffer's state machine distinguishes the two structurally.

  The sniffer is **non-destructive** (the raw bytes are forwarded to the client unchanged —
  libghostty is the real terminal; the sniffer only observes) and **streaming-safe** (a true
  byte-at-a-time state machine that holds partial state across read chunks, bounds the
  buffered OSC payload to defend against an unterminated/hostile OSC, and re-syncs on a stray
  `ESC` without swallowing the next sequence's introducer). The client surfaces both as
  `AislopdeskClient.Event.title` / `.bell` (and the `aislopdesk-client` CLI / `TerminalViewModel`
  consume them). These ride the head-of-line-independent CONTROL channel and are **not**
  sequenced/replayed.

## 5. Seq / ack / replay semantics

The host assigns every `output` message a **monotonic `Int64` `seq` starting at 1** — a
per-message index, not a byte count. The replay buffer (implemented in `AislopdeskTransport`,
WF-2) retains un-acked `output` messages so a reconnect is lossless:

- The client sends `ack(seq)` carrying the **highest contiguous** seq it has durably
  received. The host may then release retained entries with `seq <= ack`.
- On reconnect the client sends `hello(lastReceivedSeq:)`. The host replays every retained
  `output` with `seq > lastReceivedSeq`, then resumes live streaming. The result is
  byte-exact resume **without tmux**.
- The host **decides `RETURNING_CLIENT`** (Eternal Terminal `Connection.cpp`): on a `hello`
  with a known non-zero `sessionID` it resumes + replays and answers
  `helloAck(returningClient: true)`; an all-zero or unknown id starts a fresh session
  (`returningClient: false`). `helloAck.resumeFromSeq` tells the client where replay began.

### Replay-buffer caps (WF-2, documented here for the contract)

- **64 MiB** retained-byte ceiling (`ReplayBuffer.maxBackupBytes`; ET `MAX_BACKUP_BYTES`).
- **4 MiB offline gate** (`ReplayBuffer.offlineGateBytes`): while the client is offline, once
  buffered bytes pass 4 MiB the host **pauses the PTY drain** (ET `SKIPPED`) instead of
  growing unbounded; below the gate it keeps buffering (`BUFFERED_ONLY`). A long background
  build must not overflow the buffer and silently lose output.
- Seq is **`Int64`** (ET proto2 used int32, which truncates on very long sessions).
- **No crypto layer.** WireGuard already encrypts; the buffer stores **raw bytes**. ET's
  `CryptoHandler` (libsodium secretbox + nonce reset) is deliberately **not** ported — do not
  reintroduce it ([18](18-risk-resolutions.md) H).

### Equivalence to Eternal Terminal

This design is **functionally equivalent to Eternal Terminal's byte-level `BackedWriter`
sequence number**, lifted from byte offsets to a per-message index. ET tags each chunk of PTY
output with a monotonically increasing sequence and replays the tail after the last
client-acknowledged sequence on reconnect (`recover(lastValidSeq)`); Aislopdesk does the same at
the granularity of one `output` message. The reconnect handshake (`hello.lastReceivedSeq` →
host replays `seq > lastReceivedSeq`) mirrors ET's reconnect path, minus the crypto handler,
over plain TCP inside the WireGuard tunnel.

## 6. Errors (`AislopdeskError`)

| Case | Meaning |
|------|---------|
| `frameTooLarge(Int)` | Length prefix exceeded 16 MiB; associated value is the claimed length. |
| `truncated` | A complete frame's body was shorter than its message type requires (distinct from a partial TCP read, which is not an error). |
| `unknownMessageType(UInt8)` | First payload byte is not a recognized type. |
| `malformedBody(String)` | Right-length body with invalid contents (e.g. bad UTF-8 in `title`); reason string attached. |

## 7. Public API (`AislopdeskProtocol`)

- `enum Channel { case data, control }`
- `enum WireMessage: Equatable, Sendable` — all cases above; `var messageType: UInt8`,
  `var channel: Channel`, `func encode() -> Data` (full frame, prefix + type + body),
  `static let newSessionID: UUID`.
- `struct FrameDecoder` — `init()`, `mutating func append(_ data: Data)`,
  `mutating func nextMessage() throws -> WireMessage?` (handles partial reads + multiple
  frames per append; **not** `Sendable`, lives inside one actor/task).
- `enum AislopdeskError: Error, Equatable, Sendable`.
- `enum Aislopdesk` namespace — `static let protocolVersion: UInt16 = 1`,
  `static let maxFramePayloadLength = 16 * 1024 * 1024`.

`WireMessage`, `Channel`, and `AislopdeskError` are `Sendable`; `FrameDecoder` is a non-`Sendable`
value type by design (it carries the receive buffer for a single connection/channel).

## 8. Channel association & session handshake (WF-2, `AislopdeskTransport`)

> This section documents how the two physical TCP connections of one session are tied
> together and how the `hello`/`helloAck` handshake runs. It is implemented in
> `AislopdeskTransport` (`HostTransport` / `ClientTransport` / `ChannelAssociation`). It
> does **not** change the framing (§2) or the message table (§4); the association
> preamble is raw bytes the transport peels off *before* the first frame.

### 8.1 Association preamble (per connection)

A session opens **two** TCP connections (§1). To bind them to one logical session,
each connection sends a tiny fixed preamble as its very first bytes, before any
length-prefixed `WireMessage` frame:

```
CONTROL preamble:  [ UInt8 0x01 ]                              (1 byte)
DATA    preamble:  [ UInt8 0x02 ][ 16 raw sessionID bytes ]    (17 bytes)
```

The discriminator byte (`0x01` control / `0x02` data) lets the host route a freshly
accepted connection without parsing a frame. The DATA preamble additionally carries
the authoritative `sessionID` (the same 16 raw bytes UUID layout used everywhere in
§3) so the host can attach the data connection to the right session.

### 8.2 Connect ordering (deterministic — no race)

1. **Client** opens the **CONTROL** connection, writes the control preamble (`0x01`),
   then sends `hello(protocolVersion, sessionID, lastReceivedSeq)`
   (all-zero `sessionID` = NEW; a non-zero id = resume request).
2. **Host** reads the control preamble, reads `hello`, and **strictly checks**
   `protocolVersion == 1` (any other value → `handshakeFailed`, connection dropped; no
   negotiation, no downgrade). It then **decides** NEW vs RETURNING_CLIENT (it, not the
   client, is authoritative — see
   §5 and Eternal Terminal `Connection.cpp`). It replies
   `helloAck(authoritativeSessionID, resumeFromSeq, returningClient)` on CONTROL:
   - unknown / all-zero id → mint a fresh id, `resumeFromSeq = 0`, `returningClient = 0`;
   - known non-zero id → echo it, `resumeFromSeq = hello.lastReceivedSeq`,
     `returningClient = 1`.
3. **Client** reads `helloAck`, learns the authoritative `sessionID`, then opens the
   **DATA** connection and writes the data preamble (`0x02` + that `sessionID`).
4. **Host** reads the data preamble and associates the DATA connection with the
   session it minted/resumed in step 2.

Because the DATA connection only opens *after* the client has the authoritative id,
the host can always associate it — there is no ordering race to resolve.

### 8.3 Reconnect / replay

On a RETURNING_CLIENT (step 2, known id) the host, once the new DATA connection
associates, **replays** `output` with `seq > hello.lastReceivedSeq` from the
session's `ReplayBuffer` **in order on the new data channel before live output
resumes**, then continues streaming. The first live `output` after replay carries
`highestSeq + 1`, so the client sees a contiguous, gap-free, dup-free seq stream
across the reconnect. Only `output` is sequenced/replayed; control messages are not.

The rebind is atomic on the host session actor: it swaps the data/control channels
and closes the old ones. A live `sendOutput` already suspended on the *old* data
channel when the rebind runs has its in-flight send cancelled by that close (the OS
reports POSIX `ECANCELED` 89). This is **not** a fatal fault and **not** byte loss —
the bytes were retained in the `ReplayBuffer` before the send and are only evicted by
a client `ack`, so they are re-sent by the rebind's replay loop on the new channel.
The host therefore treats a dead-channel send (channel swapped out, or a typed
`notConnected` / `.cancelled`/`.failed` state) as "client offline → replay on next
reconnect", retaining the bytes rather than throwing. **Symmetrically on the client**,
a DATA or CONTROL channel that finishes — whether by error *or* a clean FIN/cancel
(the reconnect-race half-close) — terminates the merged `inbound` and surfaces a
`.disconnected`, which drives the `ReconnectManager`: there is no mid-session clean
half-close the host intends, so a clean finish is always a disconnect that reconnects
(never a silent stall).

### 8.4 `AislopdeskTransport` public API (WF-2)

- `enum TransportParameters` — `static func makeTCP() -> NWParameters` (the single
  canonical params: `TCP_NODELAY` + keepalive, no app crypto, no interface pin).
- `protocol MessageChannel: Sendable` — `var channel`, `func send(_:) async throws`,
  `var inbound: AsyncThrowingStream<WireMessage, Error>`.
- `actor NWMessageChannel: MessageChannel` — one `NWConnection`, drives a
  `FrameDecoder`, surfaces `State`.
- `struct ReplayBuffer: Sendable` — pure logic: `append(bytes:) -> Int64`,
  `ack(upTo:)`, `messages(after:) -> [(seq, bytes)]`, `retainedBytes`,
  `isClientOnline`, `shouldPauseDrain` (4 MiB offline gate / 64 MiB cap; never drops
  un-acked data — backpressure via pause instead).
- `actor HostTransport` — `NWListener`; `start(port:)`, `boundPort`, `sessions_`
  (`AsyncStream<HostSessionTransport>`), `stop()`.
- `actor HostSessionTransport` — per-session `ReplayBuffer` owner; `sendOutput(_:)`,
  `sendControl(_:)`, `sendExit(code:)`, inbound `inboundInput`/`inboundResize`/
  `inboundAck`, and `drainPauses: AsyncStream<Bool>` (PTY-drain pause/resume).
- `actor ClientTransport` — `connect(host:port:resume:lastReceivedSeq:)`, merged
  `inbound`, `sendInput`/`sendResize`/`sendAck`/`sendBye`, `sessionID`/`resumeFromSeq`/
  `returningClient`.

---

# PATH 2 — GUI video transport (UDP)

> **STATUS: CURRENT.** Documents the wire format implemented in `Sources/AislopdeskVideoProtocol`
> (WF-9) and the transport topology realized by `AislopdeskVideoHost.NWVideoDatagramTransport` /
> `AislopdeskVideoClient.NWVideoClientTransport`. This is the secondary GUI video path (doc 17 §3,
> doc 18 measured spike config); it is **independent of PATH 1** — its own protocol over plain
> UDP inside the WireGuard tunnel, with NO TCP, no `WireMessage`, no `FrameDecoder`.

## 9. Path-2 overview

PATH 2 remotes one host GUI window: ScreenCaptureKit per-window capture (NV12) → VideoToolbox
HEVC encode → UDP datagrams (packetize + FEC) → VTDecompressionSession decode → Metal render,
with a client-side composited cursor and client→host CGEvent input injection. Everything is
**datagram-oriented** — there is no stream framing, no length prefix, no replay buffer. Loss is
absorbed by FEC and, when unrecoverable, by client→host recovery requests (LTR refresh → IDR).

`AislopdeskVideoProtocol.version` is a **`UInt16`, currently `1`**, separate from PATH 1's
`Aislopdesk.protocolVersion`. There is **no negotiation**: the host accepts a `hello` only when
`protocolVersion == AislopdeskVideoProtocol.version` (strict, mirroring PATH 1 §4); any other value
is rejected. All multi-byte integers are **big-endian**, exactly as PATH 1 (§3); the
sub-pixel geometry/cursor/input fields are big-endian IEEE-754 `Float64`. Each codec serialises
as `[UInt8 messageType][body…]` and is decoded defensively — a short or inconsistent **single
datagram** throws `VideoProtocolError.truncated` / `.malformed(_)` and is dropped, never
crashing the receiver.

## 9.1 Transport topology — two sockets, six logical channels

A session uses **two UDP sockets**, not one:

| Socket | Carries | Framing |
|--------|---------|---------|
| **media** | control, video, geometry, input, recovery | each datagram is prefixed with a **1-byte channel tag** (`VideoChannel.rawValue`) |
| **cursor** | cursor updates + cursor shapes | **bare bytes** (single-purpose socket, no tag) |

The cursor channel is split onto its own socket so pointer latency = RTT, fully decoupled from
the encode/decode pipeline and from video-burst head-of-line blocking (doc 17 §3.3) — the same
"don't let bulk traffic delay latency-critical control" rationale as PATH 1's dual TCP (§1).

`VideoChannel` (the 1-byte media-socket tag) — `enum VideoChannel: UInt8`:

| Tag | Channel | Direction | Payload (after the tag byte) |
|-----|---------|-----------|------------------------------|
| `0` | `control`  | both | `VideoControlMessage` (§9.2) |
| `1` | `video`    | host → client | one `FrameFragment` (§9.3) |
| `2` | `geometry` | host → client | `WindowGeometryMessage` (§9.5) |
| `3` | `cursor`   | host → client | *(logical id; physically carried on the dedicated cursor socket, untagged — §9.6)* |
| `4` | `input`    | client → host | `InputEvent` (§9.7) |
| `5` | `recovery` | client → host | `RecoveryMessage` (§9.8) |

> The `cursor` tag value (`3`) is reserved for completeness/symmetry; cursor datagrams physically
> travel on the dedicated cursor socket as bare bytes, so they carry no leading channel tag.
> Client→host recovery messages (§9.8) ride their OWN media-socket channel (`5`), **never** the
> `input` channel: a `RecoveryMessage`'s leading type byte (1/2/3) overlaps an `InputEvent`'s
> (mouseMove/Down/Up), so multiplexing them onto `input` would have the host mis-decode a recovery
> request as a phantom mouse event. The dedicated tag removes that ambiguity (no discriminator byte).

The enum is defined identically (byte-for-byte raw values) in both `AislopdeskVideoHost` and
`AislopdeskVideoClient`; the client cannot depend on the macOS-only host module, so it carries its
own copy. *(Candidate to hoist into `AislopdeskVideoProtocol` so one definition is shared.)*

## 9.2 Session bring-up — `VideoControlMessage` (control channel)

PATH 2 has no TCP handshake; a tiny control exchange runs over the UDP **control** channel
before any media flows. `[UInt8 type][body]`, big-endian:

| Type | Name | Direction | Body |
|------|------|-----------|------|
| `1` | `hello`    | client → host | `UInt16 protocolVersion` + `UInt32 requestedWindowID` + `Float64 viewportW` + `Float64 viewportH` |
| `2` | `helloAck` | host → client | `UInt8 accepted(0/1)` + `UInt32 streamID` + `UInt16 captureWidth` + `UInt16 captureHeight` + `Float64 boundsX` + `boundsY` + `boundsW` + `boundsH` |
| `3` | `bye`      | either | *(empty)* |

- `hello` announces the client, the host `CGWindowID` it wants to remote, and the client viewport
  size so the host can size capture/encode to the client surface.
- `helloAck` confirms (or rejects via `accepted = 0`) and reports the **host-decided** capture
  dimensions plus the window's current **CG top-left bounds** — the client's input-mapping origin
  until the geometry channel updates it. ("Negotiated" elsewhere in the code/comments means this
  single host-decides-and-reports step — the host sizes capture to the client viewport and reports
  it back — **not** a two-way negotiation; the protocol version itself is strictly non-negotiated,
  per §9 line 307 / §4.)
- The host starts capture/encode **only on an accepted `hello`**; a duplicate `hello` is re-acked
  idempotently. Either side sends `bye` for a clean teardown.

## 9.3 Video frame datagrams — `FrameFragment` (video channel)

An encoded HEVC frame (AVCC: length-prefixed NAL units, with the IDR carrying inline VPS/SPS/PPS —
the client self-configures its `CMVideoFormatDescription` from those parameter sets, no
out-of-band parameter exchange) is fragmented into datagrams ≤ **1200 bytes**
(`VideoPacketizer.maxDatagramSize`, doc 17 §3.6 to stay under MTU with WireGuard overhead).

**Fragment header — fixed 15 bytes, big-endian:**

```
off 0: UInt32 streamSeq    — monotonic per-datagram sequence (loss / ordering)
off 4: UInt32 frameID      — groups all fragments of one encoded frame
off 8: UInt16 fragIndex    — 0-based fragment index within the frame
off10: UInt16 fragCount    — total fragments in the frame (data + parity)
off12: UInt8  flags        — bit0 keyframe(IDR) | bit1 parity(FEC) | bit2 crisp(Session B)
off13: UInt16 payloadLen   — payload byte count that follows
off15: [payloadLen] bytes  — fragment payload (AVCC bytes, or FEC parity)
```

`streamSeq` is a monotonic per-**datagram** index (every emitted datagram, data and parity alike,
increments it) — the loss/ordering signal, analogous to PATH 1's per-message `output.seq` but at
datagram granularity. `frameID` is a monotonic per-**frame** index. `flags` bits:
`keyframe` (fresh decode anchor / IDR), `parity` (this fragment is FEC parity, not original data),
`crisp` (the frame came from the on-demand all-intra "crisp" Session-B encoder).

## 9.4 Forward error correction (FEC)

To absorb single-packet loss without a round trip, the packetizer appends **XOR parity**
fragments per frame (`XORParityFEC`, default `groupSize = 5` ⇒ ~20% parity, the Sunshine/doc-17
target). Each group of up to 5 data fragments yields one parity fragment = the byte-wise XOR of
the group, where each member is **length-prefixed (`UInt32` BE)** before XOR so recovery
reproduces the exact original length even when group members differ in size. Parity fragments
carry the `parity` flag and share the frame's `frameID`/`fragCount`.

Recovery fills exactly **one** missing data fragment per group (`parity XOR survivors`, then strip
the length prefix); **two or more** losses in a group are unrecoverable and left as a hole, which
the client escalates via §9.8 recovery requests. The `FECScheme` protocol lets a Reed-Solomon
codec replace XOR later without touching the wire header.

## 9.5 Window geometry — `WindowGeometryMessage` (geometry channel)

Host → client window move/resize/title so the client view repositions before the next frame
(doc 17 §3.8). `[UInt8 type][body]`, big-endian; coordinates are host CG-space **points**:

| Type | Name | Body |
|------|------|------|
| `1` | `move`   | `Float64 x` + `Float64 y` (new top-left origin) |
| `2` | `resize` | `Float64 width` + `Float64 height` |
| `3` | `bounds` | `Float64 x` + `y` + `width` + `height` (move+resize in one) |
| `4` | `title`  | remaining bytes = UTF-8 title (non-UTF-8 → `.malformed`) |

## 9.6 Cursor side-channel (dedicated cursor socket)

The host strips the cursor from the captured video (`showsCursor = false`) and streams it
out-of-band so it composites client-side at RTT latency (doc 17 §3.3). Both messages travel on the
dedicated cursor socket as **bare bytes**, told apart by their leading type byte
(`CursorChannelMessage` peeks the first byte to route):

**`CursorUpdate` (type `1`) — hot, position-only, fixed 36 bytes (< 64-byte budget), ~120 Hz:**

```
off 0: UInt8   type (=1)
off 1: UInt16  shapeID      — references a shape bitmap the client has cached
off 3: UInt8   visible (0/1)
off 4: Float64 x            — host-window-space point
off12: Float64 y
off20: Float64 hotspotX
off28: Float64 hotspotY
```

**`CursorShapeMessage` (type `2`) — rare bitmap, shipped once per new `shapeID`:**

```
off 0: UInt8   type (=2)
off 1: UInt16  shapeID
off 3: UInt16  width        — points (informational; the PNG is self-describing)
off 5: UInt16  height
off 7: Float64 hotspotX
off15: Float64 hotspotY
off23: UInt32  bitmapLength
off27: [bitmapLength] bytes — PNG-encoded cursor image
```

A single cursor PNG fits comfortably in one 1200-byte datagram, so the shape channel needs no
fragmentation. The client caches each shape by `shapeID` and composites it at
`position * videoScale − hotspot`, where `videoScale = layerSize.width / decodedSize.width`.

## 9.7 Input events — `InputEvent` (input channel, client → host)

Client→host input (doc 17 §3.9 / doc 05). Pointer positions are in **normalised window space
(0..1)** — the client never sends raw pixels, removing all pixel-vs-point ambiguity; the host maps
normalised → host-window-point via `CoordinateMapping`. Every event carries a `UInt32 tag` =
the value the host stamps on `eventSourceUserData`, so it filters its own self-injected events out
of the cursor / geometry watchers and avoids feedback loops (doc 18 §A). `[UInt8 type][body]`,
big-endian:

| Type | Name | Body (after type byte) |
|------|------|------------------------|
| `1` | `mouseMove` | `UInt32 tag` + `Float64 nx` + `ny` |
| `2` | `mouseDown` | `UInt32 tag` + `UInt8 button` + `UInt8 clickCount` + `UInt8 modifiers` + `Float64 nx` + `ny` |
| `3` | `mouseUp`   | *(same layout as `mouseDown`)* |
| `4` | `scroll`    | `UInt32 tag` + `Float64 dx` + `dy` + `Float64 nx` + `ny` |
| `5` | `key`       | `UInt32 tag` + `UInt16 keyCode` + `UInt8 down(0/1)` + `UInt8 modifiers` |
| `6` | `text`      | `UInt32 tag` + remaining bytes = UTF-8 text |

`button`: `0` left / `1` right / `2` other. `modifiers` bitmask: `shift 1<<0`, `control 1<<1`,
`option 1<<2`, `command 1<<3`, `capsLock 1<<4`, `function 1<<5`. `key` is for navigation /
shortcuts by host virtual keycode; `text` is the robust layout-independent Unicode-insertion path
(doc 05 §3) — the host attaches the unicode string to the key-**down** only.

## 9.8 Loss recovery — `RecoveryMessage` (client → host)

When the client detects an unrecoverable fragment loss (a frame hole FEC could not fill), it asks
the host to recover **without** the bandwidth/latency spike of a forced keyframe. Sent on the
dedicated **`recovery` channel (tag `5`)** of the media socket — never `input` (§9.1). `[UInt8 type]
[body]`, big-endian:

| Type | Name | Body |
|------|------|------|
| `1` | `ack`               | `UInt32 streamSeq` (highest contiguous datagram seq durably received — bounds the host's LTR-pin window) |
| `2` | `requestLTRRefresh` | `UInt32 fromFrameID` + `UInt32 toFrameID` (the lost frame range) |
| `3` | `requestIDR`        | *(empty)* |

Recovery **prefers an LTR refresh** (`requestLTRRefresh`): the client names the lost frame range;
the host invalidates the referenced long-term-reference frame and encodes the next frame against an
older still-valid LTR (`kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh`). The invalidation
direction is client→host (doc 17 §3.6). The client's `RecoveryPolicy` escalates to `requestIDR` if no
decodable frame arrives within ~**2 RTT** of the LTR-refresh request (`idrTimeoutRTTMultiple`,
default `2.0`; the escalation is driven off the client's loss-detection path against the smoothed
RTT estimate).

**Host handling (`RecoveryDatagramRouter` → `WindowCapturer.requestKeyframe()`):** the host routes a
`recovery` datagram to recovery handling (not the input injector). Today both `requestLTRRefresh`
and `requestIDR` map to a **forced IDR on the next captured frame** — a keyframe is always a correct,
if heavier, refresh; the dedicated LTR-refresh encode is a future optimisation. An `ack` advances no
window yet (no retransmit buffer) and is recorded for diagnostics. This re-anchors a loss-recovering
client immediately rather than waiting for the ~1 s heartbeat IDR.

## 9.9 Errors (`VideoProtocolError`)

| Case | Meaning |
|------|---------|
| `truncated` | A datagram ended before a fixed-size field could be read. |
| `malformed(String)` | A field held an out-of-range value (unknown message type, unknown channel/cursor/button tag, non-UTF-8 title/text); reason string attached. |

A corrupt single datagram is dropped (the error is caught at the receive boundary), never fatal —
UDP loss is the normal case PATH 2 is built to tolerate.
