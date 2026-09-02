# 70 — The whole-tree audit of 2026-09-02, and what it changed

A pass over every crate, every Swift module, the lint policy, the toolchains and the docs, taken
the same day `docs/69` audited the dependencies. Written down for the reason `docs/69` gives: the
half of an audit that is "looked, found nothing" is the half nobody records, and it is the half the
next audit pays to re-derive. Every rejected finding below carries the evidence that rejected it.

Read `docs/69-dependency-currency.md` for the pins — nothing here re-derives them — and
`docs/46-gates-env-paths.md` for the gates that now ratchet what this pass found.

## 1. What was checked, and how

| Surface | How |
| --- | --- |
| Lint policy | every `rust/*/Cargo.toml` diffed against the root's `[workspace.lints]` tables; clippy `all`+`pedantic`+`nursery`+`cargo`+restriction swept per crate with `-D warnings` |
| Toolchains | rustc 1.98.0 · Swift 6.3.3 (tools 6.3) · swiftformat 0.63.0 · swiftlint 0.65.1 · nightly rustfmt (floating, never dated) |
| Dependencies | `cargo audit` over all 78 lock files: 0 advisories. `cargo machete` per crate. `cargo-deny` was installed and unconfigured; it is `just lint-deps` now, under `rust/deny.toml`, inside `just check` (§2.1, `docs/46`) |
| Daemons | superd, hostserver, screend/screenclient, dropd, inspectord, hostsession, ctl, hook — accept loops, thread spawn failure, socket timeouts, unbounded queues, lock ordering |
| Wire and video | decoders for hostile counts, packetizer/reassembler bounds, per-fragment allocation, FEC ranks, retransmit ring, backpressure |
| Apple crates | `Drop` completeness, retain/release order, main-thread hops |
| Terminal | sanitize's scanner, rowscan, fuzzy, termrender, vterm, the prompt lexer |
| Swift | actor hops per packet, main-actor conventions, dead `swiftlint` disables, port candidates |
| Docs | every read-first doc and the ops docs read against the tree by a separate pass |

Method: one audit agent per surface on the cheap tier, each finding then verified against the
code before a fix was written; every fix carries a test in the crate's own style, and every crate
touched was re-gated with `cargo +nightly fmt`, `cargo clippy --all-targets -- -D warnings` and
`cargo test`, then `just quick`, `just golden` (byte-identical) and `just check`.

## 2. Fixed

### 2.1 Lint policy and tooling

- **The lint floor is one set.** 46 workspace roots had drifted copies of the root's lint tables;
  every one now states the root set verbatim. The five crates that may write `unsafe` say
  `unsafe_code = "deny"` **and** `unsafe_op_in_unsafe_fn = "deny"`. `lint-floor-agrees` in
  `slopdesk-invariants` ratchets this (§4).
- **~1,000 clippy findings** across `slopdesk-devtools`, `slopdesk-invariants`,
  `slopdesk-loopback-validate` and eight smaller crates, fixed rather than allowed: dropped
  qualifications, missing `Debug`/`Copy`, `pub` → `pub(crate)`, indexing → `get`, `let _` →
  `let _ignored`, integer division and print sites carrying `#[expect(…, reason)]`.
- `cargo machete`: `libz-sys` in `slopdesk-git` is a build-script dependency (ignored with the
  reason in the manifest); `objc2` in `slopdesk-apple-audio` was genuinely unused and is gone,
  with the five lock files that named it re-resolved.
- `.swiftformat` targets Swift 6.3. `optional_data_string_conversion` is disabled once in
  `.swiftlint.yml` with its reason; the 53 per-line `swiftlint:disable:next` copies are deleted.
- `Package.swift`, `PRODUCT.md` and the justfile named deleted scripts (`check-supervisor.sh`,
  `measure-g2g.sh`); they name the `just` recipe that replaced each.
- `SlopDeskClient` depended on `CSlopDeskFFI` without `linkerSettings: ffiCLibraries` — it linked
  on another target's flags. Fixed, and `ffi-dependents-link-the-frameworks` ratchets it (§4).
- **`cargo-deny` is a gate.** `rust/deny.toml` — RustSec advisories and yanked crates, a
  permissive-only licence list (the one addition is `CDLA-Permissive-2.0`, the Mozilla CA bundle
  under `ureq`), no `*` requirements, crates.io plus the one `rev`-pinned git source — runs over
  every workspace as `just lint-deps` inside `just check`, 8 s with the advisory fetch hoisted
  out of the fan-out. `slopdesk-provision` was the one crate with no `license` field.

### 2.2 Daemons

| Crate | Finding | Fix |
| --- | --- | --- |
| superd | the accept loop returned on any non-`EINTR` error, so one `EMFILE` took every pane down | retry on `EMFILE`/`ENFILE`/`ECONNABORTED`/`ENOBUFS` after a 50 ms rest; the hand-over to a client runs on its own thread so a wedged hostd cannot block accept |
| hostserver | `Threads::run` dropped the work on a refused spawn while its doc promised inline execution | the closure is kept and run inline on `Err` |
| hostserver | the ctl queue was unbounded per PTY chunk | 8 MiB cap, oldest line evicted |
| screenclient | no socket timeouts, so a hung screend pinned pane teardown | read/write timeouts at dial, 5 s exchange bound |
| hostsession | `timer.rs` could re-arm after `stop` | `ensure_running` checks `stopped` under the thread-handle lock |
| inspectord / dropd | per-connection threads with no timeouts | 30 s write timeout on the pump; 60 s idle timeout per drop connection |
| ctl | no write timeout on the control socket | 2 s (reads stay unbounded on purpose: `wait` and `subscribe` are open-ended) |
| loopback-validate | `closedloop::run` returns an EMPTY result when the encoder or source cannot be created, and the suite indexed three phases — a panic where a FAIL line belonged | `ClosedLoopResult::has_every_phase` guards all three arms |

### 2.3 Wire and video

- `WorkspacePresenceRoster::decode` refuses a `client_count`/`pane_count`/`attachment_count` over
  `MAX_RECORDS` (4096) as `malformedBody` before sizing anything; `docs/20` states the cap, and the
  Swift codec tests that expected `truncated` for a hostile count now expect the refusal (a count
  UNDER the cap over an empty buffer is still `truncated`).
- The packetizer refuses a frame the reassembler would refuse (`MAX_FRAGMENTS_PER_FRAME`) and
  still consumes its frame id, so both ends agree on the sequence.
- `Reassembler::ingest` takes the fragment by value (one clone per fragment gone); the blob fold
  mutates in place; `fec::encode_group` allocates one parity per rank; the retransmit ring is a
  `VecDeque`; `K_MAX + BURST_PARITY ≤ 255` is a `const` assertion.
- `session_actuate::retransmit_fragments` honours the same backpressure gate `session_pump` does.

### 2.4 Apple crates

- `slopdesk-apple-fsevents`: `Drop` removes the address-keyed row BEFORE releasing the stream, so
  a re-used address cannot alias a live entry.
- `slopdesk-apple-sck`: `CaptureStream` gained a `Drop` that stops capture, so a dropped stream no
  longer keeps the window server recording.
- `slopdesk-apple-vt`: `pixels::image_size` — see §2.7.
- `slopdesk-apple-ax`: the observer leak test built an observer OUTSIDE the roster lock the three
  table-counting tests take, so under a loaded build farm its row landed in their counts (two
  failures in one `just test-rust`). It takes the turn now.

### 2.5 Terminal

- sanitize: `CAN`/`SUB` abort a string body under every policy (an OSC 11 could leak past
  `should_strip_osc` through `11\x18`); the UTF-8 lead range is `0xC2..=0xDF` in the boundary
  scanner as in `plaintext`; `strip` copies plain-ASCII runs as one slice, with an oracle test that
  proves the output byte-identical to the one-byte loop over a 256-round byte soup.
- rowscan: `waituntil` patterns run with `(?m)` **and** `crlf(true)` — PTY lines end `\r\n`, so `$`
  never matched before the `\r`; hint columns come from a running prefix instead of re-measuring
  every match; the accumulator test now asserts what it keeps.
- fuzzy: candidates are capped at 4096 scalars and patterns at 256 at all three doors, so an FFI
  caller cannot size the DP matrix.
- termrender: a block cursor on a wide tail inverts the head's glyph (`Cursor.col` is the corrected
  column); `run_over_row` fills a scratch the painter owns.
- terminal: the prompt lexer's `paint` indexes words in O(1) instead of searching per atom (a
  20,000-token paste test pins the spans against the old search).
- vterm: `search_rows`/`search_frame` were a SECOND logical-line walker beside the live
  `search_screen`; deleted, with their tests moved onto `LineScan` + `search_line`.
  `select_output_at` had no caller — the block "copy output" affordance is a wire request the host
  answers (`copyBlockOutput` → `requestBlockOutputBytes`), never a client-side selection — deleted.

### 2.6 Swift

- `VideoWindowPipeline.applyCursor` spawned a `Task` per cursor packet at 120 Hz; the update is now
  stored under a `Mutex` and the main-actor hop is taken once per burst (an `Atomic<Bool>` gate).

### 2.7 The in-place resize — implemented, unit-tested, and live-verified on 2026-09-02

`SLOPDESK_INPLACE_RESIZE` was parsed and documented, and the branch it selected was never wired —
`session_resize.rs` said so in its header, and `docs/61` recorded the gate as unread. The door is
landed: the pump reaches its encoder through an `EncoderSlot` (a mutex over the encoder and the
size it was opened at); when the gate is on and `can_resize_in_place` holds, a resize opens a
VideoToolbox session at the new dimensions, swaps the slot, reconfigures the live `SCStream`
(restoring the slot if the framework refuses), installs the new encoder WITHOUT bumping the
capture generation, then drains the old encoder and reseeds the controllers. The first post-swap
frame is an IDR by construction (a fresh session cannot emit anything else), and a size guard drops
buffers still in flight at the old size. Every decline — gate off, ineligible capture, open
failure, stream refusal — falls through to the unchanged teardown-and-re-dial path.

Eleven tests pin it across `session_resize.rs`, `session_pump.rs` and `session_capture.rs`. The
gate's DEFAULT was `on` while it was inert, went `off` when the branch was wired — because
`synthetic-tests-prove-nothing-fires`: a hot-path branch goes live on the real host only after
someone has watched it — and is `on` again since the same day, because `just gui-video` now
watches it (`rust/slopdesk-devtools/src/gui/video.rs`). After the decode/present proof the gate
drags the client's remote window through System Events with host-follow on; the pane turns that
into a `resizeRequest`, the host AX-resizes the captured window and the fast path runs. Three
things are then read off the logs, each counted from before the drag: the host said
`in-place resize: encoder swapped to WxH under the live stream` (a debug line added for this),
the host never said `restarting the stream` (either way the fast path declines now says so), and
the client logged `resize: adopted decodedSize=WxH` and its decode counter kept climbing — the
third is what a host swapping encoders into a client that rejects every post-swap frame would
fail.

Seen on the 2026-09-02 run (window: Parsec, 1627×943; default gate, nothing forced): two swaps,
both in place — the connect-time 1:1 negotiation to 1280×800 and the drag to 1100×688 — zero
restarts, both sizes adopted by the client, decode markers 15 → 21 across the drag.

### 2.8 Docs

Three separate reads of the read-first and ops docs against the tree. The dominant pattern is the
Swift-to-Rust hostd cutover (`docs/60` F.9) leaving OPERATIONAL docs describing deleted Swift in the
present tense; the secondary one is hand-spelled counts that grew without their sentences.

- **`SlopDeskHost.app` was still shipped on paper.** The cask (`packaging/homebrew/Casks/slopdesk.rb`)
  declared `app "SlopDeskHost.app"`, a bundle the DMG has not contained since F.9 — `brew install
  --cask` would have failed on the missing bundle. The cask, `docs/49`, `BUILDING.md` and the
  decision-log entry the comment was copied from now describe the CLI-only host
  (`slopdesk-hostd` from the formula, under its launchd agent).
- **Counts.** "Seventeen workspaces" (`docs/46`, `docs/69`, three justfile comments) — there are
  78; "72 `.cargo/config.toml`" — 78. Reworded to derive from `RUST_WORKSPACES` where a number was
  never needed.
- **Deleted Swift in the present tense.** `docs/51` (`PTYProcess`, `HostServer.*`), `docs/46`'s
  description of the panel-shutdown check (`HostServer.swift` → `rust/slopdesk-hostd/src/main.rs`),
  `CLAUDE.md`'s read-first row for `MuxChannelSession`/`HostServer`, `PRODUCT.md`'s
  "Swift/SwiftUI clients".
- **`docs/68`** cited `terminal.rs:511` (no such file) and the deleted `slopdesk-ops
  enable-renderer` in its blast-radius set; `docs/58`'s accessor count; `docs/57`'s family list
  omitted two crates; `docs/55` named two doors by illustrative names.
- `docs/69` and this doc were missing from `docs/README.md`'s table.
- **Strings the binary prints.** `slopdesk sidecars`' upgrade plan told the operator to "quit and
  relaunch SlopDeskHost.app"; it names the launch-agent restart now, and `docs/49` quotes the new
  line. `adopt.rs`'s module doc described the menu-bar host in the present tense.

## 2b. The GUI video host now ships — and the pane that dialled it no longer hangs

**Found:** `rust/slopdesk-videohostd` is the daemon (`docs/61`), and nothing in
`rust/slopdesk-devtools/src/release/tools.rs`, `packaging/` or the release workflow built, packed
or installed it; nothing in `slopdesk-hostd` spawned it. It was started from a checkout by
`slopdesk-ops` and the GUI gates and nowhere else. Meanwhile the shipped client's remote-window
pane (`RemoteWindowModel.open()`) dialled `ConnectionTarget`'s media/cursor ports (9000/9001)
unconditionally and retried its hello for ever: on every `brew install` the pane mounted its live
chrome and waited, silently, for a daemon that did not exist on the machine.

**Fixed, as a launch story rather than a line in a list:**

- **Thirteenth binary.** `RUST_CRATE_TOOLS` names it, the formula installs and `test`s it, the
  pin carries its seeded stamp (`slopdesk-release stamps`' own output for the tree), and it
  answers `--version` in the shape every shipped tool does (`docs/49`).
- **A LaunchAgent of its own, never a superd child.** TCC grants Screen Recording and
  Accessibility to the RESPONSIBLE process, and a child of a launchd job inherits its parent's —
  so the `spawn_or_adopt` route dropd rides would have had users granting Screen Recording to
  `slopdesk-superd`. Disclaiming responsibility at spawn is an SPI `slopdesk-posix` does not carry
  (a `docs/57` design change, recorded in §3). `com.slopdesk.videohostd` is the fourth `Agent` in
  `ops/launchd.rs` (`just videohostd-install`), with superd's guarded `KeepAlive` — and for that
  to converge, `EADDRINUSE` on 9000/9001 is now a deliberate exit 0 in the daemon's `main`, for
  hostd's reason. `slopdesk-sidecars` knows its label and calls its restart the operator's.
- **The pane says so.** `KeepaliveTiming.helloDeadline` (10 s, `slopdesk_video::keepalive`) is the
  sixth number in the timing record; the pipeline's stall monitor reports
  `VideoSessionRefusal.hostUnreachable` when no control datagram has arrived by then, the same
  teardown as a host refusal with a different sentence
  (`slopdesk_workspace::remote_window::unreachable_message`, naming the address dialled and the
  daemon to start). `onSessionRejected` carries the reason end to end.


## 3. Rejected, with the evidence

| Finding | Why it is not a bug |
| --- | --- |
| "draw per display-link tick" in both terminal renderer views | `MacTerminalRendererView.tick` and `PhoneTerminalRendererView` both gate `driver.present()` on `needsPresent` |
| hook: no connect timeout on the hostd socket | macOS `AF_UNIX` `connect` on a full backlog returns `ECONNREFUSED`; it does not block |
| fuzzy: the tab placeholder can collide with a literal | it is fzf's own behaviour, kept on purpose |
| `FramePacer` should be `@MainActor` | REJECTED, not deferred. `VideoWindowPipeline.swift`'s `submitDecodedFrame` hook says the orchestrator actor calls it from its own executor and the pacer's `submit` is internally locked; `FramePacer.swift`'s header says why the `NSLock` and `@unchecked Sendable` are the design (the tick path releases the lock mid-function to hop to the main actor for the present). `@MainActor` on the class would force a main hop per decoded frame — the cost §2.6's cursor coalescing removed |
| spawn `slopdesk-videohostd` under superd/hostd the way dropd is (`ServiceProcess::spawn_or_adopt`) | TCC grants Screen Recording and Accessibility to the RESPONSIBLE process, and a child of a launchd job is its parent's — the prompt would name `slopdesk-superd`. Disclaiming responsibility at spawn is an SPI `slopdesk-posix` does not carry (`docs/57`). It is a LaunchAgent of its own (§2b) |
| `HistoryProvider::candidates` clones the history per Tab | the query it would pre-filter on is derived inside `complete()` (`dequote` up to the caret); a pre-filter would re-spell that rule, and the ranker's DP dwarfs the clone |
| port `CodeSidebarFocusPolicy` to Rust | the code panel dies with code-server (`docs/DECISIONS.md`); porting policy for a panel being deleted is waste |
| port `PaneDropGate` to Rust | what is left is one-line predicates over Foundation types (`URL.isFileURL`, `NSItemProvider`); the classifier already lives in `slopdesk-workspace::drop_payload` |
| screend: one `Mutex<Registry>` across panes | contention was not measured; a split is a design change, not an audit fix |
| `slopdesk-clientnet` `a_batch_of_failed_dials_leaks_no_descriptor` failed once under `just test-rust` (`5 → 10` descriptors) | it counts the process's open descriptors while the parallel build farm is opening its own; three reruns in isolation pass. The crate was untouched by this pass. See `perf-tests-load-flaky` |

## 4. Ratchets added to `slopdesk-invariants`

| Rule | What it refuses |
| --- | --- |
| `lint-floor-agrees` | a `rust/*/Cargo.toml` whose `[lints.rust]`/`[lints.clippy]` (or, for a nested workspace, `[workspace.lints.*]`) differs from the root's by one entry, modulo the licensed `unsafe_code = "deny"` + `unsafe_op_in_unsafe_fn = "deny"` pair |
| `ffi-dependents-link-the-frameworks` | a `Package.swift` target that depends on `CSlopDeskFFI` without `linkerSettings: ffiCLibraries`. Its splitter knows `.target(name:)` is also a dependency spelling and skips comments and string literals, and a break-test pins each of those holes |

Five rules that printed their offending sites to stderr from inside a rule now carry the sites in
the verdict string, as `lib.rs` says a rule must.

## 5. How to re-run this

`just check` is the gate. For the audit itself: `cargo audit` in each workspace root, `cargo
machete` per crate, and the per-surface reading above — the verified findings are the tests this
pass added, so a regression is a red test rather than a re-read.
