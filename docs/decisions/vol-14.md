# DECISIONS vol-14 — 2026-08-31 … 2026-09-01

> Volume 14 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The reading that was standing in for a gate (2026-08-31)

`rules/mod.rs` opens by naming its own hazard and then naming the mechanism that was supposed to
catch it: "A rule that is written but not registered is a rule that runs never, and the way to notice
that is for the list to be short enough to read."

The hazard is exactly right, and it is the quietest failure this crate has. An unregistered rule is
not a red and not a skip; the gate simply reports on a set with a hole in it, and every number it
prints is true. The function is `pub` in a `pub mod`, so no dead-code warning is coming.

The MECHANISM is what expired. The registry is 361 entries over 1 928 lines. That is not a screen,
and it has not been a reading anyone performs for some hundreds of rules — it was a human eye
standing in for a gate, written down as though it were one. Measured before writing anything: 361
registered, 361 rule-shaped functions in the directory, a clean bijection. So the hazard has never
fired, which is exactly when a mechanism should be replaced rather than after.

`every-rule-is-registered` compares them now. Only that direction needs a rule — the other one, a
registry entry naming a function that does not exist, is a build error. Probed by deleting a live
`Rule` block: it reds naming `gate_health::every_ffi_door_is_opened_or_declared_deliberate`.

The scan does NOT stop at `#[cfg(test)]`, and that is the finding inside the finding. Truncating
there is the obvious way to keep a break-test fixture from being read as a rule, and it is what the
sibling `every_exemption_names_a_path_the_tree_has` does — but written that way this rule misses
TWENTY-FOUR live rules and calls them registered, because three modules spell `#[cfg(test)]` inside a
DOC COMMENT explaining that very truncation and the cut lands above their own functions. An
under-reaching gate that reports clean is what the last several rounds have all been about. The
pattern is anchored at column zero instead: a `pub fn` inside `mod tests` is indented by definition,
so no truncation is needed at all.

**Rejected.** *A macro or an inventory crate that registers rules automatically* — the registry is
explicit so a reader can open one file and see the enforced set; automating it trades that for the
property a gate can now assert anyway. *Keeping the "short enough to read" sentence alongside the
rule* — a mechanism that is not running is worse than no mechanism, because it is why nobody wrote
the real one. *Truncating the scan at `#[cfg(test)]` and exempting the three modules whose doc
comments spell it* — an allowlist over a defect in the scanner, and it would grow one entry every
time somebody explains the truncation in prose.

## The provenance column nobody read (2026-08-31)

Every rule in `slopdesk-invariants` carries an `origin:` — which document it was read out of, and
which section of it. There are 362 of them, and `slopdesk-invariants --list` printing the column is
the whole of its life. Nothing has ever asked whether a citation resolves.

The FILE half turned out to be clean, and for a reason worth writing down: all 27 distinct `docs/…`
tokens in the column exist today, because `docs-cite-live-paths` and its neighbours already ratchet
paths in the other direction. The SECTION half had rotted eleven ways.

Four of them cite a numbering that never existed. `docs/48 §4` and `docs/49 §6` were written in
`d3b1f328` against the numbered checks of the shell scripts those rules were ported from, and
neither document has had a numbered section at any commit — `listener-kinds` still carries its
script's own `3b` in the function's doc comment. `docs/56 §3.6` cites one past the last section
there is. The other seven are one defect: the nine phone-hazard ratchets cite `docs/62 §4.1`–`§4.9`,
and only Hazards 8 and 9 carry the `(§4.N)` marker — someone applied the document's own convention
to two of nine, and the seven citations under it have pointed at nothing since.

The fix is per-citation rather than uniform, because the two failures are different. Where the
document has the section and only lacks the marker, the document gets the marker: Hazards 1–7 now
read `### Hazard N (§4.N) —`, the way their siblings already did. Where the citation names a
numbering that never existed, the citation moves — `docs/51 §6.6`, `docs/48 §the bridge's own
dialect`, `docs/49 §every sidecar carries its own version`, `docs/56 §increment 38` and
`§increment 64`. A twelfth turned up on the way: `docs/55 §shared constants` names no heading in
that document, and the rule it justifies is about cross-language constant drift, which is `§8`.

`origins-cite-live-sections` reads it now. A section is looked for only on a MARKER line — a heading
or a bold lead — never in prose, which is the point: `docs/62` names `§4.4` in a paragraph nine
hundred lines below the hazard, and a citation satisfied by that sentence is satisfied by a sentence.
A shorter citation is not satisfied by a longer number either, since `§4` resolving against `§4.1` is
precisely the shape a renumbering has. Measured before the fix: 94 section citations parsed, 11 red.

**Rejected.** *Scanning every `docs/…` token in the tree* — 3 053 of them across 997 files, and the
scan reports `docs/new.md` and `docs/x.md`, which are fixture FILENAMES inside two codec tests;
`statements()` keeps string literals on purpose and that is what makes every other rule here work.
The registry column is one field with one meaning, so it is the corpus. *Numbering `docs/48` and
`docs/49`* — fourteen headings in one of them, renumbered to satisfy a citation rather than a reader.
*Requiring a quoted heading (`§"The shape"`)* — the origin is a Rust string literal, so the quotes
have to be escaped, and the crate's own `origin: "([^"]*)"` extraction truncates on the one entry
that already does it. A bare `§the shape` reads the same and parses.

## The guard that its own seed answered (2026-08-31)

`slopdesk-invariants` has about twenty rules that guard themselves against reading nothing: collect
the corpus, and if it came back empty, fail with "this rule is blind" rather than report clean over
a set with no elements in it. The guards were written one at a time and never checked against each
other. Running all 363 rules over a tree with NO FILES IN IT checks them all at once, and separates
the two kinds of silence by construction — a ban is silent because there was nothing to forbid, a
positive claim is silent because it asserted over an empty set.

23 rules said nothing. 22 are bans and are honest: `Claim::NoneUnder`, `NoneOf`, `NoFileUnder`,
`Absent`, or a hand-written scan for a spelling that must not appear. The twenty-third,
`docc-links-resolve`, guarded itself with `!known.is_empty()` over a set `known_identifiers` had
seeded with the four `DOCC_EXTERNAL` framework constants BEFORE reading a file — so the guard asked
whether a Swift identifier came off the tree and four constants answered yes for it. That constant's
own doc says those are names "this repo therefore never declares", which is the contradiction
written down one screen above the function that counted them as declarations. The live corpus is
26 137 names off four roots; the guard would have passed on 4.

The floor is a count now — 5 000, well under the live corpus and far above what a renamed root, a
broken extension filter or a `code()` view returning nothing would leave behind — and `DOCC_EXTERNAL`
is unioned in AFTER it. Existing break-tests write two-file fixtures, so they seed a padding file
that declares six thousand names: a count floor cannot be cleared by being correct, only by being
big, which is what a real tree is.

`rules::tests::every_rule_that_reads_a_set_reds_an_empty_tree` is what keeps this from recurring.
The 22 bans are declared with the sentence saying why each is honestly silent, and the comparison is
an EQUALITY, so the list cannot rot in either direction: a new rule that goes quiet is undeclared and
reds, and an entry whose rule was renamed, deleted or given a floor stops matching and reds. Probed
by putting the floor back to zero — which reproduces the old guard's semantics exactly — and the test
names `docc-links-resolve`.

**Rejected.** *A rule asserting every `roots:` entry names a live directory.* Two are stale today —
`device_law`'s `Sources/SlopDeskHost` and `settings_catalog`'s `Sources/SlopDeskPhoneUI/Settings` —
but both are already covered from the other side, by `deleted_host_swift`'s `Claim::Absent` on the
first and `settings_is_a_file`'s `GUI_DIRECTORIES` ban on the second, and `GUI_DIRECTORIES` is seven
roots that MUST NOT exist. So the rule would be green today and could only ever fire on a root no
other rule mentions, which is a narrower claim than the sweep that found these. The two stale roots
are left in place: each still names what its ban is about, and each scans a directory another rule
guarantees is empty. *Routing the dangling sites into the `Report` instead of `eprintln!`* — five
sites across two files do it that way deliberately; the list is the detail and the `fail` is the
verdict.

## The module map the stamp did not read (2026-08-31)

`slopdesk-gate macos-apps` and `slopdesk-gate ios` cost ~85 s and ~15 min respectively whether or
not a byte changed, so their verdict is cached against a digest of their inputs. Which makes the
input set the gate: anything outside it can change while the gate reports "cached — no compiled
input changed", and the reason that is safe has to be written down for every file type in the tree,
not assumed for the ones nobody thought about.

`COMPILED` is five extensions — `swift`, `yml`, `plist`, `metal`, `h`. Enumerating everything under
the four walked trees that is NOT one of them leaves ten kinds of file, and nine are correctly out:
`.pbxproj`, `.xcworkspacedata` and `.xcscheme` are xcodegen OUTPUT of a `project.yml` that is in;
`.a` is the Rust artifact, deliberately absent for the reason the module header already gives;
`.entitlements`, `.ttf`, `.json` under an asset catalog and two font licences are packaging and
resources, which decide nothing a typecheck asks; `.sha256` is the FFI gate's own record.

The tenth was `module.modulemap`, and it was in the set only for `ThirdParty/slopdesk-ffi` — a
second walk pinned to that one tree, because a module map has no extension to match on. So
`ThirdParty/ghostty/integration/CGhostty/module.modulemap` was in NO scope's inputs: not the union,
not iOS, not macOS. Both app specs point `SWIFT_INCLUDE_PATHS` straight at that directory, and the
map is what says `module CGhostty { header "ghostty.h" export * }` — rename the module, drop the
`export *`, or point `header` at a different file, and `import CGhostty` stops resolving in both
triples with the stamp still warm. Its header was covered the whole time, because `h` is a
`COMPILED` extension; the file naming the header was not.

Measured after: 708 inputs in the union, 614 for iOS and 611 for macOS — one more each than the
counts the module header used to spell, which is the whole of what this fix added. The header names
no number now; a live doc that states a length states it once and is then wrong in silence.

The lookup is by NAME in every walked tree now, and the second walk is gone — it covered nothing
`COMPILED` did not already reach. Two tests: a map outside the FFI tree is an input, and editing one
moves the stamp. The module header said "and the module maps" for as long as this was false, which
is the same shape as the `Apps/Shared` fallback recorded two sections up — a sentence describing
what the code was believed to do, with nothing comparing the two.

**Rejected.** *Stamping the asset catalog's `Contents.json`* — a missing image is a runtime defect
and these two gates typecheck; adding it would re-run 15 minutes of iOS for an icon. *Stamping
`.entitlements`* — signing, checked by the release pipeline, and unreachable from a type. *Widening
`COMPILED` rather than matching by name* — `modulemap` is not an extension of `module.modulemap`,
and a rule spelled as an extension would have missed it a second time.

## The reveal D1 refused, routed to the machine that owns the path (2026-08-31)

`PaletteDataSource` carried the last two live TODOs in the Swift tree, both the same sentence: a
working-directory reveal and open, deferred "until the host can resolve a local Finder/Open path over
the control channel." The premise had been false for some time. Metadata verbs `openPath = 9` and
`revealPath = 10` ship, `MetadataClient` calls them, `HostPathActions` binds the two closures, and
`OpenQuicklyPresentation`'s focused-pane row already actuates exactly this pair. So the deferral was
not waiting on a capability; it was waiting on somebody to notice the capability had landed.

Two palette rows now sit beside Copy Path under WORKING DIRECTORY — `action.revealCwd` ("Reveal CWD in
Finder") and `action.openCwd` ("Open CWD on Host") — each resolving the same cwd the section header
badges, through one `activeCwd(_:)` read rather than three copies of the session → tab → pane walk. A
row that acted on a different pane than the badge above it names would be the defect that walk invites.

Both fire through `LinkActionActuator`, which is the ONE home for a resolved `LinkAction`; its header
already records that the AppKit embedder's duplicate switch was deleted for this reason. Reaching the
actuator from a `.store` closure needed `WorkspaceStore.activeTerminalModel` widened `internal` →
`package` — one reader across the module line, and the alternative was the palette firing
`onRequestRevealHostPath` itself, which is the parallel dispatch the actuator exists to prevent. Not
`public`: nothing outside the package resolves an active pane. Titles and glyphs are
`slopdesk_workspace::open_quickly`'s and `slopdesk_terminal::context_menu`'s for the same verbs over
the same target, said again rather than re-invented.

Both rows are `Platform::Both` in `rust/slopdesk-workspace/src/palette_rows.rs`. Neither is an
`NSWorkspace` call on the near side — that is what would have made them the Mac's alone — so the phone
reaches them exactly as the Mac does, which is the docs/56 §3 rule (layout diverges, capability does
not) rather than an exception to it.

**This does not reverse D1.** That entry struck a details-Info "Reveal in Finder / Open in VS Code ·
Cursor · Xcode · Typora" cluster because a CLIENT-side reveal targets the wrong machine — "there is
nothing honest to open." That reasoning is untouched and is exactly why these two rows route to the
host: the cwd names a directory on the host Mac, `activateFileViewerSelecting` runs there, and the
wire carries a status byte back and no host bytes. D1 barred a local reveal; it never barred the
remote one, and Copy Path — which D1 kept — is now the client-side member of a family of three.

**Rejected.** *"Open With…" as a fourth row* — it needs host app enumeration, and listing it now would
be the inert control D1 and `PaletteRowPlatformTests` both exist to prevent; its absence here is the
same recorded omission `TerminalContextMenu.LinkItem` already carries. *A new wire verb* — verbs 9/10
are the verb, and inventing a third would have cost a golden re-pin to reach a door already open.
*Confining the path to a cwd* — the host resolves what it is handed, the mesh is the security boundary
(no app-layer auth), and a confinement check here would be the pairing logic `CLAUDE.md` bars.

## The paste framing is the engine's, and close/free are two doors (2026-08-31)

**Paste.** Six menu items in the paste family answered `false` — a dead submenu — because the
renderer had nowhere to hand a paste. The obvious fix, framing the bytes in Swift, was rejected and
the code that already did it was deleted. `PasteTransform.bracketed` wrapped text in `ESC [ 200 ~` /
`ESC [ 201 ~` and stripped a smuggled end marker; it did NOT scrub the control bytes an
escape-injection payload carries, and it did NOT rewrite newlines as carriage returns for an
unbracketed paste. Both of those are rules about how the FAR side's parser behaves, which is exactly
what `libghostty_vt::paste::encode` exists to know. So `slopdesk_term_surface_encode_paste` is the
door and Swift keeps only what is genuinely the client's: which text, what shape (base64 /
shell-quote — the latter already Rust's), and whether to ask first (`PastePrecheck`).

Bit `8` of `slopdesk_term_surface_modes` now carries the live `?2004h`, read from the engine that
parsed the DECSET. That deletes the client's second reason to parse the same bytes: a tracker that
could only ever agree or be wrong, and whose being wrong SKIPS the paste-protection sheet.

Rejected: *a `paste:` verb in `slopdesk_terminal::surface_action`.* The grammar is fire-and-forget
and answers a `bool`; a dangerous payload has to stop and ask, and there is nowhere in a spelled
action to put the question. *Basing "did the program ask for brackets" on the client's own
`TerminalModeTracker`.* Two parsers of one byte stream is the drift this whole campaign deletes.

**Close and free.** `slopdesk-invariants`' `handle-freed-in-deinit` caught the surface freeing its
handle from `detachSurface()`. The rule offers two ways out and the booking would have been the lie:
the ordering that forces an early teardown is real — the `CAMetalLayer` is LENT to the view, so the
view must drop it before the state that draws into it dies, and `deinit` cannot express that because
it runs when the last reference goes. The state moved behind an `Option` on the handle; `_close`
takes it, `_free` returns the allocation from `deinit` alone, and a closed handle answers every door
its inert value rather than faulting.

## The two pushes the surface drains, the three the host already owned, and the two dropped (2026-08-31)

`docs/68` §4 promises a terminal surface whose whole FFI boundary is QUESTIONS: no callback
registration, nothing crossing into Swift uninvited. That promise held because every question is
about the grid, and the grid is still there when you ask. Five things are not about the grid and are
gone the instant the parser moves on. Auditing the deleted fork's callback set against the door list
found the surface answering none of them.

One is a correctness bug rather than a missing feature. **The terminal owes the pty replies.** `CSI
6n` asks where the cursor is, `CSI c` and `CSI > q` what the terminal is and which version, `OSC
10/11/4 ?` its colours; the engine composes each answer itself and hands it over exactly once,
through `Terminal::on_pty_write`. Nothing was registered, so every one was dropped on the floor.
That is not a terminal missing a feature — it is a terminal that does not answer when spoken to, and
vim probing for truecolour, tmux asking for the cursor and any prompt negotiating bracketed paste
all block or guess wrong against it.

**Only one of the other four is the client's to observe, and the first shape of this change got that
wrong.** A bell, an OSC-9/777 notification and an OSC-9;4 progress report were all registered as
engine handlers and drained through a five-field frame. Every one of those three ALREADY arrives as
its own wire message from the host sniffer, folded by `TerminalViewModel.handle(_:)` — as do the OSC
0/2 title and the OSC-7 cwd, which the same change had added `_title` and `_pwd` doors for. That is
two implementations of one fact, which this tree forbids, and the engine-side one is the worse of
the two for reasons neither side can fix locally:

- **Multiclient.** One pane can have several clients attached (`docs/45`). The host's detection is
  one verdict all of them share; client-side detection is N verdicts that drift.
- **Replay.** `TerminalViewModel.attachSurface` re-feeds the retained output ring into a rebuilt
  surface so it repaints. Those bytes carry the OLD bells, the OLD progress report and the OLD
  notification, so engine handlers re-beep, re-post and re-spin everything that already happened, on
  every remount. The wire path replays nothing. This is a defect, not a preference.

So `on_bell`, `on_desktop_notification` and `on_progress_report` were unregistered, the frame
narrowed to clipboard writes alone, and the `_title` and `_pwd` doors deleted with their unused Swift
wrappers. **A clipboard is per-CLIENT** — no wire message carries an OSC-52 write, and the metadata
`SetClipboard`/`ReadClipboard` verbs are the host-pasteboard sync feature, a different path — so it
is the one push with nowhere else to come from.

**They arrive as pushes and leave as pulls, and the boundary is unchanged.** `slopdesk_vterm::events`
is a bounded sink shared between the session and the two handlers the engine boxes; `feed` runs the
parser, the parser runs the handlers, the handlers fill the sink, and `feed` returns —
synchronously, on the one thread the whole handle is already confined to. The view then drains
through two ordinary two-attempt doors, `slopdesk_term_surface_take_pty_replies` and
`slopdesk_term_surface_take_clipboard_writes`, both of which answer `0` on the common day. §4's
promise is about what crosses the C boundary, and nothing here does.

Both queues are capped, because the far side of a PTY is untrusted and a view that stops draining
must cost bounded memory rather than the process. The caps differ by what the thing IS: a pty reply
is dropped whole rather than truncated, because half an escape sequence arriving at the far side's
parser is worse than silence; a clipboard write evicts the oldest, because what a person coming back
wants is the most recent.

**The replay hazard bites the two survivors too, and the conformer answers it rather than dodging
it.** A replayed `CSI 6n` makes the fresh engine compose a reply that would type `^[[3;7R` at a live
prompt; a replayed OSC 52 under an "Allow" policy would silently overwrite the pasteboard on every
remount. The attach path therefore drains BOTH doors and DISCARDS the result before wiring the live
drain — deterministic rather than racy, because `attachSurface` replays synchronously.

**A clipboard write is REPORTED, never applied.** The door says what a program asked for; whether it
reaches a pasteboard is `slopdesk_term_clipboard_write`'s decision, made where the user's
`clipboard-write` setting lives. Applying it from the frame would make "Ask" behave as "Allow" —
the exact defect the fork's `write_clipboard_cb` carried until it learned to honour the flag.

**Known and accepted: N clients answer one `CSI 6n` N times.** Each attached client runs its own
emulator, so a device-status query fans out to as many replies as there are viewers. The fork had
exactly this behaviour through `write_callback`, and `docs/45` states no input-owner rule that would
elect one. Parity, recorded rather than discovered later.

**Dropped: the OSC-52 clipboard READ gate.** The fork ran a whole `clipboard-read` Allow/Ask/Deny
ladder with a documented recursion hazard around `completeClipboardReadOSC52`. It has no subject
any more: `libghostty-vt` documents that OSC-52 read requests (`?`) are *"always ignored and never
forwarded"*, so no program can ask and there is nothing to gate. The setting's OTHER arm — the
metadata clipboard-read channel, verbs the host answers — is a different path and is untouched. The
row stays; what it governs is now one thing rather than two.

**Dropped: OSC-22 pointer shape.** The fork actuated `onMouseShape` onto `NSCursor`. `libghostty-vt`
parses OSC 22 — `osc::CommandType::MouseShape` is a variant — but `Terminal` exposes no handler for
it, so there is no observation point at any price this side of a fork. Recorded as a drop rather
than left as a silent regression; if upstream adds `on_mouse_shape` it is one closure and one door,
in the sink that now exists.

**And the orphaned tables followed.** `slopdesk_terminal::pointer`, `slopdesk-ffi`'s
`pointer_shape.rs`, both header declarations, `PointerShapeMapping.swift`,
`MouseVisibilityMapping.swift`, both Swift suites and the `pointer-tables-one-table` ratchet are
deleted. They were not an unwired door waiting for a caller: their only producer was the fork's
`action_cb`, and the revival path named above — one closure into the sink — would not reuse a
`ghostty_action_mouse_shape_e` discriminant table anyway. The ratchet was the worst of it, since it
REQUIRED two dead Swift faces to keep calling two dead doors. What the increment argued — that a
Swift mirror of a C enum is a third copy of one declaration order — is kept as prose in `docs/56`
§50, which is where the next table that crosses will want to read it.

**Not dropped, and never needed an engine: hiding the pointer while typing.** The fork's comment
implied libghostty decided; the decision was `hide on keyDown`, which AppKit spells
`NSCursor.setHiddenUntilMouseMoves(true)`. It lives in the view, costs no door and no vterm change —
`MacTerminalRendererView.keyDown`, gated on `SettingsKey.mouseHideWhileTypingEnabled` and read live
so a Settings toggle takes effect on the next keystroke. The phone has no pointer to hide.

**Rejected.** *Keeping the bell/notification/progress drain as a fallback for when the host is
older* — a fallback is the second implementation wearing a hat, and it would fire on replay exactly
when it was least wanted. *Draining straight into the caller's buffer* — the two-attempt convention
means a first call can answer "too small", and a reply lost on exactly the call that said "try
again" is a program that waits forever; the handle holds the drained bytes until `deliver` has
actually written them. *Registering `on_enquiry` and `on_xtversion`* — the engine answers both
correctly by itself, and overriding them would mean this crate inventing a terminal name rather than
reporting the one it is. *A push door for either survivor* — it would be the first callback across
the boundary and would cost §4's promise for a latency the synchronous drain already has.

## The rows that survived their reader (2026-09-01)

The terminal's settings used to be applied by handing `libghostty` a `key = value` TEXT. That builder
is gone (docs/68 — the renderer that replaced the fork takes typed doors), and deleting it stranded
two things at once: a sixteen-field control BUNDLE nothing read any more, and fourteen `[terminal]`
rows whose only consumer had been a line in that text.

The bundle was easy — every row it carried is read at the point of use through `SettingsKey`, so it
was a second reading of the same file and nothing else. **The rows were the decision.** A row with no
consumer is not inert: a user writes `terminal.ligatures = calt`, the resolver accepts it, the
diagnostic stays silent and nothing changes on screen. That is worse than the key not existing, and
the tempting reading — "an unwired door in a ported crate is usually a door, not dead code" — is the
wrong lens here, because nothing in this pass was going to wire them and one of them (ligatures)
cannot be wired without a shaper decision that has not been taken.

So the uniform rule: **a row with no consumer left is deleted in this pass, and comes back in the same
change as its feature.** Twelve went — `font-weight`, `font-family-fallback` / `-bold` / `-italic` /
`-bold-italic`, `auto-match-weight-style`, `ligatures`, `ligatures-alphabet`, `bold`, `italic`,
`blending`, `theme` — with the three font-appearance enums that existed only to spell them. Note the
honest history: these WORKED under the fork, which parsed the text. They are a regression being
codified, not a feature that never landed. `font-family-fallback` and a terminal `line-height` are
worth their own passes; `ligatures` needs the shaper decision first.

Two rows were NOT deleted, and the difference is the whole rule working. `terminal.background` and
`terminal.foreground` also had no reader — the app's one flat profile pins the cell colours through
`AppearanceApplier`, and the file's colours reached nothing. But that hook is `nil` on the headless,
golden and `ImageRenderer` paths, and its own doc already promised those readings fall back to the
file. The promise had simply stopped being kept. Giving the fallback a consumer is one line at the
store, and it makes the rows true rather than removing the only colours the file can state. Their
selection colour is DERIVED as the per-channel midpoint of the two, which the seam's own contract
licenses: a theme that states a background and a foreground has stated enough.

The same sweep found the one real bug. `controls.clipboard-shell-controlled`, the master switch over
the whole OSC-52 path, was folded into the per-direction gate by the dead bundle — while the LIVE
write path asked `SettingsKey.clipboardWrite` on its own and never saw the switch. Turning the master
switch off did nothing. It is now folded inside the accessor every caller already uses, both
directions in one crossing, so a caller cannot forget it.

## The prompt goes in a BAND, not inline on the grid (2026-09-01)

The editor-like command prompt was built whole and mounted nowhere: `rust/slopdesk-terminal/src/prompt/`,
forty-five FFI doors, a 668-line Swift face, and zero callers. Mounting it needed one decision first,
and the tree gave two contradictory answers.

`prompt/mod.rs`'s own header said **`slopdesk-termrender` owns PLACE** — "where the caret rectangle is
in device pixels… how the completion list is drawn" — which describes an INLINE prompt: the editor
drawn into the terminal's cell grid at the shell's own prompt row, the way Warp looks. `docs/68` §5.4
says the opposite: the prompt "is what goes inside the box", the box being the external input
affordance `inputbox.rs` selects, and §10 files "the candidate list's appearance" in the view with the
rest of the composition work.

§5.4 wins, and not only because it is the later document. The inline reading requires the renderer to
grow a second text pipeline — prompt layout, caret rects, a candidate popup — inside a crate whose own
header says it has "no font engine". The band reading needs none of that: the editor is a sibling
`NSView` doing its own Core Text layout, and `slopdesk-termrender` keeps drawing exactly one thing.
The inline paragraph in `prompt/mod.rs` was describing an architecture nobody had chosen; it is
corrected rather than left to mislead the next reader.

What the band costs, stated plainly: the grid gets shorter by the band's height, so the shell has
fewer rows. That is honest — those rows are not the shell's any more — and it is forced besides, since
`surfaceView` is layer-HOSTING and AppKit does not promise a subview of one of those a layer.

**The prompt view takes no keyboard focus.** `MacTerminalRendererView` stays the pane's one first
responder and routes into the editor from `keyDown`. A second responder inside the pane would divide
the focus region the TAB owns, which is the exact shape of the four focus bugs of 2026-08-10. It also
means the whole `NSTextInputClient` stack — Telex, marked text, `consumed_mods` — is written once and
serves both the grid and the editor.

**Every editing chord is AppKit's.** The press is handed to `interpretKeyEvents`, and what comes back
is a SELECTOR: `moveWordLeft:`, `deleteToBeginningOfLine:`, `moveToRightEndOfLineAndModifySelection:`.
Mapping selectors instead of keys is `docs/68` §10 read literally (a motion crosses as a case, never as
a key) and it inherits every layout, every locale and every user's `DefaultKeyBinding.dict` for free.
A hand-rolled chord table would have been a worse copy of a table the OS already keeps.

**Four control keys are carved out**, in Rust (`prompt::keys`): `⌃C`, `⌃D` on an empty line, `⌃Z`,
`⌃L`. `readline` never owned those either, and an editor that swallowed one leaves the terminal in a
state the user cannot get out of. Everything else — `⌃A`, `⌃E`, `⌃K`, `⌃W`, `⌃R` — is the editor's,
because the editor is the thing doing the editing.

**The clipboard verbs follow the line, and the scrollback keys never did.** Arming an editor in front
of a shell silently re-points three of the oldest verbs in the app, so each was decided rather than
left to fall out. A PASTE while armed is text into the editor — all six paste variants, redirected at
the single funnel they already share, ahead of the protection sheet, because the four dangers that
sheet asks about are about what a shell does with a payload on ARRIVAL and nothing arrives. A COPY or
a CUT is the editor's only when the GRID has no selection: the two are different selections, and a
reader who just dragged over scrollback meant that text. A cut over a grid selection while armed
degrades to a copy, since the DEL bytes it would otherwise send have no line at the far end to erase.
And PageUp/PageDown/Home/End-of-document are mapped to the VIEWPORT rather than dropped — the editor
existing must not take scrollback away, which is what an unrecognised selector falling through to a
`default:` would have done.

**⌘Z while armed is the editor's history, and `controls.undo-at-prompt` does not reach it.** That
setting decides one narrow thing — whether ⌘Z emits the readline undo BYTE to a shell holding the
line — and while our editor holds it there is no shell to send a byte to and no ambiguity for a
setting to settle. So the chord is read in the same place as every other press the editor takes,
before the fall-through to `interpretKeyEvents` that would otherwise drop it (AppKit's key-binding
table names no undo; undo is a menu item, and the terminal view is not in that menu's chain). The
alternative — leaving ⌘Z inert while armed — would have shipped an editor advertising undo with
coalescing behind a key that does nothing.

**`InputBarModel.compose` is deleted in the same change.** It held the command line as a plain
`String` for a `TextField` that was never built, and keeping it would have been two line editors with
one PTY behind them — the one-implementation rule failing where it costs most, since the two only
disagree under a composition or a paste.

⚠️ This is NOT the command ladder struck on 2026-08-10 (`6eb148c5`), and the check was made before
building. That was a per-command instrument on the pane's TRAILING edge — a rail of ticks with a hover
peek — and `DESIGN.md:527-529` bans exactly that. A bottom band holding the line being typed is a
different object in a different place answering a different question.

## The phone's chords cross as a DOOR, and the band is one implementation (2026-09-01)

The band mounted on macOS the same day and the phone had to follow, because a prompt on one platform
is the parity break `docs/62` exists to close. Three decisions were forced, and none of them is "port
the Mac view".

**The band is platform-neutral, not duplicated.** `TerminalPromptBand` is the whole of it — wrapping,
UTF-8→UTF-16, selection, caret, accessory precedence, syntax ink — importing neither AppKit nor
UIKit, with a ~100-line view shell on each side that answers `intrinsicContentSize` and hands over a
`CGContext`. That is possible because `CTFont` is toll-free bridged to `NSFont` and `UIFont` both,
the Core Text attribute keys take `CTFont`/`CGColor`, and `SlateNativeColor` was already a typealias.
The alternative was a phone clone of a 495-line view: the cross-language mirror the
one-implementation rule forbids, in one language, where it is harder to see. The band's arithmetic
tests came unfenced with the extraction — a suite that only ran on macOS would have left the phone's
band pinned by nothing.

**`slopdesk_prompt_key_action` takes a KEY, and `docs/68` §10 is not bent by it.** §10's rule is
about the MUTATING doors — a motion crosses as `SLOPDESK_PROMPT_MOTION_*`, never as a key, and it
still does. Deciding WHICH verb a press names is the other half of the same split, and that half is
Rust's. The Mac never needs the door because AppKit's standard key-binding table answers the question
in selectors; UIKit has no counterpart at all, and `UITextInput` supplies none of it. So the phone
either asks Rust or keeps a Swift chord table — and a Swift chord table is a second editor's worth of
decisions in the language the rule keeps them out of. `slopdesk_terminal::prompt::keys::edit_action`
owns the table and is tested headlessly; `PhoneKey.promptKey(_:)` does only the NAMING §10 assigns to
the view, off the USB HID keyboard page rather than `UIKeyboardHIDUsage`, so the macOS test runner
drives the same table the phone does.

**The pane collapsed onto one first responder, and that was a defect and not a preference.**
`PhoneTerminalRendererView` had claimed first responder synchronously from `setPaneFocused(_:)` since
`cf06ae4d`, while `TerminalInputHostView` — the pane's ratcheted `UIKeyInput`, holding the repeater,
the accessory row and the ⌃⇥ walk since `3955de12` — claims one runloop hop later, because
`PaneFocusCoordinator` defers `becomeFocus()` (UIKit takes a synchronous claim back). The two are
SIBLINGS, so the loser's `pressesBegan` was never called at all rather than called late: the renderer
had been unreachable for keys in production, and the keyboard flickered down and up on every pane
focus because it conforms to no text-input protocol. The renderer stopped being a responder; nothing
was given up, since the four ⌘ chords already arrive as `UIKeyCommand`s on the input host and route
back through `onRequestMenuItem`. ⚠️ The generalisation is the same one the 2026-08-10 focus bugs
produced, one level down: **two responders in one pane is a second implementation of focus**, and a
sibling pair hides it completely.

What is left open on the phone is the INLINE preedit, and it is `UITextInput`'s rather than the
editor's: `UIKeyInput` has no marked text, so the band draws no composition underline. Typing
Vietnamese and Chinese at the prompt works today — an input method shows candidates in the keyboard's
own bar and commits through `insertText`, which reaches the editor as text. Shipping the band without
the underline is therefore a missing decoration, not a broken input path, and holding the whole mount
back for it would have kept the parity break open for the far larger `UITextInput` conformance.

## ⌘F counts and lights the same engine, and three doors died for it (2026-09-01)

Gap 4 was the last one-implementation violation in the terminal surface, and it did not look like
one from either side. The find bar printed `N of M` from `slopdesk-rowscan::find` — a scan over a
flat text mirror, addressed by LINE INDEX — while the surface lit cells from `slopdesk-vterm`'s own
matcher, addressed by grid CELL. Both were correct about their own buffer. Neither could be right
about the other's, so the counter and the highlights were two answers to one question, and any wrap,
any double-width glyph, any scroll made them disagree in a way no test on either side could see.

**The fix was not to rewire the counter, it was to make the surface's matcher able to answer.** It
was literal-only, and `SearchQuery` carried case-sensitivity and whole-word but nothing for regex —
so `Aa`, `ab` and `.*` had no way in and the bar met them with its own scan. `Matcher` now compiles
either a folded literal or a `regex::Regex` ONCE per query and is the per-line prefilter for the
whole buffer; case-sensitivity becomes the pattern's own flag and whole-word post-filters what either
mode found, so no mode is a special case of another. The `regex` crate is linear by construction,
which is why it and not a backtracking engine: a ⌘F pattern is re-run over the entire retained buffer
on every keystroke, and one pathological pattern must not be able to freeze the bar.

**What the door made unnecessary was deleted, not left dormant.** `slopdesk_term_surface_find` takes
all four modes and answers a COUNT; `_find_position` answers the cursor. That removed the reason for
`slopdesk_ws_find_bar_row_driven`, `slopdesk_ws_find_reanchor` and `slopdesk_ws_find_step`, for
`Arming::EndThenScroll`, and for the bar's mirror, match list and index — the machinery that existed
only to work around a matcher that could not express three of its own modes. `Arming` is two arms
now: run the search, or end it. The invariants ratchet KEEPS the row-driven pattern claim so the
branch cannot come back, and W2a — which pinned the in-pane bar's carried guess — is gone with the
scan it priced.

⚠️ **Two matchers remain and the split is deliberate.** ⇧⌘F searches every open pane on every
keystroke; asking each pane's live engine would cross the FFI seam per pane per character, so
`WorkspaceStore.beginGlobalSearchSession()` mirrors each scrollback once and `ScrollbackMatcher`
re-scans that snapshot in memory. One addresses cells in a live buffer, the other line indices in a
snapshot — that is two questions, not one question answered twice, and the header of each says so.
The collapse improved ⇧⌘F as a side effect: jumping to a hit now arms the surface's own four-mode
search, so the amber per-glyph highlight survives `Aa` and `.*`, which was a documented ceiling.

## The last four settings that lied, and the one door only the engine could answer (2026-09-01)

Four rows in `slopdesk-settings`' table did nothing: `controls.shift-arrow-select`,
`controls.shift-click`, `controls.click-to-move`, and the TERMINAL half of `terminal.line-height`
(its code-panel half has been live through `CodeFontSync` all along). Three of them were the kind of
gap that reads as a small omission and is not — a drawn, persisted, documented setting the user can
toggle to watch nothing happen, which is the failure "The rows that survived their reader" above
deleted twelve rows to avoid. These four were kept and wired instead, because unlike `ligatures` each
one's feature was reachable without a decision nobody had taken.

**Three are decided on THIS side, which is what the gesture settings' own paragraph already said.**
⇧+arrow is recognised in `TerminalSurfaceDriver.sendKey` and runs the existing
`adjust_selection:<dir>` binding — the machinery copy-mode's vi-visual selection already used, now
reachable outside copy mode. The *recognition* is a Rust rule (`slopdesk_term_shift_arrow_edge`)
rather than a Swift table, and the reason is one bug it would otherwise have shipped: `Mods` reports
a right-shift press as `SHIFT | RIGHT_SHIFT`, and Caps Lock and Num Lock ride along on every press
while they are on, so a bare `== SHIFT` refuses a right-handed typist and everyone with Caps Lock on.
That is a setting that works for *some people*, which is worse than one that does not work at all.
⇧+click is `MacTerminalRendererView.mouseDown` taking a click back off a mouse-reporting program —
the only way to select over a full-screen TUI. Its four-way value is read as a binary axis by RULE
(`MouseShiftCapture.extendsSelection`), so a stored `always` cannot read OFF.

**One half is honestly not actuated and says so.** `controls.shift-click`'s `always`/`never` differ
from `enabled`/`disabled` only in whether the PROGRAM may override the bypass (DEC mode 1029), and
`libghostty-vt` exposes no reading of that mode. The pairs therefore behave alike. That is recorded
in the code and the ledger rather than papered over, because the alternative — pretending the
distinction lands — is the same lie the setting had before.

**Click-to-move is the one that had to be a door, and the reason is worth keeping.** A shell's line
editor owns its cursor; nothing can place it. `←`/`→` are the only vocabulary every editor in every
shell shares, so the click is spelled as the presses a user would have made — and only the engine
knows where the cursor is, how many GLYPHS lie between it and the click (a wide character is two
cells and one press), and whether DECCKM wants `ESC [ C` or `ESC O C`. `VtSession::click_to_move`
answers all three. It is same-row-only, and that is the feature rather than a simplification: at a
prompt `↑`/`↓` are HISTORY, so a door that crossed rows would replace the half-typed command the user
clicked into. The one question it refuses to answer is whether the shell is at an EDITABLE prompt —
that reading is OSC 133 plus a live connection, the client already holds it for ⌘Z, and asking it
twice in two languages is how two answers drift apart.

**`line-height` went into the font stack, not the renderer.** `FontStack::new` takes the multiplier
and `measure` applies it before anything else is derived, so the taller cell centres its glyph and
every offset the face reported — baseline, underline, strikethrough — rides with it. Applying it
downstream would have stretched the cell and left the text pinned to its top, and each decoration
would have needed its own correction. `set_font`'s unchanged-test grew the third input with it:
without that, changing only the line height would have been a settings write that did nothing, which
is precisely the class of bug this pass exists to end. `TerminalPromptBand` multiplies its own rows
by the same number, because the band draws the shell's prompt line against the grid and a grid at
1.3 beside a band at 1.0 reads as the prompt having its own, tighter typography.

## The phone becomes a text client, and what that closed (2026-09-01)

**`UITextInput` on the responder, not on the pixels.** The phone's terminal had marked text nowhere:
`TerminalInputHostView` conformed to `UIKeyInput`, which carries a COMMIT and nothing else, so an
input method's uncommitted run was visible only in the keyboard's own candidate bar. Vietnamese and
Chinese typed correctly the whole time — `Tieengs` arrives as one `Tiếng` — and what was missing was
the inline preedit, the underlined run under the caret that says which letters are still being
argued over. `Sources/SlopDeskPhoneUI/Pane/TerminalTextInput.swift` is that conformance, on the
RESPONDER rather than on the renderer, because the responder is what UIKit asks and the pixels are
its sibling.

**The document is the composition and nothing else**, which is the Mac's rule in UIKit's vocabulary.
There is no text here to be an index into: the grid answers what is on screen, the engine owns the
grid, and a text view's questions — `closestPosition(to:)`, `characterRange(at:)`,
`selectionRects(for:)` — are answered with the honest empty value rather than a reconstruction the
engine would have scrolled away by the time anyone read it. Offering selection rects in particular
would have put UIKit's grab handles and loupe over a selection the pane already makes with its own
long press: two selections over the same pixels, which the user then has to keep apart.

**The one number that is never `nil`: `selectedTextRange`.** Several input methods refuse to START a
composition against a nil selection, and the failure is silent — the keyboard works, the candidates
appear, and the inline run never arrives. A zero-length caret at the only position an empty document
has is the answer, and `TerminalComposition` clamps every offset UIKit derives so a walk off either
end is met with an edge rather than a trap.

**Two seam members, because the phone's text client is a SIBLING of the pixels.**
`setComposition(_:selection:)` reports the run and `caretAnchor` answers where the caret is AND in
which view. The host does NOT decide who draws the preedit — the conformer does, band while the
editor owns the line, grid otherwise — so that fork stays written once per platform; a host deciding
it would be a second copy of a rule the Mac already holds, and the first time the two disagreed
there would be two underlined runs on screen. The anchor is a pair for the same reason the Mac's
`firstRect(forCharacterRange:)` forks: a candidate bar hanging off the grid's stale cursor while the
letters appear a band's height below is the most visible way a Telex session can look broken.

**Every text trait is turned OFF, and that is not tidiness.** Adopting `UITextInput` opts a view into
corrections `UIKeyInput` never offered: smart quotes rewrite `"` as `"` on a shell line, smart dashes
turn `--flag` into `–flag`, autocapitalisation shifts the first letter of every command, and
autocorrect rewrites the ones it does not know, which is all of them. Adopting the protocol without
them would have been a regression shipped as a feature.

**It also ended `FloatingCursor`'s wait, and needed one new door to do it.** UIKit hands a
space-bar drag only to a text input, which is why the accumulator was built, tested and caller-less.
Wiring it turned up an asymmetry: the drag's arrows are BYTES for a shell holding the line, and the
app's own editor is not a shell — there is nothing to send `ESC [ C` to. So
`slopdesk_phone_floating_cursor_steps` is a second RENDERING of the same `feed`, a signed count for
the editor's path, and the two doors are pinned against each other rather than against a number
typed in a test: what would break silently is them drifting, not either one alone. Exactly one is
called per delta, because each consumes the travel it reports.

**And it found a live defect on the seam it touched.** The phone's `insertText` had no `isSearching`
fork, so a soft-keyboard character typed into an open ⌃R was inserted into the LINE instead of the
query — the Mac has had that fork since the band landed. Two bugs in one: the wrong buffer was
edited, and the search read a query it never received.

**The preedit's pixel verification was never blocked — only the GRID's is.** This was written off as
needing a booted simulator, on the strength of `slopdesk-apple-metal` setting `framebufferOnly =
true` so its drawable cannot be read back. That is true of the grid and false of the BAND, which is
`CGContext` end to end and photographs off-screen through `HostedRaster` exactly like every other
phone pixel rig — and the band is where the preedit goes whenever the app's own line editor owns the
line, which is the case the feature was built for. `TerminalPreeditPixelsOnIOSTests` renders it.

**Which immediately caught a second live defect, and one only pixels could catch.**
`TerminalPromptBand.caretRect` took no composition, so with a conversion in flight it reported the
EDITOR's cursor while `drawComposition` drew the bar shifted into the marked run. An IME hangs its
candidate window off the reported rect, so for exactly the long conversions that need one — a
Japanese phrase, not a Telex vowel — the window pointed at the start of the run while the caret sat
at its end. Both platforms had it, because the band is one implementation. The fix is not a second
correction but a shared `compositionCaret`, measured off the SAME `CTLine` that gets drawn: the two
numbers can no longer disagree about a kern. No arithmetic assertion could have found this — the two
spellings were each self-consistent — which is the argument for the rig, not just for the fix.

**"The conformance cannot be driven headlessly" was also wrong, and it was our own header saying
it.** `TerminalInputHostView.surface` is an injectable seam, so a probe standing in for the renderer
sees exactly what a live one would. `TerminalCompositionSeamOnIOSTests` drives it: the marked run
reaches the pixels verbatim WITH its own caret, an empty run is how a withdrawal is spelled and both
sides drop it, the caret is converted out of the view that owns it — a rect returned unconverted
would place a candidate window a band's height off, right where it looks deliberate — and every one
of the six text traits is off. The traits are the cheapest test in the file and the one guarding the
most destructive default: a smart quote at a shell prompt is a string that never closes.

**And the GRID's preedit needs no readback, because it is verified where it is DECIDED.**
`slopdesk_termrender::paint` holds six pins on the composition — the bed, the underline across every
cell it takes, the caret it REPLACES rather than joins, the blink it draws through, the nothing it
draws with no cursor on screen. `setFramebufferOnly(true)` gives up a readback of the finished
drawable, which would only re-check that Metal blits quads it blits for every glyph anyway. Verify
the decision in the layer that makes it; a pixel rig is for the layers that decide in pixels, which
is what the band does and the grid does not.

## Inline images draw, and a remote terminal may not read a local path (2026-09-01)

`docs/68` §5.1 scoped kitty-graphics RENDERING out with one sentence: `TerminalConfigBuilder` enabled
no image token, so nothing regressed by not drawing them. That builder was DELETED in the same
document (§5.6), which killed the premise without anyone striking the conclusion — a scope cut
outliving its reason. §5.7 is the close. Nothing upstream had to change: the pinned bindings already
publish storage, placements, z, `PlacementRenderInfo` and a PNG hook, which is precisely the return
"owning the grid" was supposed to pay.

**The kitty file and shared-memory transmission mediums are CLOSED, and no setting reopens them.**
The protocol lets a program transmit an image by naming a filesystem PATH (`t=f`, `t=t`) or a POSIX
shared-memory object (`t=s`), and in a local terminal that is a feature — the program and the
terminal share a filesystem, and passing a 4 MB PNG by name beats base64 in an APC. **This app is the
case where they do not.** The terminal is the CLIENT and the program runs on a REMOTE host, so a path
the far side names is resolved by the LAPTOP: an arbitrary local file read, driven by whatever is on
the other end of the pty, with the bytes then drawn on screen where the far side can see what they
were. Only the direct medium (`t=d`, base64 inside the APC) is accepted. `terminal.images` gates
DRAWING and nothing else; it cannot turn this back on.

**The engine's own default storage limit is large, and reading the documentation would have missed
it.** The bindings say images are stored "only once a non-zero storage limit has been set" — which
reads as "nothing is stored until you ask". A probe test measured the opposite: a fresh session
accepts and stores a transmission with nothing configured. So the seal writes an explicit zero as
well as closing the mediums. The regression test asserts on `image_meta` and NOT on
`graphics_generation`, because the generation moves even when nothing was stored — the obvious
assertion is the one that passes for the wrong reason.

**A placement is clipped to its BLOCK.** Nothing in the protocol stops a placement's rows from
running past the command that emitted them, and under block layout the next thing below is the next
command's header. An image over it would be furniture describing the wrong command. So the
destination is intersected with the block body and the source rectangle narrowed by the same
fraction — a crop, not a squash — and the same intersection handles a placement scrolled off the top,
which is why the engine's negative row costs no second code path.

**`f64::max` swallows a NaN, which is the opposite of what an intersection wants.** `CLAUDE.md`
requires `f64::max`/`min` over a `<` ternary for bit-exactness, and those two disagree on exactly
this input: IEEE `maxNum` answers the non-NaN operand, so a NaN clip bound would be silently replaced
by the image's own edge and the placement would draw at full size in the wrong place rather than not
at all. The clip therefore checks finiteness FIRST and explicitly. The test that pins it exists
because the first version of that function claimed the intersections would reject a NaN, and they
did not.

## The core follows ghostty, the app layer takes the best of everyone (2026-09-01)

The user's ruling, and it settles a class of question rather than one question: **for the terminal's
CORE — parsing, grid semantics, protocol arithmetic, anywhere a specification is underdetermined —
do what ghostty `main` does.** Not because copying is easier, but because the programs on the far end
of the pty were tested against ghostty and kitty, and because ghostty's author has spent longer in
this problem than this project will. Agreeing with the terminal the ecosystem calibrates against is
worth more than any answer of our own, and "our answer is defensible" is not a reason to differ.

**Above that line the rule inverts.** Blocks, the prompt band, layout, navigation — everything a user
would call a feature — is ours to take from wherever it is best: Warp's blocks and editor-like input,
kitty's protocols, rio, VS Code's terminal, `otty.sh`. The two halves meet at `slopdesk-vterm`'s
boundary. The engine wrapper does not innovate; nothing above it is constrained by what ghostty
happens to draw. A Warp-class surface over a ghostty-faithful core is the whole shape of the product,
and neither half is allowed to leak into the other.

**Sixel is STRUCK, and iTerm2's OSC 1337 with it.** Both were carried in
`docs/ui-shell/current-state/terminal-features.md` as "**gap** — decoder only", which was an
accounting error the moment the render half landed: the render half is not what is missing, and
naming them gaps implied a debt. They are NON-GOALS. ghostty `main` supports neither, so by the rule
above neither is ours to add. Sixel in particular is a 1987 palette-indexed bitmap with no alpha and
no way to say where it belongs; every program that emits it emits kitty graphics when the terminal
advertises them. Adding either would mean a decoder we alone maintain, a second path through the
image store, and a second class of security question about payloads the far end chose — for pictures
the kitty path already draws. Do not re-open.

**What the rule bought immediately: kitty's VIRTUAL placements, ported rather than derived.** The
`U=1` unicode-placeholder form is the one shape of the graphics protocol §5.7 had declined, on the
grounds that the engine reports no viewport position for such a placement. That was true and was the
wrong conclusion: the position is not missing, it is in the CELLS — the image id in each placeholder
cell's foreground colour, the placement id in its underline colour, the fragment's row and column as
combining diacritics on `U+10EEEE` itself. `libghostty-vt` exposes every one of those and no iterator
over them, because walking cells is the embedder's job. So `rust/slopdesk-vterm/src/placeholder.rs`
walks them, during the frame fill that already reads the raw style and the grapheme — a second pass
would have needed the engine handle again — and caches each row's runs ON THE ROW, which is what
makes it correct under the dirty-row skip: a clean row keeps its cells, so it keeps the runs those
cells spelled.

The aspect fit is `graphics_unicode.zig` at the pinned `22d13172`, function for function. The
protocol says an image is "scaled to fit" its grid and says nothing further; whether the leftover is
centred or flushed, and whether a fragment inside the blank band draws nothing or draws the nearest
row of pixels, are the terminal's to decide. Deriving our own would put an off-by-a-pixel seam
between adjacent fragments of one image — which is exactly what a tiled image is made of. The
placeholder cell draws no glyph, unconditionally and not gated on whether images are enabled:
`U+10EEEE` is private-use, no font has it, and a cell that kept its text would put a `.notdef` box in
every cell of every virtually placed image.

**The protocol's `X=`/`Y=` cell offsets were being dropped, and nothing would have shown it.** They
are sub-cell nudges a program uses to line an image up with something drawn beside it, and the same
two numbers carry the blank band an aspect fit leaves over. Ignoring them is invisible in any
screenshot of a single image and wrong in every one of a tiled image, by a fraction of a row per
tile. `ImagePlacement` carries them now and `place` adds them as separate terms — never folded into
the multiply, per `CLAUDE.md`'s bit-exactness rule, because these land in the same vertex buffer as
the layout's numbers.

**And the same survey found the rule's first cost: the Glyph Protocol is REFUSED, out loud
(2026-09-01).** ghostty `main` ships one more APC protocol beside kitty graphics — `ESC _ 25a1 ; …`,
the Glyph Protocol, which lets a TUI register its own glyph OUTLINES so icons draw without the user
installing a patched font. `libghostty-vt` implements the whole wire half and `apc.zig` enables every
APC protocol by default (`initFull()`), so this terminal was ANSWERING the support query: a probe fed
`ESC _ 25a1 ; s ESC \` to a fresh session and got `ESC _ 25a1 ; s ; fmt=glyf ESC \` back.

That reply is a promise nothing here can keep, and it costs more than saying nothing. The C ABI has a
setter and no reader — disabling is documented to CLEAR the glossary, and no door hands the outlines
out — and the rasterizer on this side is Core Text over INSTALLED fonts, not `glyf`/COLR tables
arriving on a pty. A program that believes the reply registers its icons and then prints codepoints
we draw as tofu, displacing the Nerd Font glyph out of the user's own family that it would otherwise
have fallen back to. So `VtSession` calls `set_glyph_protocol_enabled(false)` at construction, beside
the image seal and for the same reason: the engine's default assumes an embedder that draws.

⚠️ This is a REFUSAL WITH A DATE ON IT, not a non-goal. Sixel and OSC 1337 were struck; this one
returns the day the bindings expose the glossary and `slopdesk-termrender` can rasterize a
transmitted outline. Recorded here so a future pass reads it as a gap that is owed work rather than a
question already settled — and pinned by `the_glyph_protocol_support_query_goes_unanswered`, which
fails both if the seal is dropped and if a bindings bump re-arms the default.

**The same survey's second find was an outright absence: focus reporting (DEC 1004) was never
wired.** Focus reached the RENDERER — it drives the hollow cursor — and stopped there; the FFI door's
own doc comment said "drives the hollow cursor and nothing else", which was true and read for months
as a scope statement rather than as the gap it described. A program that sets mode 1004 expects
`CSI I` when the terminal gains focus and `CSI O` when it loses it. vim's `FocusGained`/`FocusLost`
is what makes `autoread` notice a file another window wrote; tmux's `focus-events` forwards the same
edges to whatever is inside it; a full-screen picker dims itself on blur. All of them were behaving
as though this window were never left.

`VtSession::set_focused` closes it: it ASKS `Mode::FOCUS_EVENT` and encodes through
`libghostty_vt::focus::Event` into the queue a device-status reply already uses. Asking is not
defensive politeness — `CSI I` delivered to a parser that did not opt in is a bare `I` typed into
whatever line it was reading, so a terminal that reports unconditionally corrupts the input of every
program that never asked. The edge is detected inside that door rather than left to the caller,
because a view pushes its focus from `didMoveToWindow` and from every layout pass: idempotent on the
painter's side, one report per pass on the program's.

**The focus flag moved INTO the session, and that is the part worth reading.** The obvious shape —
the caller owns the flag and calls a `report_focus(focused)` — cannot answer the second half of the
protocol, and reading ghostty is what showed the second half exists: `stream_handler.zig` replies at
the moment mode 1004 is TURNED ON, with the focus the terminal already has. So a program that
enables focus reporting mid-run knows immediately whether it is focused, instead of waiting for the
user to click away and back. Answering that means being asked from inside a feed, which means the
session holds the flag. ⚠️ One honest difference remains and is written at the function: our
granularity is the FEED rather than the escape sequence, so a `1004l` and a `1004h` in the same
write cancel instead of reporting. Closing it needs a mode-change push the C ABI does not have.

**The survey's third pass found the shipped scrollback was a tenth of what the settings promised.**
`slopdesk_term_surface_set_scrollback` takes LINES, and its own doc said why — the door exists
because the path before it estimated 256 bytes per line to reach ghostty's byte-only
`scrollback-limit`, so "10 000 lines" bought somewhere between 5 000 and 40 000. Saying lines was not
enough to make lines true. The engine carries TWO caps, on bytes and on lines, and prunes at
whichever is reached first; its byte cap ships at 10 000 bytes, which is one page. MEASURED, at 80
columns with the shipped factory default of 10 000 lines: **1065 rows kept**, against **9930** with
the byte cap cleared. Every user of this terminal has had roughly a thousand lines of history while
the settings file said ten thousand, and nothing failed — the number was simply never checked against
the engine that enforced it.

`VtSession::set_scrollback_rows` now clears the byte cap whenever a line cap is set, and its
signature lost the `Option` that let a caller ask for the engine's default instead of stating a
depth. Lines bound the memory because lines are what the caller states; a byte cap underneath them
can only take back history the user was promised. Clearing it costs nothing on the parser — a
20 000-line feed measured 11.2 s in a debug build with the cap and 11.2 s without, to three digits —
and `the_configured_depth_is_the_depth_the_session_keeps` pins the ratio so the next bindings bump
cannot quietly restore it.

**Deeper history is what makes ghostty's idle compression worth taking, so it arrived in the same
pass.** The engine compresses fully historical pages — behind the viewport, drawn by nothing — and
restores them transparently the instant a scan, a search or a scroll reads one; ghostty's own
configuration puts text-heavy history at 10–30% of its uncompressed page memory. It is opt-in in the
sense that somebody has to call it, and the caller is the one who knows whether the user is watching
a `yes` flood or has walked away.

The split is ghostty's and so are the numbers: `renderer/Thread.zig`'s `Compression` postpones a
one-shot timer on every wake, 250 ms of quiet before a pass and 1 ms between the bounded steps of one
already running. What is OURS is where the policy lives. `slopdesk_vterm::compression` holds both
intervals and the engine's activity token, and `VtSession::compress_step` answers the caller with a
delay in milliseconds — so `TerminalSurfaceDriver` owns one cancellable task, arms it after a feed
only when nothing is armed, and re-arms at whatever came back until the answer is "nothing left".
The Swift half carries no interval of its own, and the token comparison stays on the side that can
tell "a historical page changed" apart from "a full-screen program repainted itself", which a feed
count cannot.

⚠️ **Not the display link, and that was the tempting shape.** A per-frame tick is already running and
already costs nothing extra — but it stops when the view leaves the window, which is exactly the pane
worth compressing: the background tab still taking output that nobody is looking at. A timer runs
whether or not anyone is watching, which is the whole point.

⚠️ Compression is HARDWIRED ON, with no setting. ghostty ships it on and recommends leaving it on;
it changes storage and never contents, so there is no behaviour for a user to prefer — only a memory
bill to pay or not pay. The setting-shaped knob here is the DEPTH, which already exists.

### The title report stays shut, and the pin says why (2026-09-01)

`libghostty-vt` exposes `set_title_report_enabled`, and the engine ships it OFF with its reason
written into the binding: a program can SET a window title (`OSC 2`) and then ASK for it back
(`CSI 21 t`), which puts a string the program chose into the pty's INPUT stream, where a newline in
it is a line executed at the shell. Every terminal that ever answered that query has carried the
same hole.

This crate does not turn it on, and the difference from "we never called the setter" is a test:
`a_program_cannot_read_its_own_title_back_into_the_pty` feeds both sequences and asserts the pty
queue stays empty. The refusal has more weight here than in a local terminal — the program is on the
REMOTE host and the shell it would be typing at is the user's own machine, which is the same
argument that closed the kitty `t=f`/`t=t`/`t=s` transmission mediums. The title itself is
untouched: `VtSession::title` still reads it and the tab still shows it. What is refused is the
report, not the string.

### Evaluated and NOT taken from the bindings, with the reason each (2026-09-01)

Four `Terminal` doors were read in the same survey and deliberately left alone. Recording them so
the next survey does not re-derive the same answers:

- **`set_apc_max_bytes`** — the engine already carries a built-in cap on APC buffering, and the
  binding documents `None` as "revert to the built-in defaults". Overriding it would mean this
  crate inventing a number for a limit ghostty tunes against real kitty-graphics traffic; the core
  follows ghostty, so the number stays ghostty's. It is not an unbounded buffer — that was the only
  question worth asking.
- **The snapshot module (`GHOSTSNP`)** — encodes a whole terminal, unfinished parser state and all,
  which is exactly the shape a client ATTACHING mid-session wants instead of a byte replay. It stays
  out because the format's own header says "version 1 is a work in progress and does not yet carry a
  binary-compatibility guarantee", and this project's wire is golden-pinned: a format that may change
  under us cannot cross it. Revisit when the format is declared stable — the shape is right, the
  timing is not.
- **The continuation APIs** — the same unfinished-parser bytes, exportable on their own. They are
  tracking-OFF by default and their value is realized through the snapshot; taking them alone would
  buy a retained buffer per pane for a consumer that does not exist yet.
- **`set_default_mode`** — sets what a mode returns to after `RIS`. Every mode this app cares about
  is one a program drives; a default we imposed would be a divergence from ghostty that no setting
  asked for.

## The code-server / baguette bump, and the tail it carries (2026-09-01)

`code-server` **4.131.0 → 4.135.0** (Code 1.131 → 1.135) and `baguette` **0.1.88 → 0.1.97**, both
sha256-pinned in `ThirdParty/tools/tools.lock` and verified by re-downloading each archive and
hashing it rather than by trusting a release page. `adb` (37.0.1) is already upstream's latest;
`scrcpy-server` and the ghostty pin are unchanged.

`docs/46` says a `code-server` bump has a tail, so the tail was walked rather than assumed:

- **`CLIPPED_TITLE_BAR_HEIGHT` stays 30.0 — MEASURED, not carried over.** A 4.135.0 workbench was
  booted on a throwaway profile seeded with `slopdesk-codeseed`'s own `resources/settings.json` (the
  activity-bar-at-top layout is what forces the title bar to show at all) and
  `#workbench.parts.titlebar`'s `getBoundingClientRect().height` read **30**, with the activity bar
  at 0 as expected. It went 35 → 30 across 1.112 → 1.131 and has not moved since.
- **All 38 seeded keys are still registered.** Checked against the shipped 1.135 workbench bundle.
  ⚠️ Four of them — `editor.glyphMargin`, `editor.hideCursorInOverviewRuler`,
  `editor.lineNumbersMinChars`, `editor.overviewRulerBorder` — do NOT appear as full dotted literals
  anywhere in `out/`, because core editor options are registered by concatenating `editor.` onto a
  bare name. A literal grep for the dotted key reports them missing and is wrong; grep the bare name.
  Anyone re-running this check will hit the same false positive.
- **Spawn → listening: 0.54 / 0.59 / 0.69 s** over three runs with a throwaway `HOME`
  (`slopdesk-ops measure-code-server 3`), against the ~0.4 s warm / ~1.2 s cold recorded when this
  chain was first timed. Inside the old envelope; the prewarm architecture above is unchanged.

## The per-block context menu, and the two keys a block wears (2026-09-01)

Right-clicking inside a command block now offers that block's own verbs — Copy Command, Copy Output,
Re-Run Command, Collapse/Expand, Bookmark — prepended above the standard menu. It is Warp's shape and
it closes the last Warp-parity gap the block work left: every model-layer piece already existed
(per-index output requests, `rerun_bytes`, the bookmark set), and the menu was the missing door.

**The pane-global "Copy Command Output" was NOT replaced.** It acts on the LATEST block because it is
also the keyboard verb and a keystroke has no pointer; the new section acts on the block under the
pointer. Warp keeps both, for that reason. `docs/68` §5.10 has the architecture.

Three decisions inside it are worth keeping written down, because each looks like an implementation
detail and is not:

- **The menu is keyed by the prompt ORDINAL, never the layout index.** The layout is a positional
  vector, the fold state is a parallel one, and output arriving while a menu is open re-segments both.
  An index captured when the menu was built can fold or copy a block the user never clicked — a
  silent wrong action, which is the failure class the block join is already built to avoid. So
  `slopdesk_term_surface_block_target` answers the ordinal and
  `_toggle_block_collapsed_at_ordinal` resolves the index again at action time. The alternative
  considered — stash the index and document the race — was rejected: it costs about ten lines to do
  it properly, next to code the change was touching anyway.
- **It acts on the CLICKED pane's model, not on `WorkspaceStore`'s active-pane conveniences.** A
  right-click on macOS does not necessarily focus the pane it lands in, so
  `copyBlockOutputInActivePane` / `reRunCommandInActivePane` would have copied from — or typed into —
  a different pane than the one aimed at. Those stay for the keyboard and palette callers that
  genuinely mean "the focused pane".
- **⚠️ Re-Run is gated by the read-only lock in two places, on purpose.** It writes to the pty.
  `TerminalViewModel.sendInput(_:)` drops the bytes at the single outbound seam and that is the
  enforcement; the menu greys the row so the affordance agrees with it. An item that looked live and
  then beeped would teach the user that the per-pane lock is advisory. `reRunCommand(_:)` became the
  one re-run implementation all three callers share while this was checked, so `BlockReRunEncoder`'s
  verbatim-UTF-8 rule (strip trailing CR/LF, append exactly one `0x0A`, NEVER `SendKeysParser`) is
  spelled once rather than at each call site.
- **A block with no ordinal gets no section, rather than a section with one live row in it.** Keying
  by the ordinal means an unnameable block — a mid-stream attach, or an alt-screen program with no
  prompt rows — cannot be acted on at all, the fold included: the fold resolves an ordinal too. The
  first cut let the section draw there with Collapse live, which would have been a row that greys
  nothing, clicks fine and does nothing. `blockTarget(at:)` refuses a zero ordinal instead, at the
  one seam both shells go through. A block that IS named but whose record the client ring has since
  dropped is a different case and keeps its fold, which is why the enablement still reads `joined`.

Also corrected in the same pass: `docs/ui-shell/current-state/terminal-features.md`'s **Cut** row
claimed ⌘X's delete half "counts zero because the GUI passes `selectionEndsAtCursor: false`". That
has been false since the door landed — `TerminalRendererSurface.selectionEndsAtCursor()` →
`slopdesk_term_surface_selection_ends_at_cursor` → `Frame::selection_ends_at_cursor`, with tests, and
both shells pass the real answer. Note 2 in the same file had already recorded the closure; the table
rows had not caught up. The stale claim is the kind that survives an audit because the row reads as a
measurement, so it is named here as well.

## The four files that could blow an agent's context, cut at their own seams (2026-09-01)

The user's ask was plain: *"có mấy cái file của mình đang dài quá, chia nhỏ ra cho tôi được không. Chứ
không agent chỉ lỡ đọc toàn bộ file cái là tràn context"* — some files are long enough that reading one
whole is a context accident. That is a different complaint from "this type does too much", and the cut
follows the complaint rather than the usual refactoring instinct: **nothing moved between concerns, every
seam was one the file had already drawn for itself.**

Four cuts, biggest first, because the biggest is also the one `CLAUDE.md` tells every agent to read:

- **`docs/DECISIONS.md`, 19 057 → a 483-line INDEX** over `docs/decisions/vol-01.md … vol-14.md`. Volumes
  are packed to ~1 500 lines and never split a `## ` section, so a `§"…"` citation still greps the same
  words; the index lists every section title as a link, and the header states the rule for a new ruling
  (append to the last volume, add the index line in the same change). Round-tripped against
  `git show HEAD:docs/DECISIONS.md` — the content is byte-identical after re-rooting `../` links.
- **`rust/slopdesk-ffi/src/workspace.rs`, 4 901 → a directory module** of 7 files, largest 1 244. The seams
  are the file's own `// MARK:` banners: `panes` (bytes in), `rows` (what the sidebar reads), `tree`,
  `codec`, `file`. `mod.rs` keeps the argued header and the flat shapes every child names, and re-exports
  the addresses the rest of the crate already learned — a door's path is part of its contract.
- **`rust/slopdesk-ffi/src/terminal_surface.rs`, 4 326 → a directory module** of 6 files, largest 984.
  `mod.rs` keeps the STATE (`Surface` and its arithmetic) because every child reaches it and a child that
  owned part of it would be the second writer of the contents scale the header argues against; the
  children are the doors over it — `doors`, `pointer`, `reading`, `blocks`.
- **`WorkspaceStore.swift`, 3 710 → 2 973**, by moving its four trailing `public extension` blocks to
  `WorkspaceStore+{LayoutDrags,Search,LiveSession,NewPane}.swift` — the pattern 25 sibling files already
  set. This one is not free and the price is named: a Swift extension in another file cannot see the
  class body's `private` members, so **nine** of them widen to module-`internal` (`lastSolvedLayout`,
  `lastContainerBounds`, `projectGitInFlight`, `globalSearchSourceCache`, and the `private(set)` setters
  of `isInteractiveResizeActive` and the four `globalSearch*`), and two members that moved out
  (`refreshCwd`, `treeGeometryBounds`) widen the same way for the callers that stayed. That is
  consistent with a body where 37 members were already implicitly internal — but `registry` is NOT
  among them: its own comment books it file-private behind the `handle(for:)` accessor, so the moved
  Search code calls that accessor instead. **A documented boundary is not a line-count cost to pay.**

**The line numbers in every `DECISIONS.md:NNN` citation are gone, not re-derived.** 47 of them across
10 docs pointed into the old monolith. Re-pointing them measured how much they had already drifted:
0 to 20 lines, *inconsistently*, because the log's preamble grew under citations that were never
re-checked. A silently-wrong anchor is worse than none, and the index now makes the section TITLE the
address — most of these citations already carry a `§Title` or a quotation, which greps. Cite the title
from here on, never a line.

**Where the cutting STOPS, and why that is a ruling and not an omission.** `TerminalViewModel.swift`
(2 779) and `SlopDeskVideoClientSession.swift` (2 354) are monolithic type BODIES with no top-level
extension seam. Splitting either means extracting members into cross-file extensions, and a Swift
extension in another file cannot see the class body's `private` members — so every extraction widens
`private` → `internal` across an observable type. That trades encapsulation for line count, which is a
different and worse bargain than the four cuts above, and both files are additionally pinned BY PATH in
several `slopdesk-invariants` rules. They stay whole. If they grow, the answer is to move behaviour out
of the type, not to spray its innards across files.
