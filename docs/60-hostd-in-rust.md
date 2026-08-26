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
  `make lint-reach` is what proves some target still runs it.

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

  **The hole this stage names rather than fills.** `Panes::capture` and `Panes::roster` — the
  reconciler's live inventory — are NOT here. `reap` and `resolve_size_passivity` are the two the
  ending ladders own and both are implemented; the other two need the per-pane truth reducer
  (`PaneTruths.swift`, 515 lines: title freshness, the open command block, the agent state), which
  is its own port and not a link-down/detach/stop decision. Nor is the laggard-EVICTION wiring:
  `Host::evict_subscriber` is the server half and it is complete, but the signal that a member is
  parked on an exhausted credit window has no Rust producer yet — `slopdesk-hostsession` has the
  eviction rule and no callback for it, and adding one is a change to that crate rather than to this
  ladder. Both are named here so stage F finds a list rather than a surprise.

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
