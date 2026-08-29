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

What crosses is a verdict, never a payload: a `channelData` frame's bytes are already in the
caller's receive buffer, and `docs/55` §4b's rule — "a decision says WHERE they go, and copying a
chunk across a boundary to be told its channel id would be the whole cost of the mux for nothing" —
is the reason the offset shape (§4, "the answer that is an OFFSET") applies here too.

`slopdesk_channel_table_*` is **deleted** by this stage rather than extended: the table crossed as a
handle only because the connection above it was Swift. With the connection in Rust the table has no
foreign caller, and a handle whose far side went away is `docs/55` §4b's own retirement criterion.

Deletes: `Sources/SlopDeskTransport/{ClientTransporting,MessageChannel,SlopDeskTransportError,PortValidation}.swift`
and the whole of `Sources/SlopDeskProtocol/Mux/`. The remaining `MuxClientTransport.swift` (329)
becomes the ~80-line face that holds the handle, the way `InputInjector.swift` did (`docs/60` §4).

### G.4 — `Sources/SlopDeskProtocol` dissolves

`WireMessage`, `WireMessageCodec`, `FrameDecoder`, `WorkspaceChannelCodec`, `MetadataCodec`,
`MetadataVerb`, `ProgressState`, `ControlLine`. Every one is `slopdesk_wire`'s already; what is here
is the marshalling. It goes the way every other face has gone — the enum stays as the Swift
vocabulary the UI switches on, the encode/decode arms become one door each.

This is the stage that retires the debt `DECISIONS.md` 2026-08-13 opened for the wire codec, at the
client end. **3,961 lines**, of which the honest residue is the `WireMessage` enum itself.

### G.5 — the CLI and `Sources/SlopDeskClient`

`Sources/slopdesk-client/main.swift` (552) is the last Swift executable in the tree that is not an
app shell. It is not ported ahead of G.2–G.4 on purpose: written today it would be a second
implementation of the client session, which is the exact trap the one-implementation rule names. On
the far side of G.4 it is a thin `main` over crates that already exist, and it becomes
`rust/slopdesk-cli`'s subcommand or its own bin.

`Sources/SlopDeskClient` follows: `ReconnectManager` (281) is `slopdesk_clientsession::backoff`
plus a thread, `EventBroadcaster` (79) is an `mpsc` fan-out, `BoundedInputPipe` (118) is a bounded
channel whose only consumer is the CLI. `SlopDeskClient.swift` (984) is the four-task driver, and
what survives it is the face that holds the handle.

`SubprocessE2ETests` launches the shipped `slopdesk-client` binary; it is re-pointed at the Rust one
in the same change, which is what keeps the crown-jewel end-to-end proof pointed at the thing that
ships.

## 5. What this campaign does NOT do

- **`Sources/SlopDeskNet`** stays. `NWByteChannel` is PATH-4 file transfer and the inspector event
  lane, not the mux; `one-nwconnection-byte-channel` (`rules/transport_lanes.rs:290`) is scoped to
  exactly those and `docs/60` §7 already records it as untouched by the host campaign. It is
  untouched by this one for the same reason.
- **`Sources/SlopDeskVideoClient`'s `NWVideoMuxClientFlow`** is PATH 2 over UDP, a different wire
  with a different crate (`slopdesk-video`). Out of scope, named here so the next census does not
  read its absence as an oversight.
- **`golden/golden_vectors.json`** is not regenerated at any stage, and
  `Sources/slopdesk-corevectors` is not ported. Its whole value is being Swift: it pins the Swift
  marshalling faces against the frozen corpus, so a Rust rewrite would be Rust pinning Rust. It
  shrinks as the faces it exercises shrink, and it retires with the last of them — not before.

## 6. The finish line, stated so it can be checked

After G.5, `git grep -l 'import Network' -- 'Sources/*.swift'` names only the PATH-4/inspector/video
lanes of §5, and the face-filtered census of undelegated non-UI Swift (the method in
`docs/40`-adjacent notes: non-UI, no `slopdesk_` door, names no face) holds only the documented
floor — CoreMedia display-layer feeds, WebKit, CoreGraphics drawing art, and the runtime half of the
document/runtime seam.
