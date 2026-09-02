# 67 — The closeout sweep, and the floor stated as a list

`docs/63` moved the client mux, `docs/65` the workspace store, `docs/66` the inspector store. This
is not a fourth projection. It is the pass that answers a question the three of them left open:
**what is actually left, and is every piece of it there for a reason someone wrote down?**

The answer turned out to be small enough that a campaign would have been the wrong shape. So this
stage ports the two things that were genuinely misplaced, deletes one that was dead, and then does
the thing the previous three could not: it BOOKS the remainder as a list, with a reason each, and
ratchets that list so the next file to fall outside it is red rather than unnoticed.

## 1. The census, and the method that lies

`docs/63` §6 states the finish line as *"the face-filtered census of undelegated non-UI Swift holds
only the documented floor"*. That sentence was not checkable, because nobody had run the census
since the three campaigns landed and the obvious way to run it is wrong.

The obvious way — a file with no `import AppKit/UIKit` and no literal `slopdesk_` in it — is a
PER-FILE test for a door, and almost no Swift file calls a door directly. It calls a sibling FACE
(`MirrorFold`, `SupervisionFold`, `TabBadgeGating`, `StoreRollup`…) which holds the `slopdesk_`
call. Run that way, `Sources/SlopDeskWorkspaceCore/Workspace/Store/` reads as **11 956 portable
lines** and `WorkspaceStore.swift` as its single largest violation. Both numbers are fiction.

The method that is right builds the face list first and subtracts it:

```sh
grep -rl 'slopdesk_' Sources/ --include='*.swift' \
  | xargs grep -hoE '^(public |package |internal )?(enum|struct|final class) [A-Z][A-Za-z0-9]+' \
  | awk '{print $NF}' | sort -u > /tmp/faces.txt      # 657 types on 2026-08-30
# a file is portable only if it is non-UI, has no door, AND names no face
```

The three modifiers matter and `package` most of all — §5 records what dropping it cost. Run this
way the whole tree holds **1 600** undelegated non-UI code lines across **44 files**, and
the Store cluster holds **zero** — every file in it names a face, `WorkspaceStore.swift` at a
density of one face reference per 3.8 code lines. Its decisions are `SupervisionFold`,
`TabBadgeGating`, `TabBadgeResolver`, `NotificationPolicy`, `StoreRollup` and
`BackgroundCompletionPolicy`; `docs/65` §3's sweep record already says so, having read every
`WorkspaceStore+*` file in full. **`docs/63` §6's floor booking for the store stands and this stage
does not reopen it.**

## 2. What was actually misplaced

Three items out of 44, and each is a different kind of wrong.

**`DropPayloadClassifier` (42 lines) — a walk decided in two languages.** The drop path is
`classify → resolve → actuate`. `resolve` has been `slopdesk_workspace::drop_action` since the
`(zone × content)` table crossed; `actuate` is effects the shells carry out. `classify` — the
file → url → text precedence and the blank gate — was still Swift. Consecutive steps of ONE walk
decided on opposite sides of the seam is the one-implementation rule broken at a join, and the fix
is to move the join rather than the rule.

**`CLILink` (35 lines) — an effect on the system.** It symlinks the bundled `slopdesk` command into
`~/.local/bin` at launch. Every effect on the system is Rust's, and this one was `FileManager`.

**`HeadlessTerminalSurface` (47 lines) — dead.** A non-rendering byte sink that conformed to
`TerminalSurface` "for tests and the headless `slopdesk-client` CLI". That CLI is
`rust/slopdesk-client` as of `docs/63` G.5, and no code constructs the type — only three doc
comments name it. Deleted, along with the sentences that pointed at it.

Note what the first two have in common and the census does not: neither was large, and neither was
found by counting lines. They were found by asking, of each file the census named, *what KIND of
thing is this?* — which is the question the ratchet in §5 makes someone answer once per file.

## 3. `DropPayloadClassifier` → `slopdesk_workspace::drop_payload`

The crate gains one module beside `drop_action`, and it reuses that module's `Dropped` /
`DroppedKind` rather than declaring a second vocabulary: what `classify` decides is literally the
value `resolve` is then handed.

What does NOT cross is the pasteboard. AppKit asks an `NSPasteboard` for its types and UIKit asks an
`NSItemProvider` to load them; the two disagree about everything up to the value and about nothing
after it. Reading them is a framework errand and stays where the framework is. What arrives at the
door is that errand's RESULT — the supported slice, already extracted — so an unsupported UTType is
simply absent rather than something the crate must know about.

`slopdesk_drop_classify` answers a `SLOPDESK_DROP_CONTENT_*` code plus a presence flag, for
`slopdesk_drop_zone_at`'s reason: `0` is a real content kind (`FOLDER`), so a sentinel could not say
"nothing supported was in the drag" without stealing a real answer. The kind lands whether or not
the value fits its buffer, so an overlay that only asks *is this drag actionable* never sizes one.

Two details the ABI had to carry explicitly:

- **`has_text` is a separate flag from `text`.** An absent published text and an empty published one
  classify the same but are not the same fact, and a length of `0` cannot tell them apart.
- **The three groups are lent from ONE arena.** A record per string would need its own nested
  `withUnsafeBytes`, and a drag's item count is not known until it arrives. So the Swift face
  gathers every run into one contiguous buffer and the records name spans into it — a shape that
  nests exactly twice however many items the pasteboard published.

## 4. `CLILink` → `slopdesk-clilink`

A crate, not a module. Not `slopdesk-cli`, whose lib is the command's argv grammar and completions —
linking that into a GUI would pull a parser in for twenty lines of `std::fs`. Not
`slopdesk-provision`, which is the only thing in the tree that opens a socket to the internet and
runs from `just provision` alone. A crate is the smallest thing that can hold this without lending
it a subject it does not have, and this one has no dependency at all.

The split is the smallest one that could work: `Bundle.main` is the only thing on either side of the
boundary that knows where this app put its own executable, so the shell resolves the source and
lends it; where the link goes, whether one is already there, whose file it is, and the `symlink`
itself are the crate's.

Four verdicts rather than a bool, because three of them are not "it worked" and one is a decision:
**OCCUPIED** means a regular file somebody else owns sits at the destination and was left exactly
where it was. That is somebody else's `slopdesk`, or an earlier copy placed by hand, and replacing
it silently is the one outcome worse than not linking at all. A stale SYMLINK is re-aimed, because a
link this app made to a bundle that has since moved is this app's to correct.

macOS only, and not because of a framework: iOS has no `PATH` and no place to put a command. The
door is inside the header's `MACOS-ONLY` region and the Swift file is `#if os(macOS)` to match.

## 5. The floor, as a list

The other 72 files stay, and this is what they are. Each class is a REASON, not a bucket — a file
that fits none of them does not belong on the list, which is the question §7's rule forces someone
to answer the next time one appears.

The count was 70 the day this section landed, and the two subsections below narrate how it got
there; their numbers are left at that day's rather than restated, because what they record is the
METHOD's history and not today's ledger. Two entries have been added since —
`TerminalChromeAppearance`, in the `ShellDeDuplication` row, and `VideoSessionRefusal`, in the
`Vocabulary` row: the two-case reason a video session ended without a rebuild, which the pipeline
raises and the pane model reads to pick its sentence (`docs/70` §2b).

| Class | Files | Why it is Swift |
| --- | --- | --- |
| `ShellDeDuplication` | 25 | A decision AppKit and UIKit would each otherwise write, hoisted so the two cannot disagree — `PanePointer`, `DeviceBezelGeometry`, `PanelChromeActions`, `HoverSelectionGate`, the `*Copy` files, the rung enums the design floor resolves. What it decides is PRESENTATION; the value is that it is written once for both. Re-triaged in full 2026-08-30, all 24 bodies: the row also holds registration seams (`VideoWindowSeam`, `AppearanceApplier`), `@Observable` state the shells bind to, and pure vocabulary enums, which the label fits loosely — but nothing in it clears the bar `docs/62` item 4 set, because crossing any of them buys a C ABI call and a handle for a comparison. It is a floor, not a backlog. The 25th is `TerminalChromeAppearance`, added with the block chrome (`docs/68` §5.3): the block furniture is DRAWN in Rust, and this is the design record the two shells would otherwise each spell — it resolves Slate's on-glass tokens into the style struct `slopdesk_term_surface_set_chrome_style` takes. The deciding is what stays; the drawing already crossed. |
| `Vocabulary` | 18 | The types the wire, the config or the ABI is typed in on this side — `WireMessage`, `MetadataVerb`, `VideoChannel`, `VideoSessionRefusal`, `KeyChord`, the config enums — plus the module-doc files that carry no code at all. |
| `SwiftRuntime` | 14 | Drives a Swift or Foundation primitive with no counterpart that can cross a C ABI: `withObservationTracking`, `Task`, `AsyncStream`, `DispatchQueue`, `NWConnection`, `JSONEncoder`, `ProcessInfo`, `async` re-entrancy, the first-responder generation, a virtual clock, `DeviceVeilWait`'s sleep-and-cancellation-check. §6 closes `docs/65` §5's triad into this class. |
| `CallingConvention` | 8 | The NEAR side of the FFI boundary: `FFIDelivery`, `ArenaText`, `RustHandle`, `LentText`, `CodecBytes`, `DevicePanelDelivery`, plus the two seams that decide what does NOT need to cross — `DeviceSectionReading` walks a blob a door filled, and `SimulatorFrameSink` holds three payloads (`docs/55` §4b: Rust would copy an IDR in and out to be told which one it was). A door's caller cannot itself be behind a door. |
| `DrawingArt` | 6 | `SlateVectorArt`, `AndroidMarkPath`, the remaining `*Art` files — CoreGraphics path data. `docs/63` §6's floor by name. |
| `WebKit` | 1 | `CodeSidebarFontSchemeHandler`. `docs/63` §6's floor by name. |

**Every row above is a reason a file STAYS, and nothing on this list is waiting on a later
campaign.** That was not true when the list landed: there was a seventh row, `DevicePanelLane`,
holding the one `import Network` socket `docs/63` §6 had explicitly deferred. The class started at
nine and read as a bucket for "device panel"; six of those gained a face once §5's `package` bug was
fixed, two belonged to a reason already in the list, and the last one — `SimulatorWebSocketLane` —
was the socket itself.

That socket is gone, and so is the row. The RFC 6455 handshake, the frame codec and its
reassembler, the reader thread and teardown, the websocket lane and the Android bridge's
line-then-stream call are `rust/slopdesk-devicelink`; Swift reaches them through six
`slopdesk_device_ws_*` / `slopdesk_device_bridge_*` doors and one near side, `DeviceSocket.swift`,
which holds doors and is therefore not floor at all. `SimulatorStreamConnection`,
`SimulatorLogConnection` and `AndroidBridgeSocket` kept their names and lost their state machines;
`SlopDeskNet` left the `SlopDeskDevicePanels` target with them. A deferral is not a floor, so the
variant is deleted rather than kept warm for the next one — the proxy campaign `docs/63` §6 deferred
alongside it will be booked when it lands, not before.

### 70, not 82 — the rule's own first bug

This list was 82 when it landed, and twelve of those entries were wrong. `declared_types` read a
face declaration as `^(public )?(enum|struct|final class) X`, and **184 of the tree's 657 face
declarations are `package`** — which is the DEFAULT spelling for a type shared inside one module
family, not an exception. A file whose every body forwards into a `package enum` therefore read as
undelegated.

`SimulatorScreenLayout` is the case that exposed it: five of its six functions are one call into
`package enum DevicePanelGeometry`, which holds eleven doors. It was booked under the since-deleted
`DevicePanelLane` class while being a pure forwarder. The same slip booked `AndroidScreenLayout`,
`AndroidFrameSink`, `AndroidStreamConnection`, `SimulatorChromeArt`, `SimulatorChromeBundle`,
`SimulatorLogConnection`, `CodeSidebarFontScheme`, `DeviceDropInstall`, `DeviceStageVeil`,
`PaneDropChipArt` and `PaneStatusPillArt`.

Note the direction of the error. A missed face makes a file look UNDELEGATED, so the failure mode
was an inflated ledger somebody had to justify — never a portable file waved through. That is the
side a census should fail on, and it is why the fix shrank the list rather than growing it. A
break-test now pins all three modifiers.

**70, not 44.** The shell pipeline in §1 answers 44 and the rule answers 70, and the rule is right:
its candidate filter runs over `Source::code()`, which strips a comment LINE wherever it opens,
where the pipeline's `grep` was matching raw text. A file whose only mention of a face is in a doc
comment reads as delegated to `grep` and as undelegated to the rule. That gap is exactly how
`HeadlessTerminalSurface` stayed in the tree after its last caller left — three doc comments naming
a type nothing constructs — so the stricter reading is the one worth ratcheting.

## 6. `docs/65` §5's parked triad, closed

That section parked three files with an explicit trigger — *"re-triage them after stage 4, not
before"*. Stage 4 landed; the trigger has fired; here is the verdict for each, recorded so the next
pass does not re-open a decision that was made.

- **`BoundedInputPipe` — already gone.** No file, no reference, nothing to triage.
- **`SerialFeedGate` (113) — stays, as the ghostty feed's runtime half.** It is a serial
  `DispatchQueue`, a set of parked `CheckedContinuation`s and a byte counter, and only the counter
  is portable. Moving it would put `pendingBytes`, `closed`, `drained` and the watermarks behind a
  door while the continuation set that those fields decide about stayed on this side — one lock's
  invariant split across a C ABI, which is strictly worse than one language holding both halves. Its
  live caller is `ThirdParty/ghostty/integration/GhosttySurface`, which a `Sources/` grep does not
  see; it is not dead.
- **`NWByteChannel` (87) — stays, as the `NWConnection` lifetime.** `docs/66` already booked its
  neighbour this way: whether a feed is live, ended or failed is about the connection's lifetime,
  and `NWConnection` is the object. Moving the client's socket ownership into Rust is a real
  campaign and a different one; it is not this triad's to start.

## 7. The ratchet

`slopdesk-invariants` gains one rule: **a non-UI, door-free, face-free Swift file must be named in
the floor list, with its reason.** New violator, red, with a pointer to §5.

What it deliberately does NOT do is re-derive the census. Encoding "build the face list, subtract
it" as a Rust rule would be a second implementation of a shell pipeline, and a fragile one. The rule
reads the same three cheap facts per file the pipeline does and compares the RESULT against a named
list — which is this repo's existing idiom for a finished campaign, and is what finally makes
`docs/63` §6's finish line a thing a gate can answer.

One ban rides along inside the same rule, because the census provably cannot state it:
`HeadlessTerminalSurface` conformed to `TerminalSurface`, which holds a door, so a resurrected copy
would NAME a face and be filtered out of the candidate set before any of the above ran. §2's
deletion is therefore ratcheted by PATH — the shape every "this Swift stayed deleted" rule in this
crate already uses.

Like every other rule it carries a break-test that seeds the drift and asserts the rule fires, and
the `fn wires` fixture gains the same entries the list did.

## 8. One pass

Both ports, the deletion, the doc corrections in `docs/65` §5, the ratchet and its fixture land
together. There is no intermediate state worth building: the classifier's Swift body and its Rust
module cannot both be the classifier, and the floor list is not a list until the two files that were
going to leave it have left.
