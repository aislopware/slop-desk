# 63 — Stage G: the client transport becomes Rust

`docs/60-hostd-in-rust.md` §4 names this campaign and declines to scope it:

> **Stage G (separate campaign, not scoped here) — the client transport.** `Sources/SlopDeskProtocol`
> and `MuxNWConnection` survive stage F because the macOS/iOS clients still speak through them.
> Moving those behind `CSlopDeskFFI` is a linked-library port under `CLAUDE.md`'s lifetime rule, not
> a socket one, and it is what finally deletes the second copy of the codec.

This document is that scope. It is the last campaign between the tree and the goal `CLAUDE.md`
states as "Swift is AppKit/UIKit and nothing else": after it, the only non-UI Swift left is
marshalling faces over doors, and no wire, no socket and no codec is spelled twice.

## 1. What is actually still Swift, measured

Two targets, 7,398 lines, zero view-framework imports between them.

| target | lines | files | what it is |
| --- | --- | --- | --- |
| `Sources/SlopDeskTransport` | 3,437 | 18 | the client mux: connection, sub-channels, registry, admission, replay |
| `Sources/SlopDeskProtocol` | 3,961 | 19 | the wire: `WireMessage`, its codec, the mux envelope, the metadata verbs |

`SlopDeskProtocol` is 14/19 files already delegating to `slopdesk_wire` through `CSlopDeskFFI`; it
is the *second copy of the codec* docs/60 names — a marshalling face thick enough that the face is
itself a program. `SlopDeskTransport` is 9/18, and the six that are not are the ones that own a
socket.

A third target follows them rather than leads: `Sources/SlopDeskClient` (1,473 lines — the
`SlopDeskClient` actor, `ReconnectManager`, `EventBroadcaster`, `BoundedInputPipe`). Its decisions
are `rust/slopdesk-clientsession` already (`seq`, `gates`, `backoff`, `rtt`); what stays behind is
four tasks and an inbox. §6.

**Where it stands now.** The table above is the measurement this campaign was scoped against and is
left as written; after G.3 and G.4 the same three targets read 1,471 / 2,595 / 1,473 across 9 / 11 /
5 files. `SlopDeskTransport` lost the six socket files and kept the faces; `SlopDeskProtocol` lost
the host diagonal of three channels. Neither number is a remaining-work estimate any more — G.5 is,
and it names what is left of all three.

## 2. What is already Rust, and is not written twice

Nothing in this campaign starts from a blank file. The wire and the host end of the mux landed with
`docs/60`:

| crate | lines | what the client needs from it |
| --- | --- | --- |
| `rust/slopdesk-wire` `mux/` | 3,128 | `MuxFrame`, `MuxFrameDecoder`, `MuxEnvelope`, `ChannelTable`, `MuxFlowControl`, `admit`/`peer_close`/`poisoned` |
| `rust/slopdesk-wire` (rest) | — | `WireMessage` and its codec — the thing `SlopDeskProtocol` is a second copy of |
| `rust/slopdesk-hostnet` | 2,532 | `ByteLink`/`TcpByteLink`, `params`, `preamble`, `SubChannel`, `MuxConnection` |
| `rust/slopdesk-clientsession` | 913 | every decision one client session makes |

**`slopdesk_wire::mux::admission` is already role-generic.** `Role::{Client, Host}` is a field of
`Arrival`, and `admit`, `poisoned` and `peer_close` each branch on it with both arms already under
test. The client half of the *decision* layer was written when the host half was, and is exercised
by the same table. What has never been written is the client half of the *driver*: the dial, the
open-and-await-ack, and the refcounted pool over connections.

## 3. The one design decision: three crates, not two

`slopdesk-hostnet` holds seven modules, and five of them have nothing to do with being a host:
`link`, `params`, `preamble`, `subchannel` and the frame loop inside `connection` are what a mux
connection IS, in either direction. Only `listener` and `pending` are the responder's, and only the
`MuxEvent::Opened` arm of `connection` is.

So the split is by direction, at the seam that already exists:

```
rust/slopdesk-muxnet     link · params · preamble · subchannel · connection (role-generic)
        │                 …including open + openAck, which need the connection's own tables
        ├── rust/slopdesk-hostnet    listener · pending    (the responder)
        └── rust/slopdesk-clientnet  dialler · registry    (the initiator)
```

**Why not one crate holding both ends.** A client that links the listener links an accept loop it
can never call, and — the part that matters — the iOS client links it too, into a binary where
`TcpListener::bind` is a thing the platform will refuse. A dependency edge that exists only to be
dead is the kind of thing `CLAUDE.md`'s "pick by lifetime" rule exists to refuse.

**Why not `slopdesk-clientnet` depending on `slopdesk-hostnet`.** It would work and it would be a
lie: the name would assert a direction the code does not have, and the next person to read
`slopdesk-clientnet/Cargo.toml` would have to discover that "hostnet" means "the shared half" by
reading it. A rename that makes the graph honest costs one commit; a graph that reads backwards
costs every reading of it.

`MuxConnection` becomes role-generic by taking `Role` at construction and reporting
`MuxEvent::Opened` only for `Role::Host` — which is not a branch added but a branch *moved*, since
`admit` already refuses a peer-initiated open on the client arm (`admission.rs:154`).

## 4. The stages

Each stage lands green, and no stage leaves two implementations *shipping*. That is a weaker claim
than "every stage deletes its Swift in the same change", and the difference is one stage wide, so it
is stated rather than glossed.

**G.2 is additive and G.3 does the deleting.** The Swift the client mux replaces is reachable from
`SlopDeskClient`, `WorkspaceStore` and `ClientComposition`; deleting it before the door that
replaces it exists would leave the tree red across a stage boundary, which is not the same thing as
`demolish-in-one-pass`'s red *within* a change. So G.2 lands the crate and its tests linked by
nothing shipping — `docs/60` §5's carve-out shape, on the same bound and with the same honest
retirement: **if this campaign stalls, the correct move is to delete the unlanded crate, not to keep
two client transports.** G.3 lands the door, repoints every caller and deletes all 2,338 lines in
one pass. Every other stage deletes what it replaces in its own change, exactly as `CLAUDE.md`
requires.

### G.1 — split `slopdesk-hostnet` into `slopdesk-muxnet` + `slopdesk-hostnet`

Pure move, and the split's own test is one question asked of each of the seven modules: does it say
HOST anywhere. Two did — `listener` and `pending`, because a client dials rather than accepts and its
two halves are made together rather than parked apart — and they stayed. `link`, `params`,
`preamble`, `subchannel` and `connection` did not, and went to the new crate, along with
`PairedConnection`: it lived in `pending` only because the host is where a pair was assembled, and
the connection that CONSUMES it is now the thing on both ends.

`MuxConnection` gains a `role: Role` field, passed to the three `slopdesk_wire::mux::admission` calls
that were spelling `Role::Host` inline. It is not branched on anywhere — the asymmetry stays stated
once, in `admission`, and every property that sounds like it needs an `if` falls out of the ladder
instead: an open arriving at a client is `Admission::Drop(Ignored::OpenAtInitiator)`, so
`MuxEvent::Opened` cannot fire there; a refusal is only produced for a responder on DATA, so
`send_open_ack` is only reached from the arm the host reaches. `tests/role.rs` in the new crate is
those properties from outside, on real loopback sockets, with the host arm beside each client one so
a passing absence cannot be a frame that was never read.

No re-export facade: two of `slopdesk-hostnet`'s three dependents — `slopdesk-hostserver` and
`slopdesk-hostsession` — stop depending on it entirely and depend on `slopdesk-muxnet` instead, which
is the seam being real rather than asserted. `slopdesk-hostd` keeps both. `slopdesk-wire` becomes a
DEV dependency of `slopdesk-hostnet`, because nothing left in its `src/` decodes a frame.
`rust/slopdesk-invariants`'s `HOSTD_CRATES` gains the new crate — the bans that read it are
prohibitions, and a crate linked into hostd owes them whether or not the phone links it too. The
`justfile` gains `muxnet-test` in the `test` chain; `RUST_WORKSPACES` discovers the crate itself.

Deletes: nothing. Proves: the seam is where §3 says it is.

### G.2 — the initiator's half: open in `muxnet`, dial and registry in `clientnet`

The only genuinely new code in the campaign, and reading the Swift moved one piece of it across the
seam before a line was written. `openChannel`, the openAck rendezvous and the id allocator are
**methods on `MuxConnection`**, not on anything in `slopdesk-clientnet`: all three mutate the
connection's own tables and dispatch maps, and a second type reaching into them would need those
private fields to stop being private. That is also the Swift's own shape — `openChannel` lives on the
role-typed connection, and the registry only calls it. `open_channel` is the exact mirror of the
`send_open_ack` already in `muxnet`, and the `role` field from G.1 is what makes both safe to hold on
one type.

In `rust/slopdesk-muxnet`:

- **`open_channel`** — allocate an id, register both sub-channels, open both tables, send
  `channelOpen` on DATA. It does NOT wait for the ack, because the Swift does not: the host opens on
  the first `channelOpen`, so the pair is usable immediately and the *verdict* is a separate
  question. A failed send undoes the whole registration rather than leaving a ghost channel that
  keeps `live_channel_count` above zero forever.
- **No third `ChannelTable` for the allocator.** The Swift keeps one purely to hand out ids; here
  `tables.data.allocate()` is the allocator, which is what `ChannelTable` was written for — its
  `last_allocated` is monotonic and independent of the state map, so the eviction ring can never make
  it re-hand out a live id, and `reject` already documents that it accepts the transition from `Open`
  *because* the client marks a channel open optimistically before the frame is sent.
- **`await_open_ack(channel_id, within)`** — the host-authoritative resume verdict. Four Swift
  mechanisms (`openAckResults`, `openAckWaiters`, `nextOpenAckWaiterID`, the cancellation handler)
  collapse into one `Mutex<HashMap<u32, Option<OpenAck>>>` behind a `Condvar`: presence of a slot is
  the phantom-id discipline, `None` is a waiter's predicate, `Some` is a recorded verdict, and
  absence answers `refused` at once. Cancellation becomes the `wait_timeout` a blocking caller passes
  in — the `withThrowingTaskGroup` race in `MuxClientTransport` is one argument here.
- **The teardown owes the waiters.** `tear_down` and `close_channel` clear the map and wake it, which
  is Swift's `flushOpenAckWaiters` and the `closeChannel` prologue. Without it a client thread parks
  on a dead connection forever — the one correctness trap of this stage, since every other failure
  here is bookkeeping.
- **The one place this crate reads its role.** `open_channel` refuses at a responder, which is a
  guard on a SEND and so cannot live in `admission` — that ladder judges arrivals. The rule itself
  still lives once in the wire, as `Role::initiates_opens`, tied by a test to the
  `Ignored::OpenAtInitiator` arm that is the same fact seen from the receiving side. The crate docs
  name this branch rather than keeping the flat "no branch on role anywhere" claim G.1 could make.

In `rust/slopdesk-clientnet`:

- **`dial`** — two `TcpStream::connect_timeout`s, `params` applied, the two 17-byte preambles written
  (`0x03│id` on CONTROL, `0x04│id` on DATA). The mirror of `listener`'s accept-and-pair, minus the
  pairing map: the dialler *chose* the connection id, so there is no half-pair to park. The 34-line
  `withMuxConnectTimeout` task-group race exists because `NWConnection` parks in `.waiting` forever
  on an unreachable host and has no bounded connect; `connect_timeout` is that bound as an argument,
  and a half-built pair is closed by `Drop` rather than by a `catch` that must remember both sockets.
- **`ConnectionRegistry`** — the refcounted per-host pool. Five semantics survive: pin/unpin,
  single-flight build, dead-connection eviction, the in-flight acquire count, and teardown only when
  a connection is unpinned, channel-less and unclaimed. Roughly two hundred lines of `await`-
  reentrancy commentary do not: the identity-gates, the TOCTOU re-checks and the lost-update note are
  each about a suspension point that a `Mutex<HashMap<HostPort, Entry>>` does not have. The
  single-flight map stays, because `dial` is slow and the lock is not held across it.
- **`MuxAdmission`'s four-guard precedence** is `slopdesk_wire::mux::admission`'s already, so nothing
  in this stage re-derives it.

Two smaller things the stage settled. The socket options are now `slopdesk_muxnet::params::apply`,
called by both the listener and the dialler — `NWParameters` was ONE object configuring both ends, and
two copies could have drifted into a connection whose halves disagree about `noDelay`; what stays in
`listener` is the handshake read timeout, which a dialler has no phase for. And the connection id is
an ARGUMENT to `dial` rather than something it mints: `slopdesk-ids` states the rule as "no clock and
no randomness — every operation that needs a fresh id takes it as an argument", and a transport that
invented one would be the second place entropy enters this tree. The `justfile` gains
`clientnet-test`; `RUST_WORKSPACES` discovers the crate itself.

Deletes: nothing — see the staging note above. Proves: the initiator's half runs on real sockets
against the responder's, both halves of one `MuxConnection` type.

### G.3 — the FFI door: one handle, one callback

The connection is stateful, long-lived and owns threads, so it is `docs/55` §4b's handle
convention — the shape `SlopDeskHostSupervisor` had, with the same three obligations stated on the
door: the opaque context stays valid until `_free` returns, the callback is callable from any
thread (so the Swift handler hops to the main actor rather than touching UI where it lands), and it
does not re-enter `_open`/`_close` on the same handle.

What crosses is a decoded MESSAGE, not a frame — and that inverts one sentence this section used to
carry. While the socket was Swift's, a `channelData` frame's bytes were already in the caller's
receive buffer and the only thing worth crossing was the routing verdict (`docs/55` §4b: "a decision
says WHERE they go, and copying a chunk across a boundary to be told its channel id would be the
whole cost of the mux for nothing"). With the socket in Rust the buffer is Rust's, so the offset
shape has nothing to be an offset INTO. The callback hands over one `SlopDeskMuxInbound` record —
a kind, three scalars and at most two `(ptr, len)` views BORROWED for the duration of the call —
which is the same economics read from the other side: nothing is copied to be told what it is, and
the one payload that genuinely must cross (the PTY bytes, whose destination is the terminal) crosses
exactly once.

That record is also why the inbound half of G.4 is not built twice. Re-encoding a decoded
`WireMessage` back to frame bytes so that Swift's `WireMessageCodec` could decode it again would be
a marshalling face built in G.3 and deleted in G.4; the record IS the decode result, so G.4's
remaining work at this end is the outbound encode and the two verb-multiplexed codecs.

**Two Swift protocols survive this stage on purpose, and neither is mux code.** `ClientTransporting`
(97) is the seam 22 test files fake against — every suite in `Tests/SlopDeskClientTests` plus the
Connection/TerminalViewModel/Workspace/Metadata suites of `Tests/SlopDeskWorkspaceCoreTests` —
whose subjects are not ported until G.5, and `MessageChannel` (30) is the same seam for
`WorkspaceChannelClient`, which injects its transport precisely so the whole subscribe→apply→ack
loop is provable with no socket. Deleting either here would mean re-faking a Rust handle in 22
files for two stages and then deleting the fakes again. They retire with their subjects —
`ClientTransporting` in G.5, and `MessageChannel` whenever `WorkspaceChannelClient` is ported, which
is not a stage this document has scoped. **Read "with their subjects" strictly:** the sentence was
briefly written into §G.5's file list as though the workspace channel went with the pane session, and
it does not. `WorkspaceChannelClient.swift:53` builds `MuxControlChannel(transport)` and
`WorkspaceStore+WorkspaceMirror.swift:644` is the shipping construction, so the protocol and its one
conformer outlive this campaign; what G.5 retires is the *pane* session's use of the mux.

The handle is therefore CLASS-GENERIC rather than pane-shaped: the workspace document rides the
same mux at `channelClass == 1` (`docs/45` §5.1) and `WorkspaceChannelClient.Handle` is built from
a `MuxAcquisition` in production, so a pane-only door would strand that path behind a bridge the
demolish rule forbids. One `_open(class)`, one inbound record covering both lanes, one send door per
verb.

`slopdesk_channel_table_*` is **deleted** by this stage rather than extended: the table crossed as a
handle only because the connection above it was Swift. With the connection in Rust the table has no
foreign caller, and a handle whose far side went away is `docs/55` §4b's own retirement criterion.
`mux_admission.rs`, `mux_decoder.rs`, `mux_envelope.rs` and all but the flow CONSTANT of
`mux_flow.rs` go the same way. **`mux_header.rs` does not**: its caller is
`Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift`, which is PATH-2 (§5).

Deletes, as the census found them rather than as the first draft of this section guessed:

| Delete | Note |
| --- | --- |
| `Sources/SlopDeskProtocol/Mux/` — **seven** files, 888 lines | `BoundedQueuePolicy` `ChannelTable` `FlowCreditPolicy` `MuxChannelClass` `MuxEnvelope` `MuxFrameDecoder` `ReceiveWindowAccountant`. The eighth, `MuxFlowControl.swift`, is `git mv`d to `MuxVocabulary.swift` and rewritten — see below |
| `Sources/SlopDeskTransport/Mux/` — all but the face | `ConnectionRegistry` (316) `MuxAdmission` (171) `MuxByteLink` (34) `MuxNWConnection` (847) `MuxRouter` (53) `MuxRoutingCore` (63) `MuxSubChannel` (426) `NWMuxByteLink` (193) |
| `Sources/SlopDeskTransport/{ChannelAssociation,NWConnection+Async,PortValidation}.swift` | each internal, each with one caller inside the mux |
| 18 of `Tests/SlopDeskTransportTests/` + 6 of `Tests/SlopDeskProtocolTests/` (~4,200 lines) | including `Support/{Blocking,InMemory,Recording}MuxLink` |

Four types the first draft deleted wholesale have live callers OUTSIDE the mux, and each is
vocabulary rather than machinery — so each stays Swift, re-homed onto `MuxVocabulary.swift`, exactly
as G.4 keeps the `WireMessage` enum: `MuxChannelClass` (`WorkspaceStore+WorkspaceMirror.swift:657`),
`MuxCloseReason` (`SlopDeskClient.swift:312,731` and the *public* `hostChannelCloseReason` at `:915`),
and `MuxFlowControl`'s two constants, which are re-sourced from the surviving flow-constant door
rather than re-typed.

**Three of this section's census claims were wrong, and execution corrected them in place:**

- `SlopDeskTransportError.swift` does **not** die here. It has ~10 live callers outside the mux —
  `ConnectionViewModel`, four `SlopDeskClientTests` suites, `MacChromeSnapshotRender` and three
  `SlopDeskWorkspaceCoreTests` — so it is not "internal with one caller inside the mux". It retires
  with `ClientTransporting` in G.5, and the surviving `ConnectionRegistry.pin` throws it meanwhile.
- `MuxAcquisition` needed a REPLACEMENT, not just a delete. `WorkspaceChannelClient.Handle` is built
  from one, so deleting the struct with nothing in its place would have stranded the workspace
  channel. `Handle.init` now takes the `MuxClientTransport` itself and reads `openedChannelID`,
  which is one fewer value type on the path and the reason the deletion is not a bridge.
- `MuxFlowControl`'s surviving members are `maxDataMessagePayloadBytes` and
  `maxOutputFramePayloadBytes`, not the pair the first census named. `initialWindowBytes` died with
  `MuxConsumptionCreditTests`, its only remaining reader.

A fourth correction is scope, not census: `LiveMuxConnectionFactory` (`NWMuxByteLink.swift:98`) does
not become a face over `slopdesk_clientnet`'s dial — it is deleted outright. The Rust pool dials
internally, so `ConnectionRegistry()` takes no factory and its two production construction sites
(`ClientComposition.swift:151`, `slopdesk-client/main.swift:41`) lose an argument rather than gain a
face. That also removes the injection seam the old registry existed to offer; the Rust pool is
tested against real loopback sockets in `rust/slopdesk-clientnet/tests/` instead, which is the
stronger proof and the cheaper one.

A fifth is a consequence nobody wrote down: **`ConnectionRegistry` stops being `@MainActor` and
becomes `Sendable`.** The annotation was never a design choice — the Swift registry WAS the mutable
state (an entry map, a refcount, an eviction path), and the main actor was the lock its callers
already had. With the state in Rust behind its own `Mutex` the object is one immutable pointer, and
the annotation turns from free into load-bearing in the wrong direction: `SlopDeskClient`'s
`makeTransport` is a synchronous `@Sendable` closure that cannot hop, so a main-actor-only pool
could not serve the CLI, the workspace mirror or the pane factory without a second construction
path. All three lose an `await` instead. The pointer crosses in a `RustHandle`
(`Sources/SlopDeskTransport/Mux/RustHandle.swift`), which is the ONE place the `@unchecked Sendable`
claim is written down and reasoned about, rather than one escape hatch per use site.

Two smaller things execution had to fix to make that land, both latent before it:

- `Held` now holds the `ConnectionRegistry`. `slopdesk_mux_pool_free` requires every transport on the
  pool to be freed first — it closes and JOINS each connection's receive loops — and ARC releases an
  object's stored properties in no specified order, so a deallocating `MuxClientTransport` could have
  freed the pool before its own channel. One strong reference makes the ordering structural instead
  of a comment.
- `Duration` → milliseconds read only `components.seconds`, flooring every sub-second bound to zero.
  Harmless while the only caller passed 10 s; wrong the moment a test asked for 50 ms. It is
  `Duration.milliseconds` now, one spelling for the pool's connect timeout and the ack wait both.

`Tests/SlopDeskProtocolTests/FrameDecoderCursorTests.swift` is MIXED — `FrameDecoder` cases at
`:27,:37,:54` survive, the Mux cases at `:128–165` do not — so it is SPLIT, not deleted.

Six invariants rules name a subject this stage deletes and must be re-aimed rather than dropped:
`wire_codecs::mux_layer` (`:173`, which carries NO break-test today and gains one),
`hot_paths::one_frame_one_doorman` (`:487`), `cross_twins::four_cross_language_twins` (`:108`),
`path_confinement::an_unknown_mux_type_is_refused` (`:205`) and
`gate_health::every_ffi_door_is_opened_or_declared_deliberate` (`:54`). No "deleted Swift stays
deleted" list covers the client — `deleted_host_swift.rs` is hostd's — so a new rule module joins
`rules/mod.rs`, with its own break-test.

The remaining `MuxClientTransport.swift` (329) becomes the face that holds the handle, the way
`InputInjector.swift` did (`docs/60` §4). **It does not shrink, and this section's "~80 lines"
guess was wrong: it lands at ~450.** The reason is worth recording, because it is the shape every
later stage's face will take. A face over a *synchronous* door is small — `InputInjector` is a
method per verb. This one spans an `async` actor, a C callback that fires on a Rust thread, and an
ARC lifetime that must outlive both, so three of its four parts are not the mux at all: an `Inbox`
that turns two `@convention(c)` functions into an `AsyncThrowingStream`, a `Held` class whose
`deinit` is the only thing that may call `slopdesk_mux_transport_free`, and one send method per
verb because `ClientTransporting` has one. What actually went is the 2,338 lines BEHIND it. A face
that grows while its subject vanishes is the correct outcome; a face that shrank to 80 would mean
the seam moved rather than the implementation.

### G.4 — `Sources/SlopDeskProtocol` dissolves

`WireMessage`, `WireMessageCodec`, `FrameDecoder`, `WorkspaceChannelCodec`, `MetadataCodec`,
`MetadataVerb`, `ProgressState`, `ControlLine`. Every one is `slopdesk_wire`'s already; what is here
is the marshalling.

This is the stage that retires the debt `DECISIONS.md` 2026-08-13 opened for the wire codec, at the
client end. **3,961 lines**, of which the honest residue is the `WireMessage` enum itself.

**What the plan got wrong, and why.** It said "the encode/decode arms become one door each" — the
shape every earlier face took. G.3 had already made that shape unreachable. Once the socket moved
into `slopdesk-clientnet`, `slopdesk_mux_transport_send` took the FLAT RECORD directly and its
inbound callback lent one back, so nothing on the client's live path ever asked for bytes again. A
census found `WireMessage.encode()` with zero callers anywhere, `decode(payload:)` reached only from
`Tests/`, and `SlopDeskProtocol.FrameDecoder` constructed only in `Tests/`. A door pair whose sole
callers are the suites checking it works is not a face — so the DOORS retired too, the way
`slopdesk_ws_listen_port` retired with `PortValidation.swift`, and `slopdesk-ffi`'s
`frame_decoder.rs` (364 lines) went with them.

The first half landed as:

- **Deleted.** `FrameDecoder.swift`, `WireMessage.encode()`, `decode(payload:)` and their private
  machinery (`attempt`, `scratchArena`, `run`, `sessionIDByteCount`, `UUID.dataBytes` /
  `init?(dataBytes:)`); the `Channel` enum and `WireMessage.channel`, which nothing outside the
  module ever read because the socket a message rides is chosen by the sender that already holds
  one; `MessageChannel`'s `channel` requirement; `SlopDesk.swift`, whose two constants had no Swift
  reader left; `slopdesk_wire_message_encode`/`_decode`/`frame_decoder.rs` and their header
  declarations; and 15 Swift suites.
- **Kept.** `flatten` and `build` — spreading a Swift `enum` onto the flat record and putting it
  back is the one thing Rust cannot do for the UI — plus `wireByteCount`, which flow control debits.
  `Data.spanning` and `WireBuffer` moved to `CodecBytes.swift`, where their real users are.
- **The pin moved, and got stronger.** The four wire-message corpus keys went `EMITTED` → `FROZEN`:
  `rust/slopdesk-wire/tests/golden_vectors.rs` replays each pinned frame against its FIELDS,
  re-encodes and asserts byte-identity, and checks `wire_byte_count`. An emission can only ever
  agree with itself.
- **Two invariant rules re-aimed rather than dropped**, on `mux_layer`'s G.3 precedent: ban the
  drift where it would actually be written (a second frame buffer in the Rust receive loop) and pin
  the one copy positively, so the ban cannot go green by everything vanishing.

**The metadata half had the same fault under a different name.** `MetadataCodec` looked bidirectional
and was not. It carried an encoder AND a decoder for all thirteen structured verbs because `Sources/`
once held a host target that answered them in Swift; that target is gone, and the host half is
`slopdesk-hostd`'s over `rust/slopdesk-wire`. A per-door census settled it in one pass: every
`decode*` but three is reached from `MetadataClient.swift`, every `encode*` but three is reached only
from `Sources/slopdesk-corevectors/main.swift` and from suites fabricating host bytes. The line is
exactly the diagonal — **a client encodes REQUESTS and decodes RESPONSES** — and it is now a rule
rather than an observation.

The second half landed as:

- **Deleted.** Ten response encoders (`encodeProcessList`, `encodePortList`, `encodeDirListing`,
  `encodeGitStatus`, `encodeAgentSessionList`, `encodeAgentHookStatus`,
  `encodeClipboardReadResponse`, `encodeHostVitals`, `encodeServiceEndpoint`,
  `encodeCodeOpenDisposition`) and three request decoders (`decodeClipboardSet`,
  `decodeClipboardReadRequest`, `decodeCodeFontSpec`); the 13 C entry points behind them, with their
  header declarations; the list-encode helper and the `present:` arm of `ClipboardClip.lent`;
  `MetadataClient.readAgentSession(id:)`, whose own doc comment said it had no caller (the live
  inspector tails the transcript through `slopdesk-inspectord`); and four
  `Tests/SlopDeskProtocolTests` round-trip suites that duplicated `rust/slopdesk-wire`'s own.
- **Three value-type mirrors went with them.** `MetadataCodec.PortProtocol` and
  `PortInfo.portProtocol` had no reader outside their own test — a port row prints the number and the
  process, never the protocol — and `GitStatusPayload.noRepo` had none once the decode stopped
  re-deciding `hasRepo`. `AgentKind` STAYED: `OpenQuicklyModel.swift` switches on it.
- **One re-decision removed.** `decodeGitStatus` ended with `guard head.has_repo else { return
  .noRepo }`, a second answer to a question `decode_git_status` had already answered by returning
  `GitStatusPayload::no_repo()` without reading a further byte. Two answers can only ever disagree by
  one of them being wrong; the head is transcribed as-is now.
- **The fixture strategy is the repo's existing one.** Three `Tests/SlopDeskWorkspaceCoreTests`
  suites genuinely test client plumbing and need host-shaped bytes. They hand-spell them, the way
  `BigEndianFixtureBytes.swift` and `VideoWireFixtureBytes.swift` already do: a second SPELLER of the
  wire in `Tests/` is allowed, a second IMPLEMENTATION is not — which is precisely the distinction
  that keeping the encoders "just for the tests" would have lost.
- **`metadataCodecPayloads` went `EMITTED` → `FROZEN`**, for the reason the four wire-message keys
  did: the generator's encoders are gone. `rust/slopdesk-wire/tests/golden_vectors.rs` replays it
  against the pinned FIELDS and re-encodes byte-identically, which an emission cannot do.
- **The `payload_channels` rule split into a positive half and a ban.** The `Mentions` list is now
  the seventeen doors the client's own diagonal opens; a `Lacks` bans the other thirteen BY NAME. The
  ban is the load-bearing half — without it the host encoders grow back one verb at a time, each one
  justified by a test that wanted bytes.

**The workspace channel owed the same census, and it did not answer by symmetry.** The diagonal is
there — a client encodes subscribe/presence/intent and decodes roster/intentResult — but it has one
real crossing that the metadata channel does not: `LoopbackWorkspaceDocument` is a HOST, a
client-local one, serving the intents of a workspace that never leaves the process. So
`WorkspaceIntentResult.encode` is host-shaped and LIVE, and the ban had to be four names rather than
a direction. A pass that "finished the diagonal" would delete the loopback's only way to answer,
which is why both the rule and the codec's own doc comment say so out loud.

The workspace half landed as:

- **Deleted.** `WorkspaceSubscribe.decode`, `WorkspacePresenceUpdate.decode`, `WorkspaceIntent.decode`
  and `WorkspacePresenceRoster.encode` — the widest marshalling in the file, three flat arrays and an
  interned label pool — with the four C entry points behind them.
- **Two bounds went with them.** `WorkspacePresenceRoster.maxRecords` had no reader at all: the
  decode sizes its slots off the payload, so the cap was the encoder's and the encoder was the
  host's. `WorkspaceSubscribe.maxLabelBytes` lost its last reader with the decode it bounded — the
  crate caps the label at both ends and the number is not respelled here.
- **One generic helper dissolved.** `WorkspaceChannelCodec.decode(_:arenaBytes:…)` existed for the
  subscribe decode alone; the roster is the one arena-filling decode left and it allocates three
  record lists as well, so it never went through a helper.
- **The tests took the fixture route again**, writer AND reader this time: a roster body is spelled
  for the four sites that feed one into the live decode, and a hand-spelled reader answers the ten
  that assert on FIELDS of what the client put on the wire — where byte-equality would over-specify,
  because the client mints the UUIDs and the presence clock.

**What is left of `Sources/SlopDeskProtocol`, censused rather than assumed.** G.4's finish line is
§6's — marshalling faces over doors — not an empty directory, so the eleven surviving files were read
one by one and ten of them clear that bar. `WireMessageCodec` and `WireMessage` are the flatten/build
marshalling between the enum the UI switches on and the flat FFI record, one arm per type byte.
`MetadataVerb`, `MuxVocabulary`, `ProgressState`, `WatchNotificationMarker`, `CodecBytes` and
`SlopDeskError` are vocabulary, faces and one shared buffer helper, each with live callers.

The eleventh is not. **`ControlLine.swift` is a hand-written NDJSON grammar with no door behind it** —
`JSONSerialization` in, `.sortedKeys` out, and a string literal for the encode-failure case. Its
three call sites are all in `Sources/SlopDeskWorkspaceCore/Control/ClientControlDispatcher.swift`,
and `rust/slopdesk-clientctl` already owns that lane's method vocabulary, its tokens and its NDJSON
codec. So it is not protocol residue at all: it is the client control lane's codec, filed one module
too low, and it retires with that lane rather than with this stage. **G.6 took it**, along with the
lane — see the section below.

### G.5 — the CLI, `Sources/SlopDeskClient` and the last of `Sources/SlopDeskTransport`

`Sources/slopdesk-client/main.swift` (552) is the last Swift executable in the tree that is not an
app shell. It is not ported ahead of G.2–G.4 on purpose: written today it would be a second
implementation of the client session, which is the exact trap the one-implementation rule names. On
the far side of G.4 it is a thin `main` over crates that already exist, and it becomes
`rust/slopdesk-cli`'s subcommand or its own bin.

`Sources/SlopDeskClient` follows: `ReconnectManager` (281) is `slopdesk_clientsession::backoff`
plus a thread, `EventBroadcaster` (79) is an `mpsc` fan-out, `BoundedInputPipe` (118) is a bounded
channel whose only consumer is the CLI. `SlopDeskClient.swift` (984) is the four-task driver, and
what survives it is the face that holds the handle.

**The order inside the stage is driver first, CLI second, and the reason is who else calls it.**
The paragraph above reads as though the CLI leads because it is the executable, but
`git grep -lE '^import SlopDeskClient$' -- Sources` names seven files and only one of them is
`main.swift`: `ConnectionViewModel`, `ConnectionPresenter`, `TerminalViewModel`, `TerminalBlockModel`,
`LivePaneSession` and `WorkspaceStore` drive the same actor from the app. So the driver is not the
CLI's private engine that a Rust `main` could quietly replace — it is the app's pane session, and
porting it is the stage. The CLI is what falls out afterwards.

#### The crate: `rust/slopdesk-clientdriver`

`slopdesk-clientsession`'s own module doc refuses the job in its second sentence — *"`SlopDeskClient`
owns a transport, four background tasks, an output inbox and a multicast event hub. None of that is
here."* That refusal is load-bearing and stays: the crate is `forbid(unsafe_code)` pure integer
policy, linked through `slopdesk_pane_session_*` and `slopdesk_pane_backoff_*` doors by an iOS slice
that wants the verdicts and not a runtime. Folding a tokio driver into it drags the runtime into
every consumer of the pure doors.

The host end already made this exact carve and named both halves. `rust/slopdesk-muxsession` is the
decisions of one hostd pane session; `rust/slopdesk-hostsession` is *"the SHELL around them — the
threads, the locks, the queues and the ladders"*. The client end has the decision half and has never
had the shell, so G.5 adds it: **`slopdesk-clientdriver`, the driver half of one client pane
session**, standing to `slopdesk-clientsession` exactly as `slopdesk-hostsession` stands to
`slopdesk-muxsession`. It is not `slopdesk-clientnet`, which §3 scoped by DIRECTION to the mux
connection — dialler and registry — and which the driver sits above rather than beside.

#### What crosses, and what stays Swift

G.3's shape holds: one handle, one callback. The driver owns the transport, the four tasks, the
inbox and the event hub; the face holds an opaque pointer and a `@Sendable` callback the driver
calls with each event. Output bytes keep the batched path the actor already has — `outputWakeups`
wakes the reader, `takeOutputBatch` drains — so the hot path stays one copy across the boundary and
does not become one call per chunk.

`SlopDeskClient` the Swift type survives with its public surface intact, because the surface is
dictated by those six WorkspaceCore callers rather than chosen here: `Event`, `events`,
`outputWakeups`, `takeOutputBatch`, `connect`/`pause`/`resume`/`close`, the four send verbs, the
`setSurfaceFeed` seam and the read-only flags. Everything behind them goes.

**`ClientTransporting` (97) does not survive, and that is the point of it.** The protocol exists so
the driver can be handed a fake, and once the driver is Rust a Swift fake would be a second
implementation wearing a test's clothes. What the app's own suites fake after G.5 is the face's
EVENT SOURCE — a driver that is told what to emit — not a transport underneath a Swift driver that
no longer exists.

#### `Sources/SlopDeskTransport` dissolves with it, and four files leave by three other doors

Five of its nine files are the session's and go behind the door: `MuxClientTransport` (491),
`ConnectionRegistry` (145), `ClientTransporting` (97), `SlopDeskTransportError` (89) and `RustHandle`
(21).

**`ReplayBuffer` (441) does not wait for the door — it has no shipping caller at all, and went
first.** The census that put it in the list above read "the only non-doc-comment hit is
`SlopDeskClient.swift`"; the grep that settles it —
`git grep -nE "ReplayBuffer[(.<]" -- Sources | grep -v '//'` — answers three lines, all of them
inside `ReplayBuffer.swift` naming its own static caps. `SlopDeskClient.swift` mentions the type in
two doc comments and nowhere else, because what it describes is the *host's* buffer, on the far side
of the wire. So the class was not transport residue awaiting a port: it was a 441-line Swift face
over `slopdesk_replay_*`, reached by nothing but the two suites written to reach it, ever since
hostd became Rust and started calling `slopdesk_wire::replay` directly. That is the
one-implementation rule's own failure mode rather than this stage's, so it retires ahead of the
driver, together with `rust/slopdesk-ffi/src/replay.rs` (1,106 lines of door), its 89-line header
block, and the two suites — after every behaviour they pinned that the crate did not was pinned in
`rust/slopdesk-wire/src/replay.rs`, where the buffer actually lives. `cross_twins`'s three
loop-shaped claims about it widen into one ban on the whole `slopdesk_replay_` prefix.

**`MessageChannel` (26) survives, and the file list above said otherwise until it was checked.** §G.3
already recorded why — it is the seam `WorkspaceChannelClient` holds — and the grep confirms the
wiring is live: `WorkspaceChannelClient.swift:53` builds `MuxControlChannel(transport)`, the
conformer declared inside `MuxClientTransport.swift`, and `WorkspaceStore+WorkspaceMirror.swift:644`
is the shipping construction. The workspace channel is not this stage's subject, so the protocol and
its one conformer keep a thin channel face over the mux doors; a G.5 that swept them up would take
the workspace mirror's transport out from under it. What retires with the driver is the *pane*
session's use of the mux, not every use.

The last two never belonged to the mux and must not be deleted with it:

- **`TransportParameters` (78)** is the module's last `import Network`, and its three shipping
  callers are `CodeSidebarProxy`, `AndroidBridgeSocket` and `SimulatorStreamConnection` — the
  code-server proxy, the Android bridge and the simulator stream, all §5 lanes. It moves to
  `Sources/SlopDeskNet`, where the `NWConnection` lanes already live.
- **`AltScreenCutScanner` (83)** is a face over `slopdesk_altscreen_reopen` whose one shipping caller
  is `SlopDeskDevicePanels/Android/AndroidControlMessage.swift`. It moves there, with its suite.

#### The CLI

`slopdesk-posix` already holds every syscall the interactive mode needs, and holds them for this
binary specifically: `rawmode::enter`/`restore`/`restore_on_signals` is the termios save-and-restore
including the signal paths, and `rawmode`'s doors in `slopdesk-ffi/src/tty.rs` say so out loud —
*"the raw-mode trio is `slopdesk-client`'s, a macOS command-line binary"*. A Rust CLI calls the crate
directly, so `slopdesk_tty_enter_raw`, `slopdesk_tty_restore` and
`slopdesk_tty_install_restore_on_signals` lose their only caller and retire in the same change. That
is the whole reason the CLI is cheap on this side of the driver: arg parsing, a raw-mode guard, two
byte pumps and a SIGWINCH resize, over crates that exist.

It lands as its own bin rather than a `slopdesk` subcommand: the shipped name `slopdesk-client` is
what `SubprocessE2ETests` execs and what `docs/49`'s pipeline signs, and a rename is a release-facing
change this stage has no reason to make.

#### The test migration is the bulk of the stage

Twelve suites under `Tests/SlopDeskClientTests` drive the actor through fake transports — `Dedup`,
`DetachResume`, `ReconnectRace`, `ReconnectInbox`, `ReconnectGiveUp`, `ReconnectClosed`, `BatchDrain`,
`Blocks`, `RTT`, `ExitTerminal`, `Smoke`, `BoundedInputPipe`. Every one of them pins driver
behaviour, so every one of them lands in `slopdesk-clientdriver` against a fake `ByteLink`, which is
the stronger pin: the Swift versions could only reach the driver through a protocol the driver
itself defined. `Tests/SlopDeskTransportTests` follows the files it covers — the seven that cross go
to the crate, `TransportParametersTests` and `AltScreenCutScannerTests` move with their subjects.

`SubprocessE2ETests` launches the shipped `slopdesk-client` binary; it is re-pointed at the Rust one
in the same change, which is what keeps the crown-jewel end-to-end proof pointed at the thing that
ships.

#### What execution corrected, and what it found that this section had not planned for

**One double replaced eleven.** The section says the app's suites fake "the face's EVENT SOURCE",
and they do — but it did not say how many doubles that is. Eleven bespoke `ClientTransporting`
actors became ONE `FakePaneDriver`, and the reason is the point of the whole stage: each old double
re-implemented an inbound stream, a session id, a resume-from-seq and a set of no-op sends, and each
one, being a transport under a Swift session, quietly re-decided a little of what the session did.
There is nothing left to re-decide, so a double at `PaneDriving` can only SAY what arrived. It is a
`final class` with a lock rather than an actor, because `PaneDriving` is SYNCHRONOUS by design and
an actor cannot conform to a synchronous protocol without every method becoming a hop the real one
does not have.

**One test's PROPERTY changed, and it is the one worth recording.** With the campaign inside the
driver, a plain link drop leaves it RUNNING — so the pane reads `.reconnecting` and the store's
fan-out is right to leave it alone, because the recovery is already in flight inside the driver that
still holds the session. A host RETIREMENT gates the campaign, so the pane reads `.disconnected` and
stays there, and the fan-out dials it. The distinction `HostRetiredPaneRedialTests` is about
survives whole; which SIDE does the recovering is what moved, and the suite was rewritten to assert
the new property rather than patched to keep asserting the old one.

**Two crates gained a type each, both to stop a second spelling before it was written.**
`slopdesk-clientnet::registry::DiallingPool` is the shipping dial closure — mint an id, `establish`,
drop the event receiver, keep the join handles — written once for the two owners that exist, the FFI
pool and this CLI. `SlopDeskMuxPool` is one field now and holds no closure.

**Twenty doors retired, not three.** The section names the raw-mode trio; the count is higher and
the reason is the same each time — a door whose far side went away.

| Retired | Its only caller was |
| --- | --- |
| `slopdesk_tty_enter_raw` · `_restore` · `_install_restore_on_signals` · `_window_size` · `slopdesk_fd_write_all` (`tty.rs`, whole) | `Sources/slopdesk-client/main.swift` |
| Sixteen of the eighteen `slopdesk_pane_session_*` / `slopdesk_pane_backoff_*` (`session_marks.rs`) | `SlopDeskClient.swift` and `ReconnectManager.swift` |
| `slopdesk_mux_transport_send_input` · `_note_consumed` | the PANE's use of the mux handle |
| `slopdesk_pane_driver_is_connected` | nothing — it shipped unasked |

`session_marks.rs` SURVIVES with two doors, and which two is the interesting part: both are asked
BEFORE any driver exists. `slopdesk_pane_backoff_default` answers the shipped schedule, which
`SlopDeskClient.Backoff` presents as three defaults and hands straight back across
`slopdesk_pane_driver_new`'s config; `slopdesk_pane_backoff_max_attempts` is the give-up ceiling,
which the chrome needs for "attempt N of M" WHILE a campaign runs, so it cannot wait for the
`GaveUp` event that would report it.

**The E2E suite moved with its subject, and its one environment variable is NOT the one the name
suggests.** `SubprocessE2ETests` launched `slopdesk-hostd` and `slopdesk-client` as subprocesses; both
are cargo binaries now, so it is `rust/slopdesk-client/tests/subprocess_e2e.rs` — the crate that OWNS
the client binary, where `CARGO_BIN_EXE_slopdesk-client` names the thing under test instead of a
hand-spelled path. hostd is a separate workspace and no `CARGO_BIN_EXE_*` reaches it, so its path
arrives in `SLOPDESK_E2E_HOSTD_BIN`, which `just client-e2e` sets after building it; unset, every
scenario prints why it proved nothing and returns green, the way `XCTSkip` did. The variable is
deliberately not spelled `SLOPDESK_HOSTD_BIN` — `docs/46` records that name as having NO reader and
the absence is the claim there, so a harness that started reading it would quietly delete a
documented invariant.

**Two files left `SlopDeskTransport` without being ported, and that is the right answer for both.**
The section scopes G.5 as "the last of `Sources/SlopDeskTransport`", and what was actually last there
was not transport. `TransportParameters` is the ONE place a Swift `NWConnection` gets TCP_NODELAY and
the keepalive ladder, and every caller it has left — the loopback code-sidebar proxy, the Android
bridge, the simulator stream — is a socket built beside `SlopDeskNet`'s byte channel, not beside the
mux, whose sockopts became `slopdesk_muxnet::params::apply`'s at G.3. `AltScreenCutScanner` is a
marshaller over `slopdesk_altscreen_reopen` with exactly one caller, `AndroidControlMessage`. Neither
is portable — one builds an `NWParameters`, the other IS the call — so both MOVED: to `SlopDeskNet`
and to `SlopDeskDevicePanels/Android/` respectively, the scanner dropping `public` on the way, since
a face with one caller in one module should not widen that module's surface.

The move is worth more than the tidying. `SlopDeskDevicePanels` no longer names `SlopDeskTransport`
at all — neither the target nor its suite — so the panels graph is one edge narrower and the mux face
has one fewer dependent to answer for. What is left under `SlopDeskTransport` is the mux face and
nothing else: `ConnectionRegistry`, `MuxClientTransport`, `RustHandle`, the `MessageChannel` protocol
the inspector and the workspace channel are both spelled against, and the error those two throw. The
target keeps a name that no longer describes it, and renaming it is deliberately NOT this stage's
change — the shape a later stage deletes wholesale is not improved by being renamed first.

**Two invariants rules moved rather than retired**, and the distinction matters. `client_session`
used to read two Swift files for door names; its subject did not change — one place decides, and the
shell may not decide it twice — only the language the caller is written in did, so it names Rust
call sites in `slopdesk-clientdriver` now. Its two Swift bans SURVIVE and are worth more than
before: a mark kept as a Swift `var` is two boundaries from the call it would disagree with rather
than one. `deleted_client_swift` gained a G.5 vector for the six paths above and a positive claim
that `PaneDriving.swift` still ASKS its four doors — because a ban list alone is green on a tree
where the face grew the driver back inside itself.

### G.6 — the client control socket, whole

G.4 named `ControlLine.swift` as a codec filed one module too low and deferred it to "the lane it
belongs to". This is that lane, and taking it turned out to mean taking the SOCKET, because the codec
was never the interesting half.

**What was there.** Five Swift files and two Rust modules, for one socket. `ClientControlServer`
(296) bound the `AF_UNIX` path, ran an accept loop, ran a per-connection `read(2)` loop, split on
newlines, capped the line, guarded UTF-8 and hopped to the main actor. `ClientControlDispatcher`
(343) parsed the line into `(id, method, params)`, switched on the method STRING through fourteen
cases, read `[String: Any]` params one `as? String` at a time and built a `[String: Any]` result.
`ControlRequestRules` (182) held the cap, the twenty refusals and two of the validators as a face
over `slopdesk_ws_ctl_*`. `ClientControlProtocol` (202) held the method table and three token
parsers as another face over the same prefix. `ControlLine` (50) was the codec. On the Rust side,
`slopdesk-workspace::control_request` (607) held the judgements and `slopdesk-ffi` exported nine
doors for the two faces to read them through.

**Why nine reader doors was the wrong shape, and not a small one.** Every one of them answered a
QUESTION about the socket — what are the methods, what does this token mean, how long may a line be,
why is this send-keys refused — so that Swift could then make the decision. That is a boundary drawn
in the middle of one subject. It costs a door per question, it costs a face per door, and it leaves
the actual dispatch in the language that is supposed to be doing presentation. The two faces were
not marshalling in `docs/60` §6's sense; they were a second implementation reading its constants
from the first.

**What is there now.** `rust/slopdesk-clientctl` grew three modules and became the socket:
`request` (the decoder — trim, cap, parse, validate, and the twenty-case `Refusal` moved over from
`slopdesk-workspace`), `reply` (the encoder, with a golden pinning twelve exact response lines) and
`serve` (the `UnixListener`, the accept loop, the framing, and a `ControlClient` trait for whoever
answers). The CLI already linked this crate to BUILD its requests; now it links the same crate that
DECODES them, so the agreement between the two ends is a round-trip test — `every verb the CLI
builds decodes to the op it meant`, fourteen cases — rather than a resemblance a gate has to check.
The byte goldens stay beside it, because a round trip cannot catch version skew and a literal can.

**The FFI is one door and one callback.** `slopdesk_client_ctl_serve` binds and starts accepting;
every decoded request calls back into Swift with two opaque handles, a request to read and a reply
to fill. Nothing on the request can be malformed — the decoder refused every line that was — so the
accessors are total: a verb INDEX, a text field with an absent-vs-empty flag, a flag, a number, and
the named keys. The reply takes typed pushes. A callback that fills nothing leaves the request
refused as an unknown method BY NAME, which is the honest answer for a well-formed request this
build has nowhere to send. The connection thread parks in the main-actor hop, which is why the
handles can be valid for exactly the callback and never after — the same lifetime `slopdesk_pane_driver_*`'s
forwarders have, for the same reason.

**Teardown does not join, and the context is therefore immortal.** Every other `*_free` in this
header joins its forwarders and hands the context back; this one cannot. A connection thread inside
the callback is parked on the MAIN ACTOR, and `stop()` runs on the main actor — `deinit` at quit is
exactly that — so a joining free would wait on a thread waiting on it, which is the one deadlock the
semaphore hop is shaped to avoid. The other end of that trade is stated rather than hidden: the
connection threads are detached, `slopdesk_client_ctl_free` stops the listener and unlinks the path
without claiming anything about who is still running, and Swift's `Unmanaged.passRetained` box is
never released. One object, once, for a socket bound once per process — against a release racing a
callback that is already reading the pointer.

`Sources/SlopDeskClientCore/Control/ClientControlHost.swift` is what is left in Swift: a bind, a
`switch` on the verb index, and one backend call per verb. It is the only part that was ever this
language's — reaching `@MainActor` stores — and it is the shape §6 asks for.

**The host's control socket came home in the same pass.** `slopdesk-hostserver::ctlserve` imported
`slopdesk_workspace::control_request`'s `scan_line`, `LineVerdict` and `MAX_REQUEST_BYTES` — the
CLIENT socket's module, governing the HOST socket's lines, because the two happened to agree about a
trim and a cap. Deleting that module forced the question, and the answer is that they are two
grammars that agree rather than one rule two lanes share: `ctlserve.rs` now trims and caps for
itself, three lines beside the `answer`, `failure` and `UNKNOWN_ID` that were already there, and the
cross-lane dependency is gone.

**What replaced the gate.** `the_client_control_socket_has_one_vocabulary` used to compare two
spellings; then it checked that only one existed. It still bans the words from Swift — that is the
part no suite can fail on — but its five reader doors became the seven that carry a DECISION out of
Swift (the bind, the path, the verb, the three param readers, the refusal), and it gained the claim
the new shape needs: every `SLOPDESK_CTL_*` code is declared in exactly two places, the shim that
matches on it and the header the face compiles against, with the same number in both. The shim's own
suite pins its half against `METHODS` and `Refusal::code`, so agreement at the gate means all three
agree — and a face dispatching a neighbour's verb, the one failure a door answering an index cannot
catch for itself, is caught.

## 5. What this campaign does NOT do

- **`Sources/SlopDeskNet`** stays. `NWByteChannel` is PATH-4 file transfer and the inspector event
  lane, not the mux; `one-nwconnection-byte-channel` (`rules/transport_lanes.rs:290`) is scoped to
  exactly those and `docs/60` §7 already records it as untouched by the host campaign. It is
  untouched by this one for the same reason.
- **`Sources/SlopDeskVideoClient`'s `NWVideoMuxClientFlow`** is PATH 2 over UDP, a different wire
  with a different crate (`slopdesk-video`). Out of scope, named here so the next census does not
  read its absence as an oversight.
- **`golden/golden_vectors.json`** is not regenerated at any stage, and the minter is not ported. Its
  whole value is being Swift: it pins the Swift marshalling faces against the frozen corpus, so a
  Rust rewrite would be Rust pinning Rust. It shrinks as the faces it exercises shrink, and it
  retires with the last of them — not before. (It later stopped being a BINARY, which is a different
  question and the one the standing rule asks: it is `Tests/SlopDeskCoreVectorsTests` now, same Swift,
  same corpus, a target kind that is not an executable. `docs/65` §5 records that move.)

  **G.3 is where the first of them retires, and it costs a gate change this section originally did
  not budget.** `Sources/slopdesk-corevectors/main.swift` builds twelve `MuxFrame`s and emits the
  `"muxEnvelopes"` block (`:1230,:1233,:1310`); `MuxEnvelopeCodec` is one of the eight files G.3
  deletes, so that block cannot be emitted by anything after G.3. `"muxEnvelopes"` moves from
  `EMITTED_KEYS` to `FROZEN_KEYS` in `rust/slopdesk-devtools/src/gates/golden.rs:45`, which is the
  one edit that keeps `just golden` — and therefore `just quick` (`justfile:372`) and `just check`
  (`:339`) — green. **The corpus entry itself is not touched**: a frozen key is still diffed, it is
  simply no longer regenerated, which is precisely the retirement this bullet describes happening
  one block at a time instead of all at once.

  Frozen is not free, and the gate says so in the message it prints: *"move it to FROZEN_KEYS with a
  suite that pins its bytes"*. The reader must be a Swift suite under `Tests/` or a Rust INTEGRATION
  test that opens the corpus (`golden.rs:106,113`), so G.3 adds
  `rust/slopdesk-wire/tests/golden_mux_envelopes.rs`, which replays the block against
  `slopdesk_wire::mux`. That is the stronger pin and not a weaker one: the bytes were pinned to the
  Swift codec because the Swift codec was the one that shipped, and after G.3 it is Rust's that
  ships. `"muxBare"` and `"muxFragment"` stay EMITTED — they are `VideoMuxHeaderCodec`'s
  (`main.swift:555,558`), which is PATH-2.

## 6. The finish line, stated so it can be checked

After G.5, `git grep -l 'import Network' -- 'Sources/*.swift'` names no mux file, and the
face-filtered census of undelegated non-UI Swift (the method in `docs/40`-adjacent notes: non-UI, no
`slopdesk_` door, names no face) holds only the documented floor — CoreMedia display-layer feeds,
WebKit, CoreGraphics drawing art, and the runtime half of the document/runtime seam.

**The `import Network` half is stated as a list rather than a description, because the description
was wrong.** §5 names the PATH-4, inspector and video lanes, but the grep answers ten files today and
three of them are lanes §5 never mentioned. The eight it may name after G.5 are: `NWByteChannel`
(the inspector's byte channel — PATH-4 left `Network` entirely when its socket became
`slopdesk-dropd`'s, reached through one door), `WorkspaceStore` (which dials that
inspector channel — the `NWConnection` at `:3439` is its only `Network` use), `NWVideoMuxClientFlow`
(PATH 2), `CodeSidebarProxy` (the code-server proxy), `AndroidBridgeSocket`, `SimulatorWebSocketLane`,
`SimulatorLogConnection` and `SimulatorStreamConnection` (the device panels' own lanes, `docs/47`/`48`),
plus `TransportParameters` at its new address in `Sources/SlopDeskNet`. None is the client mux, which
is the claim this campaign actually gets to make. The device-panel and proxy lanes are their own
campaigns and are not scoped here.

**Porting the E2E suite exposed an isolation hole the Swift original had all along, and it was not a
Swift problem.** `SubprocessE2ETests` set a sandbox `HOME` and, later, the four container variables —
so its journals, its workspace state and its drops were its own. Its screen ENGINE never was. hostd
renders a state-transfer restore through screend, and an engine that does not answer is not an error:
the restore demotes to the distilled path, which is the right answer for a user and an invisible one
for a test. So the two composer scenarios dialled whichever screend the developer's live host had
already started — a binary from some other commit — and the suite passed or failed on which machine
ran it. The Rust port made that visible only because it ran somewhere the Swift never had: the same
two scenarios were 6/6 green under one developer's live daemons and 4/6 an hour later under none.
The fix belongs to the sandbox and not to the assertions — `Sandbox::build` now aims
`SLOPDESK_SCREEND_SOCKET` at a private path, names `SLOPDESK_SCREEND_BIN` from this tree, and sets a
short `SLOPDESK_SCREEND_IDLE_EXIT` because hostd starts the engine DETACHED and no test guard can
reap it. The general lesson is the one that made the four container variables necessary in the first
place: a sandbox is the set of things a daemon would otherwise resolve from the developer's machine,
and every sidecar it dials is one of them. `just client-e2e` gained a `screend` dependency to match,
which is also what makes the absent-binary case a SKIP rather than a false red.
