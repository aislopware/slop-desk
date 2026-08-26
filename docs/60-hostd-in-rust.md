# 60 — hostd becomes a Rust process

The continuation of `docs/59-hostd-projection.md`. That document moved hostd's *decisions* into Rust
crates while the process stayed Swift; steps 1–9 are landed. This one moves the *process*. When it is
done `Sources/SlopDeskHost` and the host half of `Sources/SlopDeskTransport` are deleted, and the
two-language codec debt that `DECISIONS.md` 2026-08-13 opened — and said "its only honest retirement
is finishing the port" — is retired for the host end.

Read `docs/59` §5 and §6 first. This document CORRECTS one line of §6.

## 1. The correction: `MuxNWConnection` is not Network.framework

`docs/59` §6 lists `Sources/SlopDeskTransport/Mux/MuxNWConnection.swift` as "837 lines of
Network.framework… for as long as hostd is a Swift process". Measured on this tree, that is wrong in
the way that matters: the file is 847 lines and **does not `import Network`**. Its imports are
`Foundation` and `SlopDeskProtocol`; it is generic over `any MuxByteLink`, and the tests already
drive it through an `InMemoryMuxLink`. It is IO *orchestration*, not framework binding — portable by
the same rule everything else in `docs/59` moved under.

The real Network.framework surface in this repo is four files, 863 lines:

| file | lines | what it is |
| --- | --- | --- |
| `HostTransport.swift` | 494 | the `NWListener`, accept loop, CONTROL/DATA pairing |
| `Mux/NWMuxByteLink.swift` | 193 | `MuxByteLink` over one `NWConnection` |
| `NWConnection+Async.swift` | 110 | `send`/`receive` continuations |
| `TransportParameters.swift` | 66 | the `NWParameters` every socket is built from |

And what those parameters ask for is plain TCP:

```swift
tcp.noDelay = true                    // TCP_NODELAY, mandatory
tcp.enableKeepalive = true
tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
NWParameters(tls: nil, tcp: tcp)      // no app crypto, raw bytes over WireGuard
```

No TLS, no QUIC, no Bonjour, no multipath, peer-to-peer disabled. Every one of those five knobs is
`std::net::TcpListener` plus `socket2::TcpKeepalive::{with_time, with_interval, with_retries}` and
`set_nodelay`. **So there is no Apple binding on hostd's transport path at all** — no `objc2` crate,
no `unsafe`, and nothing in the `slopdesk-apple-*` family. `socket2` is rust-lang's own crate, which
is the "prefer a maintained library" answer for the three keepalive sockopts that would otherwise be
three hand-written `setsockopt` calls in `slopdesk-posix`.

The floor §6 drew was real when it was drawn — it was drawn around a *linked-library* port, where
Swift keeps the runloop. It does not survive the process moving.

## 2. What is actually left in Swift on the host

`Sources/SlopDeskHost` is 20,572 lines across its files (comments included; `docs/59`'s ~10.5k is the
code-line count). Exactly **six** files touch an Apple framework or `Darwin`:

| file | lines | pinned on | where it goes |
| --- | --- | --- | --- |
| `RepoStatusWatcher.swift` | 316 | CoreServices (FSEvents) | new `slopdesk-apple-fsevents` |
| `AgentHookListener.swift` | 251 | `Darwin` (sockets) | `slopdesk-posix` / plain `std` |
| `HostMetadataProbe.swift` | 133 | `Darwin` (sysctl) | `slopdesk-posix` |
| `HostClipboardPerformer.swift` | 129 | AppKit (`NSPasteboard`) | new `slopdesk-apple-pasteboard` |
| `HostPathActionPerformer.swift` | 97 | AppKit (`NSWorkspace`) | `slopdesk-apple-app` (extend) |
| `PTYProcess.swift` | 753 | `Darwin` (fd, termios) | `slopdesk-posix` (already has `pty`) |

1,679 lines, of which the genuinely Apple-framework part is 542 and the genuinely `objc2` part is
226. Everything else in the directory is decisions, ladders and timers — and the decisions are
already Rust (`slopdesk-muxsession`, 7,071 lines, `docs/59` steps 1–9).

`PTYProcess` deserves its own line: hostd does not fork. superd forks and keeps the master; hostd
holds a `SCM_RIGHTS` duplicate and does the read loop, resize and teardown on it. `slopdesk-posix`
already owns the fork window and `pty::window_size`; superd already owns the fd-passing. Porting
this file is fd plumbing between two things that are Rust already.

## 3. The threading model: threads, not a runtime

Every sidecar in this tree is blocking `std` on threads — `slopdesk-superd` serves a `UnixListener`
with a thread per connection, and **no crate in `rust/` depends on tokio, smol, async-std or
futures**. hostd follows them. That is a deliberate choice and not an omission:

- The concurrency is bounded and known — two sockets per client connection, a read thread per socket,
  a thread per pane's PTY read loop. It is tens of threads, not tens of thousands.
- `docs/59` §7's constraint is *zero allocations added per chunk*. A blocking read into a reused
  buffer meets it by construction; an async runtime's poll machinery does not obviously.
- Adding tokio would make it the largest dependency in the tree and would fight the six existing
  daemons' shape for no measured gain.

`docs/59` §6 keeps "the `Task`s and the timeouts — every ladder step answers WHAT to do and WHEN to
arm a timer under which generation; Swift arms it". Under a process port there is no Swift to arm
them. Each ladder's timer becomes an explicit deadline on a thread, and the *generation* check that
made the Swift version correct is carried across verbatim rather than re-derived — a generation-stale
timer firing is the failure this design is shaped to prevent, in either language.

## 4. The stages

Each stage lands green on its own, is committed on its own, and keeps `golden/golden_vectors.json`
as its gate. No stage leaves the tree unable to run.

**Stage A — the socket.** New crate `rust/slopdesk-hostnet`: `TcpListener` + `socket2` parameters +
CONTROL/DATA pairing by `connectionID`, and a `ByteLink` trait matching `MuxByteLink`'s contract so
the in-memory test double ports with it. Deliverable: a listener that accepts two real sockets
naming one `connectionID` and hands up the pair of byte links they became.

Its gate is preamble-level pairing on real file descriptors — nine loopback tests dialling with
`std::net::TcpStream`, covering both arrival orders, two clients not cross-pairing, a mute socket,
an unknown tag, the reaper, a same-side repark, and `stop` both closing what it parked and releasing
the port. Reading a mux FRAME is not stage A's gate and could not be: there is nothing above the
links yet to read one. That deliverable belongs to stage B, and this paragraph used to promise it
here — the correction is worth leaving visible, because a plan that claims a gate it did not run is
the same failure as code that claims a test it does not have.

Two things stage A settled that are worth writing down, because both are the SECOND implementation
biting before it was born:

- **The keepalive ladder moved to `slopdesk_wire::transport`, not to the new crate.** Writing
  `KEEPALIVE_IDLE_SECONDS = 10` in `slopdesk-hostnet` made `shared-number-asked-or-ratcheted` fire
  against `TransportParameters.swift`'s `keepaliveIdleSeconds = 10`, correctly: the listener and the
  dialler are two programs, and a ladder configured on one end only is a half-open connection that
  neither end reports. The three numbers now live once, under a `TCP_` prefix that keeps them clear
  of the video path's application-level UDP keepalive, and are vended at `slopdesk_wire_constant`
  indices 3/4/5. Swift asks. `slopdesk-ffi` gains no dependency on `slopdesk-hostnet` — dragging
  `socket2` into the `.xcframework` to export three integers would be the wrong trade. This also
  emptied `HOMONYMS`, which had been excusing that exact pair.
- **The listener binds dual-stack and `stop` really unbinds.** `NWListener` answers both families;
  an IPv4-only `TcpListener` would silently refuse a v6 mesh dial, which only shows up on somebody
  else's network. And `accept()` has no cancel lever, so `stop` sets a flag and then dials its own
  loopback port to wake the thread — otherwise `make host-restart` re-binds seconds later and gets
  `EADDRINUSE`. `stop_releases_the_port_it_was_listening_on` is the test that pins it.

**Stage B — the mux connection.** `MuxNWConnection`'s HOST role (of 847) + `MuxSubChannel` (426) +
`MuxRoutingCore`/`MuxAdmission`'s payload-attachment half (234) → `slopdesk-hostnet::connection`.
The routing and admission VERDICTS are already Rust (`slopdesk_wire::mux`'s `channels`, `admission`,
`flow`, `decoder`, `envelope`); what ports here is the receive loops, the per-channel dispatch
tables and the suspension around the flow accounting.

Three scope corrections, each made by asking who imports the file rather than by reading it:

- **`ConnectionRegistry` (316) is not in this stage.** It is the CLIENT's refcounted connection
  pool — `Sources/SlopDeskHost` and `Sources/slopdesk-hostd` reference it zero times. So does
  `MuxNWConnection`'s whole initiator surface: `openChannel`, `awaitOpenAck` and its waiter table,
  `pin`/`unpin`, and `isDead`-for-the-pool. Porting them now would be a second implementation with
  nothing linked to it until stage G. They go with the client, in stage G.
- **`ReplayBuffer` (441) is not a port at all.** Stage 30 already deleted the Swift implementation;
  what is left is an FFI HANDLE over `slopdesk_wire::replay::ReplayBuffer`. Its only real consumer
  is `MuxChannelSession`, so the handle dies with that file at stage C and the Rust it points at is
  simply called directly. Counting its 441 lines as work to be done would have budgeted a stage for
  a file that is already the thing it would have been ported into.
- **`MuxRouter` (53) is already gone from this list**: the name in `Sources/SlopDeskVideoHost` is
  `VideoMuxRouter`, a different type on the video path. Substring greps put it here; a consumer
  grep takes it out.

**Placement is `slopdesk-hostnet`, not `slopdesk-muxsession`.** This stage owns file descriptors,
threads and the `ByteLink` trait, and `slopdesk-muxsession`'s charter is verdicts with no IO —
threading it would change what that crate is. Anything genuinely new and pure that surfaces while
writing this still goes to `slopdesk-wire`/`slopdesk-muxsession`, the way `pairing` did.

**The handler-install pattern does not port.** `pendingHostOpens`, `pendingHostCloses`, the
`linkDownFired` one-shot and `setHostOpenHandler`-after-`start()` are four patches for one Swift
ordering problem: the receive loops start before their owner has wired itself up, so every early
event needs a replay queue to land in. Stage A already solved this shape — `Listener::serve` hands
back the receiver BEFORE any thread runs — and this stage repeats it: the connection yields
`MuxEvent::{Opened, Closed, LinkDown}` on a channel the owner holds from construction. The race
class dissolves instead of porting, and so does the handler retain-cycle that `close()` nils out.
`detachShellsOnLinkDrop` does not become a constructor parameter either, which was this document's
first guess: it is a decision ABOUT PANES, and the connection has none. `LinkDown` reports which
channel ids were live and the owner — stage D — decides whether that detaches a shell or kills it.

Two properties of the Swift carry over verbatim, because they are correctness rather than
scaffolding: decode → route → deliver stays INLINE on the link's own thread, so per-channel wire
order is the thread's order and needs no sequencing; and a window grant rides CONTROL, never DATA,
so a grant can never queue behind the full window it is meant to open.

On zero-copy: one copy out of the link's receive buffer into the per-channel reassembly is the
floor once a channel is consumed on another thread. Reuse one receive buffer per link and stop
there — `docs/59` §7's zero-allocations-per-chunk budget is a constraint on the FFI crossing, and
it does not bite until stage C.

Its gate is twelve tests in `rust/slopdesk-hostnet/tests/mux.rs`, each driving the whole stack over
a real pair of loopback sockets: open → ack → input; a frame split across two writes; the two lanes
never crossed; a grant riding CONTROL; a peer close reporting its reason and finishing both
sub-channels; a dropped link reporting the live ids and then going silent; an open on CONTROL
dropped unanswered; a duplicate open minting no second pane; a reopen of a closed id refused WITH an
answer; two channels not crossing; the owner's own `close()` staying silent; and a spurious
`channelOpenAck` not retiring a live channel. The earlier plan promised "a loopback test driving the
shipping Swift client" here, and that is not what this is — but every frame in the suite is built
and parsed by `slopdesk_wire::mux`, which is the golden-pinned codec the Swift client encodes
against, so client compatibility is covered at the frame level rather than by linking the client.
The end-to-end-with-the-real-client gate is stage F's, where the Swift is deleted.

**Stage C — the pane.** `PTYProcess` (753) + `PaneOutputStream` (402) + `MuxChannelSession` (4,108)
→ the ladders over `slopdesk-muxsession`'s existing `outbox`/`fanout`/`truths`/`lifecycle`. This is
the largest single stage and the one `docs/59` §7's A/B harness exists for: 20,000 32-KiB chunks
through `ingestPTYChunk` on both sides before it is committed.

**A fourth file this plan did not count: `Sources/SlopDeskSupervisor` (2,657).** The line counts
above were taken over `Sources/SlopDeskHost` alone, and every one of `PTYProcess`'s verbs — spawn,
adopt, signal, resize, release — and the whole of `PaneOutputStream` go through `SupervisorClient`.
Nothing in stage C can be written before it exists in Rust, so the stage is committed in three:

- **C.0 — `slopdesk-superclient`.** hostd's end of the control socket: the framing a descriptor
  rides on, the connection, the reply-waiter table, the reader thread and the writer behind it.
  Small, because the MESSAGE set is already `slopdesk-superwire`'s and shared with superd by
  construction — what was left in Swift was the connection. Two Swift mechanisms do not port.
  `unawaited` — a set of ids whose replies must be discarded — existed because the Swift parked
  arriving REPLIES in a map; registering the WAITER instead leaves the set nothing to hold. And the
  `connection === link` identity check guarding the disconnect path existed because that client
  reconnected in place; a client here is one connection for its life, and reconnecting means
  building another with the same observer.

  The gate is thirteen tests against a fake superd on a real `AF_UNIX` socket, over eleven unit tests
  of the framing and the connection, every frame built by
  `slopdesk-superwire` and every descriptor crossing by `SCM_RIGHTS`. One of them is load-bearing on
  its own: a pause fired from INSIDE a pane sink must not wait on the socket the reader is draining,
  or superd blocked writing output into hostd's full receive buffer and hostd blocked writing a
  pause into superd's wedge both sides for ever. That is why the writer is its own thread.
- **C.1 — the pane's descriptor and its stream.** `PTYProcess` + `PaneOutputStream` →
  `slopdesk-hostpane`. Three things settled here that the plan had left implicit:

  **`winsize-set` gains a second enabler, and the split between the two IS the rule.** The feature
  existed so that superd could not compile `TIOCSWINSZ` into a release build; superd enabled it in
  `[dev-dependencies]` only, and the comment said "here and NOWHERE else". A Rust hostd is the one
  writer that rule names, so `slopdesk-hostpane` enables it as an ordinary dependency and superd's
  dev-only enabling stands unchanged. Non-dev where the ioctl is the job, dev-only where it is a
  stand-in for hostd's. §6's floor — one writer, still hostd's — is unchanged by this; what changed
  is which language that writer is written in.

  **The sink is split from the stream, to close a reference cycle Swift closed with `[weak self]`.**
  `SupervisorClient` holds every subscribed sink in an `Arc`, and it holds every exit handler in
  one. A `PaneOutputStream` that both held the client and WAS the sink would be a cycle for every
  stream nobody stopped, and an exit closure capturing the pane would be the same cycle through the
  handler table. So the reader-thread half is its own type with no client reference, the exit
  plumbing is its own object with no pane reference, and `Drop` on the stream unsubscribes. Rust has
  no `weak self` to reach for here, which makes the split the design rather than a patch on it.

  **Three Swift shapes collapse rather than port.** The 5 ms poll loop in
  `waitUntilExitedDrainingMaster` becomes one `Condvar::wait_timeout` woken by the notice itself.
  The `exitLock`-across-the-ioctl comment becomes a borrow-checker fact, because the descriptor and
  the identity live under one lock and the fd cannot be named outside its guard. And
  `waitUntilExitedDrainingMaster`'s alias for `waitUntilExited` goes, because there is no Swift
  caller left to keep the name for.

  Its gate is twenty-one tests in `rust/slopdesk-hostpane/tests/pane.rs` against a fake superd on a
  real `AF_UNIX` socket with a real `openpty` behind it — so the four ioctls are checked against a
  terminal the kernel made, not a mock — over nine unit tests of the cwd resolution. Each pinned
  Swift comment is one of them: an exit announced BEFORE the spawn reply is still heard, which is
  the reason the handler is registered first; a refused spawn taking over an unattached survivor;
  a survivor another daemon is attached to being left alone, with the exit route it registered taken
  back out; a lost supervisor declaring the child hung up at `128 + SIGHUP`, once, so a session
  cannot wait for a notice nobody is coming to send; the window size round-tripping through
  `TIOCSWINSZ`/`TIOCGWINSZ` with superd told afterwards; the jiggle shrinking by a row and restoring,
  and yielding to a resize that landed during the hold; keystrokes reaching the slave, with `ICRNL`
  proving it is a terminal; a closed master being idempotent and releasing nothing; the three-rung
  signal ladder routing through superd; and a release retiring the pane and its exit route together —
  which is what makes release the LAST rung, because the client drops the sink and the handler before
  the verb goes out, so a `wait_for_exit` after one never returns.

  The stream half is the other nine: a stream with no pane ending at once and sending nothing; sniff
  and block events arriving with the chunk they were found in, and an empty chunk carrying only
  events still being delivered; a gap logged without dropping the chunk; a backlog that already
  ended declaring the end AFTER its last byte; an end learned two ways told once; a lossy resume
  readable the moment `start` returns; a pause before `start` reaching superd and `stop` lifting it;
  a dropped stream unsubscribing; and a resubscribe restating the pause on the new connection.

  One contract this stage hands upward rather than solving: `hangup`, `terminate`, `force_terminate`
  and `release` park for superd's reply, and that reply can only arrive on the client's reader
  thread. None of them may be called from inside a pane sink. A session that tears down on EOF has
  to hand the teardown to another thread first, and stage C.2 is where that lands.
- **C.2 — the session.** `MuxChannelSession`'s ladders, with the A/B harness above as the gate.

**And one shape from stage C.0 that must NOT be repeated upward.** Pane output is delivered
SYNCHRONOUSLY, on the reader's own thread, with the payload borrowed out of the frame that carried
it — not through a channel, the way stage B's mux events are. Stage B could use a channel because
flow-control credit bounds it. Nothing bounds a subscription queue: a per-pane channel anywhere on
this path is precisely the unbounded buffer the `pause` verb exists to prevent, and it would turn
the never-drop invariant into a memory leak. The chain that must stay intact is hostd stops reading
→ superd's writes block → superd stops reading the master → the kernel PTY buffer fills → the shell
is paused.

**Stage D — the server.** `HostServer` (3,134) + `HostSessionRegistry` + `HostLifecycleRules` +
`DetachedSessionStore` + `SupervisedServiceLifecycle`/`Process` + `CodeServerManager` +
`CodeBridgeServer` + `AgentControlListener` + `MetadataResponseBuilder` + the workspace channel.

**Stage E — the Apple residue.** `slopdesk-apple-pasteboard` (NSPasteboard), `NSWorkspace` into
`slopdesk-apple-app`, `slopdesk-apple-fsevents` (FSEvents). `docs/57`'s bar, `objc2` only, a leak
test each. `PreventSleepDriver`/`slopdesk-apple-power` is the shape.

FSEvents is a CoreFoundation C API, not Objective-C, so "is it reachable through `objc2` at all" was
checked rather than assumed: **`objc2-core-services` 0.3.2** — the same version family as the
`objc2-core-foundation = "=0.3.2"` every crate in the family already pins — generates
`FSEventStreamCreate`, `FSEventStreamSetDispatchQueue`, `FSEventStreamStart` and
`FSEventStreamRelease` in `generated/FSEvents.rs`. They are `unsafe extern "C-unwind"` rather than
safe wrappers, which is what `slopdesk-apple-cgwindow` and `-cgdisplay` already deal with, and the
callback's borrowed `FSEventStreamRef` is a Get-rule pointer — `CFRetained::retain`, one of `docs/57`'s
two named admissions. So the crate stays inside the family and no third `unsafe` crate is proposed.
The `notify` crate would also work and is better maintained, but it is not `objc2`, so it would have
to live outside `slopdesk-apple-*`; that trade is not worth taking for one watcher when the bindings
exist.

**Stage F — the cutover.** `Sources/slopdesk-hostd/main.swift` (382) becomes
`rust/slopdesk-hostd`; `make host-restart` and `slopdesk-hostlaunch` retarget; `Sources/SlopDeskHost`
and the host half of `Sources/SlopDeskTransport` are DELETED, with their tests ported to the crates
that now hold the behaviour.

**Stage G (separate campaign, not scoped here) — the client transport.** `Sources/SlopDeskProtocol`
and `MuxNWConnection` survive stage F because the macOS/iOS clients still speak through them. Moving
those behind `CSlopDeskFFI` is a linked-library port under `CLAUDE.md`'s lifetime rule, not a socket
one, and it is what finally deletes the second copy of the codec.

**What stage F does NOT delete, said plainly.** The consumer grep is unambiguous:
`MuxNWConnection`, `MuxSubChannel` and `ConnectionRegistry` are imported by `SlopDeskClient`,
`ClientComposition`, `WorkspaceStore` and `WorkspaceChannelClient` — the CLIENT, on both platforms.
So stage B does not move that code, it adds a second implementation of the HOST half and leaves the
Swift standing; the second copy lives until stage G, and the client-only half
(`ConnectionRegistry`, `openChannel`, the openAck waiters) is never written twice at all. Stage F
deletes
`Sources/SlopDeskHost` and the host-only half of `SlopDeskTransport` (`HostTransport`,
`NWMuxByteLink`, `NWConnection+Async`, `TransportParameters`); it leaves the mux connection standing
for the clients. Anyone reading "the host port deletes the transport" should read this paragraph
instead.

The same grep corrects the parenthetical above it. Of the four Network.framework files, only
`HostTransport.swift` is host-only. `NWConnection+Async` and `TransportParameters` are imported by
`MessageChannel`, `CodeSidebarProxy`, `AndroidBridgeSocket` and `SimulatorStreamConnection`, and
`NWMuxByteLink` is by definition the DIALLER'S half — the listener never builds one. So stage F
deletes `HostTransport.swift` and nothing else in `SlopDeskTransport`; the other three go with the
client transport at stage G. That is also why the keepalive door is not throwaway scaffolding: the
Swift that asks through it outlives the Swift host by a whole campaign.

## 5. The carve-out, said out loud

`CLAUDE.md`: "One implementation, never two languages. Porting means deleting the original in the
same change." Stages A–E cannot obey that literally — a process cutover has one switch, at stage F,
and until it is thrown the Swift hostd must keep running. This is the same carve-out
`DECISIONS.md` 2026-08-13 recorded for the wire codec, on the same bound and with the same honest
retirement: **the new Rust is linked by nothing shipping until stage F**, and the golden corpus is a
gate both implementations must pass, so they cannot drift silently. If this campaign stalls, the
correct move is to delete the unlanded crates, not to keep two hosts.

## 6. The floor that survives

- `TIOCSWINSZ` on hostd's duplicate — one writer, still hostd's. `PaneResizeFold`'s line is unchanged.
- `tcgetpgrp`/`tcgetattr` — no polled IPC for the foreground process group. They move to
  `slopdesk-posix`, they do not move to superd.
- `golden/golden_vectors.json` — never regenerated over, at any stage.
- superd owns `read` on every PTY master; hostd reads its own duplicate and nothing else.
- No app-layer crypto or auth. `tls: nil` becomes "we never call a TLS library", not "we add one".

## 7. The invariant rules that move with the stages

`make lint-invariants` ratchets two rules onto files this campaign deletes. Each moves in the stage
that empties its file, with its break test, and neither is a reason to keep the Swift:

- **`one-frame-one-doorman`** (`rules/hot_paths.rs:709`) — `Claim::Exists` + `Claim::Doors` on
  `MuxAdmission.swift`, and `Claim::Doors` + `Claim::NoneOf { maxChannelsPerConnection }` on
  `MuxNWConnection.swift`. It says the four-guard precedence has one owner and the connection asks
  rather than re-derives. **Stage B** re-points every claim at the Rust connection and its doorman
  call sites; the claim it encodes is unchanged, only the language it is checked in.
- **`one-nwconnection-byte-channel`** (`rules/transport_lanes.rs:290`) — scoped to `SlopDeskNet`,
  the inspector event lane and PATH-4 file transfer. **Untouched by this campaign**; those lanes are
  not hostd's mux and keep their Swift channel.

`rules/apple_floors.rs` pins injection, the window list and capture — none of the six hostd files
above. Stage E adds a row to it per new crate, the way `slopdesk-apple-power` did.
