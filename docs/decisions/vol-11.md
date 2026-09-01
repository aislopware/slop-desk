# DECISIONS vol-11 — 2026-08-15 … 2026-08-16

> Volume 11 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## One vocabulary for a foreground process name (2026-08-15)

A PTY foreground process name is read three ways: classified (`claude`? a wrapper?), labelled (the
sidebar's shell slot), and refused (a credential prompt the control RPC must not touch). The first
was already in `slopdesk-agent::process`, with a private `basename` doing the reduction. The other
two were Swift — `ForegroundProcessDetector.basename` / `canonicalName` / `isVersionShaped`, and an
eleven-name `SensitiveSessionPolicy.sensitiveBasenames` with no Rust twin at all. Its own doc
comment pointed at the Swift reducer as the one it matched, which is the shape a drift takes before
it drifts.

All three now cross one door apiece over the same module. `basename` became total — the last
non-empty `/`-separated component, falling back to the whole input rather than `Option::None`. The
`Option` was right for a predicate, which reads nothing as "not claude", and wrong for a label,
which would have printed nothing where the raw input was the best answer available. Every existing
answer is unchanged: `is_claude_running("/")` compares `"/"` to `"claude"` instead of `None`.

Two deliberate divergences kept, each with the reason at its definition:

- `process::basename` splits on `/` ONLY, while `kind::path_basename` splits on `/` and `\`. The
  first answers what a Unix host's foreground poll reported, where a backslash is a filename
  character; the second reads names that may have been written on another platform.
- `is_version_shaped` accepts `.` and `v.`. Nothing real is named that, and tightening it would be
  a rule change rather than a port, so the Rust suite PINS the current answer instead of quietly
  improving on it.

`isVersionShaped` no longer exists in Swift, so the five assertions that drove it directly moved to
the Rust suite (which also gained `python3.11`, the case that proves a dot is not enough).

## One badge ladder for a tab row (2026-08-15)

`TabBadgeResolver.badge` fuses four independent per-pane signals — the agent status, the stored
exit-code badge, the live busy bit, the `OSC 9;4` progress mirror — plus the foreground process
name, into the ONE badge a sidebar row has room for. Ten rungs of precedence, all of it pure, none
of it SwiftUI, and it had no Rust twin at all. It is `slopdesk-agent::badge` now, and the Swift
resolver is a face over one door.

Two rungs are the reason this is a rule rather than a sort, and both moved with their reasons
attached: the AGENT finish sits ABOVE the busy tiers, because `claude` holds the shell's OSC-133
block open for its whole interactive lifetime — checked later, a finished turn would be shadowed by
`isBusy` for hours and never show. A plain COMMAND's clean exit sits BELOW them, because there a
newly-running command genuinely supersedes the previous exit.

The seven inputs cross as one `Signals` struct in Rust and as positional arguments at the ABI, each
optional carrying its own absence sentinel (`-1`) rather than a pointer — the same shape the answer
comes back in, since an all-clear row is `-1` too. The percent inside a progress report never
reaches the rule, so it does not cross: only whether the indicator is still going or has gone red.

`needsAttention` / `isBusyTier` became faces over the same module, and the privilege allow-sets
(`sudo`/`su`, `caffeinate`) went with them. The Rust suite pins what the Swift one could not state
as one assertion: no badge is ever both attention and busy.

All 80 existing badge tests pass unchanged, which is the point — this is a port, not a redesign.

## One vocabulary of secret shapes, for the title and for the paste (2026-08-15)

Two Swift modules recognised credentials. `SecretRedactor` masked them out of untrusted titles and
notification bodies with ten compiled `NSRegularExpression`s; `SecretPasteClassifier` decided
whether typing the clipboard into a remote field would leak one — and it CALLED the redactor to
answer half of that question, which is the honest admission that the two are one rule. Both are
`slopdesk-workspace::secrets` now, behind three doors.

**No regex crate.** Every one of the ten patterns is a prefix, a character class and a length floor
— shapes a scanner states directly. The crate is linked into the iOS app, and pulling `regex` in for
ten fixed shapes would buy nothing but binary size. The two rules that are not pure shapes (a
`key=value` assignment, a `Bearer` header) are written as what they actually are: find the
delimiter, look left for a key that ENDS in a secret word, mask what follows.

Porting the assignment rule exposed a subtlety the regex hid. `\b([A-Za-z0-9_]*(?:…|token))` puts
the word boundary before the OPTIONAL PREFIX, not before the secret word — so `GITHUB_TOKEN=`
matches (prefix `GITHUB_`) while a boundary check at the word itself would have rejected it, since
`_` is a word character. The first port did exactly that and the existing Swift test caught it.

The entropy sum is now order-independent: Swift accumulated `-Σ p·log2(p)` over a `Dictionary`'s
unspecified iteration order, so the last bits of the answer depended on hash seeding. The crate
sorts the characters and sums the runs, which is reproducible across builds — and the Rust suite
asserts that two orderings of the same multiset agree to the bit, a property the Swift suite could
not have stated.

`KeystrokeReplay.maxLength` crosses as an argument rather than moving into the crate: it is a
transport ceiling on what can be typed at all, not a rule about secrets.

Both existing Swift suites pass unchanged against the Rust scanner — 36 tests including the
vendor-token fixtures, the false-positive negatives (a hex SHA, a path, `tokenizer=`), and
idempotency. That is the differential proof this port rests on.

## What a fresh install carries is spelled once (2026-08-15)

The product's terminal defaults — `SF Mono`, 13pt, `regular`, `22212C`, `F8F8F2`, opacity 1, 10 000
scrollback lines — lived in `TerminalPreferences.init`'s default arguments AND in
`slopdesk-terminal::config`'s test fixture, which called itself "the preferences a fresh install
carries". Two of the values were the same literal in both files with nothing connecting them.

A test fixture that restates another language's constants is precisely the cross-language mirror
CLAUDE.md bans, and this one had teeth: the Rust test asserts the exact emitted config line for
line, so a default changed in Swift alone would leave a green suite proving the OLD terminal.

`config::factory()` is the fresh-install config now, built from seven named `FACTORY_*` constants.
The Rust suite varies fields off it; Swift's `init` defaults read the same constants through two
doors — one for the strings by index, one for the numbers. Every field NOT named is the type's own
`Default`, which is the empty string or a false: "the user has not chosen", rather than a value
someone picked.

The doors are indexed rather than one-per-value on purpose. Seven exported symbols for seven
scalars is the shape that grows without bound; two doors and an index do not.

## The secret shapes are `regex`, not a scanner I wrote (2026-08-15)

Ported the Swift redactor's ten `NSRegularExpression`s to a hand-written byte scanner the day
before, and the reason given was that `slopdesk-workspace` was dependency-free and is linked into
the iOS app. Both halves were the wrong test. The user's ruling: *"nếu crate nào ngon, vẫn được
maintain active thì dùng chứ đừng tự viết"* — and the repo had already made exactly this call once,
in `slopdesk-screend`, whose header argues for `regex` over `NSRegularExpression` because a finite
automaton has a documented linear-time bound where ICU's backtracking has none on a line an
adversary chose. A crate that is right for untrusted PTY output in a daemon is right for untrusted
PTY output in a title.

The notation is the real argument. These shapes are published as regular expressions by every
secret-scanning corpus there is, so a new vendor prefix should be one line in a table, not a new
byte loop with its own `\b` reasoning to review. The scanner it replaces had already been wrong
twice during its own port — a vacuous word-boundary check, and the wrong character class for the
Google key — and both were caught by tests rather than by reading, which is what hand-writing a
notation buys you.

One rule does not survive the translation intact: the generic backstop's three lookaheads. A
lookahead is not regular, and `regex` will not compile one. It does not need to be part of the
pattern — it only inspects the run the automaton already matched — so it is a filter on the match
(`Action::WholeIfMixed`) rather than a reason to reach for a backtracking engine and give up the
bound that made the crate the right choice. A pattern that fails to compile is dropped rather than
fatal, and `every_pattern_compiles` is what stops that silence being how a rule rots.

Measured, because binary size was the stated objection: a probe linking one plain door is 439 KB
after `-dead_strip`; the same probe calling `slopdesk_ws_redact_secrets` is 1.61 MB. ~1.17 MB for
the app, next to a `libghostty` an order of magnitude larger. `scripts/build-ffi.sh`'s header
carried a "384 KB linked" figure that had gone stale long before this change; it now carries both
measured numbers.

## Three hand-written base64 codecs became one crate (2026-08-15)

Auditing the tree with the same lens found `slopdesk-superd/src/blocks.rs` arguing the case out
loud: *"Standard base64 with padding, twenty lines rather than a dependency … a codec this small is
cheaper to read than to audit a crate for."* Its own doc comment then names the counterpart decoder
in `sniffer.rs`, which is the tell — an encoder and a decoder written separately, in one binary,
agreeing by inspection. `slopdesk-wire/src/document/state_file.rs` carried a third and fourth, and
the standard alphabet was a verbatim literal in three files.

"Small enough to read" was never the test. `CLAUDE.md`'s rule is one implementation, and a codec
copied per call site is one implementation per copy — this one had already grown four readings of
what padding is legal, each with its own comment explaining why it rejects what it rejects. The
`base64` crate's `STANDARD` engine is the alphabet Swift's `base64EncodedString()` wrote and the
canonical-padding strictness all four copies were reaching for: unpadded tails, padding in the
middle and two payloads spliced together are refused by construction rather than by four separate
loops that each remembered to. The strictness tests came through unchanged, which is what says this
was a replacement and not a redesign.

Not everything a crate could do is a thing a crate should do here: `percent-encoding` was rejected
for the two OSC-7/OSC-99 decoders in the same sweep, because it is LENIENT by design — a malformed
`%ZZ` survives as literal text — and both call sites refuse malformed input on purpose, since the
bytes come from whatever holds the far side of a PTY. A crate that cannot express the requirement
is not the wheel you were about to reinvent. That duplication is real and is dealt with separately.

## One reading of `\xNN` and `%NN` (2026-08-15)

The same sweep that found the base64 copies found two more rules spelled twice and one spelled four
times:

- The shell shim's `133;E` escaping of `;`, `\`, ESC, BEL, CR and LF was inverted in
  `slopdesk-sanitize::distill` AND in superd's block segmenter — the same rule, one written
  `(high << 4) | low` and the other `high * 16 + low`. Two spellings of one arithmetic is how a
  rule stops being one rule.
- Percent-decoding was byte-for-byte identical in superd's OSC 7 / OSC 99 reader and in the
  client's link scanner, differing only in whether the nibble helper was called `hex_nibble` or
  `hex_value`.
- `hex_nibble` had four copies. Three matched over `b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F'`
  by hand; the fourth already called `char::to_digit(16)`, which is what the other three were
  re-deriving.

`slopdesk-sanitize::escape` is the single reading. That crate already declares itself the home of
the shared byte scanners — `vtscan` and `width` are there for exactly this reason — and both new
consumers take it as a path dependency, which `slopdesk-wire` had already established is not the
supply chain a "zero dependencies" header is defending against. `slopdesk-terminal`'s header said
"Zero dependencies, on purpose"; it says "No EXTERNAL dependencies" now, because that was always
what the paragraph beneath it argued.

`percent-encoding` was considered and rejected, and the reason is worth recording next to the
opposite ruling on `base64`: it is lenient by construction — a malformed `%ZZ` survives as literal
text and the decode has no failure case — while both call sites refuse malformed input on purpose,
one feeding a desktop alert and the other a path a person is invited to click. "Use the crate" is
not "use any crate": it is use the crate that expresses the requirement, and where none does, the
answer is one implementation rather than four.

## One receive buffer, and a narrowed length spelled where it is named (2026-08-15)

A mechanical sweep for identical function bodies across the Rust tree — run because "audit again
after the fix" is the only way a consolidation pass finds what the first reading missed — turned up
two things worth the change and a pile that was not.

**The streaming decoders.** `FrameDecoder` and `MuxFrameDecoder` live in the same crate and each
carried the whole framing rule: fail-stop poisoning that frees the buffer, a read cursor with a
64 KiB wasted-head bound, and a compaction that is OWED rather than taken when the answer just
given points into the buffer. Three of those had already drifted between the copies — one `poison`
cleared the owed compaction and the other did not; one took an owed compaction at the top of a
decode and the other only at `append`; one compacted unconditionally on the two not-enough-bytes
paths where the other honoured the elide flag. None had produced a bug, which is precisely the
state a rule is in just before one copy is fixed and the other is not.

`slopdesk-wire::framing::PrefixedReader` is the rule now, and each decoder is what a framed payload
MEANS and nothing else — three lines and a closure. Where the copies disagreed the conservative
reading won, and the module header names each disagreement rather than quietly picking. All 361
wire tests pass unchanged, including the eliding suites that exist specifically to catch a span
going stale across a compaction, which is what says this was a port and not a redesign.

**The narrowing casts.** `truncating_uN` had FIFTEEN copies across four crates. Fourteen were
mechanical, but four in `slopdesk-ffi` shared the name `truncating_u32` while two of them
SATURATED — the name was lying at half the call sites. They are now `truncating_u32` and
`saturating_u32`, kept apart deliberately: on the unreachable path where they differ a wrapped
length makes Swift read a truncated payload as complete, and a clamped one makes it ask for a
buffer it cannot get. Merging them would have been a behaviour change dressed as a cleanup. Each
crate that writes a wire now has exactly one home for these — its own `bytes` module, or the FFI
root beside `deliver`.

`slopdesk-video::cursor`'s `truncating_u16` was NOT one of the copies: it takes an `f64` and
reproduces Swift's `UInt16(truncatingIfNeeded: Int(rounded()))`. It is `rounded_truncating_u16` now,
because a name that collides with a shared helper is how the next reader merges two rules by
accident.

## The arena's read half is one function per side of the boundary (2026-08-15)

`docs/55` §4c's arena convention has two halves. A door that hands Swift a list of records with
strings in them interns the strings into one buffer and puts `(offset, length)` pairs in the
records, so no record makes the caller own a lifetime. The WRITE half — `TextArena::intern` — was
shared from the day the convention was written. The READ half never was, and there is no reason for
that beyond nobody having looked: **eight copies in `slopdesk-ffi`, ten more in Swift.**

The eighteen had drifted, in ways that are all unreachable today and all the kind of thing that
stops being unreachable without anyone noticing:

- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift` and `VideoControlCodec`'s blob
  arm bounds-checked NOTHING — a projected row whose pair ran past the arena would have read
  whatever followed it. `VideoControlCodec`'s text reader checked the length was non-zero and not
  that the span fit.
- `WorkspaceChannelCodec` and `FileTransferCodec` answered `""` for bytes that are not UTF-8, where
  the other faces — and the crate's own reader — repair them. That is a different answer for the
  same bytes: one loses the whole field, the other one character of it.
- On the Rust side, five copies folded overflow with `saturating_add` and three with `checked_add`.
  Both answer empty on a real arena, but only by the accident that `arena.get(start..usize::MAX)`
  also fails.

`crate::arena_span`/`arena_text` and `SlopDeskArena`'s `ArenaText` are the readers now. A door whose
pair is a named C struct — `SlopDeskMetadataText`, `SlopDeskWorkspaceText`, `SlopDeskDropText`,
`SlopDeskKeybindRun`, `SlopDeskWsSpan` — keeps a one-line overload beside that struct and calls
through, because the struct belongs to that door's vocabulary and the read does not.

**Why a new Swift target for one function.** `SlopDeskProtocol`, `SlopDeskVideoProtocol`,
`SlopDeskWorkspaceModel` and `SlopDeskFileTransfer` are deliberately leaves whose only dependency is
the shim, so putting the reader in any of them would have widened three graphs to narrow one.
`SlopDeskArena` depends on NOTHING, not even `CSlopDeskFFI`: an offset and a length are arithmetic,
not a boundary. It is the shape §6 already describes for `SlopDeskAgentDetect` — the module that is
a vocabulary rather than a port.

**Two contracts survived on purpose.** `WorkspaceStateCodec`'s reader answers `String?`, because
that door's span carries a `present` flag and an ABSENT field is a different fact from an empty one;
it calls `ArenaText.optionalText`, which is `nil` only for a pair that does not fit. And
`link_detect` and `blocks` spell their pairs `size_t`, the way §4 spells every length, rather than
the `u32` the record-carrying doors use; the two widths meet at exactly one `saturating_u32` per
call site, which is where a cast belongs.

The bar this cleared is §6's own: `process::basename` was two implementations that disagreed for a
month with neither side able to see it. Eighteen readers of one convention is that setup, eighteen
times over.

## One NWConnection byte channel, and a lane keeps only its vocabulary (2026-08-15)

`SlopDeskInspector.NWByteChannel` and `SlopDeskFileTransfer.NWFileTransferChannel` were the same
actor line for line. Not similar — identical, apart from the dispatch-queue label and the prose
above it. Both wrap one `NWConnection` as an `AsyncThrowingStream<Data, Error>` in and an `async`
send out, with framing a layer up.

What makes two copies of this worse than two copies of a pure function is that the lifecycle is
where the bugs are, and the file records three of them: the continuation's `onTermination` cancel
(for a consumer that stops iterating without calling `close()`), the `cancel()` beside every
`finish()` (finishing the stream alone leaves the connection and its fd alive until the actor
deallocates), and the idempotent `start()`. Each was an fd leak, and each had to be fixed in both
places or the copies drift. They had not drifted yet, which is the same "just before" state the
framing decoders were in.

`SlopDeskNet.NWByteChannel` is the actor now — Foundation and Network and nothing else, so neither
caller widens its dependency graph by naming it. Each lane keeps its own protocol —
``ByteChannel``, ``FileTransferChannel`` — and one conformance line, because the protocol is that
lane's vocabulary (what a caller there is allowed to ask for) and the socket is not. The queue label
is the one thing the two ever disagreed about, so it is the one initialiser parameter: a spindump
still says which lane a thread belongs to.

This is the same split the arena readers took the same day: the RULE is shared, the NAME each door
gives it is not.

## One write(2) loop and one read-exactly, and drop-or-report stays with the caller (2026-08-15)

Thirteen copies of "move every byte, and fold in what `write`/`read` actually do": ELEVEN write
loops and two `readExactly`s. The first sweep found six of the writes because they were named
`writeAll`; the other five were inline — two closures inside the agent control listener, one
returning `Bool` in the code bridge, two spelled at the call site in the `slopdesk` CLI, one of
which called `die`.

Every one of them folded in the same two facts: **EINTR is a retry, not a failure**, and **a short
write is normal**. Getting either wrong is a truncated control response or a spin, and thirteen
places is thirteen chances.

`SlopDeskTTY.FileDescriptorWrite.all` and `FileDescriptorRead.exactly` are the loops now. The leaf
already owned the Swift side's raw descriptors — raw mode, termios, `TIOCSWINSZ` — and it has no
dependencies, so none of the six targets that now name it widened a graph.

**What did NOT collapse is the reaction**, and that is the whole design. Six callers DROP a failure
(a control client that has gone away is not something a listener can do anything about); five
REPORT it (a supervisor frame or a screend answer half-written is a lost boundary, and the CLI has
nothing to fall back on). Both are right, so the loop answers a `FileDescriptorOutcome` —
`.complete`, `.peerClosed`, `.failed(errno:)` — and each lane switches on it into its own error
type. `SupervisorFrame` still throws `FrameError.peerClosed`; `ScreenClient` still spells an EOF
mid-frame `ECONNRESET`; the `slopdesk` CLI still `die`s with `strerror`.

**Not a Rust port, and this is the one place that argument does not carry.** `rust/slopdesk-posix`
is the crate for a syscall with no safe wrapper, but it has no FFI door and needs none here: the
loop holds no policy, every caller already owns the descriptor, and routing each control-response
write through the boundary would add marshalling to a call whose entire cost is the syscall itself.

The outcome type was `FileDescriptorWriteOutcome` for about ten minutes, until the read side reused
it — the same lie `truncating_u32` was telling at half its call sites earlier the same day. It is
`FileDescriptorOutcome`, and the payload label is `transferred`, not `written`.

## One device-panel law, two device protocols (2026-08-15)

`Sources/SlopDeskClientUI/Simulator` and `Sources/SlopDeskClientUI/Android` are ~10k lines of
deliberately parallel code, and most of that parallelism is correct: the two panels speak different
protocols. The simulator's framebuffer never rotates, so a scroll delta has to be un-rotated against
the bezel's `rotationEffect`; `scrcpy` rotates on the DEVICE and restarts its encoder, so the frame
is always the right way up and there is no angle to be out of step with. The simulator sends touches
in the fitted rect's own space because the host rescales; the Android lane must send them in the
video's own pixel grid, because `PositionMapper` compares the pair on the wire against the size it
is currently encoding and DROPS a mismatch. Those files should read differently, and they do.

Five things were not different, and each of them fails quietly — a tap two rows off, a pinch whose
contacts leave the frame, a finger planted inside the system-gesture band. Both files even said so,
in the same words, in the two places where the same arithmetic could be wrong two different ways:
"this is the part that can be wrong in a way nobody notices until a tap lands two rows off."

- `DevicePanelGeometry` — the aspect fit, the panel-point→device-point mapping, the pinch pair, the
  safe-area margin, and the regrip that makes a long scroll one gesture instead of a series of
  unrelated flicks.
- `DevicePanelSampleBuffer` — the AVCC access unit becoming a `CMSampleBuffer`, identical down to
  the `-1` returned for a null base address. Only `formatDescription` is genuinely per-panel: the
  simulator is asked for `format=avcc` and parses a record, `scrcpy` forwards raw `MediaCodec`
  output whose parameter sets arrive as the Annex-B NALs CoreMedia wants anyway.

**The aspect fit went one level further than the two panels.** It is
`slopdesk-video::geometry::displayed_video_rect` through the door now — the same law the desktop
video client's renderer, input encoder and cursor overlay all invert, and which is Rust precisely so
a click lands on the pixel it was drawn for. It was a fourth spelling of it. What stays on this side
is the panels' own contract, which the video client does not share: a degenerate input answers
`.zero` (the view reads that as "nothing to draw yet") rather than the full view rect, and the
result is rounded to whole points because a device frame is drawn on a pixel grid.

The gesture tests reference `SimulatorScrollGesture.regrip`, `.planted` and `.edgeMargin` by name
and are unchanged, which is what says this was a port.

## The small rules that were spelled twice (2026-08-15)

A mechanical sweep for identical function bodies across `Sources/` found 53 of them. Most were the
two clusters above; these are the rest that were real, each one law with two call sites:

- **`ControlLine`** (`SlopDeskProtocol`) — the NDJSON control-line grammar. The host's agent-control
  listener and the client's control dispatcher run different verb sets over different objects and
  stay that way, but a request was `{"id", "method", "params"}` in both, and `nil`-on-anything-else
  in both, character for character, along with the `sortedKeys` encode and the fallback line for a
  failure that cannot happen. The trailing newline stayed with the callers, which is the one thing
  they genuinely disagreed about.
- **`TerminalModeEvent.init?(_:)`** — the `SLOPDESK_MODE_EVENT_*` discriminant becoming a case. It
  belongs ON the enum, because `docs/55` §6 makes the case list a CONTRACT: it is one vocabulary in
  two type systems and the mapping between them has exactly one right spelling. It had two — the
  mode tracker's and the input box's, identical down to the doc comment — which is two places for
  the next event to be added to one of.
- **`RustServicePaths.locateBeside`** — where a ROOT-workspace binary lives. `slopdesk-probe` and
  `slopdesk-agenthooks` are staged beside hostd rather than in a per-crate cargo target, so the
  existing `locate` walk has nothing to find and both had written the two-line fallback themselves.
- **`SimulatorWebSocketLane`** — the websocket state machine, receive loop and pong that the frame
  stream and the log stream both ran. The pong is why this one matters: `autoReplyPing` is INERT
  when set on an inserted options object (the protocol stack stores a copy that reads the flag back
  as its default), so a lane without an explicit pong is dropped on the server's idle timer minutes
  into a session for no visible reason. That was measured once and written down twice — which is one
  copy away from being written down once and fixed in the wrong file.

`VideoDecoder.stampDisplayImmediately` was left alone on purpose. It is the same three lines of
CoreFoundation as the panels' `annotate`, but in a target whose dependency floor deliberately
excludes the media frameworks, and for a different reason — Parsec-parity present-on-decode before a
`VTDecompressionSession` submit, not marking a panel's sample for an `AVSampleBufferDisplayLayer`.
Sharing it would widen a leaf's purpose to save three lines. The supervisor records that as a
decision so the next sweep does not re-litigate it.

## The five sidecar managers keep their vocabulary and share their lifecycle (2026-08-15)

`Sources/SlopDeskHost` had five managers for the five children hostd supervises — `code-server`,
`baguette serve`, `slopdesk-androidd`, `slopdesk-inspectord`, `slopdesk-dropd` — and between them
two lifecycles, each written out once per manager.

`HostServiceProcess` already held the shape's PROSE at the top of its file ("spawn with port `0` and
LEARN the bound port from the child's own log line, merge stdout+stderr into one pipe, probe
readiness with a BOUNDED loopback connect") and the production seams. What it did not hold was the
code. So `CodeServerManager`, `SimulatorServerManager` and `AndroidServiceManager` each carried
their own `Instance` record, spawn generation, probe-and-latch and drop-the-exited-child head, and
`InspectorServiceManager` and `FileDropServiceManager` were the same 200-line file twice — a
`sed`-substituted diff of the two comes back as prose and nothing else.

They had already drifted, in the way that is invisible one file at a time:

- `CodeServerManager.endpointLocked` wrote its updated record INSIDE the `if due` block; the other
  two wrote it after. Equivalent today, and equivalent only because nothing else in the record
  changes on a not-due round.
- The dropd and inspectord announce parses accepted a `:0` port; androidd's rejected it. `:0` is the
  port the child was ASKED for under `--port 0`, echoed back before the OS had picked one — the one
  value in that position that is always a lie. Two of five parsers rejected it.

Neither difference was intended by anyone, and each copy reads as correct on its own. That is
`docs/55` §6's `process::basename` precedent in a second target, so it is answered the same way.

**Two lifecycles, in `SupervisedServiceLifecycle.swift`, because the difference between them is
real.** `ProbedPortService` is for a child whose port the OS picks: spawn, learn the port from its
line, probe until it answers, and report where it stands RIGHT NOW. It never waits, because its
callers sit on per-session metadata queues answering an RPC whose client-side timeout is 5 s and
every one of those children does something slow first. `AnnouncedPortService` is for a daemon whose
port hostd CHOOSES: it waits a bounded while for the announce line and VERIFIES that what the child
announced is the port this hostd advertises, respawning it when it is not — affordable because it
runs on the startup path, where there is no deadline to miss, and necessary because the pane id is
stable across a `make host-restart` while the port is not.

**What stayed with each face is what the daemons genuinely disagree about**: the service name, the
announce marker (which `check-supervisor` pins against the crate's `server.rs`), the argv, the env
override that names the binary, and — the one control-flow difference — whether a spawn that THREW
reads `unavailable` or `starting`. It reads `unavailable` for the panel backends, where a broken
binary is indistinguishable from an absent one and the install hint is the right surface for both,
and `starting` for androidd, where an unreachable superd or a thread limit says nothing about
whether this host has a bridge. Both are asserted by their own tests; `ProbedPortService.Boot`
carries the state rather than deciding it.

**One lock per service, not two.** `CodeServerManager` has boot gates of its own — the settings
seed, the bridge bind, the one-shot bundled-extension install that DEFERS the spawn — and they gate
the same spawn as the instance record, so they run under the same lock through
`ProbedPortService.locked(_:)` and `bootLocked(_:)` rather than beside a second `NSLock`. That is
why the engine exposes the pieces as well as the whole round: two faces take `ensure(boot:)` and
have nothing else to serialize; the workbench walks the pieces and keeps its gates inside the same
critical section, including the one re-entry (`finishBundledExtensionInstall`) that has to flip a
flag and re-run the boot in place. `check-supervisor` fails a manager that takes an `NSLock` beside
its service.

## The two device panels share what they DRAW, not just what they compute (2026-08-15)

The earlier pass gave the simulator and Android panels one geometry (`DevicePanelGeometry`) and one
CoreMedia wrap (`DevicePanelSampleBuffer`) on the grounds that the arithmetic was never per-device.
The sweep that followed found the same thing one layer up, in the drawing:

- **The empty stage and its caption.** Both stage views carried `veil(content:)` and `caption(_:)`
  character for character, each with the same doc comment written in the singular — "a scrim says
  something is on top of the picture; there is no picture, and the truthful drawing is the stage
  itself, empty". A sentence that argues for one decision, stored in two files, is the shape of a
  design pass re-toning whichever one it happened to open.
- **The empty-list notice.** Both device lists had `message(_:)`, and both had the 2026-08-04
  user-directed comment saying a failed poll draws nothing — one of them recording the reasoning and
  the other pointing at it ("for the reason `SimulatorDeviceList` records").
- **The loading-veil asymmetry.** `followLoading` waits on the way UP and fires immediately on the
  way DOWN, and that asymmetry is the entire reason the views keep their own copy of the model's
  loading state. Written out twice.
- **The console lexer.** `token(_:)` and `isTime(_:)` were identical in `AndroidLogLine` and
  `SimulatorLogLine`, and `isDate` differed only in a length — `logcat` prints no year, the unified
  log does.
- **The frame dimensions.** `CMVideoFormatDescriptionGetDimensions` read off the FORMAT DESCRIPTION
  rather than the session header, twice, each with its own paragraph explaining the same choice.

**The measured numbers stay per panel.** The veil delay is 400 ms on the simulator (a booted
device's first keyframe lands 0.09 s after the socket opens) and 600 ms on the bridge (0.83 s, because
the host pushes the server jar, starts `app_process` and waits for the device's encoder). Those are
facts about two pieces of hardware; merging them would throw away the measurement, so
`DevicePanelChrome.loadingVeilState` takes the delay and each view keeps its own with its own
citation. The same holds for each console's header shape after the tokens — a priority letter and a
`Tag( pid):` on one, a severity token and a `Process[pid:tid]` on the other — which is why
`DeviceLogLexer` stops at the tokens and the grammars stay apart.

**One pasteboard write, for a reason that is not tidiness.** `NSPasteboard.general.setString`
without a preceding `clearContents` appends to whatever the previous writer declared, so the pair has
one correct order and five files were spelling it.

**Correction, same day.** That pasteboard funnel was a MISTAKE, and the entry above is left standing
so the mistake is legible: a `Pasteboard.copy` was added to ClientUI when `ClientPasteboard.write`
already existed one target down and had been "the one client-side copy funnel" since it was written.
The new one was worse, too — `ClientPasteboard` resolves to a per-PROCESS named board under XCTest
precisely so a copy test cannot clobber the developer's own clipboard, and reaching `.general`
directly gave that up. It was deleted and every caller repointed the same day. The sweep that found
five copies of two lines has to look for the funnel that already exists BEFORE it writes one; a
duplicate-body scan cannot see a duplicate whose original it never opened.

**Correction, same day (2).** The other thing this entry got wrong was the notice/failure pair on
the two sidebar models, recorded here as "left alone, on purpose" because sharing it would widen
`private(set)` on an `@Observable` model. That objection is about sharing the STATE. The eight
identical lines are not state — they are a TIMER: cancel the pending deadline, sleep, fire unless
cancelled. `DeadlineLatch` owns the `Task` and nothing a view observes, so both models adopt it with
their setters untouched, and so do `TerminalViewModel.beginAwaitingReflow` and
`RemoteWindowModel.noteResized`, which had the same five lines for the resize scrim. Three details
in those five lines are load-bearing and each reads as noise until it is missing: the cancel comes
FIRST (a re-arm during a live drag otherwise stacks one timer per layout pass), `Task.isCancelled` is
checked AFTER the sleep (`try?` swallows the cancellation throw, so without it a cancelled timer runs
its body anyway), and the caller's closure is `[weak self]`.

## The arena convention is one implementation on the Swift side too, both ways (2026-08-15)

The earlier pass gave `docs/55` §4c's arena convention one READER on each side —
`crate::arena_span`/`arena_text` and `ArenaText` — and reported nine Swift copies folded into one.
That count was wrong, and the sweep that found the rest is the reason this entry exists: the
mechanical duplicate-body scan only sees copies that are their own FUNCTION, and half of this
convention was written inline.

Folded in this pass, for twenty-six Swift copies in total:

- **Five more text readers** — `CLIArgs`, `JumpResolver`, `CLIConfig`, `CLICompletions`,
  `HostWindowRecordRows` — all spelling `String(bytes:encoding:) ?? ""`, the answer the crate's own
  reader does not give. `CLIConfig` and `CLICompletions` also had no lower-bound guard.
- **Three BYTE readers**, which the first pass did not look for at all because they answer `[UInt8]`
  rather than `String`: `KeybindGrammar.bytes` guarded only `end <= count`,
  `VideoClientSessionLogic.run` guarded all three, and `RetransmitRing` guarded NOTHING — a pair
  naming bytes past the arena would have trapped there rather than answered empty. They are now
  `ArenaText.bytes`/`.data` over the same `range(in:offset:length:)` as the text reads.
- **Nine writers.** `TextArena::intern` was shared on the crate side from the day it was written and
  never on the Swift side. Six were inline in the loop that built the arena; three were their own
  `intern`. They disagreed about overflow: most used `UInt32(clamping:)`, while `WireMessageCodec`
  and `VideoControlCodec` used a plain `UInt32(...)` conversion, which TRAPS rather than clamps.

**The generic write, and the one concrete exception.** `intern` is generic over
`RangeReplaceableCollection where Element == UInt8`, because both arena spellings are in use and
neither is wrong — a door that lends the crate an `UnsafeRawBufferPointer` builds `Data`, one that
lends an `UnsafeBufferPointer<UInt8>` builds `[UInt8]`. The exception is `Data`-into-`Data`, spelled
concretely: the retransmit ring interns every outgoing packet of every frame, and the generic would
reach `Data.append(contentsOf:)` through a `Collection` witness on the video send path. That is a
perf decision, not a style one, and it is why the overload exists at all.

**What is still per-door**: the named C struct. `SlopDeskByteSpan`, `SlopDeskKeybindRun` and the
bare `(UInt32, UInt32)` pairs are each a door's own vocabulary, so each face keeps a one-line
overload that wears its struct and calls through — the same shape `crate::arena_text`'s field-keyed
readers have on the other side. `ArenaText` still depends on nothing but Foundation: an offset and a
length are arithmetic, not a boundary.

## Clipboard sync's two ends read the pasteboard from one file (2026-08-15)

`HostClipboardPerformer` (the daemon) and `ClipboardSyncEngine` (the client) are the two halves of
one wire contract, and each carried its own `NSPasteboard` ↔ `MetadataCodec.ClipboardClip`
conversion: the same three-way read preference (PNG as-is → TIFF transcoded → non-empty text), the
same cap check, the same TIFF transcode, the same PNG-plus-TIFF-twin write. This is the exact shape
`docs/55` §6 records for `process::basename` — two implementations of one contract, drifting where
neither side can see it.

**They had already drifted, and the drift is a privacy asymmetry.** The client refuses to PUSH a
concealed clip (`org.nspasteboard.ConcealedType`, what password managers set). The host does not
refuse to SHIP one back on a `readClipboard` pull — copy a password on the host machine and the
client applies it to its own pasteboard. That is preserved exactly as it was, because closing it is a
product decision and not a refactor's to make. What changed is that it is now the named parameter
`skippingConcealed:` at two call sites instead of a difference between two function bodies that
nobody was comparing. **Flagged for a decision; it was not made here.**

**`PasteboardClip` is its own target, and that is the whole reason.** `SlopDeskHost` is the daemon
graph and `SlopDeskWorkspaceCore` is the client graph; neither depends on the other. The only thing
below both is `SlopDeskProtocol` — the WIRE, which has no business importing AppKit. So the shared
reading is a leaf of its own: AppKit plus the clip type, nothing else, and hostd links what it
already linked.

> **SUPERSEDED (2026-08-29).** The target is deleted. The argument above holds for as long as both
> ends are Swift, and once `docs/60` stage F made the host Rust it stopped holding: a Swift leaf
> below two Swift graphs cannot be shared with a daemon that is no longer in either. For one stage
> the two ends WERE two implementations again, in two languages — exactly the drift this section
> opens by naming. The four rules are `rust/slopdesk-clipboard` now, a `forbid(unsafe_code)` leaf
> both ends read, and the boards under it are `rust/slopdesk-apple-pasteboard`'s two framework
> halves. What is left in Swift is `ClientPasteboard`, a face over eleven `slopdesk_clipboard_*`
> doors that decides one thing: whether this process is a test process, and so which board to name.
> The `skippingConcealed:` asymmetry survives the move unchanged and is still flagged, still
> undecided.

**The write answers `Bool`, not a status.** It validates before it clears, so a garbage clip arriving
over the wire cannot destroy the clip already on the board. The two callers spell the refusal
differently — the host answers `MetadataStatus.error` over the wire, the client just drops — which is
why the answer is a boolean and the vocabulary stays with each caller.

## The client copies, opens and traces from one funnel each (2026-08-15)

Three platform forks were written out at their call sites rather than inside the thing that owns
them, and each hid something a call site could not see:

- **The copy fork.** `#if canImport(AppKit) ClientPasteboard.write … #elseif canImport(UIKit)
  UIPasteboard.general.string = …` appeared at four call sites (terminal leaf, link overlay, command
  navigator, palette). The asymmetry worth hiding is that the AppKit arm reaches a test-safe named
  board and the UIKit arm reaches `.general`; a fifth copy would have had to know that. The fork is
  now inside `ClientPasteboard.write`, which also grew the frame write the two device panels had
  (`NSImage(data:)` → clear → `writeObjects`, identical but for the argument label) — they keep their
  own named faces so each panel still says whether its transport delivers PNG or JPEG.
- **The open fork.** `openURLString` was identical in `TerminalLeafView` and `LinkActionActuator`,
  and `DefaultTerminalIntegration` had a third macOS-only spelling. The parse is part of the law —
  a string that is not a URL is dropped inside `ExternalOpen`, not at each caller. The HOST's
  `NSWorkspace.open` is deliberately NOT folded in: it READS the return to answer `.ok`/`.error` over
  the wire, has no UIKit arm, and its target cannot see ClientUI. Same call, different law.
- **The stderr trace.** `SLOPDESK_BLOCKS_DEBUG` gated two tracers (`[blocks]` in the store,
  `[flash]` in the overlay) with the same three lines, and `SLOPDESK_WORKSPACE_DEBUG` a third. Two of
  the three read the environment on EVERY call — a syscall per gesture on a path that runs per
  gesture, which is exactly why the third had already hoisted it into a `static let`. `DebugTrace`
  resolves once for all of them. The VIDEO host's `SLOPDESK_AUDIO_DEBUG`/`SLOPDESK_VIDEO_DEBUG`
  tracers stay put: `SlopDeskVideoHost` depends on nothing that could carry a shared one down to it,
  and inventing a leaf for six lines costs more than it saves. They are also not the same shape —
  eleven files read `SLOPDESK_VIDEO_DEBUG` into a `static let` and use it as a GUARD over blocks of
  measurement work at 58 sites, not as a write-one-line funnel; `docs/46` says outright that the call
  site owns the idiom.

  **Correction, same day.** That entry said "two tracers". There were three: `TerminalViewModel`
  carried its own `flashDebugLog` — the same `SLOPDESK_BLOCKS_DEBUG` gate, the same `[flash]` tag as
  the overlay's paint end, its own copy of both, and no `@autoclosure`, so it built the trace string
  on every arm and settle whether or not anyone was reading. It is the arm/settle MIDDLE of a trace
  whose other two thirds had already been folded, which is exactly the half that goes missing without
  looking missing: a jump prints `[blocks]` and then a paint, and the gap between them reads as a
  step that never ran rather than a tracer that was never called. `check-supervisor` now fails on any
  file outside `DebugTrace.swift` that reads either gate — one gate, one spelling, one tag grammar.

**Also folded, same sweep:** the `refreshing(_:)` binding wrapper (three copies across two Settings
pages, sixteen call sites, three different doc comments for one seam) is now an extension on
`PreferencesStore` — the seam is the store's, not a view's, so a page that has a store has the
wrapper. It is an extension in ClientUI rather than a method in `PreferencesStore.swift` because that
file is deliberately SwiftUI-free and a `Binding` is SwiftUI's. The two device sidebars' readiness
enum is one `DevicePanelPhase`: four identical cases and one non-obvious rule (a `ready` endpoint
with no usable address degrades to `.offline` rather than trapping on a zero port) that would
otherwise get fixed on one side only. What each state MEANS stays per panel, on the typealias.

**What is left alone, and why — so the next sweep does not re-litigate it:**

- **`status(for:)`** on the two workspace documents. `WorkspaceIntentOutcome` lives in
  `SlopDeskWorkspaceModel` and `WorkspaceIntentStatus` in `SlopDeskProtocol`, and those two targets
  cannot see each other; only the two callers see both. It is an exhaustive `switch`, so a new
  outcome case breaks BOTH sides at compile time — the silent-drift hazard the one-implementation
  rule exists for cannot occur here, and a target for eight lines is not the trade.
- **`setInitialCwd`** on the client and the mux transport: two lines of trim-then-empty-is-nil, an
  idiom this codebase spells 57 times in shapes that are not the same law.
- **`park`, `setLogLevel`, `deliver`** on the two device sidebars: same shape, different member
  types (two stream protocols, two log-level enums), so sharing needs a protocol whose only
  implementers are these two — abstraction bought with nothing.
- **`fromEnvironment`** on the OWD detector and the depth policy: the fold is the same six lines but
  each `apply` goes through a different FFI door with a different config struct.
- **The per-door `intern`/`string` faces** over `ArenaText`: already recorded above — a named C
  struct is a door's own vocabulary.

**One sidecar encoder per target, and a rule for the rest.** Four stores inside
`SlopDeskWorkspaceCore` built their own `JSONEncoder` with `[.prettyPrinted, .sortedKeys]`, each
carrying half the reason in a comment; they now share `SidecarJSON.encoder()`, where both halves are
written down (`.sortedKeys` is `docs/22` §8's byte-comparison contract, `.prettyPrinted` is for the
human reading a `git diff`). The four other targets that write sidecars hold ONE encoder each — there
is nothing duplicated to remove there, only a dependency edge to add to four deliberately narrow
graphs — so `check-supervisor` pins the rule instead: whoever writes a sidecar sorts its keys. One of
them already spelled the option set in the other order, which is harmless and is also the sign that
nobody was comparing.

## The video channel tag is one enum in the wire target (2026-08-15)

**The host and the client each declared their own `VideoChannel`,** seven cases, byte-identical raw
values, and each side carried a doc paragraph justifying the copy: *"the client and host live in
separate modules (the client must not depend on the macOS-only host), so each carries the same pure
enum — the wire contract is the agreement, not a shared Swift type."* The first half is true and
still is. The second half was not: both modules already depend on `SlopDeskVideoProtocol`, and a
1-byte tag on every media-socket datagram is exactly what a wire target is for. The client's own doc
had already written the fix down as outstanding work — *"(The docs step should hoist this into
`SlopDeskVideoProtocol` so both sides reference one definition.)"* — which is how long a two-copy
contract survives once its justification stops being read.

This is the `process::basename` shape (`docs/55` §6) with the failure still ahead of it rather than
behind: the two copies agreed for as long as nobody added a channel. They would have kept agreeing
right up to the day a seventh landed on one side, and nothing — not the compiler, not a test, not the
golden corpus — would have said so. What the far side does on an unknown tag is drop it, silently.

`Sources/SlopDeskVideoProtocol/VideoChannel.swift` now holds the enum and the rationale that is
genuinely shared: the tags are the wire, `.cursor` is a separate socket (doc 17 §3.3 — never
multiplex with video, so video backpressure cannot delay the cursor), `.recovery` is a dedicated
channel because `RecoveryMessage`'s leading type bytes overlap `InputEvent`'s and multiplexing them
onto `.input` would decode a recovery datagram as a phantom mouse event, and `.audio` rides the media
socket but always sends IMMEDIATE so it never queues behind a fat video frame. What differs per side
— which tags that side SENDS and which it RECEIVES — stayed in each transport's own doc, where its
reader already is.

Two `check-supervisor` pins, because one of them cannot catch what the other does. A negative check
fails if a second `enum VideoChannel` is declared anywhere in `Sources` or `Tests`. A positive one
pins each `case name = number` in the shared file: the raw values ARE the wire tags, so renumbering
one re-routes a channel on the far side with nothing failing to compile and no golden vector moving.

## The half-paired mux reaper had five test seams and no test (2026-08-15)

**A sweep for functions declared once and referenced nowhere** — the class a duplicate-body sweeper
cannot see, because dead code has no twin — turned up sixty-odd candidates, most of them delegate
methods the framework calls by selector. One cluster was not noise. `HostTransport` carries
`pendingCount()`, `isPending(_:)`, `reapExpiredPending(now:)`, `instantNowForTest()` and
`instantPastAllPendingDeadlines()`, every one of them documented as a test seam, and
`reapExpiredPending`'s own doc says the expiry is *"called directly by tests with a synthesized `now`
so the behaviour is verified WITHOUT any wall-clock sleep."* Nothing called any of them. The two
`isPending` hits a grep finds are `WorkspaceMirrorBox` and `MetadataRequestRegistry`, different types
entirely — which is exactly why this survived: the seam LOOKS called.

What was unverified is not a nicety. The reaper is the bound on a hostile peer opening many
CONTROL-only mux sockets with distinct connectionIDs — each parks a live `NWConnection` whose fd only
the pending map can reach. Its `createdAt` is deliberately preserved across a same-side re-park,
because a peer re-sending the same side in a loop would otherwise push the deadline out forever: the
entry is never reaped, and `pendingCount()` reads a reassuring 1 the whole time.

The seams were unreachable, not merely uncalled. The only way to park an entry was
`associateMux(_ connection:connectionID:isControl:)`, which takes an `NWConnection`, and no suite here
opens a socket — a real listener hangs the test process. So `associateMux` split: the `NWConnection`
overload now wraps the socket in an `NWMuxByteLink` and hands it to
`associateMux(link:connectionID:isControl:)`, which owns everything the seams exist to observe —
parking, the same-side displacement close, the `createdAt` the reaper measures against, the
post-`stop()` refusal. `internal`, not `public`: the daemon's callers hand over connections.

`HostTransportPendingReaperTests` drives all five paths through a `MuxByteLink` that records nothing
but its close count. Four of them use only the transport's own clock, so they never sleep. The fifth —
that a re-park does not defer the deadline — cannot: the discriminating question is which `createdAt`
the entry kept, and no seam exposes it, so it uses a 50 ms timeout and a real wait past it. That
assertion is one-sided by construction: a slower machine only ages the entry further, so a preserved
`createdAt` reaps under any load and only a restamped one can fail it.

Each assertion was mutation-tested before being trusted: restamping `createdAt` on re-park, dropping
the displaced-half close, and neutering the reaper's filter each fail the tests that claim to cover
them (the last one fails four assertions across two tests). A seam whose test cannot fail is the same
false comfort as a seam with no test at all.

## Thirty-two functions nothing called, and the docs that said otherwise (2026-08-15)

**The dead-code sweep that found the reaper's untested seams found thirty-two more declarations with
no caller anywhere in `Sources`, `Tests` or `scripts`.** They are gone. The interesting part is not
the line count — it is that almost every one carried a doc comment asserting a call site that does
not exist, which is how they survived a codebase that reads its own comments:

- `TreeWorkspace.activeSessionPaneIDs()` / `.activeTabPaneIDs()` — *"drives active-tab
  focus/visibility"*. Nothing drives anything; the callers ask `activeSession?.allPaneIDs()` directly.
- `WorkspaceStore.groupHandleOffset(for:)` — *"Read by `CanvasItemView`"*. It is not, and neither is
  the state behind it: `GroupHandleDragState`, `groupHandleDragLive`, `updateGroupHandleDrag`,
  `endGroupHandleDrag` and `groupBoxOffset` form a complete live-drag feature with no view on either
  end. The whole cluster went.
- `PanePresentation.lastCommandSummary` — *"this is the formatter the pill tooltip uses"*. The pill
  has no tooltip. `formatCommandResult`, which it called, says *"Exposed (and tested) independently"*
  and had no test either. `latestBlock` (*"Drives the chrome status chip"*) and `openBlockNavigator`
  (*"the chrome chip's tap action"*) are the same story; `displayTitle` is the only member anything
  outside the file asks for.
- `PreferencesStore`'s green "Enable … notifications" pill — five methods, two private helpers and
  two persisted `UserDefaults` keys, describing a chip that is never built.
- `exitOverview` (*"Esc / a card tap routes through here"* — `selectFromOverview` clears the flag
  itself), `newTabDefault` (*"The 'new tab' command entry"*), `isActivePane`, `groupSlideOffset`,
  `assessPaste`, `currentSelectionText`, `makeCopyModeKey`, `toggleRichMode`, `checkTitle`,
  `truncatedCwd`, `refreshPicture`, `stopWorkspaceChannel`, `activitySummary`, `sessionLiveness`,
  `VideoPaneControls.toggleFill`/`.resetZoom` (internal forwarders the overlay could not see anyway),
  `wsText`, `rectBits`, and the two `AgentJobIdentifier` FFI faces.

Four unused TEST seams went with them — `foldScreenDetectionForTesting`,
`enqueueRestoredScrollbackForTesting` with its paired `hasRestoredScrollbackForTesting`,
`reconcileWorkspaceDocumentForTesting`, and a `#if DEBUG` `forceStatusConnectedForTesting` whose own
comment reads *"Test hook (no production caller)"*. Their siblings in the same files are called by
dozens of tests, which is exactly why nobody noticed these four were not.

**Four deletions were WRONG and were put back**, with the reason written into each. `looksLikePNG`,
`looksLikeJPEG`, `intersectionArea` and `WatchProgress.progressBytes` have no Swift caller and are
pinned by `check-supervisor` anyway, which failed the build the moment they left. The pin is not
about the call: it is that the face IS the door. The blob magic, the NaN-ignoring intersection maxima
and the OSC framing are the crates', and an uncalled face is what stops the next
`data.prefix(8) == pngMagic` from being written in Swift. Each now says so in its own doc, so the
next sweep does not delete it a second time.

**Two survivors are unfinished FEATURES, not dead helpers, and are left for a decision rather than
quietly removed.** `Canvas.groupIDsInUse()` says it is *"used to prune dangling group metadata (a
`PaneGroup` whose every member was closed) on load / save"* — nothing prunes, so that metadata
accumulates. `WorkspaceTreeOps.insertPaneAtRootEdge` is a complete, invariant-preserving rail-drag
commit for `docs/45` with no drop site wired to it. Deleting either would erase intent; both are
reported instead.

## Sixty-eight doc links named symbols the repo had deleted (2026-08-16)

A port moves an implementation to Rust and deletes the Swift original in the same change — that is the
rule. What the rule does not cover is the paragraph next door. `MuxChannelSession` still told a reader
that a `` ``TerminalQueryStripper`` `` pass strips the replayed history; the pass is
`rust/slopdesk-sanitize/src/query.rs` and no Swift type by that name exists. `HostOutputSniffer` was
named as live machinery in five files across three modules. `CommandBlockSegmenter`,
`ScrollbackDistiller`, `PromptEOLMarkStripper`, `TerminalInputModeStripper`, `WireMessageCodec`,
`PacketizeOptions`, `AndroidDeviceCatalog.merge`, `AgentKind.pathBasename`, `process_priority` and
`ScreenVerb.detect` all read the same way. A DocC double-backtick promises a symbol in THIS doc graph;
each of these promised one that had moved to a crate, so a reader who greps Swift concludes the
machinery is gone rather than that it is somewhere else. Every one now cites the item the way the rest
of the tree already cites a ported item — `name` plus its crate path.

The other half were never ports. `isPaneOnActiveTab` is `isPaneOnCanvas`; `PaneNode.updatingSpec` is
`Canvas.updatingSpec`; `WorkspaceStore.blockJumpCursor` is `BlockBookmarkSeam.jumpCursor`;
`openRemoteWindow(windowID:title:appName:)` is `openDesktopWindow(displayID:)`; the ⌘1…9 family is
`selectPane`, not `selectTab`, and the registry's own class doc said "select tab". `DSDensity` and
`DSScale` are gone entirely, so `SettingsKey.density`'s doc described a token pipeline that no longer
runs. Three said something FALSE rather than merely stale: `OverlayCoordinator` called four surfaces
"SCRIMMED" and mounted "behind a ``Scrim``" when `OverlayHostView`'s own doc says in as many words
that *the backdrop does NOT dim* and there is no `Scrim` type; `PaneSessionHandle.isReadyForInput`
cited `sendChatToNewSession` as the caller that polls it, and nothing polls it at all; and
`WorkspaceStore.liveCameraOffset` said *"Only `CanvasView` reads"* it — `CanvasView` is deleted and
nothing reads it, so the scroll-pan rule survives with `CanvasScrollPanTests` as its only consumer.
That last one is left standing and now says so, on the same reasoning as `insertPaneAtRootEdge`:
deleting a tested rule because its view was rebuilt away erases intent.

Where the referent is a view that a rebuild has not yet replaced, the link is demoted to a single
backtick rather than renamed — `RemoteWindowPanel`, `TerminalInputHost`, `CanvasView`,
`RemoteGUIPaneView` and the iOS UIKit input surfaces are prose about a thing that is not here, which
is what the L0 headers were already doing with `` `PaneLeafView.swift` ``. Renaming them to something
live would be inventing a fact.

**The check is the point.** A fix without a ratchet regrows — `build-ffi.sh --check` is in `make lint`
for exactly that reason. `check-supervisor` now walks every `` ``link`` `` in a comment and fails on
one that names nothing the repo declares, where "declares" means an identifier on a NON-comment line
(a name kept alive only by other comments does not vouch for itself) or a Swift file basename (several
links legitimately name a file that groups a vocabulary). Three framework symbols — `SwiftUICore`,
`CGDisplayGammaTable`, `CGEventTap` — are listed as external; the list stays short on purpose. It
found six more the first time it ran. Its vouching set comes off the FILESYSTEM, not `git ls-files`
like every other check here: the question is whether the repo declares the name, and an unstaged file
declares it just as much as a committed one — reading the index instead failed a perfectly good link
to `SupervisedBlocksTests`. Negative-tested by planting both link forms in a tracked file. 2.3 s.

Two more duplicate mutators went in the same pass: `removePane(_:)` existed byte-identically in
`HostWorkspaceDocument` and `LoopbackWorkspaceDocument`, called by nothing. The live reaper is
`removePanes(keeping:)`, which is tested. Two copies of one uncalled operation is the
`process::basename` shape with no compiler to notice, so both are gone.

## The read-first doc still said Swift owns the wire (2026-08-16)

The doc-link ratchet added the day before only looks at comments in *code*. Running its mirror —
symbols and paths cited in `docs/` — found the sentence that most of this repository's orientation
hangs on, `docs/00-overview.md` §"Core / shell split", claiming **"Native Swift owns the wire …
Only non-Swift code: `Sources/CSlopDeskSIMD`"**. Both halves had been false for weeks: the codecs,
FEC, reassembly and every realtime controller are `rust/slopdesk-wire` and `rust/slopdesk-video`
reached through `CSlopDeskFFI`, and `Sources/CSlopDeskSIMD` is deleted. Whoever read the overview to
decide where a new codec belongs was told the opposite of the rule in `CLAUDE.md`.

The same claim had been copied into five more live files, which is how a stale sentence survives:
`docs/README.md`, `docs/01-architecture.md` (prose *and* the package tree), `docs/12-coding-profile.md`,
`docs/20-wire-protocol.md` and `docs/51-process-supervision.md`, whose §2.1 rested its "no C shim is
required" argument on an invariant named after a target that no longer exists. `CLAUDE.md` itself
offered `CSlopDeskSIMD` as one of the two live examples of a linked port; it is now `CSlopDeskFFI`.
The invariant that actually holds today is narrower and worth stating that way: nothing under
`Sources/` *implements* anything in C. The one C target left there, `CSlopDeskVirtualDisplay`,
declared private CoreGraphics headers and had no `.c` file at all.

**2026-08-27 — that target is gone too, and the narrower invariant has become the wide one: there is
no C under `Sources/`.** What removed it was not a rewrite but a correction: the four
`CGVirtualDisplay*` types are Objective-C CLASSES in the PUBLIC CoreGraphics framework, and only the
HEADERS were private. `rust/slopdesk-apple-cgvirtualdisplay` therefore reaches them by name through
the Objective-C runtime, which collapses the `weak_import` linkage attribute and the
`NSClassFromString` availability gate into one lookup, and the whole area now arrives through
`CSlopDeskFFI` with everything else. The port also found a bug the shim had carried for its whole
life: `applySettings:` takes `unsigned int` width and height, not `NSUInteger` as the class dump
claimed, so the shim had been passing 64 bits into a 32-bit parameter. `objc2` verifies method
encodings and refused to compile it.

`Package.swift`'s own tombstone was wrong in the other direction — it said the codec moved to
`rust/slopdesk-video`, "which is `forbid(unsafe_code)` and holds parity **without a hand-written
kernel**". The kernel did not dissolve; it came back as `rust/slopdesk-gfsimd` (the third `unsafe`
crate), and `slopdesk-video/src/gf256.rs` calls straight into it. What left with the C target is the
last hand-written implementation under `Sources/`, not the intrinsics. `docs/46`'s SIMD note named a
`GF256NeonDifferentialTests` that went with it, so it now names the two suites that really pin the
kernel: `rust/slopdesk-gfsimd/tests/differential.rs` for kernel ≡ scalar twin, and the cross-region
cases in `gf256.rs` for the seam a 16-byte chunk straddle opens, which the kernel cannot see alone.

Four smaller citations died the same way and were repointed at what does the work now:
`docs/46`'s vendored-tool search order said it was mirrored by `AndroidToolchain.locateSDKTool`
while the same file, twenty lines up, lists `AndroidToolchain` among the Swift types
`check-supervisor` forbids from coming back — the mirror is `locate_sdk_tool` in
`rust/slopdesk-androidd/src/toolchain.rs`. `docs/20` credited `title`/`bell` to a
`HostTitleBellSniffer` wired into `HostSession`'s output relay, two names for one deleted thing;
it is `rust/slopdesk-superd/src/sniffer.rs`, one pass over the pump's stream. `docs/45` named a
`RecentlyClosedTab` ring at a line number that has since become unrelated prose — it is
`WorkspaceTopology.closedTabs`, read LIFO. `docs/55` called an FFI handle `BlockStore` in a
paragraph where `FrameReassembler` and `RecoveryIdrPolicy` are exact Rust type names; the handle is
`SlopDeskBlockStore`.

Two axes were audited in the same sweep and found clean, recorded so the next pass skips them.
Every `SLOPDESK_*` default `docs/46` states matches its constant (`SUB_LAG_BYTES` 32 MiB,
`PANE_RING_BYTES` 4 MiB, `SCREEND_IDLE_EXIT` 120 s, replay 256 MiB / gate 64 MiB, queue 64 KiB
attached ↔ 64 MiB detached); the 246 gates the code reads that the table omits are covered by its
own "Not exhaustive — grep `SLOPDESK_`". And no live doc cites a rooted file path that does not
exist: every hit was either a historical handoff/plan doc or a `### What this deleted` section,
where naming the deleted file is the point.

The class now has a gate, scoped to the half of it that is decidable. `check-supervisor.sh` reads
every file path a read-first doc cites and fails if it does not exist. Two bounds keep it free of
false positives, and both were measured before the check was written: only paths ROOTED at a real
top-level directory count, because a bare `Overlays/PaletteView.swift` is ordinary shorthand for a
path relative to its package and resolving that guess is exactly how a gate earns noise; and only
the docs `CLAUDE.md`'s own table sends a reader to, because a handoff from March naming files that
are gone is a correct record, not drift. The live set is derived FROM that table rather than listed
again — a doc becomes read-first by being added there, and the gate follows without being told
twice. A doc may still name a deleted file on purpose, which is the whole point of `docs/51`'s
"What this deleted"; those are one allowlist entry each, and removing the entry fails the check,
so the list cannot quietly outlive its sentence. The symbol half was left ungated on purpose: a
sweep of the same docs produced 68 candidates of which nearly all were legitimate — SDK types,
signal names, Claude Code hook events, and the deliberately-absent names `check-supervisor` already
forbids from returning — and an exception list long enough to silence that would rot faster than
the thing it guards.

## Twenty ban checks were reading the index, not the tree (2026-08-16)

`check-supervisor.sh` has two kinds of rule and they disagreed about what "the repo" means. The
ABSENCE rules — no Swift screen engine, no revived file-drop receiver, no Android bridge — all
`grep -r Sources/`, so they see the working tree. The BAN rules built their file lists with
`git ls-files`, which lists the INDEX. Those are not the same tree here: 415 files under `rust/`
and 55 Swift files under `Sources/` are on disk and unstaged, so twenty bans were passing on files
they never opened. Nothing was violating one today — the hole was latent — but a gate that cannot
see half the tree is not a ratchet, it is a coin flip whose result depends on what happens to be
staged.

They now go through `repo_files`, which is `git ls-files --cached --others --exclude-standard`:
git's own pathspec semantics, which those bans are written against, over tracked *and* present-but-
not-ignored files. The docc check next door had already made this move for its vouching set and
said so in a comment that ended "which is why an untracked file is invisible to the other checks";
that sentence described a defect, and it is now gone along with the defect.

Switching it over immediately failed the tree, which is the point — and the failure was the check's
own regex, not the code. `(Darwin\.)?write\(socket` matched `SupervisorFrame.write(socket: fd,
body:)`, whose argument LABEL is the same word as the syscall's first parameter and whose `writeAll`
delegates to `FileDescriptorWrite.all` exactly as the rule demands. A syscall spells a comma and a
Swift call spells a colon, so the pattern now requires the comma. That over-broad regex had been
sitting there unable to tell a call from a contract, and could only be found by pointing the check
at the files it had been skipping.

## `INPUT_CRATES` stopped being a list, and the FFI flake was re-diagnosed (2026-08-16)

`build-ffi.sh` reads `REQUIRED_SYMBOLS` out of the header, with a comment saying why: "a hand-kept
list beside it is a second list to forget." Ten lines further down, `INPUT_CRATES` was a hand-kept
list — the twelve crates whose sources decide whether the artifact is stale — and `CLAUDE.md` asked
a human to keep it right ("keep `INPUT_CRATES` covering every crate the shim wraps"). Forgetting it
does not fail loudly: the stamp calls a stale library fresh, which is precisely the one failure mode
`docs/55` says a linked port has and a socket port does not. It is now the transitive closure of
path dependencies from `rust/slopdesk-ffi`, read out of the Cargo graph. The derived set is
byte-identical to the list it replaced and the stamp did not move, so `--check` still says "up to
date" on an untouched tree; a fixture proved the walk follows two hops (`ffi → a → b`) and that a
path dependency with no `Cargo.toml` fails loudly instead of being skipped. `slopdesk-posix` stays
correctly outside it — superd forks, and the shim does not wrap it.

Separately, `MetadataClientTests.testEndToEndEchoedReplyDecodesThroughClientAndFold` failed a second
time in a full `make test`, and the earlier reading of it as a load flake is wrong. It does not
fail SLOWLY: it returns `[]` at exactly its 30-second timeout, which means the echoed reply never
reached `resolve` at all. A longer timeout cannot fix that, and the comment in the test — which
raised the bound from 2 s to 30 s on the theory that it "bounds a HANG, not a latency" — is
measuring the hang it named. The loss window it worried about is genuinely closed:
`EventBroadcaster.subscribe()` registers the child continuation synchronously inside the
`AsyncStream` build closure, before the request is ever sent, and the buffer is unbounded.

What is now ruled out, with the runs to say so: the test alone passes 3/3; the whole class passes
5/5 with the machine loaded to 2× its core count; and `swift test --parallel` over the target did
not reproduce it in 3 attempts. The remaining suspect is the one dependency the test has that
nothing bounds — the fold runs in a `Task { @MainActor }`, and if that task is never scheduled the
reply sits in a buffer nobody drains, which is exactly the observed `[]`-at-timeout. Left as is
rather than rewritten on an unconfirmed hypothesis; recorded so the next pass starts from the
evidence instead of re-deriving it.

One neighbouring fragility surfaced while chasing it: `TerminalBlockStoreBenchTests` and
`TerminalLinkScanBenchTests` assert wall-clock budgets and fail under `swift test --parallel` on a
busy machine (167 µs against a 100 µs ceiling, 32 ms against 20 ms). `make test` does not run them
that way and is green; noted because a future move of those suites into a parallel lane would
convert a real regression signal into noise.

## `docs/46` had the unsafe policy exactly inverted (2026-08-16)

Auditing the bar `CLAUDE.md` sets for the third `unsafe` crate — "a differential suite that runs
under Miri" — found the bar genuinely met: `make miri` runs `rust/slopdesk-gfsimd`'s five
differential cases under `cargo +nightly miri test`, and they pass in 47 s with no UB reported. The
suite narrows itself under `cfg(miri)` so the sweep stays minutes rather than hours. That target is
deliberately outside `make test`; it is the thing to run when a line inside an `unsafe` block moves.

The row above it in `docs/46` was wrong in three ways at once, and each way pointed a reader at
permission the tree does not grant. It said `make lint-rust` "sweeps all SIX workspaces" and named
`slopdesk-hook` as one — the sweep is SEVENTEEN, and the hook is not a workspace at all but a
root-workspace member carrying `[lints] workspace = true`, already covered by
`cargo clippy --workspace`. It said "the hook is `unsafe_code = "forbid"` and the other five are
`"deny"`", which is inverted: the hook has no `unsafe_code` line because it inherits the root's
`forbid`, and all five daemons state `forbid` in their own manifests. And it explained the
exemption as "superd needs the fork/exec window" — that window moved to `rust/slopdesk-posix`, and
`check-supervisor.sh` now fails on a `libc::fork` anywhere else. Somebody reading that row would
have believed they could write `unsafe` in superd behind an `#[expect]`; the ratchet would have
told them otherwise, but only after they wrote it.

The three genuinely exempt crates are `deny`, not `forbid`, and that is the point: `forbid` cannot
be lifted by the per-site `#[expect]` that makes each `unsafe` block self-expiring and auditable.
`make lint-rust`'s own help line said "all ten Rust workspaces" and is now 17, counted from the
recipe rather than remembered.

## The staleness gate fired on its own build output (2026-08-16)

`make ffi` assembled three fresh slices and reported success; `make lint`, run seconds later on an
untouched tree, said the artifact was STALE. Twice. The earlier pass had recorded this as noise.
It is not noise, and the cause is in the gate rather than around it: `current_stamp` walked each
input crate whole, and `target/` is inside each input crate. Build scripts write real `.rs` there —
`target/<triple>/release/build/<crate>-<metadata-hash>/out/private.rs`, twelve of them across the
shim's closure — so cargo's own output was being hashed as if it were a source. Worse, the hash in
those directory names is cargo's, and `cargo build --target aarch64-apple-ios` MINTS a fresh path
for a triple it has not built before: the stamp changed after `WANT` was computed and before `WANT`
was written, so a clean build recorded a value the next `--check` was guaranteed to disagree with.

An input-hash gate that fires on its own output is worse than no gate, because the failure it
reports is the one it exists to report. Somebody who saw "STALE" right after `make ffi` learns to
run `make ffi` again and move on — and the day the message is true, that reflex ships the stale
archive. `target` is now pruned. Planting a cargo-shaped `out/private.rs` leaves `--check` clean;
appending one line to `rust/slopdesk-video/src/lib.rs` still fails it.

The banner has claimed since it was written that the stamp covers "the Rust sources of this crate
and the crates it wraps, plus the header and this script." The header was covered — it is a `.h`
under the crate. The script never was, though it decides which slices exist and which symbols each
must carry, so an edit to it could change the artifact without touching one line of Rust. It is an
input now, which is why this change itself reads as stale exactly once.

## A null resolver callback resolved nothing, not "resolve it here" (2026-08-16)

Chasing why `slopdesk_agent::job::realpath_basename` had no caller in either language found a live
bug rather than dead code. `Resolver::resolve` in `rust/slopdesk-ffi/src/agent.rs` opened with
`let call = self.call?;`, so a null callback meant "resolve nothing." Both sides of the boundary
document the opposite: `AgentJobIdentifier.defaultSymlinkResolver` is `nil` ON PURPOSE and says why
— routing a filesystem touch back out through the trampoline would pay two boundary crossings per
token to reach the same `realpath`, so the crate is supposed to run it itself. `nil` is the arm
production takes, reached from `MuxChannelSession`'s host probe, which is why the fallback had no
caller: it was unreachable, and the comment explaining it was a lie.

The user-visible effect is silent by construction. A wrapper whose own basename identifies nobody —
`/usr/local/bin/cc-agent` symlinked at `…/claude` — simply goes unidentified; the pane shows no
agent and nothing is logged anywhere. `a_null_callback_still_resolves_a_symlink_through_the_crate`
builds a real symlink on disk, asserts the link's own basename identifies nobody so the test can
only pass through the resolver, and fails when the fix is reverted.

## The group resize was written twice, and the two copies disagreed about `min` (2026-08-16)

`Canvas::resizing_group` in `rust/slopdesk-workspace` and `Canvas.resizingGroup(_:toBox:)` in
`Sources/SlopDeskWorkspaceModel/Domain/Canvas+Ops.swift` were the same algorithm in two languages,
down to the doc comment: derive the group's box, floor the proposed box at the minimum pane size,
scale each member's offset and size by the per-axis ratio, clamp every member back inside. Only the
Swift one ever ran. The Rust one was reachable from nothing — no door, no crate, no Swift line —
and was kept alive solely by its own two unit tests.

They had already drifted, in the quietest possible way. Swift's `clamping` used `Swift.min`/`max`,
which order by `<`; the crate used `f64::min`/`max`, which are IEEE `minNum`/`maxNum`. The two
answer differently for ±0 and for NaN, which is exactly the class `CLAUDE.md` pins bit-exactly.
Nobody would have found that by reading either file, because each is correct on its own.

Resolved in the direction the rules name: the rule moved to `canvas_arrange::resized_group`, beside
align/distribute/tidy, whose module banner already says why — "there is one implementation of
'aligned to a shared edge', not one per caller." It is a rule over `(id, frame)` pairs, so the old
box is DERIVED from the members handed over rather than passed alongside them; a caller cannot
supply a box that no longer matches its members. `slopdesk_ws_resize_group` exposes it and Swift's
body is now the same four-line marshalling as `aligning`/`distributing`. The Rust `Canvas` method
is gone rather than kept as a second entry point.

What makes this checkable rather than hopeful: the two Rust tests moved to the frame-level rule and
ran GREEN beside the Canvas-level copies before those were removed, and Swift's three existing
`resizingGroup` tests were not touched and still pass against the ported rule. The new door also
carries the first boundary test any arrange door has had — align, distribute and tidy have none —
because `slopdesk_ws_resize_group` is the only one taking a struct BY VALUE, and a header that
disagreed with the crate about a by-value `CRect` would misread the box rather than fail to link.

## Four enums crossed the ABI by a hand-written map with a plausible default (2026-08-16)

`check-supervisor.sh` compares `AlignEdge`, `FocusDirection`, `ResizeAnchor` and `LayoutPreset`/
`TileLayout` across the two languages, and its own comment says why: "a reordered Swift enum would
send focus the wrong way with nothing failing. Compared, not trusted." What it actually compares is
the COUNT of cases. A count cannot see a reorder, and — more to the point — it cannot see a case
added correctly to BOTH enums and forgotten in the third place the order was written down: the
shim's decoder.

Each decoder was a hand-written `match byte { … }` ending in a default, and the defaults were the
dangerous kind — plausible values, not refusals. `direction_from` fell back to `Next`, so a seventh
focus direction would have CYCLED instead of failing. `anchor_from` fell back to `BottomRight`, so a
ninth anchor would have resized from the wrong corner. The tile decoder fell back to
`EvenHorizontal`, so a sixth layout would have quietly re-tiled as one row. `slopdesk_ws_align` fell
back to `Left`. In every case the gate stays green, the tests stay green, and the feature is simply
wrong.

The order is now stated once per enum, as `ALL`, with an exhaustive `index()` beside it and a
`from_index()` derived from `ALL`. That makes the compiler the gate for the half it can decide — a
case added to the enum but not to `index()` does not compile, which a negative test confirmed:
planting a seventh `AlignEdge` failed the build in two places. For the half it cannot decide — a
case added to both `ALL` and `index()` at DIFFERENT positions, which compiles fine — each enum grew
a round-trip test asserting `ALL[i].index() == i` and that a byte past the end reads as `None`
rather than as the last case. Swapping two entries in `ALL` fails that test with the position named.
The shim's four decoders are now one line each and restate nothing. The count gate stays: it still
guards the Swift side, which the crate cannot see.

## An E2E flake was undiagnosable by construction (2026-08-16)

`SubprocessE2ETests.testShippedBinariesEchoOverTCP` failed once in a full `make test` with an EMPTY
stdout and passed 6/6 immediately after, then 15/15 in a row. Two things in the test made that
failure impossible to read, and both are fixed rather than the timeout being raised.

The client's stderr went to `Pipe()` — constructed, attached, never read, never reported. On the one
run that mattered, the process's own account of what went wrong was written into a pipe that was
then thrown away, which is why the failure message could only say "got: " and stop. It is collected
now and printed alongside the exit status and termination reason.

The second is the mechanism itself. The test called `waitForExit`, then cleared
`readabilityHandler` on the next line. A process that has exited is not a pipe that has been
drained: the handler runs on a background queue, so bytes written just before exit can still be in
the pipe with no dispatch delivered, and clearing the handler discarded them. That fits the
evidence exactly — the failing run took 0.433 s and a PASSING run takes 0.310 s, so the client had
not been slow or failed to connect; the test simply read its accumulator too early. There is now a
bounded 2-second drain before the handlers come down. Not proof — the flake reproduced once in
dozens of runs — but it is the only mechanism consistent with an empty stdout on a run that was not
slow, and the diagnosis for the next occurrence is now in the failure message instead of absent.

## The ABI-enum gate is now a comparison, and it no longer dies quietly (2026-08-16)

Hardening the four crossing enums left one place unreachable from Rust: Swift's `ffiByte` switch,
where the byte is written for the third time. The compiler covers the crate, the round-trip tests
cover `ALL` against `index()`, and neither can see Swift. `check-supervisor.sh` now extracts both
maps — `case .centerHorizontal: 4` and `Self::CenterHorizontal => 4` are the same claim spelled two
ways — lower-cases and sorts them, and compares. Swapping two Swift bytes fails it by name.

Writing that gate surfaced a trap worth recording on its own. Under the script's `set -euo
pipefail`, a `grep` inside a command substitution that matches NOTHING exits 1 and takes the whole
script with it. The first version of this check did exactly that: with the Swift extension renamed,
`check-supervisor` stopped at that line, printed no failure, and every one of the ~40 contracts
below it never ran — a log that ends early reads exactly like a log that passed. The script already
carries this warning beside the `build-ffi --check` call ("under `set -e` a bare call would exit
here and the ~40 contracts below would report nothing, which reads as 'they passed'"), and the same
trap was re-entered anyway. Both pipelines end in `|| true` so an empty map reaches the guard that
names it, and the empty branch returns rather than falling through to also report a disagreement —
"one side is missing" and "the two sides differ" are different repairs.

Both halves were negative-tested: a swapped Swift byte fails with `AlignEdge: the two languages
disagree`, and a moved switch fails with `read as EMPTY`, once, instead of aborting the run.

## The registry's own doc argued away the buffer that a race needed (2026-08-16)

`MetadataRequestRegistry` had no place to put a reply that arrived before its waiter, and said so on
purpose: the class doc argued that "a reply requires the request to have been sent first (a host
round-trip), which cannot complete before the awaiting façade has registered its continuation."

That is false, and reading `MetadataClient.request` is enough to see it. The order there is: mint the
id, `await send(…)`, then `await registry.reply(for: id)`. The `await` on the send frees the main
actor. The inbound-pump fold is also main-actor, so it runs in that window, calls `resolve`, finds no
waiter, and hits `guard … else { return }`. The reply is gone. The request then waits out its whole
timeout and answers `(error, empty)` — five seconds of a spinning Details Panel and then nothing,
with nothing logged, because a timeout is exactly what a genuinely dropped reply looks like. Rare
against a real host over a mesh; routine against a fast one; and reproducible in the suite, where the
fake transport replies synchronously.

The atomicity the doc described is real — registration inside `reply(for:)` is synchronous on the
main actor, so nothing interleaves *once `reply(for:)` has been entered*. The argument's error was
extending that to the gap *before* it was entered, which belongs to the caller, not to the registry.

So an early reply is now held rather than dropped, in `landed`, and `reply(for:)` probes it before
parking anything. The distinction that decides which replies are worth holding is `outstanding`: ids
`next()` has minted whose `reply(for:)` has not returned. A reply for an outstanding id is early — a
waiter is on its way. A reply for an id nobody minted is stray, and dropping it is the point of the
existing `testResolveOfUnknownIDIsDroppedNotBuffered`: a later request that reused that id must not
find itself pre-resolved by a ghost. Buffering unconditionally would have traded one silent bug for a
worse one, and for an unbounded map.

`cancelAll()` clears both. A held reply belongs to the session that just died; handing it to a
request made after the reconnect would be a cross-session answer.

Three tests, one per behaviour: the early reply is held (30 s timeout, so only the hold can satisfy
it), it answers exactly one await, and `cancelAll()` discards it. The first was negative-tested by
restoring the drop — it fails after 31.35 s, which is the timeout, which is the bug.

## The silent-death trap was in twenty-three more places, and it disarmed the guards (2026-08-16)

The `set -euo pipefail` + empty-`grep` trap was fixed once in `compare_abi_enum` and recorded above.
Sweeping for it found twenty-three more assignments of the same shape in `check-supervisor.sh`. The
sweep was worth doing because this is not a tidiness bug: under `set -e`, `x=$(… | grep …)` where the
grep matches nothing exits 1 and takes the whole script with it, and a log that ends early reads
exactly like a log that passed.

What made it worse than "the script stops" is what it stopped BEFORE. Five of those assignments are
immediately followed by a guard whose message is some variant of "the extraction in this gate has
gone stale" — `verb_count`, `ws_vocab_count`, `field_count`, `op_count`, `swift_android_ops`. Each
was written for exactly the case that killed the script one line earlier, so the guard could never
run in the situation it exists for. Adding `|| true` is what lets the guard speak.

Two more needed a guard that did not exist, and they are the sharp ones. `codec_code` and
`solver_code` are ban lists — a haystack, then a loop of `grep -qF` for symbols that must stay
deleted. An empty haystack passes every ban in the list at once. A ban list is the one shape where
losing the input is indistinguishable from compliance, so `|| true` alone would have converted a
silent death into a silent pass, which is worse. Both now fail by name when the haystack reads empty.

`doc_missing` is the same problem inverted: its PASS state is empty output, so no check on the output
can tell "every cited path exists" from "nothing was extracted". The liveness check had to move to
the input, so the citations are now extracted into `doc_cited` and that is what is checked for life.

Proven both ways on one planted fault — `public enum AgentKind` renamed to `MovedAway`. Before: exit
2, two lines of output, ending in a bash trap fragment, roughly eighty contracts never run, no named
failure. After: exit 1, eighty-five lines, one precise failure ("AgentKind has 0 Swift cases and 21
Rust ones"), and the run reaches its last line. The emptied-haystack guard was planted separately by
truncating `WorkspaceStateCodec.swift` to a single comment, and it names the file.

Fixing twenty-five instances of one trap is worth less than making the twenty-sixth impossible, so
`check-supervisor.sh` now runs `scripts/gate-death.awk` over `scripts/*.sh` and fails on any
assignment whose command substitution runs `grep` without an `||`. It reports zero on the clean tree;
stripping the `|| true`s out of `check-video.sh` makes it name eleven offenders and fail.

The detector lives in its own file because the first version did not. Written inline as shell text
inside `gate_deaths=$(…)`, its own source contains the literal `grep` and an escaped `/\|\|/` — which
holds no two adjacent pipes — so the check read itself as an offender and failed on a clean tree. A
checker that cannot be written inside the thing it checks belongs beside it.

## `same()` called an empty extraction agreement (2026-08-16)

The dying-gate sweep turned up its own inversion. `sed`, unlike `grep`, exits 0 when it matches
nothing — so a `sed -n …p` extraction that has gone stale does not kill the run, it returns the empty
string. `check-supervisor.sh`'s `same()` compared the two sides and nothing else, which means twelve
cross-language constant checks read `"" == ""` as agreement.

One side going empty was always caught, because the other side still had a value to disagree with.
Both going empty in the same commit is the case that passed, and it is not a contrived one: renaming
a constant on both sides at once is precisely what a port does, and this gate exists to survive
exactly that commit.

Proven by renaming `versionMajor` in `SupervisorProtocol.swift` and `VERSION_MAJOR` in
`slopdesk-superd/src/protocol.rs` together. With the old `same()`: no output about the protocol
version at all, no violations, exit 0 — the gate passed while comparing nothing. With the guard:
`protocol major: one side read as EMPTY`, exit 1.

The verb loop above it had the same shape for the same reason — `for verb in ${swift_verbs}` over an
empty list runs zero times and reports nothing, which is indistinguishable from every verb crossing.
It now asserts the extraction is live before iterating it.

## One of the two "unfinished features" was a decision already taken against (2026-08-16)

The sweep above left `Canvas.groupIDsInUse()` and `WorkspaceTreeOps.insertPaneAtRootEdge` standing as
unfinished features rather than dead helpers, on the grounds that deleting either erases intent. That
was right for one of them and wrong for the other.

`insertPaneAtRootEdge` is still what it was called: a complete, invariant-preserving commit for a
rail-drag drop site nobody has wired, and `DECISIONS.md` records the user request it belongs to.

`groupIDsInUse` is not. Its doc said it existed to "prune dangling group metadata (a `PaneGroup` whose
every member was closed) on load / save" — but `Workspace.normalizingGroups()` decides the opposite,
in as many words: *"Empty groups are KEPT (a user may create a group before assigning panes)"*, and it
repairs only the other direction, an item pointing at a group that is gone. So the "unfinished"
feature is a feature the repo already refused. Wiring it would delete a group the user made on purpose
and had not filled yet.

The function stays — a membership query with no asker is exactly what someone re-derives badly when
they need the set and do not find one — but its doc now carries the refusal instead of the plan, so
the next sweep does not report it as work owed for a third time.

## A ban check at the end of a pipe stops working when its input gets big (2026-08-16)

`spells()` already carried the warning: `grep -q` exits the instant it matches, the producer upstream
then dies of SIGPIPE, and under `pipefail` that non-zero status becomes the PIPELINE's — so a spell
that WAS found reads as not found. It was written for exactly that, with the haystack hoisted into a
variable and matched from a here-string.

Fourteen other checks in the same file never adopted it, all of them the shape
`grep -vE '^//' file | grep -q "${banned}"`. The failure is worse than the one it resembles, because
it is silent AND size-dependent: the producer only takes SIGPIPE if it is still writing when `grep`
exits, so a ban check works on a small file and quietly stops working once the file grows. Nothing
about the log changes.

Measured rather than argued: three hundred thousand lines, each containing the needle. The pipe form
reports NOT FOUND; the here-string form reports FOUND. All fourteen are now here-strings, and the
planted `getpid()` this class was written to catch is caught again.

The same sweep found the floor missing under all of it. Forty `SWIFT_*` / `RUST_*` constants name the
files these contracts are read out of, and nothing checked that they still exist — a renamed file
makes `grep` print to stderr and return nothing, and every ban reading that haystack passes at once.
The check is derived from the variables themselves (`${!SWIFT_@}`), not a list kept beside them, and
it runs at the END on purpose: the constants are declared throughout the file, so it cannot un-run the
checks it invalidates, only report that they were reading nothing. Proven by moving
`WorkspaceChannelCodec.swift` aside — it names the variable and the path.
