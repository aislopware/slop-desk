# 51 — Process supervision: what outlives a hostd restart

The contract for `slopdesk-superd`, the fd-custody daemon. Read this before touching `PTYProcess`,
the two PTY spawn sites in `HostServer`, the agent hook/ctl socket paths, or anything that assumes
"the daemon owns the shell". `docs/46` has the gate matrix and env paths; `docs/45` §6.5 described
the *old* restart behaviour and is superseded by §7 here.

Written 2026-08-11, after the cost of restarting hostd — every running agent killed — made
host-side iteration expensive enough to distort how the host gets developed.

---

## 0. The one-paragraph version

A pane's shell is forked by `slopdesk-superd`, not by hostd. superd keeps the PTY master fd open for
the pane's whole life and hands hostd a **duplicate** over `SCM_RIGHTS`. hostd then reads, resizes
and inspects that fd exactly as it always has — the byte path is unchanged and gains no hop. When
hostd exits, its duplicate closes, superd's copy keeps the pane's fd refcount above zero, and the
shell does not get a `SIGHUP`. The next hostd asks superd for the list and re-adopts. Everything
whose address is baked into a *running* process's environment — the hook socket, the ctl socket,
`SLOPDESK_PANE_ID` — belongs to superd for the same reason: hostd's pid is not allowed to appear in
anything a live child remembers.

---

## 1. Why this boundary and not another

The instinct is to split hostd by subsystem — detection here, workspace there, inspector
elsewhere. That is the wrong axis. It multiplies IPC and failure modes, and it does not answer the
actual question, which is not "how small can the pieces be" but:

> **What is a running process allowed to depend on?**

A `claude` that started twenty minutes ago holds three things it can never be told to update: its
controlling terminal, its environment, and its parent. Anything hostd owns that appears in that
list makes hostd un-restartable. Everything else is free.

That yields exactly one boundary, and it is small:

| Belongs to superd | Why |
|---|---|
| `openpty` + `fork` + `execve` + `waitpid` | The child's parent cannot change |
| The PTY master fd, held for the pane's life | Last close sends `SIGHUP` |
| Agent hook socket path | Baked into the child env as `SLOPDESK_SOCKET_PATH` |
| Agent ctl socket path | Baked into the child env as `SLOPDESK_CONTROL_SOCKET` |
| The generated `ZDOTDIR` shim dir | Baked into the child env, and outlives every hostd |
| `paneID` per pane | Baked into the child env as `SLOPDESK_PANE_ID`, and it is the hook routing key |
| The OSC sniff over a pane's output | It already holds every byte; a second reader is a second copy and a drift (§6.13) |

Everything else stays in hostd: the mux, the replay buffer, the strippers, the screen model, the
scrollback journal, the block segmenter, the whole detection stack, the workspace document. None of
it is addressable by a child, so none of it costs anything to restart.

The last row is the one that is not about addressability, and §6.13 is the whole argument for it.

**superd does not touch pane bytes.** It never reads the master. It is not in the latency path, and
`docs/DECISIONS.md` 2026-08-10 (AF_UNIX `SO_SNDBUF` is 8KB on macOS) does not apply to it, because
no bulk path moved to a unix socket — the fd itself moved instead.

---

## 2. The two facts this rests on

Both were verified by running code on macOS 26.5 / Swift 6.3 before any of this was designed, not
assumed from the man pages.

**2.1 — A PTY master fd survives `SCM_RIGHTS` with all of its powers intact.** The receiver can
`read()`, `TIOCSWINSZ`, and — the load-bearing one — `tcgetpgrp()`, which is the primary,
zero-config agent-detection signal (`PTYForegroundProbe.foregroundName(masterFD:)`). A
non-parent can `kill()` the child; only the forking process can `waitpid()` it. The `CMSG_*` macros
are invisible to Swift, but their arithmetic is stable and hand-rollable, so **no C shim is
required** and the invariant stands that nothing under `Sources/` implements anything in C — the
one C target left there, `CSlopDeskVirtualDisplay`, declares private CoreGraphics headers and has no
`.c` file at all.

**2.2 — The pane survives its fd-holder's death iff someone else still holds the fd.** This is the
whole design in one sentence. If superd closes its master copy after handing off, hostd's exit drops
the refcount to zero and the shell is hung up — the exact failure we are trying to prevent. superd
therefore keeps its copy open and never reads it.

**2.3 — The duplicate hostd is given is taken where the pane is decided, not looked up again
afterwards.** `Registry::spawn` and `Registry::adopt` return `(PaneRecord, OwnedFd)`; there is no
`master_fd(pane_id)`, and reintroducing one is reintroducing the bug it was deleted for. A pane can
stop existing between the insert and the reply: `/bin/sh -c "exit 0"` is usually already reaped by
then, and the reaper's first act is to remove the pane and drop its master. A lookup landing after
that answered one of two ways, and both were wrong — it found nothing, so an `ok` spawn reply went
out with no descriptor attached (hostd raised `missingDescriptor` for a child that really had run,
which is what made `testRapidSpawnShutdownChurnDoesNotLeakFDs` flaky), or it found a raw fd number
the reaper had already closed and the kernel had since reissued, and hostd would have adopted a
descriptor belonging to something else entirely without a single error anywhere. `frame::write`
therefore takes a `BorrowedFd`, not a `RawFd`: "this descriptor is open for the length of the
`sendmsg`" is a claim the compiler can check, and every caller now proves it.

During the gap, nothing drains the master. The kernel PTY buffer absorbs what fits and then blocks
the writer. **No bytes are dropped** — this is the same backpressure `PTYReadLoop`'s pause gate
already relies on, and it is why superd needs no ring buffer of its own.

---

## 3. Version skew is the central constraint

superd is a LaunchAgent. It outlives hostd by design, which means it also outlives hostd's *build*.
The normal daemon assumption — both ends ship together, so the protocol can change freely — is
false here, and it is false in the one direction that hurts: you rebuild hostd all day and superd
stays whatever it was when you last logged in.

Rules that follow, and they are not negotiable:

1. **The protocol is append-only.** Verbs and fields are added, never repurposed or removed.
2. **`hello` carries a version on both sides.** superd serves any hostd whose major matches; a
   mismatch is refused with a diagnostic naming the fix, never a silent degradation.
3. **An unknown verb is answered `unsupported`, not dropped.** A newer hostd must be able to detect
   an older superd by asking, and fall back.
4. **Changing the protocol costs a superd restart, which costs every pane.** So the protocol stays
   boring: spawn, list, signal, exited, and the socket forwarding. If a change seems to need a new
   verb, the change probably belongs in hostd.

### The minor is not the build

Rule 4 has a corollary that only shows up after a release. The minor says what superd can *speak*,
and it moves only on a wire change — so a superd rebuilt with a fixed reaper, a corrected journal
sweep or a faster pump reports the minor it always did. "Does the running superd contain this
release" is a question the minor cannot be asked, and it is the question a `brew upgrade` raises:
the binary on disk is replaced and the process on the socket carries on with the old code.

Minor `8` answers it with a **field**, `buildVersion` on the hello reply — superd's own
`CARGO_PKG_VERSION`, compiled in, never read back off disk. A field rather than a verb for exactly
rule 4's reason: asking costs nothing, and the answer rides a handshake hostd already performs.
`Option`/`String?` because a superd older than minor 8 sends none, and "unknown" must stay
distinguishable from "same". hostd compares it against `slopdesk-superd --version` on disk and
**reports** — restarting superd would take every live pane, so that stays the user's call
(`docs/49`).

This is the opposite of the three wire paths, which are golden-pinned and version `1` with no
negotiation (`docs/46`). Those are frozen because both ends ship together. This one negotiates
*because* they do not. It is a fourth local IPC, not a fourth path: no golden vectors, no
cross-machine exposure, AF_UNIX only, `0600`.

---

## 4. Lifetime and failure modes

superd runs under launchd (`RunAtLoad` + `KeepAlive`), so it starts at login and comes back if it
dies. hostd finds it at a fixed socket path; if it is absent, hostd says so and refuses the
supervised path rather than silently forking its own shells.

**If superd crashes, the panes are lost.** fd custody dies with the custodian and launchd cannot
inherit it. There is no clever recovery — this is the inherent cost of the design and the reason
superd is small, dependency-free, and does nothing per-byte. Its job is to be boring.

**If hostd crashes**, which is the common case during development, nothing is lost. This is
strictly better than the exec-in-place alternative (hostd `execve`-ing its own new binary), which
preserves the pid but cannot survive a new binary that fails to boot — and during host development
a new binary failing to boot is not a rare event.

---

## 5. Identity across a restart

`SLOPDESK_PANE_ID` is derived from `(connectionID, channelID)` and baked into the child env at
spawn, immutable for the shell's life. `connectionID` is per-TCP-connection, so after a restart the
new hostd would derive a *different* pane id and the agent's hook POSTs — which carry the old
one — would route nowhere.

So the pane id is **recovered from superd, never re-derived** on the adopt path.
`registerHookSink(session:paneID:)` already exists as the generic overload for ctl-spawned panes,
which have no channel pair; adopted panes use the same door.

---

## 5.5 Relinquish is not destroy

The single most important line hostd draws, and the one place a careless edit undoes the whole
document. Two teardowns exist and they must never merge:

| | `relinquish()` | `shutdown()` |
|---|---|---|
| Means | "hostd is going away" | "this pane is over" |
| Child | untouched — no `SIGHUP`, no wait | `hangup()` → `terminate()` → bounded wait → `forceTerminate()` |
| hostd's master | closed (`closeMaster()` — a *duplicate*) | closed |
| superd | told nothing; keeps the original master | reaps the child and drops the pane |
| ZDOTDIR shim dir | kept (the shell is still living out of it) | deleted |
| Reached from | `HostServer.stop()`, and nothing else | the child's own exit, a peer `channelClose`, a link drop |

Before superd these were one code path, which is exactly why editing one Swift file cost the user
every running agent. The distinction is only *safe* because of §6.5: `closeMaster()` used to block
while a reader was parked in an uninterruptible `read()` on that fd, so "stop reading" implicitly
meant "kill the shell". hostd does not read the master any more, so nothing is parked, so a pane can
be let go without being ended.

The same line runs through `PTYProcess`: `closeMaster()` drops hostd's `SCM_RIGHTS` duplicate and is
safe on any path including `deinit`; `release(kill:)` is the deliberate end and **must never be
called on hostd shutdown**.

---

## 6. What superd stores per pane

Only what is needed to hand the pane back: `paneID`, `sessionID`, child pid, the retained master
fd, the resolved cwd, the spawn argv/env fingerprint, the generated shim dir when the pane has one
(§6.4), a bounded ring of the pane's recent output (§6.5), and — for a pane that asked for the shim
— one OSC state machine, whose entire state is a coalescing anchor and an open command's start time
(§6.13). No screen state, no detection state. Those are hostd's, and §7 says how they come back.

---

## 6.4 The shell-integration shim is superd's, and the environment is not

These look like the same decision and are opposite ones.

The curated ENVIRONMENT is passed through whole. `HostEnvironment.curated` is policy, it changes
often, and a superd that had opinions about it would need a rebuild every time hostd learned a new
variable. superd overlays only what is its own to know: the socket paths of §6.6, and the pane id.

The zsh shim is not policy. It is a generated directory of rc files — `ZDOTDIR` pointed at a
`slopdesk-zdotdir-*` under tmp, whose `.zshrc` sources the user's real one, installs a `TRAPWINCH`
that forces `zle reset-prompt` after a resize, and installs the OSC 133 marks and cursor-shape
hooks. It is a RESOURCE, and its lifetime is exactly one child's.

That is why it moved. Held in hostd it needed three cleanup sites — spawn failure, session
teardown, orphan sweep — each of which had to re-derive the relinquish-versus-terminate distinction
of §5.5 on its own, and none of which ran when hostd was killed rather than stopped. So the common
case, a `make host-restart`, leaked one directory and four files per open pane, permanently. superd
already knows that distinction, because it IS the distinction, and it is the process still standing
afterwards.

hostd still decides WHETHER: `SpawnRequest.shellIntegration` is a request, set for an interactive
login shell and cleared for a `$SHELL -c …` pane that has no prompt cycles for prompt machinery to
hook. superd decides whether it is possible on this machine — a non-zsh, a `/etc/zshenv` that
reassigns `ZDOTDIR`, a home with no zsh startup files at all — and every rejection is a log line
and a perfectly usable shell, never an error.

The dir is removed when the child is KNOWN dead: an explicit kill, or the reaper seeing it exit. A
relinquished pane keeps its directory, because the shell is still running out of it.

The three opt-outs (`SLOPDESK_SHELL_INTEGRATION`, `SLOPDESK_OSC133`, `SLOPDESK_SHELL_CURSOR`) are
all read downstream of hostd — the first by superd, the other two by the generated `.zshrc` in the
child — so hostd's only job is to carry them across its allowlist, which
`HostEnvironment.shellIntegrationEnvKeys` names in one place.

---

## 6.5 superd reads the master, and hostd subscribes

**This reverses one sentence of §2 and nothing else.** The original design said superd holds the fd
and never reads it, and gave two reasons that were correct and remain correct: relaying every byte
would put an `AF_UNIX` hop on the keystroke path, and it would turn `tcgetpgrp` — the zero-config
half of agent detection — into polled IPC.

Both survive, because only `read` moved. hostd still holds its `SCM_RIGHTS` duplicate of the master
and still uses it for `write`, `TIOCSWINSZ` and `tcgetpgrp`. Keystrokes go hostd → kernel with no
hop. The foreground process group is a syscall.

### Why `read` had to move
The old text said the kernel's PTY buffer would backpressure the child across the restart gap, and
called that acceptable. It is not, and the reason is the same reason this document exists. A PTY
buffer is a few KB. With nobody reading it — which is precisely the state between hostd's exit and
the next hostd's `adopt` — the child's next `write` blocks. The pane superd just saved from
`SIGHUP` spends the whole restart **frozen**, and a `claude` mid-task stops at whatever line it had
reached. Surviving and being stopped is better than dying, but it is not what was promised.

So every pane gets a `pump` (`rust/slopdesk-superd/src/pump.rs`): one thread, `poll(2)` on the
master plus a wake pipe, draining for the pane's entire life whether or not any hostd is attached.
Bytes land in an `OutputRing` addressed by **absolute offsets since the pane was born**, and hostd
receives them as binary frames over the existing socket.

### The rules that fall out of it
- **A pane with no subscriber is still drained.** That is the whole point. Its bytes accumulate in
  the ring, bounded by `SLOPDESK_PANE_RING_BYTES` (4 MiB); past that the oldest are evicted.
- **Eviction is announced, never silent.** `subscribe` answers with the offset the stream *actually*
  resumed at. A stream spliced across an unannounced hole renders a terminal that is wrong rather
  than merely short, so the gap is reported to the log and the receiver decides.
- **The pause gate moved but narrowed.** hostd still asserts backpressure when a channel's output
  queue crosses its high-water mark; superd is now what stops reading, so the kernel buffer fills
  and the shell blocks — the never-drop invariant, unchanged. What is new is that **losing the last
  subscriber clears the pause**: a hostd that died mid-flood must not leave a pane frozen forever,
  which would be this document's own failure arrived at from the other direction.
- **Output is ordered ahead of `exited`.** superd's reaper drains the pump to EOF and joins it
  before broadcasting, and both leave through the same per-connection write lock. A shell's
  farewell can therefore never arrive after news of its death, which is what hostd's EOF latch
  relies on to keep `.exit` behind the last `.chunk` on the wire.
- **Offsets are per pane LIFE, in memory.** They need not persist: superd's own death takes every
  pane anyway (§4). The disk scrollback journal is a different mechanism with a different job — the
  transcript of a pane whose process is long gone — and it stays in hostd.
- **A pane's output outlives the pane, briefly.** The pane itself dies the instant its child is
  reaped — the master must close and the pump must stop — but hostd only subscribes after the
  `spawn` reply has travelled back to it, and `slopdesk-ctl spawn --cmd ls` finishes well inside
  that window. So the reaper moves the ring into a bounded *graveyard* (16 panes) before it
  broadcasts `exited`, and `subscribe` falls back to it. Without this the pane rendered **empty**,
  reliably, for every command fast enough to win the race. The graveyard holds a ring and never an
  fd, and `release` evicts from it.
- **A finished stream says so in the subscribe reply.** `StreamPosition.ended` exists because the
  `exited` notice that normally ends a subscription was broadcast *before* a late subscriber
  existed. Without the flag hostd renders the backlog and then waits forever for an end that
  already happened. hostd declares EOF once it has taken the last byte of that backlog, so the
  ordering `.exit` behind the final `.chunk` holds on this path too.

### What this deleted
`Sources/SlopDeskHost/PTYReadLoop.swift`, and the destroy-path master drain inside
`PTYProcess.waitUntilExitedDrainingMaster` — which existed only because nobody was reading the
master between `hangup()` and the `SIGKILL` escalation, and which would now be a second reader
stealing bytes from the pump on a file description they share.

Test code was the other holder of that habit, and it was the one that made the rule legible: half a
dozen suites `poll`ed and `read` the master to assert on a shell's output. They did not fail
loudly — they hung. `poll` said readable, the pump had already taken the bytes, and the `read`
parked in the kernel until the child died thirty seconds later. They now read the way hostd does,
through `PaneOutput` (`Tests/SlopDeskHostTests/SupervisedPTYSupport.swift`), which is both correct
and strictly stronger: matching is sequential from a cursor, so nothing is lost between two
assertions the way it was with a raw fd. `rust/slopdesk-invariants` ratchets the absence.

### Two things that are un-awaited, and must be

`pause` and `unsubscribe` are sent without waiting for their replies, and that is a correctness
requirement rather than a latency choice. Both can be reached FROM the client's read loop — `pause`
via the bounded-queue gate running inside a chunk's ingest, `unsubscribe` via a session unwinding
from an `exited` handler — and waiting there for a reply only that loop can deliver is a deadlock
with no timeout to break it. The ids are still allocated and superd still answers; the client simply
records them as unawaited and drops the replies on arrival, because a retained reply per keystroke
would be an unbounded map.

For the same reason the per-pane output handler runs SYNCHRONOUSLY on the client's single read
thread. Hopping to a per-pane queue would isolate the panes from each other, and it would also
destroy the gate: the reader would never stop reading, and the queue it hopped to would become the
unbounded buffer the whole never-drop design exists to avoid. One slow pane holding up the others is
the price, and it is bounded — ingest is an enqueue plus a sniff, and a full queue pauses rather
than blocks.

---

## 6.6 superd binds the child-facing sockets, hostd serves them

§1 said the hook and ctl socket paths lose their `-<pid>` suffix, because a running child remembers
its environment from `execve` and that snapshot can never be corrected. Making the *name* stable is
only half of it. A name is a promise to be listening at it, and the process that was listening was
hostd — so a restart still broke the promise, just at a different layer: the path was right and
nothing was behind it.

So the `bind` moved to superd, and **only** the `bind`.

### The shape
superd binds `slopdesk-agent.sock` and `slopdesk-ctl.sock` at boot and holds them for its whole
life. hostd sends `listen` naming the kinds it will serve (`hook`, `control`). When a child
connects, superd `accept`s and hands the **accepted connection** to the claiming hostd over
`SCM_RIGHTS`, as a `connection` event. It reads not one byte of either protocol.

That is what keeps "superd is not a protocol relay" (§8) true, and it is what keeps the
one-implementation rule true: the hook record parser, the Claude state machine, the `tool_use_id`
ledger and the dissent watchdog all stay in the one process that has the state they need. Moving
them would have meant either a second copy in Rust or a relay hop for every hook POST.

### Unclaimed is not unbound
Both sockets are bound for superd's entire life; whether a hostd is *behind* one is separate state
(`Claims`). It gates exactly one thing: whether the path is advertised into a spawned child's
environment. An address nobody serves is never put in front of a child, because advertising an
address is a promise to be listening at it.

This is also how the default-off ctl flag survived the move without leaking a hostd feature flag
into superd. `SLOPDESK_AGENT_CTL` off simply means hostd does not claim `control`; superd knows
nothing about the flag.

### No hostd attached → accept and close, at once
Not queue, not buffer. The peer is Claude Code's hook binary, which **blocks its agent** until its
write completes, so a fast `EPIPE` beats a wait every time. The lost record is self-healing by
design: detection is two-tier, `lastAuthoritativeAt` goes stale, coverage is revoked and the screen
engine takes over (`docs/50`). A hung `claude` is not self-healing.

### Claim rules
Most-recent claim wins, per kind — the same rule as `adopt`, and for the same reason: the new hostd
is the live one. `release_all` on disconnect clears only the slots the disconnecting client still
holds, so a displaced hostd noticing late cannot take its successor's claim away.

### What this deleted
`UnixSocketAcceptor` in `AgentHookListener.swift` (~150 lines of bind/listen/accept/unlink),
`AgentControlAcceptor`'s accept loop, `AgentControlListener.socketPath`, and the pid-keyed path
derivations in `Sources/slopdesk-hostd/main.swift`. hostd no longer knows where either socket is
until superd tells it at `hello`, which is the correct number of answers to that question.

---

## 6.7 The panel backends are panes too

§8 used to call this a non-goal, and the reasoning was wrong in a specific way worth recording:
it asked *how a new hostd would find code-server again* (a port is not an fd; read it from a small
state file) and never asked *why it had to find it again*. The answer was `HostServer.stop()`, which
terminated both backends. Every host edit therefore cost the user a Node reboot in the code panel
and a dead simulator server — the exact tax this whole document exists to remove, still being paid
by the surface the user looks at most.

### Spawn-or-adopt by a stable name
The pane id is `service:<name>` — `service:code-server`, `service:baguette`. Not a UUID, and not
derived from anything about this hostd, for the reason in §1. A starting manager calls `adopt` first
and falls back to `spawn`; a hit means the backend ran straight through the restart.

**The port is re-learned from the child's own words.** The subscription starts at offset 0, so
superd's ring replays the announce line that the backend printed when it first bound — the same line
the port parser already existed to read. There is no state file, no port handshake, and nothing to
go stale. `SupervisedServiceProcess` is ~190 lines because the ring had already done the hard part.

### Held on a PTY, deliberately
superd's one spawn primitive is `openpty` + `fork` + `execve`, and it stays that way. Both backends
were run on a real terminal before this was written: neither colourises, neither moves its announce
line, and the only difference in the stream is `\r\n`, which `LineAssembler` strips. Teaching superd
a second, pipe-flavoured spawn would put a second pre-exec window next to the disassembly-pinned one
(`fork_window_contract`) to buy a carriage return.

### relinquish, not terminate
The §5.5 line, drawn again: `HostServer.stop()` calls `relinquish()` (hostd stops listening, superd
keeps the child), and only a deliberate stop calls `terminate()`. Both spellings compile and both
read like cleanup, so `rust/slopdesk-invariants` ratchets it.

### Not adopted by `adoptSurvivingPanes`
A `service:` id does not parse as a UUID, so the pane loop skips it — the managers adopt lazily on
the first `ensure`, which is right: a panel nobody opens should not boot Node. It gets its own log
line rather than the "not ours" one, because a surviving workbench is good news, not a stray.

### What this fixed on the way
The bridge socket path carried `getpid()`. That is §1's bug in a second place, and it
only became fatal here: a code-server that now survives a restart would keep dialling the address of
the hostd that started it, forever, because a child cannot be told a new environment. The path is
stable now (one bridge per user, which is what one code-server per user already implied), and
`slopdesk-invariants` ratchets every socket path in `Sources/`, not just superd's three.

---

## 6.8 Four rules the review found, all of them about *where a stream starts*

§6.5 moved `read` into superd and §6.7 moved the panel backends in behind it. What both left behind
were seams at the JOIN: the moment a new hostd, or a re-connected one, asks superd to start sending
again. Each of these was a silent wrong answer rather than a failure, which is why they needed
finding rather than reporting.

### The resume point is not written down at all, because superd already holds it
hostd restores a pane's history from the disk journal (§7) and then subscribes to superd's ring. Both
contain the same bytes. They cannot be *aligned* after the fact — the journal is a distilled or
snapshot-composed transcript and the ring is raw output, so there is no offset in one that can be
found in the other — so a subscribe from `0` prints the user's session **twice**, and feeds the
sniffer, the block ledger and the screen engine the second copy as if it were new.

The boundary between the two is therefore load-bearing, and for a year it was a **number two
processes had to agree about**: hostd journaled a stream superd numbered, so "how much of the stream
is on disk" was a fact neither one held alone. Everything that followed came out of that split — a
`<uuid>.scrollback.resume` sidecar; a `spawnedAt` stamp on it, because offsets restart with every
fork and a session id outlives many of them; a 250 ms re-claim on the flush path, because a hostd
that is `kill -9`ed never reaches its orderly write; and a rule about which of two non-atomic writes
was allowed to be stale.

**All of it is gone, and none of it was replaced.** superd owns the `read`, so it numbers the
stream; since stage 27 it also writes the file, so the boundary is a variable it already holds:
`JournalStore::head`, the stream offset it last flushed, answered over the `journal_info` verb. It is
exact by construction rather than by cadence — there is no window in which it can be behind, because
the same lock that appends the bytes advances it. There is nothing to stamp with a pane life,
because the value lives in the pane's own writer and dies with it. And there is no staleness trade
to make, because a `head` that could be stale would have to belong to a pane superd forgot — and
superd forgetting a pane means superd died, which takes every pane with it (§4).

What is left for hostd to decide is what it always should have been: `HostServer.resumePointForSurvivor`
asks `journal_info` and reads three cases off the answer. No file, or an empty one — nothing was
restored, so the stream starts at `0`. A file and a `head` — resume exactly there. A file and **no**
head: the pane that wrote it is gone (superd drops the head when it closes the journal), so the
answer is the transcript we have plus everything from NOW, `PaneOutputStream.fromNowOn`
(`UInt64.max`, which superd clamps to the ring head and answers with an empty backlog). Only the
third case loses anything, and it is the case where there is provably nothing to lose: no live
stream exists to have a position in.

### The transcript is superd's file, and the policy stays hostd's
The split is not "superd took the journal". superd took the **writing**: where the bytes go and how
the file is bounded, because those are decisions about a stream it owns. hostd kept every decision
that is about a *session* — which directory journals live in, how big one may get, whether a pane
gets one at all (`SpawnRequest.journal`), when one is deleted (deliberate close only), and how long
an orphan may live (`journal_sweep` carries hostd's age and count on every call, so neither number
is baked into a daemon that would have to restart to see it changed).

The verbs are stateless about panes on purpose. `journal_info`, `journal_delete` and `journal_sweep`
take a directory and a session id, not a pane — so they answer for a session whose pane died with
the machine exactly as they do for a live one. That is what makes an archive that outlives every
process in the system possible while a daemon that dies with the machine does the writing: the
archive is a **file**, and neither daemon has to be alive for it to exist.

Two things follow that are worth stating outright. The delete is a verb rather than an `unlink`
here, because superd may still hold the file open — on POSIX that unlink is not an error, it is a
pane journaling the rest of its life into an inode nobody can open again. And the sweep is superd's
to execute for the same reason: which file a live pane is still writing is the one thing a sweep
must not get wrong, and only the writer knows.

### A signal goes where the kernel would have sent it
`signal` used to deliver everything to the child pid. That is right for exactly one class of signal
and wrong for the other. A hangup belongs to the **session leader**; a `^C`, `^\` or `^Z` belongs to
the **foreground process group**, which is what `tcgetpgrp` on the master answers and what the tty
driver itself would have signalled. Sent to the leader instead, a `SIGINT` interrupts the user's
shell rather than the `claude` running inside it — the pane looks like it ignored the keystroke.
`registry::targets_foreground_group` names the five (`SIGINT`, `SIGQUIT`, `SIGTSTP`, `SIGTTIN`,
`SIGTTOU`); everything else keeps going to the pid.

### A backlog is chunked, because one frame cannot hold a full ring
`ring::DEFAULT_CAPACITY_BYTES` and `frame::MAX_BODY_BYTES` are both 4 MiB, so a full backlog plus an
output frame's own header is provably one frame too big — the reply was silently refused, and the
pane that most needed its history got none of it. `frame::max_output_payload(pane_id)` states the
arithmetic and `Connection::write_backlog` walks the backlog in chunks, each carrying its own
absolute offset so the receiver's gap detection stays exact.

### `attached` is a property of the CONNECTION, so a stopped hostd must drop its own
`registry::detach_client` is the only thing that clears `attached`, and `adoptSurvivingPanes` skips
an attached pane — correctly: after the rekey to bare session UUIDs it is the only way to tell
another live daemon's panes from free ones, and adopting one would put a second daemon's shell in
this one's detached store, on the same journal file, one eviction away from hanging up a pane
somebody is using.

Which leaves the in-process restart to answer for. The ordinary one hides the question behind
`exit(0)`; the menu-bar host does not — it stops and starts in ONE process, so its own connection is
still open and its own panes still read as another daemon's. It refused to adopt them, and the
shells survived perfectly and never came back to a tab.

Disconnecting in `stop()` is the obvious fix and it is the wrong one: `killPaneForControl` tears its
pane down on a background queue, so the `release` for a pane the user deliberately closed is still in
flight when `stop()` returns, and closing the socket underneath it resurrects that pane at the next
`start()` — adopted, parked, and unkillable-looking. (Tried, and caught by
`testAPaneClosedBeforeTheRestartDoesNotComeBack`.) So `stop()` instead NOTES the pane ids it is
letting go, before the maps are drained, and `adoptSurvivingPanes` accepts an attached pane whose id
this process wrote there — once, then forgets it. The connection lifecycle is untouched.

---

## 6.9 One writer of a pane's window size, and it is hostd

`TIOCSWINSZ` after the spawn belongs to hostd alone. superd's `resize` verb records `rows`/`cols`
into the `PaneRecord` and touches no ioctl; `openpty` is handed the initial size, so the spawn path
needs none either.

Two reasons, and the second is the one that bites.

**hostd knows things superd is not told.** The client sends pixel geometry with every resize, and
hostd writes `ws_xpixel`/`ws_ypixel` alongside the cells in a single ioctl. The wire `resize` carries
cells only. A superd that re-applied what it was told would write zeros over the two fields nobody
sent, and a TUI that queries pixel geometry (sixel, inline images) would read 0×0 and stop drawing.

**A second writer is not a duplicate, it is a lost update.** `resize` is a NOTIFICATION — id 0, no
reply — so it lands whenever superd's thread reaches it, which is after hostd's own ioctl by an
unbounded margin. Anything hostd does to the winsize in that gap is silently reverted. The
cold-reattach redraw jiggle lives exactly in that gap: it shrinks the pane by one row, holds it long
enough for the app's event loop to see the `SIGWINCH`, and restores it — and a late `resize` landing
mid-hold puts the row back, so `endRedrawJiggle` sees a size that is no longer the shrunk one, yields
(correctly — it cannot tell a stale echo from a real client resize), and the full re-layout the
jiggle exists to force never happens. `claude` then stays half-painted after every reattach.
Pinned by `registry::tests::resize_records_the_size_without_touching_the_terminal` and, from the
other end, `PTYProcessTests.testRedrawJiggleShrinksOneRowThenRestores`.

The record still matters: it is what `list` reports, and a spawn-time 24×80 on a 200×50 pane is a lie
in every enumeration and every log line. Recording is the whole job.

---

## 6.10 A pane says who owns it, because `attached` cannot

Every hostd pane id is a bare session UUID (§5), so nothing in the id says which daemon forked it,
and `attached` — the only other discriminator — is **false for the whole ~0.2 s of its owner's
restart**. That is precisely the window a second hostd starting up looks at the registry in. Two
hostds on one machine is ordinary (a dev daemon on one port, the menu-bar host on another), and the
pane in the middle is somebody's live `claude`: adopted by the wrong daemon it lands on that
daemon's TTL clock and journal files, and the owner that comes back finds it attached to a stranger
and leaves it alone forever.

So `spawn` carries an **`owner`** — protocol 1.4, opaque to superd, stored on the `PaneRecord` and
echoed back in `list`. hostd builds it from the requested port (two live hostds cannot share one,
and `slopdesk-ops restart-hostd` reproduces it exactly) and the workspace state directory when one is set.
`adoptSurvivingPanes` reads it three ways: **ours** → adoptable, subject to the `attached` rule as
before; **a different owner** → left alone whatever `attached` says; **absent** → treated exactly as
before the field existed, because refusing there would strand real shells on the one upgrade where
they most need adopting. Pinned by
`HostRestartSurvivalTests.testASecondHostdDoesNotAdoptAStrangersRelinquishedPanes`.

The same "one id, one owner" question inside superd is answered by a **reservation**: `spawn` cannot
hold the pane lock across a fork, so the id is taken out of circulation before the fork and released
by a guard on every path out. Without it the duplicate check was advisory — two clients spawning
`service:code-server` at once both passed `contains_key`, both forked, and the second insert
overwrote the first pane's master, pump and pid with no `abandon`: a running Node superd could no
longer list, kill or reap. What stood there instead was a `debug_assert!`, which `make superd`
(`--release`) compiles out. Pinned by
`registry::tests::two_spawns_of_one_pane_id_produce_exactly_one_pane`.

---

## 6.11 The reader thread never writes, and the buffers fit a frame

The supervisor client's read loop hands a pane's bytes to its handler synchronously, and that
handler comes back into the client to write: `PausableQueueGate` crossing capacity calls `setPaused`
from inside the ingest it just performed. Written straight to the socket, that is a blocking
`write(2)` on the very socket the reader is responsible for draining — and superd's pump is
meanwhile blocked writing a 32 KiB output frame into hostd's full receive buffer. Neither side moves
again, there is no timeout on either, and every terminal in the workspace freezes.

Two rules come out of it, and both are load-bearing:

- **Every outbound frame leaves from one serial queue** (`SupervisorClient.outboundQueue`). The
  reader hands the frame over and goes straight back to `receive()`, which is what lets superd's
  writer drain. Serial, and used by the awaited path too, because order is meaning: an `unsubscribe`
  overtaken by a later `subscribe` for the same pane cancels the live subscription.
- **The socket is widened to 256 KiB in both directions**, on both ends. `AF_UNIX` defaults to 8 KB
  on macOS against TCP's 128 KB (`DECISIONS.md` 2026-08-10), and one output frame is up to
  `READ_CHUNK_BYTES` = 32 KiB — at the default not even a single frame fits.

---

## 6.12 Closing the duplicate is bounded, and a parked write keeps it open

hostd's master is a duplicate of superd's open file description (§2), so closing it while a `write(2)`
is parked in the kernel is not a local matter: the fd number is freed immediately, the parked write
still refers to the description, and the next `open`/`socket`/`accept` in the process gets that
number back. Bytes that were meant for one shell arrive in another. That is the TOCTOU the
input-write gate closes — the gate is shut first so nothing new joins the queue, then the already
enqueued writes are waited out, and only then is the duplicate closed.

The wait is **bounded** — 2 s on relinquish, 5 s when the pane is being killed — and enqueued
`async` + semaphore rather than `sync`, because a `sync` behind a blocking `write(2)` on a serial
queue has no way out at all: a client that stops reading parks the write forever, and hostd's whole
teardown parks with it. On timeout the duplicate is **deliberately left open** and the fact is
logged. An fd leaked for the remaining life of this hostd process is the cheap failure; recycling
the number under a live write is the expensive one, and the shell is unaffected either way because
superd holds the description that matters.

The kill ladder ends the same way. `release(kill:)` returns whether superd actually accepted it, and
a `false` after the 0.25 s exit wait is logged rather than swallowed — a pane that outlived its
`terminate` is a supervision failure, and silence there is how it becomes a mystery process.

---

## 6.13 superd reads what the shell says out of band, because it already has the bytes

`HostOutputSniffer` ran an OSC state machine over EVERY byte of EVERY pane, in Swift, on the
read-loop thread, to find six things: the window title, a real bell, the OSC 133 command marks, the
working directory, desktop notifications, and the OSC 9;4 progress body. It measured 614 MiB/s and
was never a throughput problem. That is not why it moved.

It moved because §6.5 had already made superd's pump the first reader of every byte. From that
point the sniffer was a SECOND pass over the same bytes, in a second language, one hop later — and
two readers of one stream drift. Not hypothetically: the title coalescing anchor is state, and a
hostd that restarts loses it while the shell that set the title does not.

So the scan happens in `Pump::publish`, the one place a chunk exists before anyone else sees it.
The cost is a state machine on a thread that already touches the byte, and no copy and no round
trip at all.

**What crosses the socket is the ANSWER.** A `0x04` frame carries a small JSON batch —
`{"events":[{"kind":"title","value":"…"}, …]}` — and it is written immediately BEFORE the `0x03`
frame carrying the bytes those events were found in, under one hold of the connection's wire lock.
Events-first is not a preference: superd sends a sniff frame only when a chunk actually contained
something, so a receiver cannot wait to find out whether one is coming. It can only hold what it
has already been given, which is what `PaneOutputStream` does — one pending batch, handed to
`onChunk` with its own chunk, exactly the pairing hostd had when it did the scan itself.

**Three things stayed in hostd, and each for a reason.**

- *The progress GRAMMAR.* OSC 9;4 crosses unparsed, as a `progress` event carrying the body
  verbatim. `ProgressOSCParser` already owns that vocabulary; a second copy of it inside the byte
  reader is the drift this port removes. Telling progress from a notification is a shape test, not
  a parse, and that much superd does do.
- *The event → wire translation.* What the shell SAID and what a client is TOLD are the same thing
  for a title and are not for a cwd (host-gated, resolved into a project key) or a notification
  (dropped while an agent's hook already banners the edge). `MuxChannelSession.wireMessages(from:)`
  is where those decisions already live.
- *WHEN to retire the coalescing anchor.* superd drops a title identical to the one it last
  emitted. hostd's detector is what knows an agent EXITED — and the next agent's opening title is
  very often byte-identical to the one just retired, so deduping it away leaves the pane untitled.
  The `forgetTitle` verb is fire-and-forget, sets an atomic the pump clears before its next scan,
  and losing the race costs a stale title rather than a wrong one.

**A pane is sniffed only if it asked for the shim.** `SpawnRequest.shellIntegration` gates both: a
`$SHELL -c …` pane and a panel backend have no prompt machinery and say nothing out of band, so
scanning their stdout would be pure cost. It is also what keeps the new tag inside the append-only
rule — an older hostd does not know the field, so it never asks, is never sniffed, and never sees a
`0x04`.

**A reattach replays the events, not a snapshot.** `subscribe` runs a FRESH sniffer over the
backlog it is about to send and puts one batch ahead of the first chunk. A restarted hostd used to
learn a pane's title by re-reading the replayed ring; it still does, and there is no second copy of
"current truth" to go stale. The live sniffer is untouched — it belongs to the pump thread, and a
fresh one starting mid-stream is exactly the resync case its state machine is built for.

The frozen `hostOutputSniffer` golden corpus moved with it: `rust/slopdesk-superd/tests/golden_sniffer.rs`
replays the committed vectors and asserts byte-identical FRAMES, with `slopdesk-wire` as a
dev-dependency and nowhere else, because no single crate owns both ends of "these bytes produce
these frames".

---

## 6.14 …and it keeps what the shell produced, because a ring in hostd dies on every rebuild

`CommandBlockSegmenter` was the OTHER per-byte reader on that thread: the OSC 133 state machine that
turns a stream into COMMANDS — `A` prompt, `B` command line, `C` execute, `D;code` done — and
`CommandBlockTracker` was the ring that held each finished command's captured output for the
Commands panel, the `last-output` verb and `run --wait`.

Half of the reason it moved is §6.13's, unchanged: superd's pump is the first reader of every byte,
so a Swift segmenter was a second pass over the same stream in a second language. The other half is
its own, and it is not about throughput either.

**The ring outlived the wrong process.** It lived in hostd, so it died on every `make host-restart`
— 0.2 s during which nothing else about the pane changed: the shell kept running, the PTY kept its
master, superd kept the pane. A client that reattached afterwards found an empty Commands panel for
a shell that had never stopped, and the only way to refill it was to run another command. In superd
the ring is bounded by the same two ceilings it always had (64 blocks, 8 MiB total, 256 KiB per
block) and outlives every hostd that borrows the pane. Same argument that decided inspectord: blast
radius, not benchmarks.

**A second tag, not a bigger batch.** Blocks ride `0x05`, written after the `0x04` sniff frame and
before the `0x03` bytes, all under one hold of the wire lock. They are not folded into the sniffer's
batch because the two answer to DIFFERENT gates — `shellIntegration` and `blocks` — and what keeps a
new tag inside the append-only rule is precisely that each tag has exactly one thing to ask for. An
older hostd sets neither flag and sees neither frame.

**One `now_ms()` for both readers.** `Pump::publish` takes the clock once and hands the same reading
to the sniffer and the tap, so a command's measured duration and a title found in the same chunk can
never disagree about when that chunk arrived.

**What crosses, and what hostd still decides.**

- *The auto-progress list crosses UNPARSED.* `BlocksRequest.autoProgressCommands` carries the raw
  `SLOPDESK_AUTO_PROGRESS_COMMANDS` value, `Option<String>`, and superd parses it. Unset ⇒ the
  built-in slow-command list, empty ⇒ disabled, set ⇒ those entries: three states, all expressible,
  and the built-in list stays the only copy of itself.
- *The synthetic badge is superd's decision and hostd's message.* A `progress` event says
  `indeterminate` or `clear`; the type-32 that carries it is hostd's, because superd does not know
  the protocol and must not learn it.
- *`runningCommand` is a hostd-side LATCH, not a verb.* `PaneLiveness.capture` runs for every pane on
  every reconciler tick, and a round trip there would put IPC on a path documented as a handful of
  lock acquisitions. The `0x05` events already arrive; the latch is fed from them.

**Every other read IS a verb**, because each is a person or an agent asking once: `blockOutput`
(one block's retained bytes, base64 — a click on a block, or a ctl `last-output`), `blockSnapshot`
(the whole list, which is what rebuilds a reattaching client's navigator), and `blockControl` (the
last N closed blocks WITH their bytes, the running command, and the `run --wait` baseline index —
one round trip, because those three are only consistent with each other if superd read them
together).

**An absent reply is not an empty one.** A pane with no tap answers `nil` to all three, which a
caller reports differently from "this pane has run nothing yet". An unknown or evicted index on a
TAPPED pane answers EMPTY: the question was answerable, and the answer is nothing.

---

## 6.15 superd's `unsafe` left, and with it the reason superd could not `forbid` it

superd forks every pane, so for four stages it was the one crate in `rust/` that could not carry
`unsafe_code = "forbid"`. It sat at `deny` instead, with the exemption documented as "one module,
`spawn.rs`". That description was true about intent and false about effect: **`deny` is liftable by
a single `#[allow]`, anywhere in eleven thousand lines.** The crate that holds every live pane's
master fd was one attribute away from unsafety in any file, and no tool would have said so.

Stage 28 moved the five sites — the `fork`/`execve` window, `SCM_RIGHTS` fd adoption, the
`fcntl` flag helpers, `setsockopt`, and the `SIGPIPE` disposition — into `slopdesk-posix`, and
superd became `forbid`. Nothing about what superd DOES changed; a pane is still born by forking. What
changed is that the claim is now checkable.

### What `slopdesk-posix` will accept

A syscall with no safe wrapper in `std` or `nix`, plus the obligation that makes it sound — and
nothing else. The admission test is written into its crate header: *could the safety comment be
written without naming slopdesk?* "The registry holds this fd open" is not a fact about a syscall,
it is a fact about a pane table, and a fact about a pane table has to be argued where the pane table
is.

Two consequences fell out of applying that test rather than moving files mechanically:

- **The whole spawn moved, not a `fork` primitive.** `fork(2)` on its own is always sound to call;
  what is unsound is the window afterwards, and a window can only be made sound by owning every
  instruction in it. A `posix::fork()` would have handed superd an obligation it has no way to
  discharge — the rule covers instructions the *compiler* emits, not lines anyone writes. The
  disassembly pin (`fork_window_contract.rs`) travelled with the window for the same reason: a pin
  guards only the symbol it is compiled beside.
- **There is no `adopt(RawFd) -> OwnedFd`.** The proof that a descriptor is unowned exists in one
  instruction — the one after `recvmsg` returns — and cannot be carried out of it. Exporting the
  adoption as a safe function would have been a safe signature the crate cannot honour; exporting it
  as `unsafe fn` would have pushed the obligation straight back into superd. So `fdpass::recv_tagged`
  does the receive AND the adoption together and hands back an `OwnedFd`. Two of superd's five sites
  turned out not to need the crate at all: `pump`'s `BorrowedFd` helper was working around an import
  collision (`OwnedFd` already implements `AsFd`), and `frame`'s existed only because that module's
  API took integers, which it no longer does.

### §6.9 is a compiler error now, not a rule

`TIOCSWINSZ` is hostd's alone. superd's own tests still have to stand in for hostd's ioctl to check
that the `resize` verb records a truthful size, so `posix::pty::set_window_size` exists — behind a
`winsize-set` cargo feature that superd enables **only in `[dev-dependencies]`**. A release build of
the daemon therefore does not compile the function, and a production caller is a link failure rather
than a review comment.

### The gate

`rust/slopdesk-invariants` checks the MANIFESTS, not the source: rustc already enforces `forbid`
per crate, and what it cannot notice is a new crate quietly spelling `deny` or stating no policy at
all (which is `allow` by default). Every manifest under `rust/` must say `forbid`, inherit it with
`[lints] workspace = true`, or be `slopdesk-posix` — and `libc::fork`/`libc::openpty` may not appear
outside that crate, because a second window would be unguarded by construction.

---

## 7. What actually survives — and what does not

This section supersedes `docs/45` §6.5 and reverses its §8 non-goal.

**Survives:** the shell and everything under it, the controlling terminal and its winsize, the
agent's hook and ctl feeds (§1, §6.6), scrollback (the on-disk journal already did this), and the
workspace topology (`workspace-state.json` already did this).

**Survives as of §6.5:** output produced while no hostd was attached, up to the ring bound — and,
more importantly, the child no longer stalls while producing it.

**Survives as of §6.8:** the transcript arrives ONCE. The journal's history and the ring's backlog
are the same bytes, and the position superd holds in the stream it both numbers and writes is what
keeps hostd from showing the user both.

**Survives as of §6.7:** the panel backends — the embedded workbench keeps its Node process, its
warm extension host and its open editors, and `baguette serve` keeps its simulator connection.

**Does not survive, and is rebuilt:** every in-RAM per-pane structure — `TerminalScreenModel`, the
block tracker, the replay sequence, the resize votes, and the hook ledger keyed by `tool_use_id`.
Clients drop and reconnect on a 250ms backoff and receive a new epoch plus a snapshot.

The screen is repainted rather than reconstructed: `PTYProcess.beginRedrawJiggle()` already exists
and makes a TUI redraw itself, and the disk journal supplies the transcript above it.

**The known rough edge:** a `tool_use_id` whose `PreToolUse` landed before the restart and whose
`PostToolUse` lands after arrives as an orphaned resolve against an empty ledger. `docs/50` already
treats hooks as best-effort with a dissent watchdog as the escape hatch, so this degrades rather
than breaks — but it is a real seam and it is tested for, not hoped about.

---

## 8. Non-goals

- **Zero-downtime.** Clients disconnect and reconnect. The pane survives; the connection does not.
- **superd surviving its own crash.** §4.
- **superd understanding the terminal.** It reads the master fd (§6.5) and it does not look at what
  it read: no escape parsing, no screen model, no detection. Bytes go into a ring and out to a
  subscriber. The moment it needs to *interpret* them, this boundary is wrong.
- **The Android bridge.** The only non-goal left of the panel, and for a real reason rather than
  the one this list used to give for all three. `AndroidBridgeServer` is an in-process listener with
  no child to keep; `adb` invocations are sub-second; a scrcpy server is tied to two sockets hostd
  itself holds, so it dies with the video session either way; and the emulator was *already*
  deliberately orphaned and already survives. There is nothing here for superd to hold.

*(Reversed 2026-08-11: "supervising the panel backends this way" was a non-goal until §6.7.)*

---

## 9. The restart, as the user experiences it

Everything above makes a restart *cheap*. This section is about making it **easy**, which is the
half that decides whether it actually gets done. A restart that costs nothing but takes four steps
and one remembered flag still gets postponed — and postponing it was the original complaint.

### hostd states its own launch
`rust/slopdesk-hostlaunch`'s record → `<Application Support>/SlopDesk/hostd-launch.json`, written
once the listener is up and removed on the orderly stop. It carries the pid, the **bound** port, the
physical path of the running executable, argv, the cwd, and the `SLOPDESK_*` variables this process
actually resolved.

Two of those cannot be learned from outside the process, which is why the process writes it:

- **The bound port.** `--port 0` mints an OS-chosen ephemeral port that differs from the request.
- **The executable.** `argv[0]` is usually the relative `.build/release/slopdesk-hostd`;
  `current_exe` (`_NSGetExecutablePath` on macOS) is the kernel's answer and cannot be wrong.
  Symlinks are resolved so it matches `lsof -d txt`, which is how the restart confirms a pid has not
  been recycled.

**One declaration, both ends.** The record used to be a Swift `Codable` struct with a hand-written
Rust reader beside it in `slopdesk-devtools` — the same eight fields spelled twice, in two
languages, where a rename on either side compiles, passes every test and silently breaks the
restart. `slopdesk-hostlaunch` is that declaration now, taken by `slopdesk-ffi` (which the daemon
links, and which writes) and by `slopdesk-devtools` (which reads). The daemon supplies only the two
facts it alone knows — the bound port and its build version — and Rust asks the process for the
other six. hostd's argv **grammar** rides the same crate for the reason that pairs them: `--port 0`
is accepted by the grammar and answerable only by the record.

The pid is *content*, re-read every time and never baked into a name a child remembers — the
distinction §1 turns on. Its absence is meaningful too: no file means no hostd, a file whose pid is
gone means one died badly.

### `make host-restart`
`slopdesk-ops restart-hostd` — build (`--product slopdesk-hostd`, so not the client app, the video
host or iOS), then SIGTERM, then wait for both the process **and** the port, then relaunch with the
recorded binary/argv/cwd/env, then wait for a real listener. It builds *before* it stops, so a
failed build leaves the running daemon alone. It reports the observed downtime and superd's child
count on either side — measured at ~**0.2 s**, with the child count unchanged, which is the whole
claim of this document in two numbers.

`--status` reports and changes nothing. `--stop` stops without building.

### Live config reload: rejected, and not narrowly
The obvious companion — SIGHUP, re-read the flags, no restart at all — does not survive contact with
`EnvConfig`. Its overlay is a deliberately lock-free write-once global, set at `main()` before any
`static let` is forced, and it is read on the video pipeline's hot path by the golden-pinned
controllers; making it mutable means a lock there, to save a restart that now costs 0.2 s and kills
nothing. Meanwhile the hostd toggles are already split into two camps that both argue against it:
`ipcAllowSendKeys` and `ipcAllowSensitiveSessions` are re-read per request and so are *already* as
live as a process's own environment can be, while `blocksEnabled`, `agentControlEnabled` and
`preventSleepEnabled` are threaded into construction — a live flip would half-apply, giving
sessions that disagree about the rules. The restart is the reload.
