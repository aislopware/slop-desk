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
  loopback port to wake the thread — otherwise `just host-restart` re-binds seconds later and gets
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
  New crate `rust/slopdesk-hostsession`, and the placement is decided the same way stage B's was:
  the session owns descriptors, threads and timers, so it is not `slopdesk-muxsession` (verdicts
  with no IO — threading it would change what that crate is), not `slopdesk-hostpane` (one pane's
  descriptor, and nothing above it), and not `slopdesk-hostnet` (the transport under it). It sits on
  all three.

  **Almost none of the 4,108 lines is a decision, and that is the stage's real shape.** Every policy
  the file consults is Rust already, behind an FFI door: the outbox merge, the fanout roster, the
  truths fold, the lifecycle latches and the resize fold are `slopdesk-muxsession`'s; the replay ring
  and the three-source pause gate are `slopdesk_wire::{replay, mux::flow}`'s; the agent detector and
  the screen-rule engine are `slopdesk-agent`'s; the foreground and echo probes are
  `slopdesk-posix`'s; the project key is `slopdesk-project-key`'s. What ports is the SHELL — the
  output drain, the four relays per subscriber, the attach ladders and the timers that arm them.
  New Rust here is plumbing; the Swift it makes redundant is mostly marshalling.

  **It deletes nothing, and §5 is why.** Eleven of those faces — `PaneOutbox`, `PaneFanout`,
  `PaneTruths`, `PaneLifecycle`, `PaneResizeFold`, `PausableQueueGate`, `ReplayBuffer`,
  `ClaudePaneDetector`, `PaneScreenScanner`, `PTYEcho`, `TerminalReplaySnapshot` — are marshallers
  that a Rust session calls straight past. Six of them have no consumer outside
  `MuxChannelSession.swift`; the rest are also read by `HostServer`, `AgentControlListener` or the
  CLIENTS. Either way they stand until stage F throws the process switch, because until it is thrown
  the Swift hostd must keep running. Counting them as this stage's deletions would be the same
  bookkeeping error §5 exists to name.

  It lands in FOUR commits. One commit for a 4,108-line file is a commit nobody can review and a
  bisect nobody can use, and the campaign's own rule is that a finished piece is committed when it
  is finished:

  - **C.2a — the drain.** The pane→wire direction: the chunk sink, the outbox append, the drain
    thread, `sequenceAndFanOut` over the replay ring and the fanout roster, the exit ladder, the
    pause gate, and the teardown that the EOF path hands off. Enough of an attach to have an
    end-to-end test — the primary subscriber, its input relay and its two senders — and no more.
  - **C.2b — screend's client.** `Sources/SlopDeskScreen/ScreenClient.swift` (412) →
    `rust/slopdesk-screenclient`. This is C.0's shape a second time and it was not in the plan: the
    MESSAGE set is `slopdesk-screenwire`'s already and shared with screend by construction, and what
    is left in Swift is the connection. C.2c cannot compose a snapshot without it, and stage D's
    `AgentControlListener` needs the same client, so it is written once here rather than twice
    later.

    Three modules, split by what each is allowed to know: `client` (the pool, the autostart, the ten
    verbs), `transport` (one exchange and `ClientError`), `paths` (the address, the binary, the log).
    `ScreenPaths` and the one function of `RustServicePaths` it called came with it, because a client
    that cannot find its daemon is not a client — and `access(2)` with `X_OK` is kept as the
    executability test rather than `mode & 0o111`, which is a different question
    (`slopdesk-ffi/src/tool_path.rs`).

    It needed ONE change to something else first, and that change is its own commit: screend's
    `Snapshot`, `Verdict` and `State` derived `Serialize` and nothing else, which held for exactly as
    long as the only decoder was Swift's `Decodable`. They moved to `slopdesk-screenwire::payload`,
    the shape `slopdesk-superwire` already has — not into screend's crate for the client to link,
    which would drag `regex`, `toml` and a per-byte grid into hostd and invert the dependency this
    socket exists to create.

    Three things the port does NOT copy. The Swift recycled the descriptor into the pool and then
    closed it from the catch block when the reply did not decode, leaving a closed fd for the next
    caller; ownership makes that unspellable, and the split it forces is the right one — a
    REJECTION leaves the connection good (`Status::BadRequest`'s own contract) so the socket is
    pooled, a MALFORMED reply is a lost frame boundary so it is dropped. And the hand-set
    `SO_NOSIGPIPE` is gone: std sets it on every socket it creates on Darwin, the same disappearance
    `slopdesk-androidd/src/net.rs` records. The third is `screend.log`, which the Swift TRUNCATED on
    every spawn and which the port appends to: a crash loop is what that file is for, and truncating
    erases the first attempt's reason two seconds later, leaving only the last one — the growth is
    bounded by the spawn rate, which the backoff already limits and which is zero once a screend is
    up. What the port ADDS is a reaper thread per spawn — Foundation's `Process` reaps,
    `std::process::Child` does not, and a crash-looping screend would otherwise fill hostd's process
    table.
  - **C.2c — the attach ladders.** `joinSubscriber`, `detach`, `rebindRelay`, `replayTail` and the
    snapshot compose, plus the resize ladder and its generation-checked timers (`docs/59` §6 left
    "Swift arms it", and §3 above says what that becomes when there is no Swift). Three modules:
    `snapshot` (the compose and its three ways to decline), `resize` (the fold's two locks and the
    one writer), `timer` (the cancel-replace table).

    **The renderer stays INJECTED, and the screend client is not linked here.** `SnapshotPolicy` is a
    trait `slopdesk-hostsession` never implements, exactly as `SnapshotReplayPolicy` was a struct
    `MuxChannelSession` was handed. C.2b turned out to be needed for stage D rather than for this:
    the compose takes `(history, rows, cols) -> bytes` and does not care who renders it, so hostd
    wires the screend-backed implementation at C.2d and every test that has not asked for a screen
    model replays raw.

    **Three timers, ONE thread.** In Swift each cancel-replace window was a `Task`; a `std::thread`
    per arm is not that cheap, and a window drag emits an offer per frame — ~60 arms a second per
    pane. So `timer` is a table of at most three pending bodies on a single thread parked on a
    condvar, spawned lazily on the first arm and joined by the teardown. Re-arming overwrites a slot
    in place, which IS the cancel. No generation lives in there: `ResizeFold` already owns them, and
    a second answer to "is this action still the newest one" is how the two drift.

    **The exit handler had to stop being captured.** The Swift read `self.onExit` dynamically at fire
    time, which is what let detach install the detached-store handler and rebind swap the returning
    connection's back. A Rust exit thread that cloned the observer at `start()` would see neither —
    a shell dying while detached would fire a handler for a connection that is gone, and one dying
    just after a reattach would fire the detached-exit handler and kill the pane that had just come
    back. The observer moved onto `Shared` under a lock of its own, read at fire time. The companion
    rule survives intact: the exit thread is never cancelled and re-created by a rebind, because
    `wait_for_exit` parks a registration this crate cannot retire and a second waiter would send a
    duplicate `.exit` per reattach cycle.

    **What the port does NOT copy: the gate-accounting carry.** The Swift read `outputGate.outstanding`
    at detach and re-enqueued it onto the gate `rebindRelay` built, because the gate's `setPaused`
    sink NAMED the stream being stopped and so had to be rebuilt with the new one. Here the gate
    lives in `Shared`, outlives the detach holding its own numbers, and `install_throttle` only
    re-points a `Weak` — so the frames the stopped drain never shipped are still counted and the
    books still sum to zero when the restarted drain ships them. The carry was a consequence of the
    Swift's ownership, not of the protocol, and it has no use site left. What the port DOES keep is
    the reason the carry existed: the out-FIFO is not cleared on detach, because those frames were
    never sequenced and dropping them would be both a silent transcript gap and a ≥64 KiB accounting
    residue that leaves the read loop paused for ever. `close_drain` therefore gained a `reopen` and
    a `kick`, since a detach's stop must be undoable where a teardown's never is.
  - **C.2d — the detection surface.** The foreground poll, the screen scan and the echo probe, the
    cwd/project derivation, the arrival re-assert both ladders end with, and the readouts a
    supervision caller asks for. Three modules: `probe` (which OS read to reach for, and how long an
    answer stays good), `detect` (the folds, the two loops and the injected screen oracle), `project`
    (the type-33 latch and the type-34 walk behind it).

    **It is a RE-WIRE, not a port, and that is the finding that sized the stage.** Every engine was
    already Rust behind an FFI door: the detector, the alias table, the screen rule ladder and the
    scan's timing are `slopdesk-agent`'s; the foreground and cwd probes are `slopdesk-posix`'s; the
    ancestor walk is `slopdesk-git`'s; the metadata admission counter is `slopdesk-muxsession`'s and
    the metadata probes are `slopdesk-panecensus`'s and `slopdesk-probe`'s. `PaneScreenScanner.swift`,
    `ClaudePaneDetector.swift`, `ForegroundProcessProbes.swift`, `HostMetadataProbe.swift` and
    `MetadataAdmission.swift` are faces over those, so what this stage writes is the DRIVING — when
    to probe, what to hand each fold, where the answer goes — and nothing else.

    **The detector moved INSIDE the truths lock, not beside it.** `Shared::folds` holds both, because
    every readout that pairs them has to see them agree: `list-panes` reads a status beside its
    label, the arrival ladder splices the detector's re-assert between the two halves of the truths'
    one, and the type-25 notification gate is read in the SAME acquisition as the fold it gates. Two
    locks would make each of those a window where one had moved and the other had not — which is why
    `MuxChannelSession` kept `agentDetector` under `truthsLock` rather than next to it. The scan's
    pending-byte buffer is its own small lock and must be: the READ LOOP appends to it, and the read
    loop may not queue behind a fold that is talking to screend.

    **The screen oracle is injected, for the reason the snapshot renderer is.** `ScreenOracle` is a
    trait this crate never implements: `ScreenClient::new` AUTOSTARTS screend, so a session that
    linked it would spawn a daemon the moment a test constructed one. hostd wires the screend-backed
    implementation; a session handed `None` runs no scan loop at all, which is exactly what a pane
    with the gate off should do. A failed exchange is `Outcome::Failed`, never a fallback verdict —
    a detection read off a screen whose last fold was lost is how a dismissed dialog gets reported
    as a live one.

    **Both loops park on a condvar rather than sleeping.** Every Swift loop was a `Task.sleep` the
    teardown cancelled, and a `thread::sleep` is not cancellable — so a teardown would wait out up to
    one interval per pane, and the SCAN's interval is the engine's to choose, not this crate's. The
    loops also survive a DETACH, deliberately: an agent working in a detached pane is the case the
    supervision surface exists for. What the detach takes is the members, so an edge crossed while
    away broadcasts to nobody, and the rebind's re-assert is what tells the returning client.

    **The arrival ladder's order is load-bearing in two places.** Echo first, because its absence is a
    security consequence rather than a cosmetic one — a `sudo` prompt spanning the arrival leaves the
    client's automatic Secure Keyboard Entry disengaged, and the RE-ANCHOR is what forces the fresh
    type-31 that a plain re-fold of an unchanged state would not. Title LAST, because the client
    judges a title's freshness against the command-start stamp the head just republished, and a title
    that arrived first loses that comparison for the rest of the session.
  - **C.2e — the orchestrator's surface. DONE.** `src/taps.rs`, `src/metadata.rs`, `src/history.rs`,
    and the `blocksEnabled` gate C.2d left open. A re-wire again, and for the same reason: the
    admission counter and the verb-routing table are already `slopdesk-muxsession`'s
    (`metadata_admission.rs`), the pane probes behind the read verbs are already
    `slopdesk-ffi/src/pane_probe.rs` over `slopdesk-panecensus`, and the ANSI stripper `ANSIStripper`
    fronts is already `slopdesk-sanitize`'s `plaintext::strip` / `lines::logical_lines`. What was
    Swift was the driving.

    **The metadata RPC shares the project walk's executor — the same instance, not the same type.**
    One serial queue per pane is what `MuxChannelSession` had (`metadataQueue` served both), and it
    is load-bearing: two queues would let a `git status` overtake the resolve of the `cd` that caused
    it. `SessionConfig::resolve` is handed to `Project::new` and `Metadata::new` both.

    **The admitted slot is a guard, not a call at the end of the closure.** Swift's `defer` released
    it; a Rust closure handed to somebody else's executor can be dropped without ever running, and a
    slot leaked that way shrinks the cap by one per incident until the pane refuses everything.

    **`MetadataPerformer` is injected for `ScreenOracle`'s reason, and the nine side-effecting verbs
    are why.** They actuate on the host's Finder, `~/.claude/settings.json`, the pasteboard and a
    lazily-spawned workbench child — all still Swift under §5. What does NOT cross is the routing:
    `performer(verb)` decides in Rust, off the wire's own enum, and the boundary carries one call
    with the answer already in it.

    **One raw descriptor crosses, and it is written down rather than hidden.**
    `PtyProcess::master_fd_snapshot` is the only door that lets a pane's fd number out; three read
    verbs resolve the foreground group from it, and holding the pane's lock across the `git`/`lsof`
    behind them would stall every resize on a repository walk. Swift has the identical seam
    (`serveMetadata` captures `pty.masterFD` before its `async`), and stage F closes it: with the
    builder in Rust, the hold can be taken for the microsecond `tcgetpgrp` and not for the fork.

    **The close tap fires once, behind every byte, and only when the child is actually gone.** Two
    paths reach the end and each satisfies that differently. Child-first: the exit thread waits out
    the EOF latch — the gate `.exit` already rides behind — and fires immediately ahead of it.
    Host-first: `teardown` unsubscribes the stream at the top of its ladder, so every byte hostd will
    ever see has landed before anything else runs, and the close fires at the END of the ladder,
    after the latch is released and after `end_child` has reaped the child. Announcing it where the
    ladder starts, as the first draft did, would tell an orchestrator its agent was gone while the
    shell was still running. One departure from Swift, deliberate: a tap registered AFTER the end is
    fired at once rather than stored where nothing will read it — Swift left that caller waiting out
    its own timeout for an event that could no longer happen. The latch is what makes it safe:
    exactly one end per session, however many paths reach it. **A `relinquish` is NOT one of those
    paths**, and the asymmetry is the whole point of `docs/51`: it leaves the pane alive in superd
    for the next hostd to adopt, so an orchestrator told `{"event":"closed"}` there would hear that
    its agent had finished while it was still running. Nothing waits on the silence — hostd is
    exiting, and the `subscribe` pump ends on its own socket.

    **`block_backfill` now takes the `blocksEnabled` gate** C.2d found it missing. Wire behaviour was
    already identical (superd errors, `.ok()?` answers `None`); the gate saves one blocking round
    trip per arrival on a blocks-disabled pane, on the one path a client is waiting on.

  **Two hazards C.1 already paid for, carried up one layer.** The reference cycle is the first: a
  session that both held the pane and WAS its `PaneChunkSink` closes client → sink → `PtyProcess` →
  client, which is precisely the cycle C.1 split `StreamState` out to avoid. The ingest half — the
  truths fold, the outbox, the gate, the screen-scan buffer — is its own type with no path back to
  `SupervisorClient`, and the session holds the stream whose `Drop` unsubscribes. The second is the
  contract C.1 handed up: `hangup`, `terminate`, `force_terminate` and `release` may not be called
  from inside a sink, so the sink's `ended` only LATCHES eof and the teardown runs on the thread
  already parked in `PtyProcess::wait_for_exit` — the one whose condvar the exit notice wakes.
  Pausing from inside the sink stays legal, and C.0's writer thread is why.

  **A third hazard is new here, because Rust has no `Task.cancel`.** Every Swift relay was a `Task`
  the teardown cancelled; a thread has to be able to RETURN. A relay ends when its channel's
  receiver ends, a sender ends on a close sentinel in its queue, and both must hold for a
  subscriber that is retired mid-rebind — otherwise the leak is one thread per rebind, which no test
  that attaches once can see. The single-subscriber fast path stays inline on the drain thread, as
  it is in the Swift, so the common pane costs no sender thread at all.

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

  **D.0 — the scoping, and its one finding: stage D has no engine left to write.** Every decision
  these files reach for is already Rust, and the audit is worth writing down because the size of the
  Swift says otherwise. The session table is `slopdesk-muxsession::registry::Registry` — twenty-five
  `slopdesk_host_registry_*` entry points, and what `HostSessionRegistry` adds on top of them is
  buffer marshalling that ceases to exist the moment the caller is Rust. Both port lifecycles' rules
  and the log-line splitter are `slopdesk-sidecars::{service_lifecycle, line_assembler}`. Path
  confinement, the code-bridge line grammar and its root routing are `slopdesk-ffi`'s
  `path_confine`/`code_bridge_line` over their own crates. The metadata bodies are `slopdesk-probe`
  and `slopdesk-git`. The pane is C.2's, and C.2e's tap/metadata/history surface is precisely what
  `AgentControlListener` drives.

  Two beliefs that scoped the stage wrongly at first, both checked and both false. **Nothing in
  stage D spawns a process.** `SupervisedServiceProcess.spawnOrAdopt` asks superd for a pane and
  closes the returned master at once — `SupervisorClient::spawn`/`adopt`/`subscribe`/`release`
  already carry all of it, so no Rust child-process facility is needed and no new `unsafe` is in
  question. And **the listener is not Apple.** `Sources/SlopDeskHost` imports `Network` nowhere;
  `NWListener`/`NWConnection` are confined to four files in `Sources/SlopDeskTransport` (~871 lines)
  which belong to stage G, and `slopdesk-hostnet::Listener::bind` with its pairing and handshake
  timeouts is already the host side. Stage D therefore builds ONE crate that owns the composition,
  and re-wires. That crate declares its own `[workspace]`, the way `slopdesk-hostsession`,
  `-hostpane` and `-hostnet` do: `rust/Cargo.toml`'s members are the FORK-PER-EVENT programs and
  nothing else, and a daemon's half wants a daemon's profile. The cost is the one every host crate
  already pays — `cargo -p` from the root cannot reach it, so its gate is `cd rust/<crate>`, and
  `just lint-reach` is what proves some target still runs it.

  **D.1 — the registry and the detached store.** ✅ `rust/slopdesk-hostserver`, five modules and
  thirty-six tests. `HostSessionRegistry` (400) collapsed onto the `Registry` it already wraps and
  came out at 338 with more doc in it than code, because most of what it was is buffer
  marshalling that ceases to exist the moment
  the caller can hold a `Vec<Key>`. `DetachedSessionStore` (388) kept both retention rules and gained
  the driving Swift held: the TTL timer, the exclusive claim hand-off, `drainAll`/`relinquishAll`.

  Four decisions in it are worth knowing before reading it.

  **The two halves take opposite answers on locking, and the Swift was right about both.** `Sessions`
  holds NO lock — it is a plain `&mut self` type, exactly as `HostSessionRegistry` was "deliberately
  unlocked: `HostServer` calls every method with its `lock` held". That is load-bearing: the join and
  reattach ladders mutate the registry AND the object maps and must be indivisible across both, so a
  lock in there would make D.6 either nest two on every ladder or go back to the TOCTOU it took the
  ladder to close. `DetachedStore` holds its OWN, because its exclusive hand-off is a removal and a
  timer cancellation in one critical section and no caller can be trusted to hold that for it. The
  nesting stays one-way — server → store, never back — and `is_child_exited` is still asked OUTSIDE
  it, because the exit notification runs a teardown that comes back through `remove`.

  **The TTL timer is NOT `slopdesk-hostsession`'s `Timers`**, and the reason is semantic rather than
  convenience: a re-arm there REPLACES the deadline, which is the whole point at sixty arms a second
  during a drag, and a re-park here must KEEP the original — the clock started when the client left,
  and a mid-reattach link drop is not a fresh departure. What landed is one wheel: one thread for
  every parked pane rather than the one-per-entry a `Task`-per-entry becomes once a `Task` is a
  thread, lazily spawned so a store with no TTL configured — the default — never starts one, and
  holding a `Weak` to the store so the queue cannot be the cycle that keeps it alive. It fires
  NOTHING on stop, because a wheel that flushed its queue there would kill exactly the panes a
  `relinquish_all` had just handed back to superd. And because the wheel is keyed by SESSION id
  rather than by entry, a displacement's cancel and its successor's arm are ONE key: the cancel goes
  first, or the successor is left holding a TTL that silently never fires. Swift could write those
  two in either order — its timer hung off the `Entry` object — and this cannot.

  **Every kill goes through an injected executor**, never the caller's thread. An overflow eviction
  fires while the server may hold its lock, and a relinquish can block on input-quiet — so
  `relinquish_all` lets N panes go in PARALLEL and answers a handle with a BOUNDED wait, since a pane
  whose relinquish wedges must not hold the daemon open. The same bargain `ResolveExecutor` struck.

  **The pane is a six-method trait, not `PaneSession` by name.** The table and the store touch a pane
  in exactly six ways — two identities, whether its child exited, how many hold it, and the two ends
  of its life — and everything else those two files do is bookkeeping ABOUT panes rather than to
  them. Naming that surface is what lets the retention be tested as retention instead of as a PTY, a
  superd and six threads per entry. `LivePane` is the real one, and it is where the session id and
  the slot are pinned on, because `PaneSession` deliberately carries neither: a crate that named its
  own position in a collection could not be tested apart from the collection.

  One thing moved outside the new crate. `mint_slot` is now
  `slopdesk-muxsession::registry::mint_slot` and the FFI door delegates to it, because stage D gives
  hostd a SECOND minter into the same table and two counters would hand two live panes one number.

  **D.2 — the two service lifecycles.** ✅ `SupervisedServiceLifecycle` (433) +
  `SupervisedServiceProcess` (289) + `CodeServerManager` (425), landed as `service`, `serviceproc`
  and `code` in the same crate, with thirty-two tests. None of the three decides anything: the
  announce parse, the probe step, the adopt verdict, the boot step and the CLI flags were all
  `HostServiceRules`' already. What landed is the two mutex-guarded state machines, the ring-replay
  adoption with its lossy-resume refusal — a survivor whose announce line has scrolled out of
  superd's ring is a FAILED adoption, because a live handle with no port leaves the panel reporting
  `starting` for the rest of the daemon's life — and the workbench's four boot gates.

  The gap the scoping found is closed first, and it was the only thing in stage D that was not
  already Rust somewhere: `SupervisorClient` had `observe_exit` but **no disconnect observer**. The
  service process needs one, because superd holds the ONLY master for a panel backend, so superd
  dying kills the child and hostd would otherwise never hear it — the `exited` notice travels the
  connection that just died. It is a token-keyed registry of `Arc<dyn Fn()>` beside the exit one,
  drained under the client's lock and CALLED outside it, in `02f869ac`.

  **The one departure, and it is a lock.** The Swift held ONE `NSLock` across the whole ensure round,
  boot included — and the boot for a panel backend is `SupervisorClient::spawn`, a request that
  blocks until superd's reply arrives on the client's single reader thread. That same reader thread
  delivers the child's log lines, and a log line calls back in to record the port. One lock across
  both is a cycle: the round holds it and waits for a reply, the reader waits for the lock to hand
  over a line, and the reply is behind the line. So the announce record is on a mutex of its own, and
  the boot closure runs with the other one RELEASED.

  Two things follow, and both are improvements rather than trades. A second round that arrives
  mid-boot reports `starting` instead of queueing behind a Node boot, which is the never-wait
  contract stated one level stronger — a `booting` latch is what keeps it from spawning a twin. And
  the announce slot opens when the generation is bumped, BEFORE the spawn rather than after it, so a
  line that lands while the child is being spawned is recorded instead of dropped. The Swift dropped
  it, and the path where that matters is the adopt: a survivor's ring replays from offset 0 and hands
  the announce line back inside exactly that window. Both have a test named after them.

  The workbench's gates moved with it. They were under the lifecycle's lock only to avoid keeping
  two, and that lock is no longer a face's to take, so `CodeServerManager` holds its own — taken only
  inside the boot closure, one-way after the service's. Nothing is lost, because the gates and the
  child state were never read together.

  `ServiceProcess` is the one piece that IS its connection end to end, so it is tested without a
  seam: `tests/serviceproc.rs` drives it against a fake superd on a real `AF_UNIX` socket, framing
  written with `sendmsg` and the master handed over by `SCM_RIGHTS`, the way
  `slopdesk-hostpane`'s own suite does. Eight cases — the Swift's seven carried over one for one,
  plus the spawn path's announce line, which the Swift only reached through the manager above it.
  The load-bearing one is `a_survivor_whose_ring_lost_the_announce_line_is_ended_not_adopted`: every
  other case would pass with the adopt taken on trust, and that one is the difference between a
  panel that comes back and a panel that reports `starting` for the rest of the daemon's life.

  One trap the suite named, and it is the client's shape rather than this type's: `release` is an
  AWAITED verb where the `unsubscribe` ahead of it is fire-and-forget, so a fake superd that answers
  the subscribe but not the release parks the terminating thread for ever. A test hangs rather than
  fails there, so the teardown goes through one helper that answers it.

  **D.3 — the code bridge.** ✅ `CodeBridgeServer` (453) is `slopdesk-hostserver`'s `bridge`. There
  was never an engine here either: the verb table, the routing rule, the typeability test and both
  line builders are `slopdesk_muxsession::bridge_router`'s and were before the port started. What
  was left, and all that was left, is the socket — the bind, the accept, the NDJSON split, the two
  directions and the stop.

  **The one departure, and it is how a `stop` ends the accept.** The Swift closed the listening
  descriptor from the stopping thread while the accept thread was parked inside `accept(2)` on it.
  Darwin wakes the sleeper, so it worked — but it is a close of a descriptor another thread is
  inside, and between that close and the loop's next syscall any thread in the process can open
  something that lands on the same number, after which the loop accepts on a stranger's descriptor.
  Here the accept thread OWNS its listener and nobody else may touch it: it parks in `poll` on the
  listener and a wake pipe, and `stop` writes one byte. The loop returns, the listener drops on the
  way out, and no descriptor is ever closed out from under a syscall. That is superd's pump loop's
  shape, for superd's reason. Per-connection reads need none of it — the table keeps a second handle
  on each accepted socket and `shutdown(2)` acts on the socket OBJECT, which is what a duplicate is
  for.

  `SO_NOSIGPIPE` moved into `slopdesk-posix`'s `sock`, beside the buffer widener and for that
  module's stated reason: a socket option macOS has and `nix` does not wrap for a bare descriptor.
  It is not made redundant by the Rust runtime's `SIG_IGN`, which the `main` shim installs — a crate
  LINKED INTO a foreign process never runs one, so in hostd-until-F and in every `.xcframework`
  this repo ships, `SIGPIPE` still has its default disposition and one write to a workbench window
  that has just closed would end the host.

  The Swift's position was "compiled and code-reviewed only — never bound in a unit test", with the
  pure halves tested underneath. `tests/bridge.rs` retires it: ten cases against a fake extension
  host on a real socket. The load-bearing one is `a_stop_unlinks_only_the_socket_file_it_bound` —
  every other case here fails loudly, and that one fails by deleting a DIFFERENT live host's socket
  name, after which its workbench windows reconnect for five minutes to a name nobody holds and
  nothing anywhere says why.

  **D.4 — the metadata performer, as a COMPOSITE.** ✅ `MetadataResponseBuilder` (389) is
  `slopdesk-hostserver`'s `metadata`. `metadata_admission::performer` already routes every verb off
  the wire's own enum, so the split was read off the routing table rather than argued: TEN verbs land
  on `Performer::Builder` — processes, ports, cwd, git status, git diff, the directory listing, the
  two agent-session reads, host info and host vitals — and those are the reducer's. The other twelve
  belong to six named performers and cross to an injected delegate untouched. Three of those twelve
  are servable in Rust today and deliberately are not: `agentHookStatus`, `ensureSimulatorServer` and
  `ensureAndroidBridge` belong to performers a live hostd injects separately, and answering them from
  a second place would put two implementations over one `~/.claude/settings.json` and one sidecar
  socket for as long as the carve-out lasts. So the Rust performer serves what the table gives it and
  DELEGATES the rest from the first commit, and the delegate shrinks to nothing at F rather than the
  composite being rewritten.

  There was no engine here either: the confinement is `slopdesk-probe`'s `path_confine`, the encoders
  are `slopdesk-wire`'s `codec`, the queries are `slopdesk-panecensus`, `slopdesk-git` and
  `slopdesk-probe`. What the Swift added was the ORDER — decode the argument, confine the path, ask,
  encode — and that is what moved, behind a `HostQuerying` door so the suite can assert the thing
  that matters: that a REFUSED request never reached the query at all. That failure is silent, since
  a listing from outside the pane's subtree looks like any other listing, so every confinement case
  asserts the door's ledger is still empty.

  The probe is LINKED, not forked. `HostProbe.swift` forks `slopdesk-probe` for four verbs because a
  Swift process had no other way to reach Rust that was already written; this side calls `git::diff`,
  `files::list_directory`, `files::list_sessions` and `files::read_session` in-process, at the SAME
  level `main.rs` dispatches to. `read_session` is why the level matters — it confines the id against
  the host's session roots a second time, and reaching one function lower would drop that silently.
  The fork's one theoretical advantage, killing a wedged mount with the child, was never realised:
  `waitUntilExit` has no timeout, so both shapes park the same executor on the same `stat`.

  **D.5 — the agent-control listener. ✅ landed.** `AgentControlListener` (1,239) and its eleven
  verbs, onto C.2e's taps and the scrollback readouts — plus D.1's registry, since `list-panes`,
  `spawn` and `kill` are the SERVER's surface and not a pane's. This is the sub-stage that proves
  C.2e's shape was the right one, and it did: `control.rs` is the verbs with no socket in them, and
  `ctlserve.rs` is the NDJSON pump, because the two answer different questions and only the first is
  drivable without a descriptor.

  There was no engine here either. The `wait --until` scan is `slopdesk-rowscan`'s, the supervision
  vocabulary is `slopdesk-agent`'s, the sensitive-name set the K13 guard consults is the detector's,
  the tmux key table is `slopdesk-workspace`'s, and both sanitiser passes are `slopdesk-sanitize`'s.
  The Swift reached three of those through the FFI and one — the prompt-EOL excision — through a
  round trip to `slopdesk-screend`, because a Swift process had no cheaper way to call Rust it had
  already written. They are function calls now, and that sidecar hop is gone.

  Two doors, for D.1's and D.4's reason: `ControlHost` is the server's five-method surface and
  `ControlPane` is one pane's, so the suite drives all eleven verbs with no PTY and can assert the
  guard order's actual contract — that a refused verb never looked its pane up, a lookup being how a
  caller learns a pane exists. `ControlPane` is a supertrait of `Pane`, so ONE adapter serves both
  the registry D.1 holds and the control surface.

  **D.6.1 merged those two traits into one, and the reason is worth keeping.** The supertrait
  direction was the wrong way round for a LIVE host: the registry and the detached store hold
  `Arc<dyn Pane>`, `list-panes` and `lookup` answer out of exactly those tables, and a trait object
  cannot be widened back to its supertrait. Every alternative was worse than the merge — a second
  parallel table indexed the same way, generic tables that infect the store's lock, or a downcast.
  What the split protected is intact: those six lifecycle methods are still the only ones the table
  and the store call, `pane.rs` says so, and the suite that drives the verbs still hands in a fake.

  **Two deliberate departures, each because parity with a limitation is not a reason to keep one.**
  `screen` renders BEHIND the pane door rather than reaching for `slopdesk_screenclient::shared()`
  from the dispatcher: a global socket client is not something a test can hand in, so the Swift
  could not drive that verb and neither could a transcription of it. And the `subscribe` pump is ONE
  thread parked in `poll(2)` over the connection plus a self-pipe, where the Swift ran a SECOND
  thread blocked in `read(2)` purely to notice a disconnect and reaped it by having the first thread
  `close(2)` the descriptor the second was inside — D.3's accept-loop reasoning, applied again. A
  third, smaller one: a `subscribe` whose `paneId` is present but not a string is refused rather
  than falling through to the cross-pane stream, because the caller meant one pane and named it
  wrongly, and answering with every pane's status is a silent substitution.

  One contract was written DOWN rather than inherited. `ControlPane::add_close_tap` states that a
  registration arriving after the pane has already closed fires at once and registers nothing —
  `slopdesk_hostsession::taps` latches that, and the trait says so because an implementor outside
  that crate can otherwise miss it while every other test still passes. The suite carries the case
  the latch exists for: `subscribe` on a pane that ended but has not been swept from the registry
  yet, which under the Swift waited out its own timeout for an event that had already happened.

  Three gaps in `slopdesk-hostsession` were filled where they land rather than worked around:
  `report_agent_status` folds an agent's self-report through the SAME detector the foreground poll
  drives, `window_size` is the live `TIOCGWINSZ` that `screen` defaults to (as distinct from the
  negotiated grid the size fold resolves), and `foreground_name` is the canonical probe the
  sensitive gate reads. `TapToken::foreign` is a fourth, and smaller: the three tap registries are
  also a SHAPE, and an implementor of that shape outside the crate has to be able to hand a token
  back.

  What D.5 does NOT take is the live `ControlHost`. `list_panes`, `spawn_standalone`, `kill_pane`
  and the cross-pane status fan-out are `HostServer`'s adoption and observer tables, which is D.6 by
  name; the trait is what D.6 implements. `ControlLine.swift` also stays, and not by the carve-out:
  it is SHARED with the client's own control lane, which survives the cutover at F. Stage G takes
  it.

  **D.6 — the server itself.** `HostServer` (3,134) + `HostServer+Workspace` (274) +
  `WorkspaceChannelSession` (486) + `HostWorkspaceDocument` (312): the composition root, and the
  only part that is mostly its own. The listener is `slopdesk-hostnet`'s, the supervisor client is
  `slopdesk-superclient`'s, the panes are `slopdesk-hostsession`'s; what is left is the adoption
  ladder, the join/reattach ladders, the workspace reconciler and the stop order. It goes in five,
  because the ladders share a table and landing them together would make one reviewable change out
  of four independent ones.

  **D.6.1 — the live `ControlHost`, and the fan-out behind it. ✅ landed.** `host.rs`: `list_panes`
  over the three sources, `lookup_pane` over the two attached tables, `kill_pane` over all three
  kill branches, `spawn_standalone`, and the cross-pane agent-status stream D.5 could only take a
  trait for. The eleven verbs now run against the real registry and the real store, with ONE seam
  left — `Spawner`, which is `posix_spawn` and six threads and nothing that decides anything.

  That seam is the sub-stage's whole shape: every decision a spawn makes (the curated environment,
  the executable, whether `argv[0]` carries a login shell's leading dash, whether the
  shell-integration shim goes down, what order the pane is filed and routed and started in) is
  asserted with no PTY in the process. Two more seams, both smaller and both for testability rather
  than layering: `SessionIds`, because `SystemIds` reading `/dev/urandom` is the FIRST entropy
  source anywhere in this tree — `slopdesk-ids` deliberately refuses to mint and every other
  implementor is a pool Swift fills — and `Transcripts`, which is a named hole where the scrollback
  transcript store will land rather than a port of one that does not exist yet.

  Two things were found rather than transcribed. `PaneSession::completion_epoch()` read a counter
  NOTHING in `slopdesk-hostsession` ever folded, so the finished-turn epoch was permanently zero;
  the fix is `detect::fold`, one funnel every detector feed already passed through, which folds the
  truth and publishes the transition in the same place. And the presence bit: the ctl vocabulary has
  four tokens and a pane with no agent reads `idle` in exactly the way a resting agent does, so the
  agent-GONE edge is invisible in the `state` string. `Pane::agent_present` is the separate
  question, `AgentStatusEvent::agent_present` carries it, and the teardown fan is GATED on it —
  without the gate every closed plain shell publishes a supervision event about nothing, and without
  the fan a pane killed mid-turn holds the daemon's `IOPMAssertion` for the rest of the process's
  life. Four of the thirty tests are about that class of leak; none of them would fail a test that
  only asked whether the pane died.

  **D.6.2 ✅ landed** — the channel ladders, as `rust/slopdesk-hostserver/src/channel.rs` plus 45
  tests. `spawnMuxChannel`, `performJoin`, `performReattach`, `spawnFreshShell` and — for the reason
  below — `removeMuxSession`. No engine here either: the precedence between the seven routes is
  `slopdesk_muxsession::open_route`'s and always was, and so are the resume clamp, the restore gate
  and the repaint verdict. What moved is the ORDER around them, and the ONE critical section that
  makes the first four indivisible: the idempotency guard, the stopping gate, the
  attached-elsewhere lookup, the JOIN's key-and-subscriber registration and the store's exclusive
  claim under one acquisition of the registry lock, because a route decided under the lock and acted
  on outside it is the TOCTOU the lock was taken to close.

  `removeMuxSession` came with it rather than waiting for D.6.5, and the reason is a rule rather than
  a preference: it is the exit route a fresh spawn WIRES, and a spawn whose exit closure pointed at
  a hole would be a leak with a doc comment on it. D.6.5's link-down, detach and stop order are a
  different ladder and still D.6.5's.

  Four seams, each a thing that is not a decision: `Spawner::open` is the fork (so everything on this
  side of it is assertable with no PTY in the process), `Peer` is the connection reduced to an ack
  and an id, `HookRoutes` is the listener half of a hook route whose table half lands here, and
  `HostObserver` is the two things a ladder tells the outside. A fifth, `Offload`, is not about
  layering at all: `SubChannel::send` PARKS on a condvar until the peer grants credit, and the grants
  arrive on the connection's own link threads — so an inline replay would not deadlock, but it would
  stall every other open on that connection for as long as the replay takes. The join and the
  reattach go through it; the fresh fork stays inline, because a fork is bounded work with no credit
  window in it. The Swift split them the same way for the same reason.

  Two holes, named rather than skipped. `WorkspaceChannels` is **D.6.4**'s, and its default DECLINES
  — which is what this host does today for a class it does not serve. And `Transcripts` grew two
  questions (`restore`, `resume_point`) rather than a client, because the journal store is still
  Swift's.

  One gap in `slopdesk-hostsession` was filled the way D.6.1 filled three: `PaneSession` had
  `resize.add_contributor` only internally, so a reattach — which replaces the primary the detach
  retired, under the same id — had no way to re-file the returning client in the size fold. A client
  that contributed nothing is clamped by whoever else is watching, at a size its own window never
  asked for, and the returning device may not be the one that left.

  Five of the 45 tests are about something that LEAKS rather than something that breaks: a join that
  refuses retiring its own reservation, a rebind that refuses re-parking rather than stranding a live
  shell outside both the table and the store, a close taking every key that aliases one pane, a
  parked pane's late exit standing down instead of releasing a route its successor re-registered, and
  a stop racing a fork not filing into a table whose drain has already run.

  **D.6.3 ✅ landed** — the adoption ladder, as `rust/slopdesk-hostserver/src/adopt.rs` plus 20
  tests, over one new pure decision in `slopdesk_muxsession::open_route`. `adoptSurvivingPanes`,
  `adoptSurvivingPane`, `reportUnclaimedPanes`, `resumePointForSurvivor`, `ownerIdentity` and the
  three static note keepers around them.

  The decision is `survivor`, and it is a table because the two ways to get it wrong are both
  unrecoverable. Take a pane another live hostd is holding and two daemons share one master fd, one
  journal file and one eviction timer — the second to arm a TTL `SIGHUP`s a pane somebody is typing
  into. Refuse a pane that IS ours and the shell survives perfectly and reaches no tab ever again:
  in no map, in no store, and read as a stranger's by every later `start()`. Four verdicts, not two,
  because "not adopted" covers a panel backend that will be adopted in a minute, a stranger's pane
  that must never be, and one of our own that another daemon is holding — three different futures,
  and an operator deciding whether to `slopdesk-ctl` something needs to know which.

  `LetGo` is the one piece of state, and it is injected through `HostParts` rather than owned by the
  `Host` for the reason the Swift made it `static`: the point is that it OUTLIVES the host that
  wrote it. hostd deliberately never disconnects from superd on stop — a `release` still has to
  travel, and disconnecting there was tried and cut exactly that verb — so superd keeps reporting
  this process's released panes as `attached` for as long as the process lives. An ordinary restart
  hides the question behind `exit(0)`; the menu-bar host, which stops and starts in ONE process,
  does not. The note is spent on SUCCESS and only on success: spending it on an attempt is what once
  left a pane in no map, no store, note gone, with superd still calling it attached.

  Two seams. `Survivors` is superd reduced to the two questions the ladder has — is the link up, and
  what is running — narrow so that a ladder cannot reach `release`, `signal` or `subscribe`. And
  `Spawner::adopt` is `Spawner::open`'s sibling for the other way a hostd comes to hold a pane, with
  no client lanes in the request, because nobody has opened a channel on an adopted pane and nobody
  may for hours. `Transcripts::resume_point` became `Transcripts::position`, answering both facts
  superd holds in one call: a fresh fork that discovers a duplicate takes the offset, and this ladder
  takes the offset AND whether it had to be guessed, which is the one case worth a log line.

  **D.6.4 ✅ landed** — the workspace document, its reconciler and the channel session, as
  `workspace.rs`, `subscriber.rs` and `wsserve.rs` plus 40 tests, filling the `WorkspaceChannels`
  hole D.6.2 named. 1321 lines of Swift across five files: `HostWorkspaceDocument` (312),
  `WorkspaceChannelSession` (486), `HostServer+Workspace` (274), `HostWorkspaceStore` (188) and
  `PaneLiveness+Capture` (61).

  **There was no engine here either, and this time the survey says so twice.** Every decision the
  document reaches for was already Rust: the cell algebra, the diff, the snapshot and diff codecs,
  the intent applier, the liveness reconciler and the topology projection are all
  `slopdesk_wire::document`'s, and the per-subscriber ladder is
  `slopdesk_workspace::sync_ladder`'s — the Swift class was already CALLING that ladder through an
  FFI door. What was left is the same thing every other D.6 stage found: order, ownership, and the
  one rule that makes a version number mean anything. `state_num` moves if and only if the VALUE
  changed, which is why `mutate` compares rather than trusting that a closure ran.

  **The slot indirection did not survive the port, and that is the point.** Swift could not hand a
  Rust ladder a `HostWorkspaceState`, so the door minted a `u32` per retained state, Swift filed the
  bytes under it, and every releasing call handed back a list Swift had to remember to delete from.
  A slot released but never deleted is one whole workspace document leaked per frame, per
  subscriber, for the life of the daemon — and no wire assertion would ever see it, which is why the
  Swift carried a test seam that did nothing but count. `sync_ladder::Retention<T>` owns both halves
  now, so the failure does not become unlikely; it stops existing, because there is no call that
  frees a slot without dropping its payload in the same statement. `T` is `Arc<HostWorkspaceState>`,
  so a broadcast to N subscribers is N refcount bumps and a diff's base is one more — never a copy
  of the tree.

  **The send path is a thread parked on a condvar, and the queue in front of it is depth-1.** The
  Swift needed a `Task` because `channel.send` was `async`; here the control sub-channel's send is
  synchronous, but it can still BLOCK on a socket whose buffer is full, and a fan-out that blocked
  in the document's own broadcast would stall every other subscriber behind the slowest one. What
  did NOT change is the coalescing: a pending offer is DISCARDED AND RECOMPUTED, never queued, so
  host memory is O(clients × state) no matter how asleep an iPhone is. `drain` is the pump's whole
  body and is public to the crate, so the suite asserts the function that ships rather than a
  scheduler; one test starts a real pump, because "a delivery wakes the thread" is the one claim
  inline draining cannot make.

  Three seams, each a thing this crate must not decide. `WorkspaceStore` is the file — the document
  says WHEN to save and knows nothing about a path, a debounce or an atomic rename, exactly as
  `Transcripts` holds the journal; its disk half is the store's own port, and `NoStore` is what a
  host with no Application Support already does. `Panes` is the server's live session maps, held
  WEAKLY and asked at broadcast time, because a copy kept in the document is one more thing that can
  go stale — the same weak capture the Swift wrote, for the same reason. And the intent applier's
  four id mints go through the crate's one entropy seam, `SessionIds`, rather than a second one.

  The two orderings worth naming, because both are silent when wrong. `apply_intent` computes the
  panes the topology STOPPED placing under the same lock as the apply — a set read afterwards could
  have moved, and what it feeds is a `reap` that kills shells. And the store is offered the document
  only on a topology change, never on a reconciler tick: liveness does not survive a restart, so
  offering it would rewrite the same filtered bytes every tick for a host nobody is using.

  **D.6.5 ✅ landed** — link-down, detach and the stop order, as
  `rust/slopdesk-hostserver/src/lifecycle.rs` plus 24 tests, and it closes stage D's last ladder.
  `handleLinkDown`, `leavePaneChannel`, `reapPanesRemovedFromTopology`, `wireSubscriberEviction`,
  `reresolveSizePassivity`, `detachMuxSession` and `stop()` with its four drains.

  **The finding that shaped the module is that there are FOUR endings, not one.** A client leaving a
  shared pane, a link dropping, the topology deleting a pane, and the daemon stopping: the same four
  objects — a pane, a key, a link, a note — come out in a different state depending on which door
  they left by, and every test in the suite is about a DIFFERENCE between two of them rather than
  about a value. Two of those doors were once the same code path, and separating them is the whole
  product change `docs/51` is about: "this daemon is going away" is not "these panes are over".

  **Refcounted, except in the one place it must not be.** Under a fan-out one pane is named by N
  keys, so a peer's `channelClose` goes through `Pane::remove_subscriber` and reaps only on the
  `true` it returns — reaping there would take down another client's running agent, the over-reap
  `docs/45` §8.6 rules out. `Host::leave_channel` is therefore the door a close verb must use, and
  D.6.2's `close_channel` is the UNREFCOUNTED one behind it, kept for the child-exit route where a
  dead shell really does end the pane for everyone. The topology reap is blind on purpose, and that
  is the same section's other half: `closePane` is a layout fact, not a socket event, and a shell
  left alive there is the ORPHAN. Both halves are load-bearing, which is why they are two functions
  rather than one with a flag.

  **The stop's order is the module's real content, and two of its nine steps are silent when wrong.**
  The note goes FIRST — `mark_stopping`, then `note_panes_let_go` — because the note is an
  enumeration of the live tables and a drained table enumerates to nothing; the writer is D.6.3's,
  and this is the call site the forward reference promised. And the relinquish is parallel AND
  JOINED: `stop` does not return until the last pane is done, because hostd's duplicate of every
  master must be closed before the process calls `exit(0)` or a half-torn-down pane's last bytes
  never reach its journal. `Offload` has no handle to join, so the wait is an `mpsc` counted to N
  against one deadline for the whole set — with a disconnect (the offload refused a thread) and a
  timeout both ENDING it, because a stop that cannot finish is worse than a stop that finished
  without one pane's last bytes. One test uses a real `Threads` pool and a pane that stalls its
  teardown, because a join is the one claim an inline offload makes true by construction.

  **One Swift branch did not survive, and `slopdesk-hostnet` predicted which one.** The Swift
  link-down runs its detach loop only `if detachEnabled`, so a host with retention off drops the
  link and leaves its panes in the live map — the branch hostnet's own module doc names when it says
  policy is the owner's and "that also removes the branch in the Swift where the detach path must
  remember NOT to run the kill loop." Here the loop always runs and `Host::park` is what differs: no
  store means nowhere to park, so the pane is ENDED. Same two outcomes, one path, and no arrangement
  of flags that leaves a shell in a table nobody will drain.

  Three seams grew, all of them small. `Peer` gained `close_channel(channel, reason)` and `close()` —
  it was "an ack and an id", and it is now "an ack, an id, and the two ways a ladder ends something";
  the reason is `slopdesk_wire`'s existing `MuxCloseReason`, because `Retired` and
  `SubscriberEvicted` are already on the golden wire and they mean different things to a client
  (a re-open is a SPAWN, versus a reattach). `WorkspaceChannels` gained `drop_connection` — a
  subscriber lives and dies with its LINK, since presence is connection-scoped — and `shutdown`,
  which is the stop's workspace half in its own order. And `Host` grew the connection table itself:
  an eviction and a topology reap have to close a channel on a link they were not called from, and
  the stop has to close every link that is still open INCLUDING the ones carrying no channel, which
  is the half that makes it a fix for the `EMFILE` drift rather than for the visible part of it.

  One thing moved rather than being added: `resolve_size_passivity` now carries the VERDICT instead
  of looking it up. The device kind arrives on the subscribe and the fold lives in the server, so
  passing it keeps one fact in one place rather than asking two halves to agree about which channel
  a connection has. An unknown kind still CONTRIBUTES — that is the shipped `slopdesk-client` CLI,
  which only ever opens class 0 or 2, and defaulting a device the host cannot name to passive would
  leave it unable to size its own pane.

  **The hole this stage names rather than fills — ✅ CLOSED, and the reason it looked bigger than it
  was.** `Panes::capture` and `Panes::roster` — the reconciler's live inventory — were not landed
  with D.6.5. `reap` and `resolve_size_passivity` are the two the ending ladders own and both were
  implemented; the other two were held back for what this section called "the per-pane truth
  reducer (`PaneTruths.swift`, 515 lines)".

  That reading was **wrong, and worth recording as wrong**: `PaneTruths.swift` is not a reducer. The
  reducer is `slopdesk_muxsession::truths` and has been Rust since before stage D — 1141 lines of
  it, holding every latch the capture reads. The 515 Swift lines are the FFI face over it: a
  `FactTable` that interns a batch into `(rows, arena)`, the two-call buffer convention over each
  `slopdesk_pane_truths_*` door, and the marshalling back into `WireMessage`. There was nothing
  there to port, and a line count over `Sources/SlopDeskHost` cannot tell a FOLD from a FACE — which
  is the one thing a "what is still portable" audit has to check by reading, and the reason this
  section names both files rather than a number. Stage F deletes `PaneTruths.swift` with the rest of
  `Sources/SlopDeskHost`.

  So what actually landed is COMPOSITION, in three pieces. `slopdesk-hostserver/src/capture.rs` —
  one pane's latches as the two records, and only the four decisions that have to be made the same
  way by the host and by the client's mirror (the two titles `None`/`Some("")` tell apart, the
  freshness verdict through `slopdesk_wire::document::fields::title_is_fresh` so both ends ask ONE
  function, the suppressed all-zero agent row, and `liveness` riding in because it is the server's
  fact). `slopdesk-hostserver/src/panes.rs` — `impl Panes for Host` over the three disjoint
  inventories, with the roster's member → connection → client-instance join. And two accessors that
  did not exist: `PaneSession::latches` (`slopdesk-hostsession`), which reads every latch a capture
  needs in ONE acquisition of the folds lock rather than one per field, and
  `PaneDetector::foreground_name`
  (`slopdesk-agent`), which hands back the poll's LATCH — the Swift capture read the watcher's latch
  for a reason, and `PaneSession::foreground_name` is a `tcgetpgrp`+`proc_pidpath` pair the sweep
  would otherwise pay per pane per tick. 12 tests in `tests/panes.rs`, 12 more in `capture.rs`.

  ✅ **The laggard-EVICTION wiring, closed after it.** `Host::evict_subscriber` had been the server
  half for two ladders with nothing to call it: `slopdesk-muxsession::fanout` already decided WHICH
  members lose — behind the healthiest, over the threshold, never with a set of one, each latched so
  the verdict fires once — and `slopdesk-hostsession` held the fold and never asked it. What was
  missing was the ASKING, and it is `Shared::evict_lagging`: three un-nested acquisitions in the
  `docs/59` step-3 order (the roster answers which cursors are behind, the ring prices each, the
  roster latches the losers), fired from BOTH ends of the flow because the two miss opposite cases —
  a member that has stopped acking never reaches the ack path, and a pane whose every sender is
  parked ships nothing, which is exactly when dropping the slowest is what releases the retention
  the fastest is waiting on. The producer end is the tail of `drain::ship`, NOT `note_sent`: that one
  runs on a member's sender thread and goes silent in the very case the rule is for.

  Two things about it are contracts rather than choices. The close is fired on a thread carrying the
  SEAM and the id and nothing else — a laggard is by definition parked inside the sender the
  eviction cancels, and both call sites can be reached from a thread that park is starving, so an
  inline fire would wait on the condition it exists to break; carrying no `Shared` also keeps the
  thread out of the `live_threads` census, so a teardown has nothing there to wait for. And the log
  line is `slopdesk-ops soak`'s, word for word — the soak asserts eviction took the LAGGARD and not
  the session by reading it back. The threshold arrives as a NUMBER rather than being read from
  `SLOPDESK_SUB_LAG_BYTES` here, for the reason the ring's caps do: the environment is the server's.
  `Eviction::off()` — no threshold, no seam — is the default, so a `slopdesk-ctl` pane neither evicts
  nor pays the O(retained history) pricing walk. 3 tests over a real PTY and two real members.

  What stage F still owes this corner: the `SLOPDESK_SUB_LAG_BYTES` read itself. It is not among the
  seven in `gates.rs` — `slopdesk-ffi`'s `pane_fanout` reads it today for the Swift face, and the
  Rust hostd reads it once and hands it to each `SessionConfig`.

  **What stage D does NOT take.** `HostEnvironment` (350) and `RepoStatusWatcher` (316) are stage E:
  the first reads Apple bundle and TCC state, the second is an FSEvents stream per repo toplevel.

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

**Stage E ✅ landed** — three framework crates and the two folds over them:
`rust/slopdesk-apple-fsevents` (4 tests), `rust/slopdesk-apple-pasteboard` (12),
`slopdesk_apple_app::{open_path, reveal_path}` (1 more), and
`rust/slopdesk-hostserver/src/{clipsync,pathaction}.rs` plus 36 tests. `§7`'s row is
`one-rust-home-per-apple-area` in `rules/apple_floors.rs`.

**The FSEvents callback carries NO context pointer, and that is the whole design.**
`RepoStatusWatcher.fsEventsSource` round-trips an `Unmanaged<EventBox>` through
`FSEventStreamContext.info` with a manual `release` callback and a hand-balanced `box.release()` on
the create-failure arm. In Rust that is `Box::into_raw` plus a raw-pointer dereference in the
callback — exactly what `docs/57` §2 bars this family from writing. So the context is NULL and the
callback keys off the `FSEventStreamRef` ADDRESS in a process-wide `Mutex<HashMap<usize, Listener>>`,
typed `usize` so "this is never dereferenced" is a promise the compiler keeps rather than a comment.
The one race the pointer version has, a callback already dispatched when `Drop` runs, resolves here
to a `None` that does nothing; there it is a use-after-free. **The Get-rule admission the paragraph
above predicted is therefore never spent** — the borrowed `FSEventStreamRef` is a map KEY, not a
retained object, and it is not a CF object anyway: it carries its own
`FSEventStreamRetain`/`Release` pair rather than `CFRetain`. The row is removed AFTER
stop → invalidate → release, in that order, and the leak test asserts the listener's
`Arc::strong_count` goes 2 → 1 on drop.

**One test had to be rewritten around a framework fact rather than around the wrapper.** The
obvious create-failure test — `FSEventStreamCreate` with an empty path — does not fail: the
framework validates no path and hands back a stream that simply never reports. `docs/57` §2 does not
let a wrapper invent a refusal the framework declines to make, so the test became
`a_watch_the_framework_will_never_report_on_is_still_balanced`: an inert watch is still balanced on
drop, which is the claim that was actually worth pinning.

**`NSBitmapImageRep` is inside the pasteboard's area, and `NSWorkspace`'s two verbs are inside the
app's.** Neither is a new crate, and both are `docs/57` §2's unit — a framework AREA — read
straight. The board's own contract is that an image clip is declared under several types and a
reader picks one, so "the TIFF flavour, as PNG" is a question about THIS board; splitting it would
force the fold above to decide which half to ask, which is the decision §2 keeps out of wrapper
crates. And the module note that bars `frontmostApplication` bars it because it is a per-process
SNAPSHOT that freezes in a daemon — `openURL:` and `activateFileViewerSelectingURLs:` are EFFECTS
with nothing cached to go stale, so the bar does not reach them.

**Neither fold is WIRED into `metadata`'s routing, on purpose.** The pasteboard and the Finder are
host-GLOBAL, and §5's carve-out means the Swift hostd is still running: a second performer over
either would be two implementations of one machine's clipboard for as long as both processes live.
`HostMetadata`'s own module doc already makes this argument for the three verbs it could serve
today. Stage F retires that hostd and injects these.

**Two spellings of the same UTI, closed before they could drift.** `clipsync` must build with no
`AppKit`, so it types `"org.nspasteboard.ConcealedType"` and `"public.file-url"` itself.
`Flavour::uti()` exists purely so the fold's suite can assert both against what the framework
actually declares — the `docs/55` §6 `process::basename` shape, where two implementations disagreed
for a month.

**One deliberate behaviour difference from the Swift, and one bug the port found.** `~user` is not
expanded: it needs a `getpwnam`, no verb in this repository can produce such a path, and it is
refused rather than resolved — the closed answer. The bug is the EMPTY-home arm: `format!("{}/{rest}",
"")` is `/rest`, which is ABSOLUTE, so a daemon launched without `HOME` would have silently reread
`~/Documents` as the root's `Documents`. The Rust refuses every tilde against an empty home.

**The watcher fold ✅ landed too** — `rust/slopdesk-hostserver/src/repowatch.rs` plus 15 tests, the
caller `slopdesk-apple-fsevents` was written for. `RepoStatusWatcher` (316) is a face over
`slopdesk_muxsession::repo_watch` already, so what moved is the machinery AROUND the fold: the table
of live watches, the debounce, and the thread the reading runs on.

**The serial queue is gone, and two locks replace it in ONE order.** The Swift confines every field
to `slopdesk.host.repo-watch` and pays for it with a second concurrent queue, because a reading is a
walk over someone's worktree and a wedged mount must not freeze refcounting, another repo's event
delivery, or the stop. Here `rules` is the fold and `handles` is the live-watch table, taken in that
order and NEITHER held while a door is called — which is load-bearing rather than tidy: dropping a
`slopdesk_apple_fsevents::Watch` takes that crate's own registry lock from inside `Drop`, so a watch
firing while it is being dropped would otherwise wait on a lock this side holds. The reading is
`Offload`'s, which D.6.2 already built, so the second queue is not replaced by anything.

**The stop empties the live table WHOLESALE, and that is the one place the two tables disagree.**
The fold's list is what it believes is watched; the table is what actually is. A repo whose watch
the framework refused is in the first and not the second — the Swift's own `startSourceOnQueue`
comment says so — so a stop that cancelled key-by-key off the fold's list would leave that row
behind forever. Two tests pin the pair: a refused watch leaves both tables agreeing that nothing is
live, and a stop takes a row the fold does not know about.

**The debounce is a queue this suite drains by hand, which is what made the ORDER testable.** The
Swift's seams could hand in a fake event source and a fake probe, but never say WHEN a timer fired
relative to a reading returning — the serial queue decided that. So the suite asks the questions
that were previously unreachable: a thousand bursts arm a thousand timers and cost ONE walk, a repo
released before its debounce fires is an ordinary answer, and a dropped watcher lets a pending timer
resolve to nothing because the callbacks hold `Weak` rather than `Arc`.

**Nothing constructs a `RepoWatcher` yet, and that is §5's carve-out too.** `RepoStatusWatcher` keeps
serving the running hostd, exactly as the two performer folds above do; the difference is that this
one has no routing to be wired INTO — it is a lifecycle, so stage F starts it where hostd starts the
Swift one today. Until then it is linked by nothing shipping, and
`one-rust-home-per-apple-area` is what holds the line meanwhile.

**The gate table ✅ landed too, and it closes `HostEnvironment`.** `rust/slopdesk-hostserver/src/gates.rs`
plus 7 tests. This was never a framework port: `HostEnvironment` (350) is `SLOPDESK_*` gate
resolution, an `EnvConfig` overlay, and four FFI faces (`spawn_env`, `terminfo`, the two login-shell
answers) whose rules were already Rust. What was still TYPED in Swift was seven gates and two `TERM`
names, and the gates were the part that could go wrong quietly: each was a `static func` beside its
own key hand-writing one of the project's two polarity idioms, and the wrong idiom on
`SLOPDESK_IPC_ALLOW_SEND_KEYS` ships key injection into a live PTY ENABLED to every user who never
set it. As a table the polarity is one declared field per row, and one test prints the whole shipped
answer.

Three things stayed put, each for a reason that does not change by moving language. The build
version is passed INTO `spawn_env` rather than minted behind it, because `just release` rewrites
every site the marketing version is typed and a copy inside an unscanned crate is a version that
silently stops being bumped. The five keys hostd EXPORTS into a spawned pane were already
`slopdesk_muxsession::spawn_env`'s constants, so the Swift ones are duplicates stage F deletes rather
than anything to port. And `EnvConfig` itself is the CLIENT's overlay too — the env → settings
precedence over ~192 flags — so the lookup stays the caller's here exactly as
`slopdesk_video::host_gates` has it, and a gate that read `std::env::var` directly would quietly
stop honouring a setting. The two `TERM` names are the one thing that moved rather than stayed:
`spawn_env` resolves what it is handed and knows neither of them, which makes the choice hostd's,
and hostd is what this crate composes. So for as long as the carve-out runs, the seven keys and the
two names ARE typed twice — `shared_constants` cannot see either pair, since it reads numbers and
these are strings — and what closes that is stage F deleting `Sources/SlopDeskHost` outright, not a
ratchet.

With that, stage E has no open half left. What remains before the cutover is stage F's own work.

**Stage F — the cutover.** `Sources/slopdesk-hostd/main.swift` (382) becomes
`rust/slopdesk-hostd`; `just host-restart` and `slopdesk-hostlaunch` retarget; `Sources/SlopDeskHost`
and the host half of `Sources/SlopDeskTransport` are DELETED, with their tests ported to the crates
that now hold the behaviour.

**F.1 — the doors, and the accept loop. ✅ LANDED.** Two greps settled what F.1 actually contains,
and the answer was not "translate `main.swift`". `git grep -ln 'slopdesk-hostnet\|slopdesk-hostserver\|slopdesk-hostpane' -- '*.toml'`
returned only the three crates themselves: NOTHING in the tree linked them, so every trait stage D
left open had test implementations and no production one. `rust/slopdesk-hostd` is where they meet.
Seven doors and the loop:

| module | door | the other half |
| --- | --- | --- |
| `peer.rs` | `Peer` | a mux connection |
| `spawn.rs` | `Spawner` | superd's fork, and the session around its master |
| `transcripts.rs` | `Transcripts` | superd's journal, and the chain that renders it |
| `screen.rs` | `SnapshotPolicy`, `ScreenOracle` | screend |
| `resolve.rs` | `ResolveExecutor` | the pane's one serial queue |
| `keys.rs` | `KeyObserver` | the repo-watch refcounts |
| `evict.rs` | `EvictionSeam` | `Host::evict_subscriber` |
| `serve.rs` | — | the accept loop: `Listener` in, `Host` calls out |

Three things F.1 settled that were open questions before it:

- **The laggard's other end is built** (§4's F-owes note above). `Recipe::lag_bytes` is the one place
  `SLOPDESK_SUB_LAG_BYTES` will be handed in, and the seam it pairs with resolves the circularity —
  spawner-before-host, pane-after-session — through a `OnceLock<Weak<Host>>`. What is left is one
  environment read at F.2's assembly and the `publish` call after `Host::assemble`; a seam whose host
  has not landed evicts nobody, which is what `Eviction::off()` already meant.
- **A standalone pane needs no null sub-channels.** The Swift built `MuxSubChannel.makeNull` pairs
  for a ctl-spawned pane so its relay loops would exit and the offline gate would engage.
  `Shared::recompute_client_online` is `member_count() > 0`, so a session with an empty roster IS
  the offline shape: the null objects satisfied a constructor, not a behaviour.
- **`PaneSession::seed_restored` was the missing half of the restore.** `Fresh`/`Adopted` both carry
  a `Restored`, and nothing in `slopdesk-hostsession` could accept one — a fresh open does not
  replay, so a ring pre-seeded before construction would have held history the attached client never
  saw. The Swift enqueued the transcript through the ordinary FIFO; the Rust appends one chunk
  before `start()`, which is the same ordering guarantee with the window closed by construction
  rather than by a comment.

**A correction to the sentence above.** F.1's own notes said `HostQuerying` had no production
implementation and that the metadata performer was therefore F.2's assembly work. That was wrong on
the first half: `HostQueries::from_environment()` exists, and `HostMetadata::unaccompanied(query)`
carries the doc comment *"the honest shape for a host built without the Swift half, and what stage F
leaves behind once there is no Swift half to build."* The performer was a wiring line, not a port,
and F.2 wires it. What IS owed is the other twelve verbs' Rust performers — see the ledger below.

**F.2 — the daemon shell. ✅ LANDED.** `src/main.rs`, and the crate ships a `[[bin]]` again.

| Step | Why it is where it is |
| --- | --- |
| `pthread_sigmask` | FIRST. Threads inherit the mask; a SIGTERM landing on superd's reader thread before this takes the default disposition and kills the process mid-drain. |
| `setrlimit` | Before any file opens. Every live and detached pane holds a PTY master and a journal fd. |
| the sidecar overlay | Before any gate is read. `docs/58`: no GUI, no live reload — a toggle applies at the next launch, and this is that launch. |
| `integration install\|uninstall` | Before the arg parse, so it never reaches the listener. |
| the hook install | Idempotent, every launch, never fatal. |
| `SupervisorClient::connect` | The one fatal step before the bind: nothing else in this process can fork a shell. |
| `Host::assemble` → `LateHost::publish` → `serve_control` | The spawner is built before the host and the host holds the spawner. Both late-bound handles land the moment the cycle closes. |
| `listen` → `adopt_survivors` → `Listening::start` | Adopt BEFORE accepting, or a client that connects first is offered a fresh shell for a pane that is still running. |
| `sigwait` | The one blocking call in the process. No one-shot latch: a second SIGTERM during the drain is simply still blocked. |

Four things settled while writing it, each of which had been assumed the other way:

- **The settings overlay had to move with the daemon.** `slopdesk_video::host_gates` takes RESOLVED
  TEXTS precisely because the lookup was Swift's `EnvConfig.string` — env → `video-prefs.json` →
  default. A Rust hostd reading `std::env::var` would silently stop honouring every persisted
  setting. `src/env.rs` is that lookup. It reads the sidecar's `agent` table and `rawOverrides` and
  deliberately NOT `video`: those eleven keys are `slopdesk-videohostd`'s operating point, that
  daemon folds the same file itself, and mapping them here would be a second copy of
  `EnvBridge.toEnv(_: VideoPreferences)`. One behaviour difference, stated rather than hidden — Swift
  resolved six of the seven gates through the overlay and `SLOPDESK_AGENT_CONTROL` through
  `ProcessInfo` alone; here all seven go through the same door, because a raw override IS the
  documented way to reach a host-only knob and the one key it could not reach was the one the box
  exists for.
- **`Pane` had to grow `fold_hook`.** The hook table is keyed by the env-baked pane id and holds
  `Arc<dyn Pane>`; only `PaneSession` had the verb. Two implementors, so the widening cost two
  sites — `LivePane` forwards, `Ghost` records. The alternative was a second table beside the first,
  keyed the same way, holding the sessions.
- **The bytes→event match moved to `slopdesk_agent::signal::hook_event_of`.** It was private to
  `slopdesk-ffi`, under a comment saying it existed once *on purpose*. The moment hostd grew a hook
  listener that claim stopped being true of where it lived — so it moved to the crate that owns the
  vocabulary it maps INTO, and is now the one spelling both callers reach.
- **The version site did NOT move yet.** `just release` still rewrites `HostEnvironment.buildVersion`,
  because the Swift hostd is what `just build` produces until the cutover. `main.rs` reads
  `env!("CARGO_PKG_VERSION")` and the manifest carries `0.4.0`; at the cutover `release/sites.rs`
  swaps the Swift entry for this one and the count of six stays six.

**F.3 — the wiring cluster. ✅ LANDED.** Seven of the ten rows below were one batch, because they
share one shape: each is a door stage D declared and stage E left without a production
implementation, and each needs the composition to exist before it can be filled.

| Wired | What it took |
| --- | --- |
| the repo-watch sink | `Recipe.keys` now carries `hostd::repowatch::Keys`, which erases `RepoWatcher`'s four type parameters once, where the concrete doors are already named. The watcher is built BEFORE the spawner and AFTER the document, which is the only order that works. |
| `Announces` | `hostd::repowatch::Fanout`. One reading has TWO destinations and they are not the same fact: type 35 on every live pane (the edge, delivered now) and `project/gitSummary` in the document (the retained value, keyed by PROJECT). The document's copy is the type-35 BODY verbatim, so it costs no new codec on either end. |
| `Pane::push_git_status` | The fan-in offers the status to every live pane and lets each one's LATCH refuse — a fan-in that filtered by reading the latch itself would compare against a value that may have moved. `PaneSession::push_project_git_status` is the compare and the send as one statement. |
| `WorkspaceStore`'s disk half | `hostd::workspacestore::DiskWorkspace`: `SLOPDESK_WORKSPACE_STATE_DIR` or the container, a depth-1 coalescing 600 ms debounce, write-to-temp-then-rename by hand (`std::fs` has no `.atomic`), and a corrupt-or-topology-less file moved ASIDE rather than overwritten. |
| the default document | `TreeWorkspace::new(vec![], None).normalized(&mut Minting::over(ids))` — an EMPTY tree normalises into one session, one tab, one pane, so the first-run shape is stated in `slopdesk-tree`'s own repair rather than a second time in the store. `Minting` went public for exactly this. |
| prevent-sleep | `hostd::sleep::KeepAwake`, and it is NOT the Swift's shape. `SleepAssertion` holds a `CFString` and is therefore neither `Send` nor `Sync`, and a `slopdesk-apple-*` crate may not `unsafe impl` its way out of that — an `unsafe impl Send` is a claim about RUST, not about a framework. So the fold and the assertion are CONFINED to one owner thread fed by a FIFO channel: the update and the apply are not merely adjacent, they are unreachable from anywhere the order could be broken. |
| `SLOPDESK_DETACH_MAX_SESSIONS` | `DetachedStore::capped`. A non-positive or unparsable value is NOT a cap of zero — it is the absence of one, which is what keeps a typo from silently killing every parked pane but the newest. |

**F.4 — the twelve delegated metadata verbs. ✅ LANDED.** One batch, because the twelve share one
question — *who runs this verb* — and the Swift answered it six times.

| Wired | What it took |
| --- | --- |
| the routing table | `hostserver::route::Performers`, six seats, one `match` on `MetadataRequest::performer`. `MuxChannelSession.serveMetadata` asked six shims in a fixed order and took the first non-`nil`, so every shim carried its OWN copy of "is this my verb" and a `default:` arm reasoning about verbs it did not own — six opinions about one table, with nothing checking they agreed, while `metadata_admission::performer` was already the single answer and was consulted by nobody on this path. It is `HostMetadata`'s delegate, which is the carve-out that seam was built for. |
| verbs 9–10, 15–16 | `pathaction::PathActions` over `Finder` and `clipsync::Clipboard` over `GeneralBoard`, both stage-E work that only needed a seat. That is the last row of "the two unwired stage-E pieces". |
| verbs 11–13 | `hostserver::agentaction::AgentActions` over `hostd::services::ClaudeHooks`. The listener flag is a CLOSURE read at perform time, not a `bool` captured at composition: the listener claim happens after the table is built, so a frozen flag would report `false` to every client for the daemon's life. `main`'s launch-time install now goes through the same door as verb 11. |
| verbs 21–22 | ONE type. `hostserver::ensure::EnsuredService` over a `Profile`, because the two Swift managers plus their two shims — four files, ~330 lines — differed in exactly five values: the binary, the argv, the port parser, whether a version rides the same line, and what a spawn that THREW reports. A third ensure verb is now a fifth constant and no new lifecycle. |
| verbs 18–20 | `hostserver::codeaction::CodeActions` over the stage-E `CodeServerManager`, and with it the code-server prewarm, which `main` now calls after the bind. Verb 19's path validation is `pathaction::absolute_host_path` — the Swift had that rule twice and the two copies had already drifted on `~user`. |
| the ten `CodeServerSeams` | `hostd::services`. `CodeSeed.swift` forked `slopdesk-codeseed` six ways and parsed a JSON object off its stdout because Swift could not link it; hostd links it, so the six questions are six function calls. `AndroidServiceManager.announceMarker` was a string literal kept equal to `androidd`'s `server.rs` by a lint rule; the profile now names `slopdesk_androidd::server::ANNOUNCE_PREFIX` itself. `HostServiceProcess.locate` re-implemented a search order `toolchain::locate_tool` already owned — including a disagreement about what makes a candidate executable that no test could see. |

**What F.4 left owed — the parity ledger the cutover was gated on. ✅ EMPTY.** Nothing on this list
dropped off silently; each was a real behaviour the Swift hostd had and the Rust one did not.

| Owed | Where it went |
| --- | --- |
| the host DISPLAY NAME | ~~The workspace label. Swift read `Host.current().localizedName` and fell back to the POSIX hostname; `DiskWorkspace` read the POSIX hostname only.~~ **F.7 below.** The ledger's reasoning was wrong in a way worth keeping visible: it named `SCDynamicStoreCopyComputedName` because that is where the computed name LIVES, and concluded the row wanted a SystemConfiguration crate. The Swift never called it. `Host.current().localizedName` is `NSHost`, Foundation reads the store on the caller's behalf, and the literal port cost no `unsafe` at all. |

**F.5 — the two daemons hostd picks the port for, and the audit that keeps them honest. ✅ LANDED.**
One batch, because the version audit's whole subject is the set of daemons the rest of the batch
stands up, and auditing three of five would have been a report nobody could read.

| Wired | What it took |
| --- | --- |
| PATHS 3 and 4 | `hostd::sidecar::Sidecar`, one type over a private `Profile`, and `main` stands both up from the REAL bound port. `InspectorServiceManager.swift` and `FileDropServiceManager.swift` were the same lifecycle written out twice down to the blank lines, differing in FOUR values: the socket's name, its announce marker, its argv and the variable that overrides its binary. The lifecycle was already `AnnouncedPortService`; only the four values are new. |
| the restart that cannot move the drop directory | The face HOLDS its port and its argv, so `Sidecar::restart` takes no arguments. The Swift auditor could only re-open dropd by being handed the port and the directory again — four extra parameters threaded from `main.swift` through `HostServer.auditSidecarVersions` — and its own comment says what that was guarding against. A face that keeps its argv cannot move it, and the four parameters are gone from the signature rather than re-spelled in Rust. |
| the two announce markers | `slopdesk_dropd::server::ANNOUNCE_PREFIX` and `slopdesk_inspectord::server::ANNOUNCE_PREFIX`, named at the source the way F.4 named androidd's. Both crates are linked for one constant each, which is what makes the `sidecar_wires` rules that compare the Swift copies deletable at the cutover instead of re-implemented. |
| the five version audits | `hostd::audit`. `slopdesk-sidecars` already owned the verdict and the policy; what was Swift was the assembly — where each RUNNING version comes from (superd's `hello`, screend's `hello`, the announce line for the other three) and the one remedy a stale verdict permits. The JSON FFI door is off this path entirely: hostd holds the `Report` itself, and `slopdesk_sidecar_audit` stays exported only for the client that still shows one. |
| the relative drop directory, resolved on the RIGHT side | `SLOPDESK_FILE_DROP_DIR=inbox` is one directory in Swift and would have been another in a face-value port. `URL(fileURLWithPath:isDirectory:)` absolutizes against the CALLING process, so the Swift meant hostd's `inbox` — the operator's shell's. Passing the name down unresolved would have let it land against *dropd's* cwd, superd's child, somewhere else on the same disk with no error on either path. `hostd::sidecar::drop_directory` takes the working directory as an argument and answers an absolute path, so the argv the daemon receives already names one place. |
| where this tree's own daemons ARE | `slopdesk_sidecars::paths`, which is `RustServicePaths.locate` for any crate name. It was `slopdesk-screenclient`'s private copy, kept there with a note saying it would move when a second caller existed; there are six now. It has NO `PATH` rung, deliberately — these five ship with the checkout and a same-named binary on someone's `PATH` must never become one — and that also corrects F.4, which had given `slopdesk-androidd` the `locate_tool` order that is for somebody else's programs. |

**F.6 — "run this in my terminal", which had never once run. ✅ LANDED.** One row of the F.4 ledger,
and the smallest landing in stage F: both halves were already written and tested, and the wire
between them was a line nobody had typed.

| Wired | What it took |
| --- | --- |
| the arm the bridge socket was missing | `hostserver::bridgerun::terminal_runner`, installed on `Panels::bridge` from the composition. `CodeBridgeServer` has carried an EMPTY `TerminalRunner` seam since stage E and `bridge_router` has carried the DECISION for just as long, tested on synthetic rows — so every `run` the extension sent came back "no terminal runner is installed". This is the flattening between them: the live pane table into the rows the router reads, and the router's answer into a `write(2)`. |
| the candidate set, which is NARROWER than `list-panes` | `Sessions::live_panes` — attached mux panes, deduped one per pane rather than one per watching client. Not the control listing: a detached pane's shell is live but unwatched, and a standalone control pane belongs to an orchestrator that owns its input. Typing a user's command into either puts it where the user cannot see it happen. The dedupe is not tidiness either — a fanned-out pane is N members and ONE pane, and the failure it prevents is not a wrong choice but a right one made three times at the same prompt. |
| installed BEFORE the prewarm | `prewarm()` is what starts the workbench, and the workbench's first `run` can arrive as soon as it has. The seam therefore goes in one statement earlier in `after_bind`, not after — the ordering is the fix, not a style. |
| a host that is gone REFUSES | The runner holds the host weakly, the way the Swift's `[weak self]` did and for the same reason: the bridge server is the panel table's, not the host's, so a strong handle here would let the shutdown order decide whether the process exits. A pane that went away between the choice and the write is likewise a refusal in words, never a silent drop — the extension is waiting on that reply line to tell the user something. |

**F.7 — the host's own name, and the ledger reaching zero. ✅ LANDED.** The last row of the F.4
parity ledger, which is now empty: every behaviour the Swift hostd has, the Rust one has.

| Wired | What it took |
| --- | --- |
| the workspace LABEL | `slopdesk-apple-machine`, a fourteenth `slopdesk-apple-*` crate holding one function, and `workspacestore::host_display_name` reading it as the first of three rungs. The Swift's order — the name the user SET, then the POSIX hostname, then a constant — is unchanged; what was missing was only its first rung. |
| the ledger's own wrong answer, corrected | The row said the computed name is `SCDynamicStoreCopyComputedName` and so wanted a SystemConfiguration crate. That is where the name LIVES; it is not what the Swift called. `Host.current().localizedName` IS `NSHost`, `objc2-foundation` generates both halves of it SAFE, and the literal port therefore costs **zero** `unsafe` and **neither** §2 admission — where reaching past Foundation would have cost a hand-written block and a Copy-rule admission to return the same string. |
| an EMPTY name is an ABSENT one | At every rung, and it is the one behaviour the port does not take from the Swift verbatim. A host whose Sharing name was cleared answers a zero-length string rather than nothing, and a caller that took it at face value would caption the workspace with a blank — which reads as a bug in the client rather than as a machine nobody named. The crate answers `None` for both, so the ladder has one rung to check instead of two. |
| the four names that are NOT exposed | `NSHost` also answers `name`, `names`, `address` and `addresses`, and each of those RESOLVES — a network lookup that blocks for as long as the resolver takes. A daemon parking a thread on a DNS timeout to draw a caption is the failure the one-function surface forecloses. |
| one `#[expect(deprecated)]`, at the call and not crate-wide | `NSHost.h` says "use Network framework instead", and for those four names it is right — resolution is `Network`'s job now. It says nothing about `localizedName`, because `Network` has no computed-name API; the only alternative is still the `SCDynamicStore` block the row above rejected. So the opt-out is a source-site `#[expect]` carrying that reason, which is what `CLAUDE.md`'s scoped-opt-outs rule requires and what makes the day a replacement ships a compile error rather than a silent staleness. |

**F.8 — the run path retargets, and nothing is deleted yet. ✅ LANDED.** The cutover's first half,
kept deliberately separate from the sweep. Every command that BUILDS or RUNS a host now builds and
runs the cargo one; `Sources/SlopDeskHost` still compiles and the Swift host still exists. That
ordering is the point: the Rust daemon serves a real session — this one — while the Swift fallback is
still there to go back to, which is the one verification no gate performs. F.9 deletes.

| Wired | What it took |
| --- | --- |
| ONE answer to "where is hostd" | `slopdesk-devtools`' new `hostbin` module. Six places spelled the path or the build by hand — four `swift_build(root, "slopdesk-hostd")` calls in the GUI probes, a `.build/debug/…` beside them, one more in the soak runner. Six spellings of a path that just moved is six chances to leave one behind, and the one left behind does not fail: it runs last week's binary, green. |
| `just host` | `cargo build --release` in the crate, where it was `swift build --product` in debug. Release for two reasons that are not taste: the launch record this machine replays names `release`, so a debug build would leave `host-restart` starting a binary the target never touched; and the fan-out and row-scan numbers were measured at `opt-level = 3`, so an unoptimised daemon is a different program. |
| `just host-restart` | The build step only. The ritual around it — read the record up front, build before the stop, SIGTERM never SIGKILL, wait for a real listener — never knew what compiled the binary, so none of it moved. `configuration_of` did not change either: `.build/release` and `target/release` both spell the configuration as a path component. |
| the ONE launch that is REFUSED | A record naming a `.build/` artifact — a daemon started before this batch, still running, whose launch cannot be reproduced by building anything that exists now. Building the cargo binary and then replaying that record would report a fresh build and start the OLD process: exactly the "running last week's code with this week's version on the box" failure `audit.rs` exists to catch. It refuses in words, the way an absent record does, and names the binary to start by hand once. `is_swiftpm_artifact` is pinned against BOTH paths, because `.build` and `target` each hold a `release` component and a one-sided test would pass against a rule that refused every record there is. |
| the release version site | Moved from `Sources/SlopDeskHost/HostEnvironment.swift`'s `buildVersion` to `rust/slopdesk-hostd/Cargo.toml`, which is what the Rust daemon reports (`env!("CARGO_PKG_VERSION")`). MOVED, not added — the count of sites did not change here, and a Swift constant left beside the Rust manifest would have been the third place to forget. (F.9 later took it from six to four, when the host app's `project.yml` and `Info.plist` went with the app; `the_four_sites_are_four` is that count's test.) |
| the soak runner | Now takes the RELEASE daemon and says which of the two binaries is missing. Its four properties — retention, eviction, head-of-line, backpressure — are TIMING, and a debug daemon does not fail them differently, it fails them for a reason that is not the code under test. Its client half is still `swift build`'s, so "run `swift build` first" became the right advice for exactly one of the two. |

**F.8.5 — the menu-bar app stops being a host. ❌ NEVER LANDED; F.9 answered it by deletion.** This
section was marked "✅ LANDED" and was not: no `rust/slopdesk-hostsupervise` was ever committed, no
`slopdesk_host_supervisor_*` door family ever existed, and `HostController.swift` went into F.9 still
importing `SlopDeskHost` and running `HostServer` in-process — the exact thing the section below
claims it replaced. The user's later ruling ("bỏ menubar đi, control host hoàn toàn bằng cli") made
the whole design moot: F.9 deleted `Apps/HostApp-macOS` outright, so the app that needed supervising
is gone and nothing needs a supervisor. **The table below is a design that was written and then
obsoleted — read it as reasoning, not as a description of the tree.** It is kept for the two
arguments in it that outlived it: why the client count is `Sessions::connection_count` and not
`Host::peer_count`, and why hostd's three stderr prefixes are constants rather than a `format!` two
programs merely agree on today.

Its premise is still true and is what F.9 had to deal with: `Apps/HostApp-macOS` linked the
the one thing that would have made F.9 impossible to land: `Apps/HostApp-macOS` linked the
`SlopDeskHost` PRODUCT and ran `HostServer` in-process (`project.yml`'s `product: SlopDeskHost`).
Deleting `Sources/SlopDeskHost` would have taken the app with it. It is not a TCC reason — the
entitlements say so in their own comment, "mirrors slopdesk-hostd, which runs unsandboxed" — so
`CLAUDE.md`'s lifetime rule decides the shape unambiguously: a component that is `execve`d is a
binary, the thing that supervises it is lifetime-coupled to its caller, so the daemon is spawned and
the supervisor links.

| Wired | What it took |
| --- | --- |
| the supervisor | New crate `rust/slopdesk-hostsupervise`, and new door family `slopdesk_host_supervisor_*`. The spawn, the five-state machine, the SIGTERM-then-SIGKILL ladder, the generation guard that drops a dead child's last line, and the parsing are all on the far side. `HostController.swift` went from 183 lines of `HostServer`, `Task`, `AsyncStream` and error classification to a handle, a status mapping and a main-actor hop. |
| the client count, WITHOUT a new wire | hostd already prints `clients holding panes: N` on every real change, `listening on 0.0.0.0:N` once the listener binds, and `failed to start: …` before it exits. The supervisor owns the child's stderr, so all three are already in its hands. The alternative — a `status` verb on the agent-ctl socket — was REJECTED on evidence: that socket is superd's, hostd only CLAIMS it, and the claim is off unless `SLOPDESK_AGENT_CONTROL=1` (`docs/46`). The menu would have shown "Listening" instead of a count whenever the flag was off, and turning the flag on from a menu-bar app would enable remote pane writes as a side effect of drawing a number. |
| that grammar as a CONTRACT | The three prefixes are constants in `slopdesk-hostsupervise::line`, and hostd's `observer.rs` and `main.rs` format from them. A parser and a `format!` that merely agreed today is the drift nothing turns red for — both sides compile, both sides pass, and the menu quietly stops counting. `observer.rs`'s two tests close the other half: they run the app's parser over the bytes `say` actually writes, because sharing a constant makes two ends agree on the WORDS and nothing about it makes them agree on the SHAPE. |
| the count that is the RIGHT count | `Sessions::connection_count` — connections holding at least one pane — which is what `onConnectionCountChanged` carried and what the confirmation "N client(s) — they will be disconnected" has always meant. Deliberately NOT `Host::peer_count`, which counts a client that has subscribed and taken no channel. `host.rs` states the distinction where both live. |
| the Stop/Quit confirmation | Kept, unchanged, and that is the point — it is the one thing in this app that can lose someone's work, and it is gated on a count that had no out-of-process source until this batch. Dropping it would have been a silent removal of a safety confirm. |
| where hostd IS | `docs/46`'s one search order, through the same `locate_tool` seam hostd uses for its own sidecars: the `SLOPDESK_HOSTD_BIN` override, the vendored prefix, `PATH`, then the tail. NOT a parameter from Swift and not a search of its own — `docs/49` deleted the packager's second answer to this question in the previous batch for exactly this reason. |
| the app's Package edges | `project.yml` drops `product: SlopDeskHost` and takes `CSlopDeskFFI` (the door) and `SlopDeskTransport` (`PortValidation`, and the link line — a binary target carries no `linkerSettings`). `Package.swift` gained a `CSlopDeskFFI` library product, because an Xcode target has no way to reach a binary target that only SwiftPM targets depend on. `HostdArguments.defaultPort` became `slopdesk_hostd_default_port()`, the door its Swift wrapper was already forwarding to. |
| one callback, no polling | The near side is told "look again" from a supervisor thread and pulls a whole `Status` in ONE call — one call so a state and its reason cannot be read either side of a transition and render "running, Port 7654 is already in use". The C contract states the three obligations the context carries, and `finish` rings BEFORE it wakes `wait_stopped` so the ordinary teardown cannot free a context out from under a ring. |

**What F.8.5 would have accepted** (recorded because the trade-off is real for any future
supervisor, not because this one exists): quitting by any path that reaches `deinit` stops the
child, a `SIGKILL` of the app does not, and no parent-death watchdog was designed for it. That
orphan would have been the same daemon `just host-restart` replays, with its launch record still
true and `slopdesk-ops` still able to stop it — strictly better than the in-process version, where
the same `SIGKILL` took the host down mid-session with every pane on it. F.9 gets that property for
free: there is no parent.

**F.9 — the Swift host is deleted. ✅ LANDED.** 154 tracked files under `Sources/SlopDeskHost`,
`Tests/SlopDeskHostTests` and `Apps/HostApp-macOS`, plus the `Package.swift` targets that named them
and the last `.executable` product in the manifest.

The app went WITH the host rather than being converted into a supervisor of it. F.8.5 above designed
that conversion and never landed it, and the reason not to finish it is not that it was hard: the
menu bar is deleted and hostd is driven entirely from the CLI, so the only consumer the supervisor
would have had does not exist. A supervisor for nobody is the second implementation `CLAUDE.md`
bans, wearing a Rust hat.

| Wired | What it took |
| --- | --- |
| the gate as the WORK LIST | `just lint-invariants` fails loudly on a missing path rather than passing vacuously, so deleting the Swift turned it red and its output WAS the list: 101 violations, then 78, 64, 31, 25, 20, 8, 0. Nineteen rule modules were re-keyed to Rust paths, each with its break-test rewritten Rust-shaped. |
| the discriminator every re-key used | Not "does this contract span two languages" but **"can the compiler see it?"** hostd LINKS the crate ⇒ the import IS the equality, so the `SameValue`/`SameSet` is DELETED and what stays is a `Matches` that hostd still asks it, plus a ban on reacquiring the literal. Two binaries, or two constants that never meet in an expression (the ctl verbs; the opaque cap's INEQUALITY) ⇒ re-key the paths, KEEP the comparison. The client's Swift is still Swift ⇒ leave the rule alone. |
| the doors that had no caller left | 268 dead FFI entry points, and `slopdesk_supervisor_encode_listen` — orphaned by this batch's own Swift deletion, and caught by `ffi-doors-are-opened` rather than by reading. `rust/slopdesk-ffi` dropped its `slopdesk-probe` edge with it: the `path_confine` door died with hostd. |
| the listener half of `SlopDeskSupervisor` | `onConnection`, `listen(kinds:)`, `deliverConnection`, `SupervisorDoors.listen`, `connectionKind`, `ListenerKind`. Claiming the child-facing listeners is hostd's, and hostd is Rust. `.connection` stays a NAMED event on purpose: an event that stops decoding takes a path that never closes `frame.descriptor`, so deleting the case — the obvious cleanup — would have leaked one fd per frame. The handler is now an unconditional close. |
| the START, which the menu bar had been holding | The gap F.8.5 opened and nobody named: `restart-hostd` replays a launch RECORD, which by construction cannot produce the FIRST one, and the button that used to is gone. `slopdesk-ops install hostd` is that rung — a third `launchd::Agent` beside superd and screend. |
| hostd exiting 0 when it loses the port | Forced by the plist: `SuccessfulExit: false` restarts a job that exits non-zero, so a hostd that met `AddrInUse` with `exit(1)` would be respawned every ten seconds for ever — superd's shipped bug, reintroduced through a different daemon. It is load-bearing twice, because `just host-restart` SIGTERMs a job launchd relaunches, and that relaunch races the replayed one for the port. `keepalive-guarded-exit` pins it: the plist string and the exit branch sit in crates with no edge between them, so no compiler compares them and every test passes either way. |
| the doc citations that could not be repointed | `PATH_TOMBSTONES` went 1 → 13. Twelve are `docs/59`, whose entire subject is which Swift file each Rust handle was cut out of — repointing those names would make the record lie about the thing it records. |
| the SECOND wave of dead doors, which only the iOS triple could see | Deleting the doors left ten `#[cfg(target_os = "macos")]` attributes ORPHANED in `rust/slopdesk-ffi/src/lib.rs` — each had sat above a `pub mod` line that went, so each then gated the NEXT module. Nine ungated doors became macOS-only, every Rust test still passed, and `just ffi` reported success from its content STAMP. `just ffi --always-make` on the `aarch64-apple-ios` triple is what caught it. The stamp is only as good as the last run that actually compiled; `--force` it whenever the stamp itself is in doubt. |
| the vocabulary that had no view left | `AgentScreenDetection.swift` and `AgentDetectionHold.swift`, with `slopdesk_agent_hold_constant`, the whole pane-scan/detector shape family, `SlopDeskPreventSleep` and the pausable-gate marshalling. The test is not "does Swift still compile without it" — it did — but WHO READS IT: a view `switch`es on an agent's KIND and its STATUS, never on a screen verdict, a tuning interval, a working-pane set or a backpressure gate. Those four were the HOST's, and their doors existed only because the host was Swift. `agent_detection`'s FACES list went 3 → 2 and gained two `Claim::Absent`s, on `AgentJobIdentifier.swift`'s precedent. |

**What F.9 accepted, and what Batch B did with it.** `SlopDeskSupervisor` and `SlopDeskScreen` were
still Swift, and they moved together because the second linked the first. So does the video host.
None of them is a host; they were the next batch, not a floor.

**Batch B — the last two host-side Swift targets, and the FFI half that existed only for them.
✅ LANDED.** The finding that decided the shape: after F.9, *nothing imported either target*. Not the
client, not the apps, not a test outside their own two suites — only `Package.swift` still named
them. They compiled, they tested green, and they were hostd's ends of the superd and screend wires
for a hostd that had stopped being Swift. That is precisely the shape `CLAUDE.md`'s
one-implementation rule describes: not a fallback anyone chose, but a second spelling nobody
noticed had been orphaned.

| deleted | lines | why it could go |
| --- | --- | --- |
| `Sources/SlopDeskSupervisor` (8 files) + its suite | 2570 | hostd dials superd through `slopdesk-superclient`, in-process |
| `Sources/SlopDeskScreen` (3 files) + its suite | 804 | hostd dials screend through `slopdesk-screenclient`, in-process |
| `slopdesk-ffi`'s `supervisor_{protocol,batch,frame,paths}.rs` | 3124 | 29 doors, zero callers left |
| `slopdesk-ffi`'s `screen.rs`, `screen_paths.rs` | 535 | 9 doors, zero callers left |
| `slopdesk_ffi.h`'s two declaration regions | 495 | the header is hand-maintained; `slopdesk-gate ffi` catches the drift either way |

**What Batch B had to think about, and it was not the deletion.** Five invariant rules pinned those
Swift files as one side of a cross-language contract — `spawn_request_flags_cross`,
`rendezvous_address`, `one_spelling_of_the_superd_frame`, `a_length_prefix_is_parsed_once`,
`one_encoder_for_screend_frame`, plus `screend`'s address and verb gates. The tempting reading is
that deleting the Swift retires them. It does not, and the distinction is the whole point:

- Where the hop still EXISTS in Rust, the rule was **re-keyed, not retired**. `spawn_request_flags_cross`
  still walks four hops — `Standalone`'s field, hostd filling it from the resolved spawn,
  `PaneSpawner` encoding it, superwire's wire field — because `slopdesk-hostserver`,
  `slopdesk-hostd` and `slopdesk-superwire` are separate crates joined by a `serde` payload whose
  every field has a falsy default. A same-language drift is exactly as silent as the cross-language
  one was; it just no longer LOOKS like drift.
- Where the second copy is GONE, the rule became **structural instead of comparative**. The screend
  status alphabet and the reset flags were `SameValue`/`same_set` pairs; `slopdesk-screenclient`
  *imports* screenwire's constants rather than mirroring them, which is stronger than the two
  agreeing — there is nothing left to disagree. What a ratchet still owes is to catch the mirror
  growing back, so those became "the client reaches it, and declares none of its own".
- One ban genuinely died with its language: the `size_t`/`.max` trap in
  `a_length_prefix_is_parsed_once`. Swift's `ClangImporter` maps `size_t` onto the SIGNED `Int`, so
  an all-ones refusal arrived as `-1` and a `== .max` guard never fired. Both lanes take the refusal
  as an `Option` now, so there is no sentinel to compare wrongly. What replaced it is the ban that
  still bites: unwrapping that `Option`.

**Every re-keyed rule needed its BREAK-TEST re-seeded, and that half is where the work was.** A rule
and its break-test are one artifact: `CLAUDE.md` requires each rule to carry a test that seeds the
drift and asserts the rule fires. Fourteen of those tests still wrote Swift fixtures — a
`SupervisorMessages.swift` with two flag fields, a `ScreenProtocol.swift` with a verb enum, a
`SupervisorPaths.swift` resolving the control socket. Every one of them compiled and every one had
stopped asserting anything, because the rules above them no longer read those paths. The fixtures had
to be re-seeded with the SAME failure spelled in Rust: hostd's flags dropped between
`slopdesk-hostserver` and `slopdesk-hostd`, a `body_length` `Option` unwrapped in
`slopdesk-superclient`, a second `const FLAG_*: u8` in `slopdesk-screenclient`. Two tests could not
be re-seeded and were replaced rather than ported — `a_verb_renumbered_on_one_side_is_caught` had no
second side left, so what it became is `the_verb_enum_moving_out_from_under_the_gate_is_caught`: the
gate reading an empty haystack and passing forever is now the failure it proves. That is the shape to
expect for every later batch, and it is the reason a deletion is never just a deletion here.

It also cost ONE pin its language, and that pin was rebuilt rather than dropped.
`LoopbackWorkspaceDocumentTests.testTheLoopbackAndTheHostDocumentAgreeByteForByte` ran a fixed intent
script through the loopback document and the host document and compared the encoded snapshots — the
decision function is shared (`WorkspaceIntentApplier`) but the versioning around it was written
twice, and drift there is invisible to a suite that runs only one of the two. The second document is
`rust/slopdesk-hostserver`'s `workspace.rs` now, which no Swift test can reach, so the pin is a
CROSS-LANGUAGE one and lives where the tree already keeps those: the
`workspaceDocumentVersioning` group in `golden/golden_vectors.json`, minted by
`Sources/slopdesk-corevectors` through the real `LoopbackWorkspaceDocument` and replayed by
`rust/slopdesk-hostserver/tests/workspace.rs` through the real `WorkspaceDocument`. What it pins is
the LADDER and the state bytes — per step, the op and its args, the verdict, `stateNum`, `pristine`,
whether the step published at all, and the diff the two consecutive documents produce — never the
frames, which go out through `subscriber.rs`'s per-subscriber coalescer and have no loopback
counterpart. Both halves reach the same numbers by opposite routes (this document opens at 1 and
`install` does not bump; the loopback opens at 0 and `install` bumps to 1), so the shared ladder
starts AT the install, and the script may name no op that mints host-side — the Swift side hands the
crate a pool of `UUID()`s and would not reproduce.

**Batch C opens on the corpus, not on the deletion, and that ordering was not obvious.**
`Sources/SlopDeskVideoHost` is 44 files, and 22 of them import nothing but `CSlopDeskFFI` and
`Foundation` — faces over `slopdesk-video` law that hostd, now Rust, reaches directly. The obvious
move is to delete all 22 first. It is illegal, and the thing that makes it illegal is
`Sources/slopdesk-corevectors`, which is KEEP (it pins the Swift MARSHALLING, so rewriting it in
Rust would diff Rust against Rust) and which `import`s `SlopDeskVideoHost`. Delete the faces and the
generator stops compiling; and the golden gate fails on membership drift BY DESIGN, because a key
that stops being emitted must never slide quietly into the un-diffed bucket.

Seven emitted keys reached a `SlopDeskVideoHost` symbol — `networkEstimateFold`, `fpsGovernorEwma`,
`sizeNegotiationClamp`, `sizeNegotiationEpoch`, `staticIdrDrive`, `systemDialogClassify`,
`systemDialogDetect`. Six were already this crate's law behind a door, so a Rust replay gets the
same bytes. The seventh had no twin at all and was ported (`slopdesk_video::system_dialog`).

**None of the seven was replayed by any suite** — not one Rust `tests/` file, not one Swift one.
They were held up entirely by regenerating them from the implementation that produced them, which
pins nothing: exactly the shape the golden gate's own module docs call out as "looks like coverage
and is not". So the increment is: port the one, write the replay for all seven, move them to
`FROZEN_KEYS`, then drop the emissions. The corpus keeps the bytes and a suite now proves they are
still the answer.

The port caught a defect the line count hides. `CGRect.width` answers the STANDARDIZED extent — a
rect built with a negative size describes the same region walked the other way, and `width` reports
it POSITIVE. A transliterated port reads the raw component, fails the size floor, and silently drops
a real password prompt. The corpus had pinned that case all along as `negativeSizeStandardizes`; the
replay is what surfaced it. Two more in the same three lines: rounding is ties-AWAY-from-zero, and
the floor compares the ROUNDED integer, not the float. **A vector nothing reads does not stay
true** — and a rule ported without its vectors does not stay right.

The increment after it moved the OPERATING POINT, which is the half a file census does not see: the
video cluster reads sixty-one `SLOPDESK_*` keys and only two were rules Rust owned. A port that
lands the law without them lands it at whatever default the Rust struct happened to carry, silently,
with every test green — nothing compares a resolved knob against the one the host was actually
running. So the gate families move FIRST, each as a `KEYS` list plus a `from_env` beside the law it
tunes, in the shape `host_gates` and `capture_gates` already had.

The census closed on the HOST cluster — `SlopDeskVideoHost` plus the daemon's own `main` — and it is
worth saying which cluster, because six keys the wider `Sources/SlopDeskVideo*` sweep finds are still
unspelled in Rust and none of them reopens this increment. `SLOPDESK_FEC_M`, `_FEC_K` and
`_ADAPTIVE_FEC_M` are `AdaptiveFECPolicy`'s and are read on BOTH ends — two of them are the
`symmetricKeys` set, so they move with the protocol, not with the host. `SLOPDESK_PLAYOUT_MS` is the
client's jitter buffer and `SLOPDESK_ESCALATION_FLOOR_MS` its recovery signalling. `SLOPDESK_SHARPEN`
looks like a host key because it appears in `slopdesk-videohostd/main.swift`, but that is a COMMENT
explaining why capturing at 1× is acceptable — the read is `MetalVideoRenderer`'s. All six are stage
G's, and naming them here is what keeps "closed" from reading as "closed everywhere".

Transcribing them turned up **four parse idioms, not the project's usual two**, and the differences
are load-bearing rather than historical accident:

| idiom | family | why |
| --- | --- | --- |
| REJECT to the default | bitrate, cadence | a rate or a report count has no "nearest legal value" |
| CLAMP to the bound | quantiser, display rate | an ordinal on a scale the hardware fixes does |
| clamp-or-IGNORE, per field | recovery IDR | an unparseable key costs its own field and no other |
| three-way | `SLOPDESK_SCROLL_RESAMPLE_HZ` | UNSET is 250 Hz; an explicit value that will not parse is OFF — falling back to the default would resume resampling under a knob set to stop it |

Two keys are not the field they name (`_REFILL_MS` is a spacing and the field is a rate, so the knob
inverts; `_GRACE_MS` pins both ends of a band to one value), one key means the OPPOSITE of its
sibling three lines away (`SLOPDESK_ABR_GRADIENT_CUT` is default-OFF `== "1"` where the corroboration
gate beside it is default-ON `!= "0"`), and one accepts a case-insensitive `false` that appears
nowhere else in the surface. Each carries a test, and the two that invert on a one-character edit were
SEEDED to prove the test is the one that catches it: `_REFILL_MS` clamped AFTER the division instead of
before, and the resampler's unparseable arm returning the default instead of OFF. Each seed failed
exactly one test — `the_refill_key_is_a_spacing_and_the_field_is_a_rate` and
`an_explicit_zero_disables_the_resampler_rather_than_restoring_the_default` — and nothing else in the
1115. A test that fires on a defect nobody planted is a test that has not been shown to fire.

Every table reads its values BY NAME, never by position, and that is not a style preference. The
array is positional at the boundary because a flat list is the cheapest thing to hand across one —
but a rule written as `values[23]` agrees with a `KEYS` list that has drifted, and a knob resolved
under one key and read into another's slot is an inversion no compiler and no test sees. `sharp` and
`coarse` are the two ends of one range; the corroboration gate and the gradient cut are opposite
polarities three lines apart. The `at(key)` closure `host_gates` already used is the fix, and it is
now the shape in all six tables. The test fixtures are keyed by name for the same reason: a
positional fixture would move onto a different knob along with the drift and stay green.

The daemon's three launch gates stayed separate from the session tables for a reason worth stating:
each composes with something that is not an environment variable — an explicit `--virtual-display`
flag, the display's own scale, the window's measured rate — and each LOSES to it in a different
direction. That composition is the rule, so a function taking only the text answers half the
question.

One consequence for the stage that follows. `rust/slopdesk-hostd`'s `Overlay` is the Rust-native
`EnvConfig.string`, and it deliberately skips the sidecar's `video` section because that is the video
daemon's operating point. **The Rust video daemon therefore needs the sibling fold**, and that is
where every `from_env` above gets called. Without it the port ships a complete set of resolvers with
no caller: green tests, dead code, and the whole operating point quietly back at its defaults.

And that fold must not be a SECOND `Overlay`. The two daemons differ in exactly one thing — which
sections of `video-prefs.json` they are entitled to — and share everything that is actually hard:
validate-then-drop at four steps, `rawOverrides` folding LAST, and the environment beating a persisted
setting so an operator's `SLOPDESK_X=…` is never silently overridden. Duplicating that is the
one-implementation violation this campaign exists to remove, and the drift it invites is a precedence
inversion nobody would see. So `Overlay` moves DOWN into `slopdesk-video` — the crate `slopdesk-hostd`
already depends on for `host_gates` — parameterised by the sections it reads, and `slopdesk-hostd`'s
`env` shrinks to the `agent`-plus-`rawOverrides` choice. The `video` half is the eleven keys
`EnvBridge.toEnv(_: VideoPreferences)` writes, and the write rule is the one worth carrying verbatim:
a present field pins the exact `"1"`/`"0"` the READ site resolves, whatever that site's polarity is,
which is what makes one writer safe for a default-ON and a default-OFF key alike. Note `SLOPDESK_VD`
and `SLOPDESK_QP_DECOUPLE` are both default-ON reads whose sidecar writer emits `"1"` for true — so
the writer never relies on absence to mean ON, and the round trip survives a polarity it cannot see.

### The injector went first, and it was assembly rather than translation — DONE

`InputInjector.swift` is 735 lines and holds almost no rule of its own. Every DECISION in it already
has a Rust owner: `InputButtonBalance` and `should_raise` in `input_routing`, `ScrollResampler` in
`scroll_resample`, the flick recogniser in `swipe_recognizer`, the allowlist and thresholds in
`swipe_nav_config`, the point map in `coordinate_mapping`, the gate table in `injector_gates`. The
four verbs it posted through were already doors over `slopdesk-apple-cgevent`
(`slopdesk_inject_{pointer,scroll,key,text}`), the raise chain was already
`slopdesk_ax_raiser_{new,raise,free}`, and `activate`/`bundle_id` were already `slopdesk-apple-app`.
**The cluster needs no new Apple crate and no new `unsafe`.** What is left in the Swift is two
`DispatchQueue`s, one `DispatchSourceTimer`, three `NSLock`s its own comments call "harmless
insurance", and the tag stamping — which is to say the file survives on owning concurrency primitives,
and that is `coupled-swift-is-an-architecture-bug` stated in its purest form.

Three things decide the shape, and getting any of them wrong costs a whole increment.

**It shipped with its door, or it would have stranded.** The injector's only caller is
`SlopDeskVideoHostSession`, which stays Swift until the LATER cluster. A Rust injector without an FFI
door would have repeated `daemon_gates` one increment later and after far more work. So the
deliverable was *Rust injector + door + the Swift rule deleted*, and `no-stranded-rust-module` grants
the exemption on the `no_mangle` — the same way `ax.rs` earns it. The Swift call surface was five
sites, which is what made this tractable at all.

**The injector DOES live in the shim crate, and an earlier draft of this section said the opposite.**
That draft argued a thread-owning stateful object belongs in a composition crate under the shim, the
way `slopdesk-hostpane` and `slopdesk-hostsession` sit under hostd. The repo had already answered:
`slopdesk-ffi/src/cursor_sampler.rs` is a stateful, lock-carrying, two-thread handle in the shim whose
own header argues why ("three crates meet here"), and `ax.rs` makes the same argument for the raise
chain. The pattern the draft matched is real but belongs to a different layer — those composition
crates serve the Rust DAEMON, not a Swift door. A `rust/slopdesk-hostinput` whose only consumer is the
shim would be the extra layer this repo has declined twice, and it buys no isolation: safe code inside
`slopdesk-ffi` is still fully checked, because `unsafe` there is a per-site `#[expect]` and not a
crate-wide licence. So `slopdesk-ffi/src/injector.rs` owns the injector outright, beside `ax.rs`, and
it documents its own exemption from the header's one-thread-per-handle convention exactly as
`cursor_sampler.rs` does.

**Fifteen doors went away for eight, and one Swift file shrank to its ARC obligation.** Deleted with
the rule: `slopdesk_inject_{pointer,scroll,key,text}`, `slopdesk_ax_raiser_{new,raise,free}`,
`slopdesk_app_activate`, and — with `InputInjectorRaisePolicy`, whose last caller was the injector —
`slopdesk_input_should_raise`. Deleted with their only caller: the six
`slopdesk_scroll_resampler_{defaults,new,ingest,drain,is_idle,reset}` and the whole of
`slopdesk-ffi/src/scroll_resample.rs`, because the resampler now runs on the thread that posts and a
by-value crossing for it has nobody left to cross to; `ScrollResampler.swift`'s door list in
`video_client.rs` became a stay-deleted ban, with the break-test that seeds its return. Added:
`slopdesk_injector_{gate_keys,resample_hz,new,free,update_bounds,raise,inject,balance}`. `InputInjector.swift` is not gone, and pretending it would be was the one thing
worth being honest about: what remains is ~110 lines that own the handle so ARC — not a raw pointer the
session hands to a `Task` — decides when it is freed, plus the marshalling for the text arm. It holds
no rule, no default and no thread. It goes when the session does.

**The threads were the only new design, and the lock count is what it predicted.** Swift got two
serial queues and a timer for free. The Rust shape is a scroll thread whose channel receive TIMES OUT
at the drain interval, so ingest and periodic drain are one loop and no timer API is needed, plus a
raise thread that owns the throttle, the resolved `AXUIElement` and the `hasRaisedOnce` flag — all
three queue-confined in Swift and all three plain locals here. The accessibility element is the one
that had to be confined rather than merely could be: it is a Core Foundation object with no
thread-safety contract, so `SlopDeskAxRaiser`'s `Mutex` dissolved into `RaiseTarget`, a `pub(crate)`
type that never crosses a thread boundary at all.

Three locks survive, not one, and the count is the honest part. `balance` is genuinely shared — the
session reads it at teardown to seed the replacement injector, and the scroll thread reads it to
decide whether the swipe chord may ride a ⌘ the user is physically holding. `bounds` is written by the
geometry watcher and read by both threads. `swipe` is the recogniser, fed from the inject path, and
its lock is the same insurance the Swift called harmless. What made the two queues disappear was
confinement; what keeps these is that more than one thread really does read them.

**The teardown is a join, and that is a safety property rather than a courtesy.** Both pumps hold an
`Arc` of the shared state; `slopdesk_injector_free` drops the senders, which is what ends each loop,
and then waits. A cancel-and-run-on would leave a thread reading a box the caller had already freed.
The wait is bounded because the only thing either thread ever blocks on is the channel that call
closes.

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

`just lint-invariants` ratchets two rules onto files this campaign deletes. Each moves in the stage
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
above. Each new crate adds a row to `AREA_FLOORS` there, the way `slopdesk-apple-power` did: three
arrived with stage E, and `slopdesk-apple-machine` with F.7.
