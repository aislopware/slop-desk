# 53 — The file-drop service (`slopdesk-dropd`)

PATH 4's receiving end, in a Rust daemon on its own TCP port. The client dials **it**, not hostd.
hostd keeps the client end of the protocol and nothing else.

Read `docs/51-process-supervision.md` first for the daemon shape this follows, `docs/52` for the
sibling that moved the same way, and `docs/46-gates-env-paths.md` for the gate matrix.

---

## 1. Why it left Swift

Not throughput on a microbenchmark — **blast radius**. The Swift `FileTransferServer` ran inside
hostd, so a 4 GiB drop was a 4 GiB stream through the process that also owns every keystroke, every
pane's flow control and the workspace document. Two consequences, both observed:

- **A host restart took the upload with it.** `just host-restart` is ~0.2 s of downtime and superd's
  children never notice it — but an upload lived in hostd's own address space, so it died there.
  Nothing resumes; the user re-drags the file.
- **The receiving path competed with the terminal.** Every chunk arrived on hostd's `NWConnection`
  callbacks and every write went through its dispatch queues, next to the paths that have a latency
  budget measured in milliseconds.

The wire never went through hostd — the client has always dialled `terminalPort + 2` directly
(`RemoteWindowModel.fileTransferTarget()`). What changed is which process is listening there.

The move also paid for itself in code deleted. Five Swift files went (`FileTransferServer`,
`FileReceiveLogic`, `FileDropSink`, `FileNameSanitizer`, `LoopbackFileTransferChannel`) and the
incremental frame splitter went with them on the server side: `NWConnection` hands you arbitrary
chunks on a callback, so the Swift server needed a resumable decoder with a poisoned state. A
blocking socket hands you exactly what you ask for, so dropd's `read_frame` is a `read_exact` and a
fault simply ends the connection — which is the only correct answer anyway, since a stream whose
frame boundaries are in doubt cannot be resynchronised onto attacker bytes.

## 2. Shape

A separate binary over a socket, **never FFI** (`CLAUDE.md`), so `swift build` on a clean checkout
still never sees cargo. Its OWN cargo workspace, for the reason superd and screend are: profiles are
workspace-global, and this one wants `opt-level = 3` and `panic = "unwind"` where the hook wants
`"z"` and `"abort"`.

```
Sources/SlopDeskFileTransfer/   ONE file: the face over the one door (URLs in, progress out)
Sources/SlopDeskHost/FileDropServiceManager.swift   spawn-or-adopt + port re-learn (no bytes)
rust/slopdesk-dropd/
  src/upload.rs     the CLIENT end's sequence: which frame follows which, and what a fault does
  src/client.rs     encode requests (1–5), decode replies (6–9) — the initiating end's layouts
  src/protocol.rs   decode requests (1–5), encode replies (6–9)
  src/name.rs       untrusted filename → safe leaf, or refusal
  src/receive.rs    the state machine: requests in, effects out — no socket, no filesystem
  src/sink.rs       temp file per transfer, rename into place at the end
  src/server.rs     accept loop, thread per connection, one sink per connection
  src/main.rs       --port / --drop-dir
```

**No shared mutable state anywhere.** Each connection owns its state machine and its destinations,
so the only thing two uploads contend for is the disk, and a panicking thread takes its own upload
down and nothing else. The mutex the Swift sink needed is simply a local now.

## 3. hostd's job, which is not the bytes

`FileDropServiceManager` spawns-or-adopts dropd as the superd pane `service:dropd`, exactly like the
panel backends (`docs/51` §6.7): on a PTY, under a stable pane id, with the port **re-learned by
replaying the ring from offset 0** and reading the child's own announce line —

```
dropd: listening on 0.0.0.0:7702 (v0.1.0, drop dir /Users/me/Downloads)
```

There is no state file and no port handshake. If the adopted service turns out to be on the wrong
port (a hostd relaunched with a different `--port`), the manager terminates it and respawns once.

The `(v…` is the RUNNING build's version, first in the parenthetical so its position holds however
the rest of that text grows. It rides this line rather than the wire for the same reason the port
does: a dropd hostd adopted is one hostd did not start, and this line is the only channel that
describes it. hostd compares it against `slopdesk-dropd --version` on disk and restarts a stale one
on the same port and drop directory — cheap, because dropd is hostd's own child (`docs/49`).

`HostServer.stop()` **relinquishes**: hostd goes away, dropd keeps running, and an upload in flight
across a host restart is simply not hostd's business any more. Only a deliberate stop terminates.

A dropd that will not start is logged loudly and is **non-fatal** — it must not tear down a healthy
terminal server, exactly as a failed bind did not. There is then no file transfer, and no fallback:
a Swift receiver "just for when dropd is missing" is the cross-language mirror the tree forbids, and
`rust/slopdesk-invariants` fails the build if one reappears.

## 4. The wire

Unchanged from the Swift server — same version 1, same type bytes, same framing — because an iOS
build shipped months ago is one end of it.

`[u32 BE payload length][u8 type][body]`, big-endian, strings `[u16 BE byte length][UTF-8]`, no
JSON. Version 1 only, no negotiation.

| type | direction | frame |
| --- | --- | --- |
| 1 | client → dropd | `hello(version)` |
| 2 | client → dropd | `offer(transferId, fileSize, name)` |
| 3 | client → dropd | `chunk(transferId, bytes…)` |
| 4 | client → dropd | `finish(transferId)` |
| 5 | client → dropd | `cancel(transferId)` |
| 6 | dropd → client | `helloAck(accepted)` |
| 7 | dropd → client | `accept(transferId)` |
| 8 | dropd → client | `complete(transferId)` |
| 9 | dropd → client | `failed(transferId, reason)` |

The dance per connection: `hello` → `helloAck`; then per file `offer` → `accept` → `chunk`s (256
KiB, read straight off disk so a multi-GiB file stays flat in RAM) → `finish` → `complete`. A
`failed` ends that file; the rest of the drop still tries. Transfers may interleave — the id keys
everything.

Each end is written ONCE, and both are Rust. `client.rs` encodes 1–5 and decodes 6–9; `protocol.rs`
does the mirror, and a test in the same crate walks every type through both — the two-ENDS exemption
to the one-implementation rule, kept honest by a test rather than by review. `SlopDeskFileTransfer`
is the Swift face, reaching all of it through `rust/slopdesk-ffi`'s ONE `slopdesk_drop_upload`
door; it holds no byte layout, no constant and no socket of its own.

That door used to be eight — encode a request, decode a reply, feed a splitter, read a constant —
with a Swift driver above them holding the `NWConnection` and the ORDER. Every answer was right
alone and nothing could check the order they were assembled in, which is the fault `docs/55` §4b
records the audio stage earning: *a law moved without its sequencing*. `upload.rs` is that
sequencing, and with the socket beside it there is no order left on the Swift side to get wrong.
§10 of `slopdesk-invariants` pins what remains: the door exists on both sides, and no reader or
writer has grown back under `Sources/SlopDeskFileTransfer`.

Types 6–9 arriving at dropd are decoded strictly and then **ignored** — a client spelling one is
confused rather than hostile, and hanging up would turn a stray frame into a lost upload. Types 1–5
arriving at the client are refused as unknown: the peer is not a dropd.

## 5. What it refuses

Everything a peer on the tunnel could try. Validate-then-drop throughout, and the refusals are in
`receive.rs` where they are testable with no socket and no disk:

| attempt | answer |
| --- | --- |
| an `offer` before the handshake | `failed` "no handshake" |
| a frame longer than 16 MiB | refused **before** the allocation, connection ends |
| an `offer` over 20 GiB | `failed` "file too large" |
| a reused transfer id | `failed` "duplicate transfer id" |
| `../../.ssh/authorized_keys`, `/etc/passwd`, `C:\dir\evil.dll` | reduced to the leaf, or refused |
| `.`, `..`, empty, whitespace, an embedded NUL | `failed` "invalid file name" |
| a body longer than the offer | abort + `failed`, and the transfer is forgotten |
| a `finish` short of the offer | abort + `failed` "incomplete body" |
| a `chunk` for no live transfer | `failed` "no such transfer" |

Bytes land in `.slopdesk-upload-<id>.part` and are renamed into place only at `finish`, so a partial
file never appears under its real name — and a dropped connection sweeps every temp file it left,
via the sink's `Drop`. A name that already exists gets a counter (`report (1).pdf`), bounded to a
thousand rather than looping, because a thousand copies of one name is a bug or an attack and
overwriting is not the answer either way.

A sink failure is recorded per transfer id, so a later `accept` or `complete` for the same id is
suppressed: the client got its `failed` and must not also be told the upload worked.

## 6. Paths and env

| name | meaning |
| --- | --- |
| `SLOPDESK_FILE_TRANSFER` | `0` disables PATH 4 entirely (default on). Read by hostd |
| `SLOPDESK_FILE_DROP_DIR` | where uploads land, `~` expanded against the daemon user's home. Default `~/Downloads` |
| `SLOPDESK_DROPD_BIN` | which binary hostd spawns, and which one the E2E test dials |

The port is `terminalPort + 2` — the inspector's `+1` and then this — computed identically on both
sides and never negotiated. `--port 0` binds an OS-chosen port and announces the real one, which is
what the tests use.

## 7. Gates

| command | what it covers |
| --- | --- |
| `just dropd` | build (release) |
| `just dropd-test` | 28 Rust tests: 3 name, 8 protocol, 8 receive, 5 sink, 4 framing |
| `just lint-rust` | clippy `-D warnings` + `rustfmt --check`, fourth workspace |
| `rust/slopdesk-invariants` | §10 — type bytes both ways, version, both caps, the announce line, no Swift receiver |
| `swift test --filter SlopDeskFileTransferTests` | 5 end-to-end, and nothing else — the codec and splitter tests went with their subjects |
| `swift test --filter FileDropServiceManagerTests` | 7 — argv, the announce parse, a missing binary, a survivor on the wrong port, a child that never announces, relinquish vs shutdown |
| `just test` / `just test-touched` | all of it, and they BUILD dropd first |

`DropdE2ETests` spawns the **real** daemon on `--port 0`, uploads through the face, the door and
`upload.rs`, and asserts the bytes on disk, the monotonic progress, two files down one
connection with the collision counter, the empty-file case and the absence of any `.part` leftover. It is a true cross-language end-to-end test: an in-process
Swift fake standing in for dropd would be precisely the mirror this whole change deleted.

The protocol RULES are pinned in Rust and only in Rust — the state machine, the sanitiser, the sink
— and so is the client end now: `upload.rs`'s own suite drives a scripted peer through the frame
order, the refusals and a dying link. What the Swift suite is left answerable for is the CROSSING,
which is the one thing no Rust test can see.
