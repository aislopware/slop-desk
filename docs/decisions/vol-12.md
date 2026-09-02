# DECISIONS vol-12 — 2026-08-11 … 2026-08-17

> Volume 12 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## `workspace = true` was accepted as a policy without checking the workspace (2026-08-16)

The unsafe-crate ratchet is the right idea and was checked the wrong way. It gates MANIFESTS rather
than source, because what rustc cannot notice is the shape drifting back — and it accepted three
answers: the exempt list, `unsafe_code = "forbid"`, or the line `workspace = true`.

That third answer only means something for a crate that inherits from the ROOT workspace, and only
because the root is in the same loop and must state `forbid` itself. Almost every crate under `rust/`
is its OWN `[workspace]` root. For one of those, `[lints] workspace = true` says nothing about the
policy: the crate can carry `[workspace.lints.rust] unsafe_code = "allow"` beside it and inherit
permission, and the gate reads the same line and passes it. Measured on the real predicate, with
`slopdesk-sanitize` mutated to say `allow` and inherit: OLD rule accepted, NEW rule rejects it by
name. Deleting the line entirely instead of setting `allow` — a manifest that states no policy at
all, which is `allow` by default — was accepted the same way.

Two changes. Inheritance is now accepted only from the root, and the member list is READ OUT of
`rust/Cargo.toml` rather than kept beside it — a hand-kept copy of the members is a second list to
forget, and the gate fails if that list does not parse rather than silently accepting every
`workspace = true` again. And a stated `allow`/`warn` anywhere in a manifest is decisive whatever
else it also says, because the narrower `[lints.rust]` table wins over `[workspace.lints.rust]`: a
`forbid` above one of those is not protection, it is camouflage.

The invariant itself was verified while doing this and holds — exactly three crates state `deny`
(`slopdesk-posix`, `slopdesk-ffi`, `slopdesk-gfsimd`), thirteen state `forbid` in their own manifest,
and four (`slopdesk-hook`, `-ctl`, `-cli`, `-probe`) inherit the root's.

### The type-byte gates covered four ABI enums and none of the four wires (2026-08-16)

`compare_abi_enum` existed and was pointed at `AlignEdge`, `FocusDirection`, `ResizeAnchor` and
`LayoutPreset/TileLayout` — four enums that cross the FFI boundary as a single byte. Every one of
those is a small, closed set nobody appends to. Meanwhile the maps that actually carry traffic, and
that a new feature DOES append a case to, had no gate at all:
`WireMessage.messageType` (29 cases, the primary wire) and the video wire's three —
`VideoControlCodec` (28), `RecoverySignaling` (6), `WindowGeometryCodec` (4). All four have a Rust
twin spelling the identical claim a second time, and all four agreed at the time of writing, which
is the only reason this reads as a near miss rather than an incident.

The failure this gates is not a decode error. Both ends parse a length-prefixed frame and switch on
byte zero, so a case numbered differently at the two ends produces a frame that decodes CLEANLY as
the WRONG message — the exact shape the metadata-verb gate two hundred lines above already exists
for. The widest map is the most exposed: appending to a 28-case switch is where a number gets
reused, and neither compiler can see the other one's list.

`compare_abi_enum`'s Rust extraction had to widen to reach them. It matched only `Self::Case => N`,
where these three spell `Self::Hello { .. } => 1` and `Self::Move(_) => 1`; a payload pattern read as
no match, and a no-match on a whole file is the EMPTY-map case, which the function already fails on
loudly. So the widening was found by the guard rather than by a silent pass — the one part of this
that worked as designed.

Each of the four was planted against in both directions: a renumbered case reports the
disagreement, and a renamed marker (`messageType` → `wireTagByte`) reports that the map read empty
rather than reporting agreement.

Swept the rest of the tree for hand-written byte maps afterwards. What remains is `radius` and `y`
in `SlateDesign.swift` — `CGFloat` design tokens, not bytes — and `rank` in `SimulatorDeviceKind`
and `AndroidDeviceKind`, a UI sort order with no twin anywhere. No gate is owed on those; the
similarly-named `fn rank` under `slopdesk-ffi` ranks folders and is unrelated.

### The byte-at-a-time mux test compared two empty vectors (2026-08-16)

Swept the golden corpus for the zero-iteration shape — a loop over a section that would pass by
never running. Swift is clean: all nine `GoldenCorpus.load` sites assert a case count, and
`golden-check.sh` already reports that every frozen key has a suite replaying it, which is the
liveness check on the other end. Rust's corpus tests are guarded too, with one exception and one
near-miss.

The near-miss is `the_pinned_unknown_discriminants_are_carried_verbatim`, which looks unguarded and
is not: it counts matches into `seen` and asserts `seen == 2` at the bottom, which is the stronger
check — it survives the section being non-empty but having lost exactly those two vectors.

The real one is `the_pinned_mux_corpus_survives_being_delivered_one_byte_at_a_time`. It builds a
byte stream from `muxEnvelopes`, feeds it one byte at a time, and ends at
`assert_eq!(collected, expected)`. With an empty section both sides are empty and it passes. A
renamed section still panics on `as_array().expect`, so the reachable hole is narrow — the section
present and empty — but the cost is not: this test is, by its own doc, the ONLY check that the
decoder finds the right boundaries in a stream carrying no framing of its own. Now asserts at least
two pinned frames, because the premise needs two: one frame cannot share a read with anything.

### Half a ban is not a ban (2026-08-16)

`docs/46` records two env gates as deleted deliberately, do not reintroduce —
`SLOPDESK_WORKSPACE_DOC` and `SLOPDESK_PANE_FANOUT` — because multi-client sync is unconditional: a
client draws its layout FROM the workspace document, so a host that switched the channel off would
hand it a blank window and no error, the worst shape a kill switch can take.

Only one of the two was enforced. `SLOPDESK_WORKSPACE_DOC` has a ratchet written as a test —
`testTheWorkspaceChannelIsServedWithTheEnvironmentSetToZero` sets it to 0 and proves the document is
served anyway, which is stronger than a name ban because it pins the BEHAVIOUR. `SLOPDESK_PANE_FANOUT`
had nothing at all: the doc's sentence was the whole enforcement. Both names are now banned from
`Sources/` by the supervisor, shipping code only — the test that spells the surviving name is the
enforcement of the ban, not a breach of it.

### The header/library check ran one way only (2026-08-16)

`build-ffi.sh` reads every `slopdesk_*(` out of `slopdesk_ffi.h` and fails if the assembled slice
does not export it — a header that promises what the library lacks fails at build rather than at app
link, or worse at runtime on one platform only. That direction was sound. The other was never asked.

A symbol the library EXPORTS but the header never declares is not a link error and never will be. It
is a door with no handle: the port shipped, it pays for its bytes in a 37 MB archive, and no Swift
line can reach it. Neither compiler can see it — rustc treats a `pub extern "C"` item as used by
definition (which is why the 115-item dead-`pub fn` sweep could not have found these either), and
Swift never hears the name at all. It is the exact residue a half-finished port leaves.

Measured before gating: 784 declared, 784 exported, an exact bijection. So this adds no cleanup —
it holds a correspondence that is currently perfect and had nothing keeping it that way.

Two things went wrong writing it, both worth the reader's time. The first draft compared a stripped
symbol list against `REQUIRED_SYMBOLS`, whose entries carry the leading underscore the linker uses.
`comm` compares LINES, so mismatched shapes do not report everything — they report whatever the two
sort orders happen to interleave, and this one surfaced a single name that was in fact declared on
header line 3528. A gate whose first output is a false positive is the good outcome of that mistake;
the same bug on the other `comm` argument would have reported nothing and read as a pass. The second
was the negative test itself: the planted door failed to COMPILE (`no_mangle` needs the
`expect(unsafe_code)` every real door carries), and a non-zero exit from the wrong cause is not a
passing negative test. Re-planted with the attribute, the gate named `_slopdesk_probe_undeclared_door`
and failed.

### "Skipped, loudly" was not loud (2026-08-16)

`VirtualDisplayGoldenVectorTests.testRefreshRateVectorsStillHold` guarded a known-stale corpus key
with `XCTSkipUnless` and a paragraph explaining that the skip was the announcement — three of the
five `vdRefreshRates` vectors predate `6281fae2`'s 2×-oversample mode, refreshing a frozen vector is
the owner's call, so the test stepped aside and said why.

It said why to nobody. `make test` runs `swift test --parallel`, which prints one progress line per
test and no skip reason at all, and `--xunit-output` records a skipped case as a plain passing
`<testcase>` — so the machine-readable half loses it too. Measured on the full run: the reason string
appears zero times in 11,455 lines of output, and the test's progress line is indistinguishable from
the 7,559 that passed. Run alone, without `--parallel`, XCTest prints it in full. The loudness was
real and the gate that ships never showed it.

A skip nobody can see has the same shape as the stale vector it was announcing, which is the failure
this whole suite was revived to prevent.

The fix needs no corpus edit and therefore no owner's call: the test RUNS, and pins the disagreement
instead of hiding behind it. `knownStale = [60, 90, 144]` is asserted as an exact SET, and the
remaining two cases are compared for real. Both directions now fail loudly — refreshing the corpus
makes `knownStale` wrong and says so, and a new drift on 30 or 120 is a plain mismatch. Planted
against by narrowing the set to `[60, 90]`: two failures, the set assertion naming what moved and
the vector assertion naming fps 144.

The general fact is worth more than the one test: ~60 `XCTSkip` sites exist, most of them legitimate
environment guards (daemon not built, font absent, snapshot env var unset), and under the shipped
run mode not one of them can report itself. `make test` mitigates the important ones by DEPENDING on
the daemon build targets rather than detecting the skip afterwards — prevention, not detection. Do
not write "skipped, loudly" again; under `--parallel` there is no such thing.

### clippy runs per workspace, and the list of workspaces was hand-kept (2026-08-16)

`make lint-rust` cannot lint `rust/` in one command. Almost every crate there is its OWN `[workspace]`
root — sixteen of them — and cargo will not cross a workspace boundary, so the recipe carries a
`cd rust/<crate> && cargo clippy` line per crate plus one for the root. That is a hand-kept list
sitting beside a derivable fact, which is the shape this file has now found four times
(`root_members`, the gate path variables, the FFI input crates, this).

The counts agree today: sixteen own-roots, sixteen recipe lines, plus the root's `--workspace` run,
which is the seventeen the target's own help text claims. Nothing kept them agreeing. A crate added
tomorrow and not added to the Makefile is never seen by clippy, and the miss is silent in the worst
way — `make lint-rust` still passes, and passes FASTER.

The supervisor now derives the left side: every `rust/*/Cargo.toml` that declares `[workspace]` must
be named by a clippy line in the Makefile. Planted against by deleting `slopdesk-wire`'s line — the
gate names the crate and says clippy has never seen it.

### And the same list again, in the target that runs the tests (2026-08-16)

The clippy gate above has a twin: `make test` must reach every crate that carries tests. A crate
nobody lints has a missing opinion; a suite that never executes is a green report about code nobody
exercised, which is strictly worse.

The first draft read the `<short>-test` names off `test:`'s prerequisite line and reported
`slopdesk-sanitize` as untested. It is not: it has no target of its own, and its 138 tests run inside
`screend-test`. So the predicate was wrong, not the tree — recipe-reading cannot answer "what would
`make test` actually run" no matter how carefully it is done. `make -n test` answers it exactly, in
30 ms, and is what the gate asks now. Twenty crates get a `cargo test`: sixteen own-workspace roots
entered by `cd`, four root members by `-p`.

Two other things this cost, both worth writing down. The first draft walked `rust/<crate>` looking
for `#[test]` and descended into `target/` — ~2 GB per crate of build output that also contains
`#[test]`. It got the right answer and took minutes to do it, inside a gate that runs on every lint;
scoped to `src` and `tests` it is instant. And the first attempt to plant a failure ran
`perl -0pi -e 's/ wire-test / /'` over the whole file, which hit the `.PHONY` line at 193 and left
`test:` at 448 untouched — a negative test that changes nothing reports exactly like a gate that does
not work, and the only way to tell them apart is to check that the plant landed.

### SwiftPM ignores an undeclared directory, and says nothing (2026-08-16)

The Rust half of this — clippy and `make test` reaching every crate — has a Swift twin nobody had
asked about. SwiftPM builds the targets `Package.swift` declares. A directory under `Tests/` or
`Sources/` that no target names is not an error and not a warning: it is simply not there.

For `Tests/` that means a suite nobody runs, the same shape as the Rust one. For `Sources/` it is
worse. The directory is never COMPILED, yet `swiftformat` and `swiftlint` still walk it — so it keeps
passing `make lint`, keeps getting formatted, and reads as maintained code that nothing links. The
only symptom is the absence of one.

Both sides are exact today (17 test directories / 17 `testTarget`s, 39 source directories / 39
targets) and now both are derived rather than assumed. Planted against in both halves: an
undeclared `Tests/SlopDeskProbeOnlyTests/` and an undeclared `Sources/SlopDeskGhostModule/` are each
named and rejected.

### The lint scope was `git ls-files`, so five scripts had never been checked (2026-08-16)

`SHELL_FILES` and `PY_FILES` were derived with `git ls-files '*.sh'`. Tracking is not ownership, and
using it as a proxy for "files this repo is responsible for" fails in one direction only — silently,
and against exactly the files most likely to be new or in flight.

Five scripts under `scripts/` are untracked, so `git ls-files` never named them, so `shellcheck` had
never run on any of them and `make fmt-shell` had never touched one: `check-supervisor.sh` and
`build-ffi.sh` among them — the ratchet this repo leans on hardest and the script that assembles the
FFI artifact. A lint scope that shrinks when a file is new is exactly backwards.

Nothing was broken underneath. Run for the first time, shellcheck reported 22 findings in
`check-supervisor.sh` and zero in the other four, and all 22 were style-level: sixteen SC2046 on the
`$(repo_files …)` idiom where the word-splitting IS the argument list, two SC2016 where the single
quotes hold a regex, one SC2086, one SC2231, and two `tr 'A-Z' 'a-z'` pairs. The four real ones were
fixed (`[:upper:]`/`[:lower:]`, a quoted glob); the rest carry a per-site `disable` naming the code
and the reason. Per-site, not a file-level blanket — a blanket would hide the next SC2046 that is
NOT the idiom, which is the same trade this file keeps refusing elsewhere.

The scope now reads the filesystem: `$(wildcard scripts/*.sh)` plus `ThirdParty/tools/provision.sh`,
and `$(wildcard scripts/*.py)`. All 25 previously-tracked shell files and all 3 Python files already
lived there, so nothing left the scope — 60 shell files are checked now where 26 were.

One consequence worth predicting, because it happened: `shfmt` reformatting `build-ffi.sh` made the
FFI artifact stale by that script's own definition (it hashes ITSELF into the stamp, deliberately),
so the supervisor failed on the next run and `make ffi` was the fix. The staleness gate firing on a
whitespace-only edit to the builder is correct — the script decides which slices exist and which
symbols they must carry.

### The green-tree cache could not see the artifact the suite links (2026-08-16)

`pre-push-test.sh` skips `swift test` when `git rev-parse HEAD^{tree}` matches the recorded last-green
tree and nothing under `Package.swift`/`Sources`/`Tests`/`Apps`/`golden` is dirty. Both halves are
sound about SWIFT: `git status --porcelain` reports untracked files too, so a new file in `Tests/`
invalidates properly.

Neither half can see Rust. The suite links `SlopDeskFFI.xcframework`, `rust/` is not in the
tested-inputs list, and adding it would not help — the tree is untracked, so `HEAD^{tree}` is byte
identical before and after a Rust edit. On a CLEAN tree the sequence is: edit `rust/`, run
`make test`, watch its `ffi` prerequisite rebuild the artifact, and then watch the Swift half report
"already tested green" for a suite that never ran against what was just built. That is the linked
port's one failure mode — a Swift side calling last week's logic with every test green — one level
above the `build-ffi.sh --check` gate that exists to prevent it.

Not reachable in this working tree today, and only because it is dirty: `tested_inputs_clean` is
false, so the cache never engages at all. It is reachable on any clean checkout, which is the state
this cache was written for.

The key is now `HEAD^{tree}` plus `ThirdParty/slopdesk-ffi/sources.sha256` — the stamp `build-ffi.sh`
writes as the hash of every Rust input plus its own text, which is exactly the right witness and
already exists. Absent artifact reads as an empty half rather than an error.

The stamp lives in its OWN marker, `.build/pre-push-green-ffi`, and that detail is the whole lesson
of the first attempt. Concatenating it onto `pre-push-green-tree` broke `test-touched.sh`, which
reads that file as a git REF — `git cat-file -e "$(cat …)"` and `git diff "${base}"`. A marker with a
suffix stops being an object id, so the fast inner loop would have failed its baseline check and run
the FULL suite for ever: a "safe direction" regression that costs ~100 s on every inner-loop run and
announces itself as a normal escalation message. A marker is an interface; two readers had already
agreed what it holds.

`test-touched.sh` needed the stamp for its own sake as well. Its selection diffs the working tree
against the baseline tree over `Sources`/`Tests`/`golden`/`scripts` — a pathspec that cannot see a
Rust edit for the same reason `HEAD^{tree}` cannot, and the SwiftPM dependency closure cannot rescue
it either, since targets link the xcframework through the package graph rather than through a
changed file. It now escalates to FULL when the stamp differs from the last full green, and writes
BOTH halves when it records one — the tree marker alone would claim a green that the artifact half
then denies.

## The other linked artifact does not need the gate mtime said it did (2026-08-16)

Right after the green-tree cache was taught to see `SlopDeskFFI.xcframework`, the same question was
asked of the repo's *other* linked artifact — `ThirdParty/ghostty/libghostty.xcframework`. It has
none of the protection: `build-libghostty.sh` writes no stamp, offers no `--check`, and no Makefile
target invokes it. The artifact is gitignored, so nothing rebuilds it and nothing complains.

The mtimes looked damning. The artifact was built `Jul 14`; `build-libghostty.sh` is dated `Aug 10`
and `integration/GhosttySurface/GhosttySurface.swift` `Jul 22`. Two inputs newer than the output is
the exact shape the FFI gate exists to catch.

Neither is an input. `integration/` is Swift the *app* compiles — `build-libghostty.sh` never reads
that path, so it cannot make the archive stale. And the one commit that touched the script since the
build, `77ff99e8`, changed four comment lines and nothing else: every `+`/`-` line outside the diff
header begins with `#`. The archive matches its sources.

So the finding is a negative one, recorded because the *signal* will recur: mtime is not content, a
`git checkout` reorders it freely, and "newer than the artifact" was weak evidence that read as
strong. The reason no `--check` gate was added is not that staleness is impossible here but that the
cost is upside-down — it is a Zig build measured in minutes, wired into `make lint`, to protect a
tree that is tracked (so `HEAD^{tree}` already sees every change to it, unlike `rust/`) and that is
edited a few times a year. The FFI gate is cheap because `shasum` over a file list is cheap. Revisit
if the vendored delta starts moving, or if `build-libghostty.sh` ever gains a real input list.

One more fact settles it: `.github/workflows/release.yml` runs `ThirdParty/ghostty/build-libghostty.sh`
as a build step, so what ships is built from source every time. A stale local artifact costs a
developer a confusing afternoon; it cannot reach a release. The FFI artifact has no such backstop —
`make ffi` is local-only — which is why the asymmetry in gating is the right one.

## The read-first doc gate watched one of the five docs the table names (2026-08-16)

`check-supervisor.sh` checks that every file path a read-first doc cites still exists, and it builds
the read-first set off `CLAUDE.md`'s own table rather than a second list — the right instinct, and
the reason it was worth reading twice.

It matched `docs/[0-9]{2}[a-z0-9-]*`. The sidecar row is written

    | a sidecar daemon | `docs/51` superd · `52` screend · `53` dropd · `54` inspectord · `48` androidd |

so four of the five docs on that row carry no `docs/` prefix and were never in the set. Ten docs went
in where fourteen should have. Nothing was wrong in the four today — every path they cite exists —
which is the point: the gate's pass state is an empty `doc_missing`, and four unwatched docs print
exactly like four clean ones. The extraction now reads both spellings.

A token that resolves to no file used to be dropped in silence by the same loop. That is a doc the
table sends readers to and that is not there, so it fails now.

The "rooted at a real top-level directory" bound was a hand-written alternation, and it had drifted
in both directions at once: `manifests` and `research` are gone, so two of its ten branches could
never match, while `hid-bridge` — a real top-level tree — was never in it, so a citation into that
tree was exempt without anyone deciding it should be. It is read off `ls -d */` now. Sixth time in
this audit that a hand-kept list stood beside a fact the filesystem already had.

## `make lint-swift-analyze` had never run an analyzer rule (2026-08-16)

`.swiftlint.yml` sets `analyzer_rules: all`, and the Makefile carries a target to run them. The
target read `.build/debug.yaml`, which is llbuild's build MANIFEST, not a compiler log. SwiftLint
took the path without complaint, collected nothing out of it, and printed

    Done analyzing! Found 0 violations, 0 serious in 0 files.

Exit 0, over an empty file set. The recipe's `|| echo "note: run 'swift build -v | tee build.log'…"`
was written for exactly this case and could never fire, because nothing had failed — and the note
names the correct command, so the recipe knew the right answer and ran the wrong one. Every analyzer
rule in the config had been unenforced since the target was written, reporting green each time.

The same page already carries the lesson, six lines above `lint-shell`: "the `|| true` that silences
THAT silences every real diagnostic with it: the tool prints its findings and the gate still passes."
This was that failure reached from the other side — not a swallowed error, a success with nothing
behind it.

Fixed by capturing a real `swift build --build-tests -v` log, dropping the `|| echo`, and asserting
the file count in the summary line: a run that analyses zero files fails. The analyzer's own exit
status is the target's, which is why the log is written to a file and printed afterwards rather than
piped through `tee` — a pipe hands make `tee`'s status and re-opens the hole one line lower.

It stays out of `make lint`. On this tree it collects 753 files and takes minutes, not seconds, and
"heavier, run on demand" was always the right call about the cost. It was the honesty that was wrong.

## The push gate did not fire for the two inputs most likely to break it (2026-08-16)

`scripts/pre-push-test.sh` is wired into prek as the `swift-test` pre-push hook, and the hook's
`files:` regex was `^(Sources|Tests|Apps)/.*\.swift$`. A `files:` regex is not a filter over an
already-running gate — it decides whether the gate runs at all. So a push whose commits touched only
`rust/` skipped the Swift suite entirely, and the suite LINKS `SlopDeskFFI.xcframework`: exactly the
blind spot the green-tree cache had inside the script until the artifact stamp joined its key, one
level up and still open. `golden/` and `Package.swift` were in the same position.

`scripts/` was the sharper one, because it was already known elsewhere. `test-touched.sh` maps a
`scripts/` change to `SlopDeskClientUITests` — `LaunchRestoreGateContractTests` and
`GuiGateLaunchContractTests` open `scripts/*.sh` and `scripts/fixtures/` off disk at run time, with a
comment saying so. The fast inner loop knew about that input; the push hook did not, and neither did
`tested_inputs_clean`, which is what decides whether a green may be RECORDED. A green written over a
dirty `scripts/` is a green about text nobody ran.

The regex now names every input the suite consumes, and both cleanliness checks name `scripts`.

Both scripts write `.build/pre-push-green-tree`, so the input list existed in two copies and now has
a ratchet: `check-supervisor.sh` extracts the `git status --porcelain --` pathspec from each and
fails if they differ, and does the same for the set of `.build/pre-push-*` markers each file names.
The marker half started as `grep -qF pre-push-green-ffi` per script and was rewritten after a
negative test: a rename to `pre-push-green-ffi-stamp` passes a substring check, so the check would
have survived precisely the edit it exists to catch. Sets, not spellings.

The gate-death ratchet then failed the first draft of that block for a nested `$(grep …)` without an
`||` — a rule added earlier this same audit, catching the person who added it.

## What the analyzer found the first time it ran: 495 (2026-08-16)

With the target fixed, the first honest run collected 1423 files and reported

    Done analyzing! Found 495 violations, 495 serious in 1423 files.

379 `unused_import`, 98 `unused_declaration`, 18 `capture_variable`. Fifty minutes wall clock — a
clean rebuild plus a real frontend pass per file — which is the cost the old vacuous version was
buying its speed with.

Not fixed in this pass, deliberately. `swiftlint analyze --fix` corrects `unused_import` and would
rewrite ~379 sites at once across a tree with 652 uncommitted paths and no commit to fall back to;
that is a bulk overwrite nobody asked for, and the right person to authorise it is the one who owns
the tree. A copy of `Sources/`, `Tests/` and `Apps/` was taken first, so the run is one command away
when it is wanted.

One caveat belongs with the number, because it decides how much of it is real. The compiler log is
the macOS SwiftPM build, so an import or declaration used only from an `#if os(iOS)` branch, or only
from an Xcode app target, is invisible to it and reads as unused. `unused_import` is the safer half —
SwiftLint resolves actual symbol use — but any correction has to be followed by `swift build
--build-tests` AND `scripts/check-ios.sh`, which type-checks the slice `swift build` never sees.
`unused_declaration` (98) is the half to distrust: it should be read as a list of candidates.

## `--workspace` at `rust/` reaches four crates out of twenty-one (2026-08-16)

`docs/46` says it plainly in the row about `make lint-rust`: "`--workspace` does NOT reach [an
excluded crate], so each needs its own invocation and forgetting one is a silently unlinted crate."
Three prek hooks were written the way the doc warns against —

    rustfmt     entry: bash -c 'cd rust && cargo +nightly fmt --all'
    clippy      entry: bash -c 'cd rust && cargo clippy --workspace … -D warnings'
    cargo-test  entry: bash -c 'cd rust && cargo test --workspace --quiet'

— each firing on `^rust/.*\.(rs|toml)$`, that is, on a change to any of the seventeen workspaces,
while running against the root's four members. A commit touching only `slopdesk-video` ran
`slopdesk-hook`'s tests and reported green. The formatter was the one that bit both ways: it fixed
four crates while `make lint`'s per-workspace `--check` judged all seventeen, so the hook that exists
to stop a formatting failure was a way of producing one.

They call `make fmt-rust`, `make lint-rust-clippy` and `make test-rust` now. Measured warm: 8 s for
clippy across all seventeen, 16 s for the tests — commit-time costs, which is what made this a fix
rather than a trade-off. `lint-rust-clippy` is a new split of `lint-rust` without its `fmt --check`,
because prek runs hooks in parallel and the rustfmt hook is rewriting the files a `--check` reads.

The seventeen were themselves spelled out by hand three times in the Makefile — once in `fmt-rust`,
twice in `lint-rust` — so the list is now `RUST_WORKSPACES`, derived by grepping `rust/*/Cargo.toml`
for `[workspace]`. Seventh time this audit that a hand-kept list stood beside a derivable fact.

The supervisor gate that ratcheted those lines was checking the Makefile's TEXT for three `cd
rust/<crate> && …` lines per crate, which the rewrite deletes. It asks `make -n` of each of the four
targets now and looks for the crate in the plan — the same correction the `make test` gate took
earlier, for the same reason: what a target would RUN survives however the recipe is spelled next.

## The release could not have built the FFI artifact, and nobody would have known until the tag (2026-08-16)

`Package.swift` declares

    .binaryTarget(name: "CSlopDeskFFI", path: "ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework")

and `.gitignore:84` ignores that whole directory — correctly: 110 MB across three slices, rewritten
by every Rust edit. `scripts/build-ffi.sh` produces it locally, `make ffi` runs that, and `make lint`
carries `--check` so a stale one cannot pass.

`.github/workflows/release.yml` did not mention it. No step ran the script, nothing downloaded an
artifact, and the file cannot be checked out. SwiftPM does not resolve a graph whose `binaryTarget`
path is absent, so the first tag cut after this work lands would have failed in the `package` job,
after the vault pull and the keychain setup, before compiling a line. `docs/49` did not know either:
its pipeline diagram named one linked artifact where there are two.

It never bit because the entire FFI port is uncommitted — the binaryTarget line does not exist in any
commit, and v0.3.0 predates it by hours. That is the window in which to notice, not a reason it was
fine.

The workflow now runs `rustup target add` for the three arm64 triples plus `scripts/build-ffi.sh`,
as a step in `package` rather than a job of its own: the script stamps its own inputs, and unlike the
40-minute Zig build there is nothing worth caching across runs on a runner that is cold anyway. This
step has NOT been exercised on a GitHub runner — the disabled CI workflow means the only way to try
it is to cut a release — so it is written to fail loudly rather than skip.

The ratchet took two corrections, both of the same family this audit keeps finding:

1. It first asked whether `release.yml` MENTIONED the artifact. A negative test that deleted the
   whole build step passed, because the comment above the step named the file. A gate a comment can
   satisfy is a gate about prose; it reads only non-comment lines now.
2. It then resolved "the producer" as the first script naming the artifact, and nominated
   `build-ffi.sh` as libghostty's builder — that script discusses libghostty's gitignore in its
   header. Four scripts name `libghostty.xcframework` and only one builds it, so the gate asks the
   question that has one answer: does the workflow run ANY script that names this artifact outside a
   comment?

## The test the harness was built for was never written (2026-08-16)

`RecordingChannel` in `WorkspaceDocumentChannelTests` carried two fields — `_gate` and `_gated` —
under the comment *"Held sends, for proving that an update arriving MID-SEND still lands."* Nothing
read them. Seventeen tests covered snapshot, diff, ack, epoch, resubscribe, presence and roster;
none covered the case the fields were declared for. In their place `send` did `await Task.yield()`
and hoped the window opened.

A yield is a hope, not a window. The gate now parks the send AFTER recording its frame, so the test
holds the host's send loop suspended mid-frame, delivers an update into that suspension, and
releases. Three things are then asserted that nothing asserted before: the in-flight frame ships
what it was BUILT with, the mid-send arrival is not lost, and it ships exactly once, on the ack.

It was verified by mutation, not by passing: moving `claimPendingState()` from before the `await` to
after it — the classic form of this bug, where the slot is cleared of whatever arrived during the
send — turns the new test red and leaves the other seventeen green.

## An unused `pub fn` in an unwired port is not dead code (2026-08-16)

Ten `pub fn` out of 2101 in `rust/` have no reference anywhere in the tree. Deleting them was the
obvious move and would have been wrong for eight of them:

- `schedule_geometry`, `schedule_cursor` (and `schedule_control`, which only its own test calls) are
  a complete, tested scheduling family in `slopdesk-video` that `lib.rs` does not re-export.
- `Canvas::solved_layout`, `moving_to`, `moving_group`, `TreeWorkspace::active_session_pane_ids`,
  `active_tab_pane_ids` are the Rust counterparts of Swift methods still in use — `allPaneIDs()` has
  eleven live call sites in `SlopDeskClientUI` alone.

These are port surface waiting for their call site, in a migration where almost all of `rust/` is
still untracked. Deleting them would set the port back and read, later, as work that was never done.
The defect is that nothing marks them as unwired, so every tool reads them as garbage.

Two of the ten were real and are gone:

- `Toolchain::locate_default` collected the process env and called `Toolchain::locate` — which is
  exactly what `server.rs::locate_toolchain` does, on the path that actually runs. Two spellings of
  one step, one of them uncalled.
- `TrendlineEstimator::wire_trend_milli` / `wire_trend_flags` wrapped `pack_trend_milli` /
  `pack_trend_flags`, which the FFI already calls directly.

## Two env keys that named themselves three times (2026-08-16)

`slopdesk-superd`'s `OSC133_ENV_KEY` and `CURSOR_ENV_KEY` were `pub const` and read by nothing.
The names they hold are spelled twice more: literally inside `ZSHRC_BODY`, which the child shell
evaluates, and literally again in the test asserting the body gates on them — plus a fourth time in
hostd's curated env allowlist. A rename of either constant changed nothing anywhere.

They are load-bearing now: the assertions build their expected substring with `format!` from the
constant. Renaming `CURSOR_ENV_KEY`'s VALUE without touching the body fails the suite; before, it
passed. Both keys stay documented in `docs/51` and the shell-integration spec — the point is that the
Rust name and the shell text can no longer drift apart silently.

## The stale worktrees are not stale (2026-08-16)

`.claude/worktrees/wf_b77efe2d-807-{1..5}` hold 7.2 GB and were previously noted as safe to reclaim.
They are not. All five carry uncommitted work, and three carry files that do not exist in the main
tree at all — `Sources/SlopDeskVideoClient/Mux/UDPSendPathPolicy.swift`,
`Tests/SlopDeskVideoClientTests/UDPSendPathPolicyTests.swift`,
`Tests/SlopDeskHostTests/ScrollbackJournalTests.swift`. Sixteen more files differ from their
main-tree namesakes. Reclaiming the space means deciding what to do with that work first, which is
not a cleanup decision.

## The lint that argues against the invariant (2026-08-16)

`CLAUDE.md` keeps `a * b + c` as two roundings, because `golden/golden_vectors.json` pins the `f64`
bit patterns a fused multiply-add would change. Clippy's `suboptimal_flops` and `imprecise_flops`
argue the other way — both want `f64::mul_add` — both live in `nursery`, and all seventeen Rust
workspaces deny the whole nursery group.

Four manifests opted out of those two lints. The other thirteen did not, because they have no float
math today. That is the whole trap: in those thirteen the FIRST float expression to land is a hard
clippy error whose only suggested fix is the thing the repo forbids, arriving at the moment nobody
is reading a manifest, with `-D warnings` making it look mandatory. The opt-out is not a local
judgement about a crate that happens to do geometry; it is a repo invariant, so it belongs in all
seventeen. It is in all seventeen now, and a gate keeps the eighteenth honest.

Allowing the lint only stops clippy ASKING. Nine Swift files carried a comment promising never to
write `addingProduct`, `.swiftlint.yml` has no `custom_rules` at all, and `check-supervisor.sh` had
never heard of `fma` — so in both languages the invariant was enforced by prose. It is a ban now:
`.addingProduct(` and bare `fma(` in Swift, `.mul_add(` in Rust, at zero sites today. The METHOD
form only — `gf256::mul_add` and `slopdesk_gfsimd::mul_add` are Galois-field region ops over `u8`
and have nothing to do with float rounding.

## An exemption nobody checked the terms of (2026-08-16)

The unsafe-policy gate reads every manifest under `rust/` and demands `unsafe_code = "forbid"`,
with three crates exempt by name. The exemption was unconditional: an exempt manifest was skipped
before the `allow`/`warn` check ran, so `slopdesk-ffi` could have said `unsafe_code = "allow"` and
passed — and taken every per-site `#[expect]` with it, because a lint nobody fires cannot expire.
The comment above the list already argued why the level must be `deny` and not `forbid`; nothing
asserted it. It does now, and an entry naming a manifest that no longer exists fails too, rather
than reading for years like protection.

## The obligation that paid for the third unsafe crate was never run (2026-08-16)

`CLAUDE.md` sets the bar for a crate allowed to write `unsafe`: "a measured conflict where safe Rust
cannot reach parity, paid for by a crate small enough to read in a sitting and a differential suite
that runs under Miri." `rust/slopdesk-gfsimd` has that suite — five tests sweeping every table pair
against a scalar oracle, at four alignments, inside a guarded arena, with a `#[cfg(miri)]` seed
reduction written specifically so Miri can run it.

Nothing ran it. `make miri` existed and no target depended on it: not `check`, not `test`, not the
prek hooks, and the disabled CI workflow had no Rust job at all. The whole enforcement was a
sentence in a document.

The reason it was left out was written in the Makefile — "Miri interprets every instruction, so even
the narrowed `cfg(miri)` sweep runs for minutes". Measured: **47 seconds**, compile included. The
seed reduction the suite's own doc comment describes is what makes that true, and nobody had timed
it since. `make check` now depends on `miri`, `make -n check` is asserted to reach it, and the
comment carries the measurement instead of the guess. It stays out of `make test`, which the
pre-push hook runs on every push.

## A dormant workflow describing a tree that no longer exists (2026-08-16)

`.github/workflows/ci.yml.disabled` claimed "a clean checkout builds with no prerequisite — the
package is pure Swift plus the in-tree `CSlopDeskSIMD` C target … no staticlib to pre-build". Both
halves were false: `CSlopDeskSIMD` was deleted when the SIMD kernels moved to `slopdesk-gfsimd`, and
`Package.swift` declares a gitignored `binaryTarget`, so a fresh checkout cannot even RESOLVE the
package until `scripts/build-ffi.sh` has run. It also ran no Rust: seventeen workspaces of clippy
and tests, plus the Miri audit, were invisible to it.

The `.disabled` suffix is why it rotted — nothing parses the file, so nothing fails when it lies.
It now runs `make` targets rather than restating their commands, which is the only way a dormant
file stays true: the Makefile derives its own lists, and a workflow that copies them is a second
list to forget. It is still dormant.

## The layer the gates are written in (2026-08-16)

Every gate in this repo is a pipeline somewhere, and without `pipefail` a pipeline reports the LAST
command's status — a generator that crashed feeding `grep` reads as success. All twenty-five scripts
set it; nothing checked that they did. They are checked now.

The first draft of that check matched the string `set -euo pipefail` and reported two false
positives, because `soak-fanout-laggard.sh` and `video-input-test.sh` say `set -uo pipefail`
deliberately. It matches the WORD now. A gate that names a spelling rather than the property is the
same mistake as a gate that names a file rather than what the file does.

## Three silent gate failures in one afternoon, all of them shaped like a grep (2026-08-16)

Every ratchet in `check-supervisor.sh` is some form of "this spelling must not appear in code", and
in shell that is a `grep`. Writing four new ones in a row produced three distinct silent failures:

1. `repo_files 'Sources/*.swift' | xargs grep -ln …` PRINTS the offending file and still exits
   non-zero, because `xargs` splits 742 paths into batches and reports the LAST batch's status. The
   surrounding `if hit=$(…)` is therefore false exactly when there is something to report. This was
   not only my new gate: the shell-quoting ratchet had carried the same construction all along, so
   the one-owner rule for POSIX quoting had never been enforceable.
2. A `grep` for `pkill` matched the gate's own failure MESSAGE. It reported itself, and no edit to
   the repo could ever make it pass — the fourth time this audit has found a gate that reads prose.
3. `sed -E 's,//.*,,'`, the comment-stripper `spells()` uses, also eats `https://…` inside a string
   literal.

None is a shell-scripting mistake so much as the shape of the tool: a pipeline hides status, a regex
cannot tell code from a comment, and both failures look exactly like success. So the token bans moved
to `scripts/check-invariants.py`, which carries a small tokenizer that blanks comments while keeping
string literals and line numbers intact, and where each gate is a named function returning its sites.
`check-supervisor.sh` runs it and folds the status into its count; `ruff.toml` already had
`select = ["ALL"]` pointed at `scripts/*.py`, so the gate is linted at the same strictness as the
code it guards.

Six invariants moved or arrived there, all at zero sites: app-layer crypto (CryptoKit/CommonCrypto,
with one named allowlist entry — a SHA-256 over a COMMITTED jar against its `tools.lock` pin is
supply-chain integrity, not an auth path), a SwiftPM build plugin, the fused multiply-add, `pipefail`
in every script, an unqualified `pkill` naming hostd, and the one owner for shell quoting. The
comment/code distinction is tested both ways: `// .plugin(name:)` passes, `plugins: [.plugin(…)]`
fails.

## The ratchet spent two thirds of its time in `rust/*/target/` (2026-08-16)

`make lint-supervisor` took 114 s. Profiling it with `PS4='+ $EPOCHREALTIME:$LINENO ' bash -x` and
sorting by per-line delta made the shape obvious: two lines accounted for 21 s and about a dozen more
for 4–9 s each.

The two big ones were `grep -rl … rust --include='*.rs'`, which walks `rust/*/target/` — gigabytes of
`build.rs` output and vendored expansions. That was never only a speed problem: a match inside build
output would have been reported as a stray `fork` or `extern "C"` in the source tree, and the fix
(`--exclude-dir=target`) closes a false-positive channel as much as it saves the time.

The dozen were `spells()`, which comment-strips a file with `sed` and then greps the result. Twelve
call sites hand it the whole Swift tree, so that was two processes per file, per call site. It now
runs ONE `grep -lE` over the entire list first and comment-strips only the files that matched.
Semantics are identical by construction — stripping comments can only ever REMOVE a match, so a file
the first grep rejects could not have matched afterwards.

114 s → 39 s, byte-identical output. Verified by mutation, not by reading: renaming `pub fn
reset_suffix` out of `rust/slopdesk-sanitize/src/inputmode.rs` still fails the script. The first
attempt at that negative test renamed it to `reset_suffix_renamed` and passed — the gate greps for
`pub fn reset_suffix`, which is a prefix of the new name. A negative test that mutates nothing
observable reports exactly like a gate that does not work; this is the third time that lesson has
landed in this document.

## The ratchet ran only when someone typed `make` (2026-08-16)

`check-supervisor.sh` is the file that enforces which Swift files must stay deleted, the socket
paths, relinquish-vs-terminate and the FFI staleness gate — and it was reachable only through
`make lint` and `make check`, both of which a person has to remember. That is the same shape as the
Miri audit found earlier this cycle: the obligation that pays for `slopdesk-gfsimd`'s `unsafe` was
written down, and no target ran it.

At 114 s it was arguably too slow to hang on a push. At 39 s it is not, so it is now a `pre-push`
prek hook, running beside `swift-test` — which takes ~60 s, so on any push touching Swift the
ratchet is free.

It is the only hook in `.pre-commit-config.yaml` with `always_run: true` and no `files:` regex.
Every other hook can name its inputs. This one asserts absences — "this Swift file is still gone",
"no file anywhere respells a Rust constant" — and an absence has no path to match: a deletion that
violates it stages as a change to some unrelated file, or to none at all.

## Eighteen suites that skip themselves, behind a gate that never built what they need (2026-08-16)

`SupervisedPTYSupport`, `ScreendFixture` and `DropdE2ETests` each boot a real sidecar, and each
throws `XCTSkip` naming the daemon when its binary is absent. That is the right call *inside a
test*: `swift build` never sees cargo, so the alternative is a suite that passes without exercising
anything. `make test` lists `superd screend dropd` (and three more) as prerequisites, so the
developer path is honest.

The push path was not. The prek hook ran `bash scripts/pre-push-test.sh` directly and the dormant CI
job ran `swift test` — neither builds a sidecar. On any tree that had not had `make test` run
against it, the entire supervised, screen and file-drop surface skipped and the gate reported green.
The skip message even says "run `make superd`", which is precisely the instruction nobody was there
to read.

Both callers now go through `make test`. That alone would be a fix by convention, so the script also
refuses to run when a needed binary is missing, whoever invoked it. The daemon list is DERIVED —
`grep -ohE 'rust/slopdesk-[a-z]+/target' Tests` — because every fixture already spells that path to
find its own binary, so a nineteenth suite booting a new daemon is covered the day it lands rather
than the day someone remembers a list. Verified by hiding `slopdesk-dropd`: the run stops before
`swift test` and names `make dropd`.

## Neither app had built, on either platform, and four gates all read green (2026-08-16)

`xcodebuild` on `ClientApp-macOS` and on `ClientApp-iOS`:

    error: Multiple commands produce '…/Build/Products/Debug/include/module.modulemap'
      note: Command: ProcessXCFramework …/libghostty.xcframework …
      note: Command: ProcessXCFramework …/SlopDeskFFI.xcframework …

`-create-xcframework -headers X` copies X's contents to each slice's `Headers/`, and Xcode's
`ProcessXCFramework` then flattens that into `$BUILT_PRODUCTS_DIR/include/`. Both xcframeworks kept
a `module.modulemap` at their Headers root, so both wrote the same destination and Xcode refused the
graph. This began the moment `SlopDeskFFI.xcframework` joined — the linked half of the Rust port.

Nothing noticed, and the reasons are worth separating:

* `swift build` and `swift test` never run `ProcessXCFramework`. SwiftPM reads the xcframework
  directly, so the entire Swift gate — lint, build, test, golden — is blind to this class of break
  by construction. Green tests and no app.
* The two scripts that DO build the apps, `check-macos.sh` and `check-ios.sh`, were reachable from
  no `make` target, no prek hook and no workflow. The same shape as the Miri audit found earlier in
  this cycle: an obligation written down and never run.
* `check-macos.sh` sent `xcodebuild` to `/dev/null`, so even run by hand it said `** BUILD FAILED **`
  and nothing else. Finding the actual line meant re-running the same invocation with the redirect
  removed.

The fix is in `scripts/build-ffi.sh`: the headers are staged into `Headers/CSlopDeskFFI/` before
wrapping, which gives the copy a unique destination. SwiftPM still resolves the module — it walks
the Headers tree rather than only its root — verified by `swift build` green and by the macOS app
building for the first time since the port. The script then asserts BOTH halves per slice: the
modulemap is under `CSlopDeskFFI/`, and there is none at the root. libghostty's stays where upstream
puts it; nesting the side we own is the smaller change and needs no vendor rebuild.

`check-ios.sh` is now `make check-ios` and a prerequisite of `make check`. `check-macos.sh` is
deliberately not: it drives a real window and needs a logged-in GUI session. Its build log now goes
to a file and its failure path prints the compiler's own words.

## The formatter could not produce a tree the linter accepts (2026-08-16)

`.swiftformat` states the division of labour in its first line: SwiftFormat owns formatting,
SwiftLint owns lint. It does not survive `leading_whitespace`. SwiftFormat cannot remove a blank line
at the START of a file — `consecutiveBlankLines` collapses three to two and stops, and no other rule
reaches file position 0 (checked against every rule's `--ruleinfo`). SwiftLint enforces it. So a file
beginning with a blank line failed `make lint-swift`, and `make fmt-swift` could not fix it: the one
thing a format target exists to guarantee.

Sixty-five files were in exactly that state, because deleting a file's only import leaves the blank
line behind. `swiftlint --fix` — the correctable-rule pass, not `analyze --fix` — clears it, and is
a verified no-op on a clean tree: zero output, byte-identical `git status` and diffstat. So it now
runs inside `fmt-swift`, and `lint-swift` stays strictly read-only. Everything that WRITES is in the
format target; nothing that lints writes.

## What `unused_import` gets wrong, and how to find out (2026-08-16)

`swiftlint analyze --fix --only-rule unused_import` judges from a compiler log of ONE configuration.
The log was macOS. Two failure classes followed, and they need different gates to catch:

* Imports the macOS build itself needs — `CoreGraphics` under a `CGRect`, `OSLog`, `Observation`
  behind an `@Observable` macro. Thirty-three files. `swift build` finds these.
* Imports only an `#if os(iOS)` branch uses. `swift build` on macOS cannot see them at all; only the
  iOS triple can, which is the gate that was not wired up (above).

Both were repaired the same way and it is the right way: build, take every file the COMPILER names,
restore that file's missing imports from the pre-fix state, build again. What survives is the subset
a compiler vouches for, not the analyzer's belief. The loop is worth more than its output — it
converges in a handful of rounds and needs no judgement about any individual import.

`make fmt-swift` runs `swiftlint --fix` and never `analyze --fix`, for this reason.

## The iOS client had not compiled since 2026-08-11, at HEAD (2026-08-16)

With the modulemap collision fixed, the iOS triple got far enough to report what was underneath it:

    Sources/SlopDeskClientUI/Chrome/SlateTitlebar.swift:96: error: cannot find 'RailStatusRollupMount' in scope

`RailStatusRollupMount` moved inside `#if os(macOS)` when the agent rollup rolled into the band
(a0e99e58, 2026-08-11). `SlateTitlebar`'s only MOUNT — `ContentColumn` — was already `#if os(macOS)`,
so nothing on iOS renders it; but the TYPE sat under `#if canImport(SwiftUI)` alone, so it still
compiled for the iOS triple, and its body reaches for the macOS-only view. Neither file was touched
by the `unused_import` sweep; `git diff` on both is empty. This was red at HEAD.

The gating now matches the mount: `#if canImport(SwiftUI) && os(macOS)` on the whole file.

Three separate things had to be true for this to sit for five days, and each is worth naming:
`swift build` compiles the macOS slice only, so the entire Swift gate is blind to `#if os(iOS)` by
construction; `check-ios.sh` existed for exactly that and no target ran it; and the xcframework
collision meant that even running it by hand failed earlier, on a different error, which reads like
one broken thing rather than two.

A gate that has never run is not a gate that passes. It is a gate with an unknown verdict, and the
verdict here was no.

## `git checkout HEAD --` is not a revert here, it is a delete (2026-08-16)

Repairing the `unused_import` sweep's damage, the repair script reverted four files to `HEAD`. That
destroyed work, because almost the whole tree is an uncommitted in-flight migration: `HEAD` is not
"the version before my mistake", it is "the version before *every* uncommitted change in this file",
and the two are five days apart. `make lint` went from green to seven supervisor violations —
`SlateFactLine` grew a second pasteboard write back, both device sidebar models grew their
cancel-and-re-arm timers back, and a doc link came back pointing at a type deleted in `2682df50`.

The ratchet is the only reason this was recoverable at all. Nothing in the compiler, the tests or
the formatter objects to a hand-rolled `Task { try? await Task.sleep(...) }` — it builds, it runs, it
is merely the second copy of a rule. `check-supervisor.sh` names each one it wants and where, so
the repair was mechanical instead of archaeological: `noticeClear.arm`, `reattempt.arm`,
`ClientPasteboard.write`. A ratchet earns its keep on the day someone deletes the thing it protects
without noticing.

The rule that follows: when the tree is a working migration, restore from a copy of the *working
tree*, never from a commit. `git stash` or a `cp -a` of the file, and check `git diff --stat` for the
file first — an empty diff is the only case where `checkout HEAD --` is what it looks like.

## The next tag would ship a host that cannot open a pane (2026-08-16)

`scripts/package-release.sh` ships exactly five things: two apps in the DMG, and three binaries in
the CLI tarball —

    SPM_TOOLS=(slopdesk slopdesk-hostd)
    RUST_TOOLS=(slopdesk-ctl)

Not one of the sidecar daemons is in that list, in either app spec's copy phase, or anywhere else in
the pipeline: `slopdesk-superd`, `slopdesk-screend`, `slopdesk-dropd`, `slopdesk-inspectord`,
`slopdesk-androidd`, `slopdesk-codeseed`, `slopdesk-agenthooks`, `slopdesk-probe`.

For five of those the consequence is a feature that reports unavailable, which is survivable.
superd is not one of the five. It forks and owns every pane's PTY master
(`Sources/SlopDeskHost/PTYProcess.swift:9`, `docs/51`), and `HostServiceSupervisor.connected()` says
what happens without it in its own doc comment: "hostd does not fork, so there is no fallback to
have." A `brew install aislopware/tap/slopdesk` therefore yields a `slopdesk-hostd` that cannot open
a terminal — the product's entire purpose.

It has not shipped broken. v0.4.0 was cut from a tree whose hostd still forked its own PTYs; the gap
opens the moment a tag is cut from the migration. That is the same window the FFI xcframework step
was found in, and for the same reason: the release path is exercised by tagging, so a change that
moves an implementation out of the Swift graph is invisible to every gate that is not a release.

Shipping the binaries is necessary and not sufficient. `scripts/install-superd.sh` also installs a
LaunchAgent plist pointing OUT of the build tree, and superd must be RUNNING before hostd's first
pane — `SupervisorClient.swift:38` calls `make superd-install` "a prerequisite, not an optimisation".
So the release needed an answer to *who loads the agent on a machine that never had a checkout*.

**Decided (user-directed 2026-08-16): the formula owns it, through `brew services`.** Not caveats —
a required daemon left to a paragraph somebody skims is not shipped — and not hostd bootstrapping
its own LaunchAgent, which would make the host write to `~/Library/LaunchAgents` and call
`launchctl` as a side effect of starting. One install path, and it is the package manager's.

Four things fell out of it, and each was its own defect:

**A packaged host could not have found the daemons even with them installed.** `RustServicePaths`
searched the override, `~/Library/Application Support/SlopDesk/bin`, and a cargo target tree — a
release tarball is none of the three. It now looks beside the running executable too, after the
hand-installed copy and before the walk, which is exactly what a flat `bin` directory needs. The
function had NO test; it has seven now, and removing the new step fails two of them.

**The cask was the same bug wearing a menu-bar icon.** `SlopDeskHost.app` does not shell out to
`slopdesk-hostd` — `HostController` runs the same `HostServer` in-process — so it needs superd just
as much. The cask now declares `depends_on formula:`, because the dependency is real rather than a
convenience. (Superseded by `docs/60` F.9: the Swift host is deleted, the host is the CLI daemon
`slopdesk-hostd`, and the cask ships the client viewer alone. The `depends_on` stands, on the
formula owning every daemon and every command.)

**`slopdesk-hook` had to ship for a reason no lookup in Swift states.** `slopdesk-agenthooks`
installs the relay from `executable.parent()/slopdesk-hook`, so a formula that split the daemons
into `libexec` would leave the hook install with nothing to copy. Everything lands in one flat `bin`.

**superd's `KeepAlive` contradicted superd's own comment.** It exits 0 on purpose when another
instance holds the lock, and `main.rs` reasons that launchd "would restart a job that exited
non-zero" — true only of `KeepAlive { SuccessfulExit: false }`. The plist said `<true/>`, which
restarts on ANY exit, so the loser respawned every ten seconds forever. Both plists are the dict
form now, which is also what lets the checkout's agent and Homebrew's coexist: whichever booted
first keeps the panes, the other exits once and stays quiet.

The gate is `check-invariants.py`'s `the_release_ships_every_sidecar_the_host_needs`, derived from
the `RustServicePaths` call sites rather than a maintained list. It reads the tool ARRAYS in
`package-release.sh`, not the file — a first draft grepped the script whole, and the comment above
those arrays names every daemon, so it passed on prose alone. A gate a comment can satisfy is not
a gate.

## Four Rust modules were written, tested, and then called by nothing (2026-08-16)

An audit of what is still worth moving to Rust, what is duplicated, and what was moved without
deleting the Swift found the third category in its worst form. `e6b1ce9b` added four modules to
`rust/slopdesk-workspace`, gave them 47 tests between them, re-exported all four from `lib.rs`, and
wired none of them to anything:

| module | lines | tests | the Swift that still runs |
| --- | --- | --- | --- |
| `persist` | 928 | 22 | `WorkspacePersistence.swift`, `Canvas+Codable.swift`, `SplitNode+Codable.swift` |
| `templates` | 606 | 15 | `SessionTemplate.swift`, `LaunchPreset.swift` |
| `listen` | 171 | 7 | `PortValidation.swift`, `SlopDeskTransportError.swift` |
| `connection` | 94 | 3 | `ConnectionTarget.swift` |

Nothing failed, and that is the finding. `cargo` has no unused warning to give for a `pub` item in
a library crate; the tests are green because a test is a caller; and the only place the defect was
visible was a question nobody had asked — *who calls this?* Every one of the eight `persist`
encode/decode functions appears exactly once outside its own file, on the `pub use` line that
exports it. Two implementations of the same rule, which is the one thing `CLAUDE.md` forbids
outright, hidden behind a re-export that reads like use.

`listen` and `templates`'s keystroke rule are now wired and their Swift bodies are faces. That one
mattered beyond tidiness: the `cd` line a preset types is built from literal bytes and must never
reach the token parser, because a `<Enter>` inside a path ends the quoted line early and runs the
rest as its own command. Two copies of a security property agree only until they do not.

`persist` and `connection` are registered as debt in the new gate's waiver set rather than fixed
here. They point opposite ways, and that is the interesting part: `persist` should be finished —
it is an encoder, and the Swift should go. `connection` should be DELETED — `ConnectionTarget` is
a four-field `Codable` value twenty files hold and SwiftUI diffs, which `docs/55` §6 already calls
a vocabulary rather than an implementation, so the Rust twin is the copy in the wrong language.
Neither is a change to make without the user, since one deletes tested Rust and the other rewrites
the client's persistence.

The gate is `check-invariants.py`'s `no_rust_module_is_written_and_then_never_called`. A module
counts as reached when another Rust file names `module::`, or names something `lib.rs` re-exports
from it, or when it exports a `no_mangle` door — that last is the FFI crate's whole shape and its
caller is Swift, which is not in this tree's `.rs` files. `lib.rs` counts as a caller, but its own
`pub mod` / `pub use` lines do not: a re-export is precisely what a stranded module has INSTEAD of
a caller, so counting one would have made the gate unable to fail — which is how all four of these
survived a repo that already ratchets cross-language contracts in two other scripts.

## The same audit, one level down: item granularity was tried and rejected (2026-08-16)

The module gate above is precise because a module is a unit a `pub mod` line declares. The obvious
next question — which `pub` ITEMS inside a live module are reached by nothing — was measured and
does not gate. Three scans, with what each got wrong:

**Every `pub` item, unreferenced outside its own file: 100 hits, 281 more that are `pub` but only
used file-locally.** Most of the 100 are legitimate: `retained_count`, `subscriber_count`,
`followed_count`, `open_ids` are observability a test asks and production does not, which is a
pattern, not a defect. Gating would mean a hundred-entry waiver list, which is a list nobody reads.

**Types re-exported from `lib.rs` and named nowhere outside their module: 26 hits.** Over-reports
badly — a return type is used without ever being named (`let decision = decide(…)`), so
`QpDecision`, `CongestionDecision` and most of the other 24 are live. Worse, it MISSES the case it
was built for: `ConnectionTarget` passes because the Swift twin has the same name, and a name-based
scan cannot tell a duplicate from a caller. A gate that is blind to its own motivating example is
not a gate.

What the scans did surface, by hand rather than by rule, is a THIRD instance of the pattern the
module gate found — and the tail it comes from is now legible. `e6b1ce9b` ported the video input
path as two free functions, `slopdesk_input_normalize` and `slopdesk_input_next_tag`, and Swift's
`InputEventEncoder` (`VideoClientSessionLogic.swift:779`) is a proper face over both: it normalises
through the door and mints tags through the door, and the only Swift left is assembling the
`InputEvent` enum, which is a vocabulary the codec and SwiftUI both read. Correct. But the port ALSO
wrote `slopdesk_video::client_input::InputEventEncoder` — the same struct, the same five methods,
the same tag semantics — and nothing constructs one. The FFI imports six names from that module and
not this one; `lib.rs:217` re-exports it, and that line is its only mention in the tree.

So all three stranded duplicates — `ConnectionTarget`, `InputEventEncoder`, and the value types
inside `templates` — are the same mistake, and it is a specific one: **the port correctly left a
vocabulary in Swift and then wrote the Rust twin anyway.** `docs/55` §6 already draws that line;
what was missing is that nothing checks the line was respected in the direction of writing too much
Rust, only in the direction of leaving too much Swift. The module gate catches it only when the
whole module is stranded, which is why `connection` is caught and `client_input` is not.

## The dead-Swift oracle was in the repo the whole time, and nothing ran it (2026-08-16)

Two hand-rolled dead-code scans were written this session and both were wrong — the first indexed
only top-level type declarations, so a file whose whole API is a `View` extension method read as
dead; the second indexed every declared name and returned nothing, because names like `decide` and
`token` collide. The authoritative answer already existed: `.swiftlint.yml` sets
`analyzer_rules: all`, and `unused_declaration` resolves through the compiler's index, not a regex.
It found **154 serious violations in 1423 files** — 91 `unused_declaration`, 45 `unused_import`, 18
`capture_variable` — the first time it had ever run against a real compiler log.

`make lint-swift-analyze` is reachable from `make lint`, `make check`, the pre-push hook and CI:
none of them. Deliberately, and the cost argument is right — it needs a clean `swift build
--build-tests -v` and takes minutes. But "run it when you think of it" is how 154 accumulated, and a
gate nobody runs is the same shape as a gate that cannot fail, one level up: nothing was silenced,
nothing was asserted either.

The raw 91 are NOT a delete list, and two systematic false positives have to be named or the list is
worse than useless:

  * **A reference from inside a `ViewBuilder` or an escaping closure is invisible to the rule.**
    `selectedPane` is read at `NavigatorColumn.swift:403` inside a `Binding` closure, `pickerRow` is
    called at `SettingsView.swift:1363`, `activeAgentStatus` three times in a view body,
    `wireOverlayKeyToggles()` at its own file's line 247, `onToggleFill` at
    `VideoWindowView.swift:1972`. Five of the six `private` hits — the subset that looks most
    conclusive, because a `private` declaration unused in its own file cannot be used from anywhere —
    are live.
  * **A declaration whose purpose is the side effect of existing has no reference by design.**
    `@NSApplicationDelegateAdaptor … private var terminationDelegate` installs the app delegate; the
    property is never read and its own doc-comment says the instance is unreachable. `sigintSource`
    and `sigtermSource` in `slopdesk-hostd/main.swift` are the retention of two
    `DispatchSourceSignal`s — dropping either binding cancels the source and the daemon stops
    shutting down cleanly. `WatchProgress.progressBytes` is a face with no Swift caller ON PURPOSE
    and says so, and `check-supervisor.sh:2838` pins it.

Comments are not references either: a doc-comment that names a symbol (`windowRadius` is cited by
the constant below it, `radiusPill` by the one above) reads as a use to a name grep and is prose. It
took stripping comments and string literals, and reading the two trees the SwiftPM analyzer never
compiles — `Apps/` and `ThirdParty/ghostty/integration/` — to get from 91 to **34 real ones**.

Six of the 34 were the stranded-mirror class this audit has now found in both directions, and are
deleted here: a constant that crosses the FFI once and a Swift `static let` restating it with no
reader. `ClaudeStatusMachine.hookBlockScreenOverrideGrace` (the grace is applied at
`rust/slopdesk-agent/src/machine.rs:857`), `InspectorWire.subscribeTag` (the subscribe frame is
encoded whole by `slopdesk_inspector_encode_subscribe`), `MuxEnvelopeCodec.minMuxFrameLength` and
its `sessionIDByteCount` — the THIRD Swift declaration of that one wire fact, beside
`WireMessage.sessionIDByteCount` and `ChannelAssociation.sessionIDByteCount`, and the only one
nothing reads — and `TrendlineEstimator.maxScaledDeltas`.

`FrameReassembler.maxFragmentsPerFrame` is the sharpest of the six: not a door read but a literal
`8192`, hand-copied from `rust/slopdesk-video`'s `MAX_FRAGMENTS_PER_FRAME`, under a doc-comment
saying it is "restated here because `FrameReassemblerFragCountPinTests` pins the wire's shape
against it". That test exists and never names it — it spells `fragCount: 3` and `4` as literals. So
the comment described a pin that was not there, guarding a cross-language mirror of exactly the kind
`CLAUDE.md` forbids. The cap is enforced at `reassembler.rs:503` and tested at `reassembler.rs:1003`,
which is the one implementation.

## Two of the three analyzer rules were the finding; the third was the bug (2026-08-16)

Running the analyzer's 154 to ground turned each of its three rules into a different verdict.

**`capture_variable` (18): all noise, and now off.** The rule warns that `[x]` in a capture list
snapshots a mutable `x` at closure-creation time. It reads the declaration kind and not the
lifetime, so it fires on `private let shimLaunchGrace` (`WorkspaceControlBackend.swift:239`), which
cannot change at all, and on the App struct's `@State private var overlayCoordinator` /
`keyDispatcher` / `chrome` / `windowBox`, which are reference types assigned once in `init` — where
the capture list is there precisely to avoid capturing `self`. The one capture of a genuinely
reassigned `var`, `[state]` at `HostWorkspaceDocument.swift:201`, is a value snapshot taken and
consumed inside a single actor-isolated call, which is the reason it is written that way.

**`unused_import` (45): the rule is wrong here, and its autocorrect proved it.** SwiftLint asks
which MODULE each used symbol resolves to; Swift answers with the module that DECLARES it, not the
one the file imported to reach it. So `@Observable` resolves to `Observation` and not to the
`Foundation` that re-exports it, `Logger` to `os` and not `OSLog`, `CGFloat` to `CoreFoundation` and
not `CoreGraphics`. `swiftlint analyze --fix` removed all 45 and the very next build died on
`unknown attribute 'Observable'` in `InspectorViewModel.swift`. Every import is restored and the
rule is disabled with that reason: a rule whose `--fix` does not compile cannot be a gate, and its
warnings cannot be hand-triaged either — the failing case is indistinguishable from the passing one
without building.

It also took an edit with it. `--fix` reads every file at the start of the run and writes its
corrections at the end, so a doc-comment fix made to `SlopDeskVideoClientSession.swift` while it ran
was silently overwritten by swiftlint's stale copy. Nothing warned; the file simply had the old text
back. Do not edit under a running autocorrect.

**`unused_declaration` (91): 34 real, and they are gone.** Beyond the six stranded FFI mirrors above:
`Slate`'s chrome ladder lost two of its three rungs — `chromeLine` and `chromeLift` were `Color`
accessors nothing read, over two stored hexes that existed only to feed them, over two initialiser
arguments, over two `ChromeLadder` fields the one profile filled in. Four levels of a dead chain
whose only live rung is `ground`, so the struct itself is gone and the ground crosses as a `UInt32`.
Ten more `Metric`/`Colors` tokens went the same way (`windowRadius`, `radiusPill`, `railWidth`,
`railChip`, `edgeHandleLength`, `edgeHandleThickness`, `gaugeDiameter`, `gaugeStroke`, `cardMargin`,
`Accent.deep` + the private hex behind it) — each carrying real design rationale, so the two
measurements another token is derived FROM were folded into that token's doc rather than deleted
with the constant.

Three of them were claims rather than tokens. `AndroidScreenLayout.touchSlop` said "the panel uses
it to decide when an accumulated wheel delta is worth a move message at all" and no line of the
panel reads it, so no delta is measured against anything. `NavigatorColumn.detailLine` and
`PaneConnectionStatus`'s `showsDot` / `pulses` / `detailedLabel` are view-facing derivations no view
calls. `Tests/SlopDeskProtocolTests`' `BigEndianReader` was a 71-line second copy of
`VideoWireFixtureBytes`' reader that this target never built one of.

And four are declarations the rule is RIGHT about and that must stay, each now silenced at the site
with its reason: `progressBytes` (uncalled on purpose, pinned by `check-supervisor.sh:2838`),
`terminationDelegate` (the property wrapper installs the delegate; the instance is unreachable), and
`sigintSource` / `sigtermSource` (the bindings ARE the retention — a `DispatchSourceSignal` nobody
holds is cancelled, and hostd stops draining its children on ⌃C).

## A comment that names a test is a claim, and 12 of them named nothing (2026-08-16)

`maxFragmentsPerFrame`'s doc-comment naming a pin that did not exist turned out not to be a one-off.
185 comments in `Sources/` and `Tests/` cite a `*Tests` class by name; 17 cite a name no class
declares. Five of those are test TARGET names (`SlopDeskHostTests`, `SlopDeskScreenTests`, …), which
is a legitimate citation, and two are correct prose ABOUT a deletion — `OpenTerminalRootedStoreTests`
says "the since-deleted `WebPaneStoreTests`" and `WireCodecBenchTests` says "it was called
`RustWireBenchTests` until 2026-08-12". The other ten were stale, and were fixed by finding what the
test was renamed to (`AgentSettingsCardTests` → `AgentSettingsCardWiringTests`,
`GeneralSectionLayoutTests` → `SettingsSectionTaxonomyTests`, `RelayBackpressureTests` →
`MuxChannelSessionBackpressureTests`, `WorkspaceStoreTreeTests` → `TabCloseSuccessorTests`,
`SplitContainerTests`' resize coverage → `SplitLayoutSolverTests` / `SplitNodeOpsTests`) — except
one, which named a test that had never been written.

`DropActionResolver` claims no `(zone × content)` cell can spawn a video pane, "pinned by
`RemoteGUIFirstClassPeerTests`". That pin is real now, and it is a compile-time one rather than an
assertion: the new sweep walks all 20 cells and switches EXHAUSTIVELY over `DropAction`, so a fifth
case stops the test file compiling. An `XCTAssertNotEqual` against a video case would have passed
forever by being written before the case it was supposed to catch.

This was NOT made a gate, and the two correct-prose citations are why: a rule that fails on any
`*Tests` name without a class would fail on both of them, and the allowance it would need is the
hand-kept list this audit has already caught drifting six times.

## The cursor and the badge disagreed on a CJK row, so both walks moved (2026-08-17)

`ViLineMotion` walked a terminal row `Character` by `Character` in Swift, asking
`TerminalLinkDetector.displayCellWidth(of:)` for each glyph's width. `HintLabelAssigner` walked the
same row the same way. `slopdesk_terminal::link` walked it a third time, through its OWN grapheme
clustering, to report the spans the underline and the hint badges are drawn over. Three walks, two
clusterings, one row — and the columns they produce are the columns a cursor lands on and a badge
claims. On a row where Swift's `Character` and the crate's `clusters()` disagree by one boundary,
the block cursor sits half a glyph away from the badge that says it is there. Nothing tests that,
because nobody types `w` over an emoji family by hand.

So `slopdesk_terminal::vimotion` took the motions and `slopdesk_hint` took the target scan, and both
read `link`'s clustering. Nine `slopdesk_vi_*` doors cross an `intptr_t` per keystroke, which is a
new reading of §4's refusal: `-1` is the row WRAP (`w` off the last word, `b` at the start), and
column `0` stays a column, because "0 means no answer" is unavailable when 0 is the most common
answer there is. `slopdesk_hint_scan` is the link scan's handle-over-arena shape again, with one
record type covering all four target kinds — a LINK target carries the whole detected link so the
actuator keeps routing through the one link policy the ⌘-click path uses.

**The hint scan bought a second thing, and it is the reason it is its own crate.** A `hint-pattern`
is a regex a human pasted into Settings, run against rows a remote program wrote. The Swift ran it
on `NSRegularExpression`, which backtracks — so a pattern copied off the internet could hang the
overlay on a long row, and no amount of bounding the SCAN fixes a pathological match. `regex` is a
finite automaton: linear in the row, whatever the pattern says. That crate cannot go in
`slopdesk-terminal`, whose manifest takes no external dependency precisely because it sits on the
PTY hot path parsing untrusted bytes, so `slopdesk-rowscan` is where the module that needs one lives,
taking the link scan as a sibling. The cost is a dialect change — the engine has no lookaround and
no backreferences — and a pattern using either now DROPS, which is the same validate-then-drop an
uncompilable pattern always had. The two built-in shapes lost their lookarounds too, and their
boundaries are now predicates over the neighbouring scalar, which is where they can be read.

**The labels stayed in Swift, on purpose.** `labels(count:alphabet:)` and `filter(typed:labels:)`
are list arithmetic over 26 letters — no text, no bounds, no untrusted input — running per keystroke
beside the overlay that already holds their result. Crossing a boundary twice to slice forty
two-character strings would cost more than it computes. `check-supervisor.sh` pins that they stay,
so the next person to move them has to argue it rather than slip it in.

Both ports are pinned by their PRE-EXISTING Swift suites, unchanged: 12 `ViLineMotionTests` and 20
`HintLabelAssignerTests` pass against the marshallers exactly as they did against the walks.

## ⌘F was the same hazard as Hint Mode, reached far more often (2026-08-17)

Hint Mode's `hint-pattern` is a regex a human pastes in once. Find-in-terminal's is a regex a human
RETYPES on every keystroke, run against the whole scrollback, and `TerminalSearchController` ran it
on `NSRegularExpression` — the same backtracking engine, the same untrusted-pattern × untrusted-text
product, on the path the user is most often on. `(a+)+$` typed into a find bar over a long log line
is a frozen window with no cancel.

So the find scan moved beside the hint scan, into `slopdesk-rowscan` — which is why that crate is
named for the rows it scans and not for hints. `find::matches` is the whole engine: literal or
regex, case-sensitive or not, whole-word as a post-filter over either. Three walks over the same
rows became one.

**Two decisions inside it are worth naming.** The literal scan folds case per UTF-16 UNIT rather
than calling `str::to_lowercase`, because the full Unicode mapping can change a string's LENGTH —
`İ` lowercases to two scalars — and a column into a string of a different length is not a column
into the line the caller will highlight. Folding one BMP unit at a time preserves every column
exactly, at the price of the pairs nobody types into a find bar expecting the other (`ß`/`SS`). And
the answer's columns are UTF-16 units, not scalars: the surface indexes in UTF-16, so counting them
anywhere else would mean a second walk per match, in Swift.

**The door is §4's blob, not §4b's handle**, because a match is three numbers and needs no arena.
It leads with a `[uint32 count]` anyway — zero matches is where the find bar sits for most
keystrokes, and a §4 return of `0` already means "no answer", so a derived count would make
"nothing matched" indistinguishable from "ask again".

Pinned by the PRE-EXISTING Swift suites, unchanged: 20 `TerminalSearchControllerTests` and 11
`GlobalSearchControllerTests` pass against the marshaller exactly as they did against the walks.

## The third untrusted pattern was the one on the read loop (2026-08-17)

`wait --until PATTERN` is how an agent blocks on a marker appearing in a pane. The pattern comes
from the agent, the text comes from whatever program holds the far side of the PTY, and
`WaitUntilScanner` matched them with `NSRegularExpression` — on the PTY READ-LOOP thread. Hint Mode's
version of this hazard hangs an overlay and ⌘F's hangs a find bar; this one stalls the thread every
pane's bytes come through. It was the worst of the three and the least visible.

So it moved into `slopdesk-rowscan` beside the other two, and the crate stopped being "row scans"
in the narrow sense: `waituntil` holds STATE, because its text is not a buffer that exists — it is a
stream arriving a chunk at a time. All three carried pieces went with it: the raw carry that holds
back a chunk ending mid-escape, the fixed overlap window that lets a marker span a boundary, and the
capped accumulation. Leaving any one of them in Swift would have been a second implementation of an
incremental scan, which is exactly how the strip and the holdback drifted apart the last time.

**The crate took `slopdesk-sanitize` as a second sibling**, for the stripper and the
where-does-this-chunk-stop-being-decidable rule. `slopdesk-sanitize` refuses external dependencies
for the same reason `slopdesk-terminal` does, and the same reading applies: the module that needs a
regex engine lives here and reaches back, rather than smuggling one in beside the stripper.

**The door is a handle**, unlike the find scan's blob — a scan that carries state is what §4b is
for, and `new` answers NULL when the pattern does not compile. Null is an ERROR here rather than an
empty scan: this pattern arrived whole from an agent, so a mistyped one has to be reported, not
silently blocked on until the timeout. The dialect change costs the same lookaround and
backreferences it costs everywhere else.

Pinned by the pre-existing suite: 8 `WaitUntilScannerTests` and 47 `AgentControlListenerTests` pass.
The only test edit is the two lines that built a scanner — an `NSRegularExpression` became a pattern
string, and a `var` became a `let` now that the scanner is a class holding the handle.

## One clustering was not enough: there were still two width tables (2026-08-17)

Moving the vi motions beside the link scan gave the cursor and the hint badge one CLUSTERING. It
did not give them one answer, because underneath sat two hand-written tables saying how wide a
cluster is — `slopdesk-sanitize::width::scalar_width`, which the screen model measures a pane with,
and `slopdesk-terminal::link`'s `is_zero_width`/`is_wide`, which the cursor, the ⌘-hold underline
and the hint badge measure the same row with. They disagreed in three ways, each in a different
direction:

- **sanitize knew marks terminal did not** — the Arabic, Hebrew, Cyrillic and Thai combining ranges
  (U+0483–0489, U+0591–05BD, U+0610–061A, U+064B–065F, U+06D6–06DC, U+0E31, U+0E34–0E3A). On a Thai
  line the overlay counted every mark as a cell the screen model did not.
- **terminal knew ignorables sanitize did not** — the whole `Default_Ignorable_Code_Point` set, so
  a soft hyphen or a bidi control shifted every column below it in the screen model only.
- **terminal painted U+1F300..U+1FAFF wide with one brush** — which swallows the ornamental
  dingbats, the alchemical symbols and Supplemental Arrows-C, all of them NARROW.

They also straddled the Hangul split incompatibly. The merged table takes the standard reading: the
leading jamo at U+1100..U+115F carries the cell, and U+1160..U+11FF — the medial filler and the
trailing jamo — compose onto it at zero.

`slopdesk-terminal` now reads `slopdesk-sanitize`'s table and keeps no copy. Its manifest already
settled that a path dependency on a sibling under the same `forbid(unsafe_code)` contract is not
the supply chain its "no external dependencies" rule guards against — `slopdesk-wire` took
`slopdesk-workspace` for exactly this reason, to stop spelling six enums twice.

**The rule this is an instance of:** one implementation means one at every layer it decomposes
into. A shared clustering over two width tables is two implementations wearing one name, and it
fails on precisely the rows nobody types by hand. `check-supervisor.sh` now greps every source file
in the tree for the CJK sentinel `0x4E00`, which is the cheapest tell that a third table has
appeared: nothing measures East Asian width without it.

## The hand-written JSON stays, but not for the reason it said (2026-08-17)

`slopdesk-workspace/src/json.rs` is ~700 lines of parser and writer, and its header justified them
with a supply-chain argument: `serde_json` would be "the first third-party dependency in a crate
whose whole supply-chain story is that it has none". **That argument is dead.** `src/secrets.rs`
took `regex` — a bigger transitive tree than `serde_json` — so the premise stopped being true, and
the audit had to re-decide the module on its merits rather than inherit a stale ruling.

It survives on the WRITER, and only the writer. Both persistence files are on disk today in Swift's
`.prettyPrinted` spelling, and `serde_json`'s pretty formatter disagrees with it three ways --
measured against `serde_json` 1, not assumed:

| | this module | `serde_json` |
| --- | --- | --- |
| object separator | `"a" : 1` | `"a": 1` |
| U+007F | `\u007f` | emitted raw |
| U+0008 / U+000C | `\u0008` / `\u000c` | `\b` / `\f` |

Each divergence is a whole-file diff on every user's first save after the swap. Buying them back
means a hand-written `serde_json::ser::Formatter` impl — most of what would have been deleted,
re-added with a dependency underneath it. Porting the parser alone is worse still: a parser and a
writer that disagree about one file's shape is two implementations of that file.

**What would reopen it:** the on-disk spelling being allowed to change for some other reason. Then
the module goes at once, not in halves. The two OTHER `json.rs` modules in the tree — codeseed's
and inspectord's — are already accessors over `serde_json::Value`, not a third JSON.

## The fifth CSI parser is gone (2026-08-17)

`slopdesk-sanitize/src/vtscan.rs` opens by saying why it exists: "The Swift originals hand-rolled
this four times over ... it is one implementation, and a bug in the CSI parameter ranges is fixable
in one place instead of four."

`slopdesk-altscreen` was the fifth. It carried its own `ESC`, `BEL`, `parse_csi` and
`string_sequence_end` — and it is the crate that decides, from bytes an evictor is about to drop,
whether tens of MiB of alt-screen churn replays into a user's scrollback. Two scanners disagreeing
about where one sequence ends is how that crate and the replay passes reach different answers about
the same bytes. Same shape as the two width tables, one layer down.

The copies turned out to be semantically identical: its `parse_csi` matched `vtscan::parse_csi`
range for range, and its `string_sequence_end` was exactly `Terminators::replay(bel)`. All 18 of
its tests passed against the shared scanner UNCHANGED, which is the evidence that this was
duplication and not divergence — caught before it became a bug rather than after.

Two behaviours the deleted parser enforced implicitly now have tests, because the shared `Csi`
REPORTS what the local one decided:

- **an intermediate byte disqualifies a look-alike DECSET.** The old parser zeroed its own
  `final_byte` when intermediates were present; `vtscan` hands back both, so `alt_transition_param`
  makes the call where it can be read.
- **a bare `ESC` inside an OSC body does not end it.** `vtscan` offers `Terminators::lenient()`,
  which would; this crate must stay on `replay()`, or the scan walks into body text and reads an
  embedded `?1049h` as a real transition.

**The crate's "empty dependency list" was not the argument it looked like.** That rule guards
against parsing foreign bytes with a foreign crate; `slopdesk-sanitize` is a sibling under the same
`forbid(unsafe_code)` contract, which is the distinction `slopdesk-terminal` already drew when it
took the same edge for the width table.

**Not a sixth copy:** `slopdesk-screend/src/model.rs` walks CSI too, but incrementally, byte at a
time, into a cell grid — it interprets parameters, where `vtscan` only answers "where does this
end" over a whole buffer. Different question, correctly separate.

## Every FFI door is called, or is a written-down decision (2026-08-17)

The audit swept all 803 doors in `slopdesk_ffi.h` against every Swift call site. Four had no caller,
and they were three different problems wearing one symptom:

- `slopdesk_replay_result_count` — a SECOND way to ask something a live door already answers.
  `slopdesk_replay_messages` and `slopdesk_replay_replay` RETURN the count they staged, so the
  caller holds it before it can index anything. Two doors answering one question can only ever agree
  or be a bug. **Deleted**, with a comment in its place naming the one way.
- `slopdesk_inspector_decoder_buffered` — a hook held open for a Swift test that was never written.
  `FrameDecoder::buffered_len` is asserted natively in `slopdesk-wire`, on the side that owns the
  buffer. A door kept for the other language's test is the cross-language mirror fixture the
  one-implementation rule bans. **Deleted.**
- `slopdesk_swipe_nav_config_free` and `slopdesk_zoom_reset_policy_free` — destructors whose only
  shipped owners are process-lifetime `static let`s that say, in their own doc comments, that
  nothing frees them. A singleton is not a leak. **Kept**: a constructor whose ABI offers no
  destructor is what makes the next owner — one that is per-window rather than per-process — leak
  for real.

**The gate is the point, not the four.** `scripts/check-ffi-doors.py` now runs in `make lint`: every
door is called from Swift, or is named in its `DELIBERATE` map WITH the reason. A bare name added
there is the failure the file exists to prevent, so the allowlist is the review. It also fails on a
STALE exemption — a door that is now called, or that no longer exists — for the same reason
clippy's `#[expect]` warns when unfulfilled.

This is the second failure mode of a linked port. `build-ffi.sh --check` catches the loud one, an
artifact older than its sources. A dead door is the quiet one: it costs nothing at runtime and
everything at read time, because the next reader cannot tell "the way to ask" from "a way nobody
asks" without doing what this audit did by hand, four times.

## The inner loop's floor was twenty-one tree walks (2026-08-17)

`make quick` runs `lint-supervisor` on every edit, and it was **44 s** — the single largest fixed
cost in the loop, and the Makefile called it "the honest price of the cross-language contracts".
Most of it was not the contracts. It was **31 s of the same file tree, walked over and over**:

- **25 "this Swift must stay deleted" bans**, each its own `grep -r … Sources/`, each asking for a
  list that is EMPTY every time the gate passes. They were written in four different shapes — a
  one-line assignment, a wrapped one, a `2> /dev/null` one, and a bare `if grep -rq`; the shapes are
  why the repetition was easy to miss. One union walk now collects candidates and each ban
  re-greps only those — no files at all in the passing case.
- **four per-file loops**, spawning a grep (sometimes two) for every one of ~1000 files, to answer a
  question one `grep -l` over the list answers first. Two of the four were added the same day, in
  this audit, which is how a floor gets built.

**44 s → 31 s**, all 102 checks still running and all still firing — verified by planting a
violation for each rewritten gate and watching it fail.

**The trick is the one `spells` already used**, and its correctness argument is the same one:
stripping, or filtering, can only ever REMOVE a match, so a file the first pass rejects could not
have matched afterwards. Every ban keeps its own pattern and its own message; the union is a filter,
never the answer.

**The union is verified, not trusted.** Drop one ban's pattern out of it and that ban stops seeing
its own violation — and reports SUCCESS, because an empty candidate list is exactly what passing
looks like. That is the silent pass this gate has an entire section warning about, so
`scripts/check-ban-union.py` runs in `make lint` and fails if any ban is not spliced into the union
verbatim — which also forces the four shapes into one, since only the `among_deleted` form is seen. The check is textual on purpose: regex-superset is not a thing to decide in a lint gate,
and verbatim splicing is both the convention and the whole argument.

## The screend wire becomes a crate, because stage 17 only half-landed (2026-08-17)

Stage 17 ruled that each protocol's client end moves INTO Rust so the round trip becomes a test
rather than an agreement two files keep by review. dropd's Swift original was deleted in that
change. screend's was not. `ScreenProtocol.swift` went on hand-writing the request frame, the
detect payload and the reply split for a whole stage after the Rust versions landed beside the
decoders that read them back — so the property the ruling bought was never actually bought here.

**They had already diverged, which is the argument.** Both ends refused an over-long detect label
and refused differently: Swift threw `frameTooLarge`, Rust truncated to the prefix's capacity. Rust's
reading survives, and its own doc argues it — a truncation is a wrong answer where a throw is no
answer at all, and no manifest label is within three orders of magnitude of 64 KiB.

**The wire moved to `rust/slopdesk-screenwire` rather than staying in screend's crate.** This does
not reopen the stage-17 ruling: both ENDS moved together, so the round trip is still one crate's
test. What the split buys is that the app can link the WIRE without linking the ENGINE — screend
carries `regex`, `toml`, `serde` and a per-byte screen model, none of which belongs in an iOS
binary, and the whole point of screend being a daemon is that the app does not parse screens. It is
`slopdesk-sanitize`'s reason exactly, and that crate came out of screend for it.

**The crate keeps `indexing_slicing` denied where screend allows it.** screend's exemption is about
a terminal GRID, whose coordinates are clamped on the way in. There is no grid in a framing layer:
every byte it decodes arrived over a socket, so `decode_request` was rewritten onto
`split_at_checked` plus a slice pattern. The length check is the proof and the pattern is what makes
the compiler hold it.

**What stayed in Swift is a VOCABULARY, not a layout** — verb numbers, status numbers, flag bits,
the hello banner. `check-supervisor.sh` already pins those across the two languages the way it pins
the other five daemons', and a door per constant would buy nothing that ratchet does not, at the
cost of a call on a path that runs per scan.

## A viewport op stays in Swift, and its Rust twin was deleted (2026-08-17)

**Ruling: `rust/slopdesk-workspace`'s `tree_ops` keeps the ops an INTENT performs and nothing else.
Seventeen functions that had no caller were deleted rather than wired to Swift.** Do not re-propose
porting `WorkspaceTreeOps.swift` into them.

The seventeen: `toggle_zoom`, `resize_divider`, `even_divider`, `resize_active_pane`,
`balance_splits`, `move_pane_in_direction`, `apply_layout`, `cycle_layout`, `move_focus`,
`cycle_pane_target`, `cycle_pane_focus`, `select_tab`, `insert_pane_at_root_edge`,
`move_leaf_to_active_tab_root_edge`, `reattach_pane_beside`,
`reattach_pane_to_active_tab_root_edge`, `reattach_pane_to_new_tab`. Every one had a live twin in
`Sources/SlopDeskWorkspaceModel/Domain/Tree/WorkspaceTreeOps.swift` or an intent in
`slopdesk_wire::document::apply` — which is what the audit was looking for, a second implementation
in the other language, and it was the RUST half that was dead.

**How they got there.** `tree_ops` was written as the whole op set, before the intent applier
existed. When `document::apply` became the one decider of what a topology becomes, it reached in for
the ops it needed — split, close, focus, swap, dock, detach, reattach, and the tab and session verbs
— and left the rest compiling with nothing calling them. A zoom toggle became the `SetZoom` intent, a
tab select became `FocusTab`, a gutter dock became `DockPaneAtTabEdge`, and each of those decides in
`apply.rs` without touching the `tree_ops` function of the same name.

**Why the answer is not "wire them up".** The ones left over are VIEWPORT ops: a divider nudge, a
directional focus step, a directional move, a re-tile. Each needs the geometry the person is looking
at — solved frames, a live rect — which the document does not have and must not grow. The Swift side
is already thin: `WorkspaceTreeOps` navigates to a tab and calls `slopdesk_ws_tree_*`,
`slopdesk_ws_retile`, `slopdesk_ws_focus_neighbor` or `slopdesk_ws_solve_layout`, so every DECISION
in it is already in Rust; what is in Swift is which tab to apply it to. Routing the ops themselves
would mean crossing a whole `TreeWorkspace` — the document's own snapshot encoding, the one
`slopdesk_ws_apply_intent` uses — once per frame of a divider drag, to move one weight. That is the
measured regression `CLAUDE.md` names as the only veto, and `slopdesk_ws_retile`'s own doc already
ruled on the same question for the tiler: what crosses is the leaf ORDER in and the tree out,
because that is the only part of a re-tile that is a decision.

**What the deletion cost, stated.** Twenty-two tests went with the functions. Eleven of those also
covered a LIVE op, so they were restored with the dead call edited out: a test that zoomed a tab
through `toggle_zoom` in order to assert what a SPLIT does to a zoom now sets `zoomed_pane` as a
field, which is the more honest spelling anyway — the zoom verb is an intent, not a `tree_ops`
function, so reaching for one to build a starting condition was always describing the wrong thing.

## Four things the audit looked at and left alone (2026-08-17)

The migrate/duplicate/leftover/reinvented sweep produced findings that were fixed, and four it
deliberately did not. Each is a shape that reads like a violation from the outside, so each is
written down with what makes it not one. Do not re-propose these.

**The sniffer keeps its own escape-sequence state machine; `vte` is not the wheel it is missing.**
`rust/slopdesk-superd/src/sniffer.rs` walks OSC 0/2/7/9/99/133/777 with a hand-written grammar, and
alacritty's `vte` is the maintained parser that grammar resembles. Two things stop the swap, and
both are in the file. First, the caps are per-OSC: 4096 for a title, 256 for a command mark, 1024
for a notification, chosen by OSC number because a kitty payload and a status mark have nothing to
do with each other's hostile case — `vte` has one raw buffer for all of them. Second,
`skim_ground` is a bounded `ESC`/`BEL` scan, not a per-byte loop, and its own doc explains why the
bound is there: this runs on every byte of every PTY's output, which is the hottest path in the
product. A per-byte `Perform` dispatch is the measured regression `CLAUDE.md` names as the veto.
`base64` was the opposite call and was taken (2026-08-15): a codec with one shape and no hot path.

**`rust/slopdesk-fuzzy` stays a port of fzf, not a dependency on `nucleo-matcher`.** The crate says
what it is in its first line — `FuzzyMatchV2`, the DEFAULT scheme's constants, the edge-triggered
bonus matrix, upstream's tie-breaking. `nucleo` is actively maintained and fzf-LIKE, which is the
problem: what the palette promises is that it ranks the way fzf ranks, and the crate's 31 tests are
that promise written down. Swapping the ranker would keep the feature and delete the assertions,
because there would no longer be anything to assert against.

**`SupervisorProtocol.swift` is a vocabulary across a socket, not a second implementation.** Twenty
`Codable` structs whose names also exist in `slopdesk-superd` is what a JSON message set looks like
from both ends of a Unix socket. A separately-shipped binary cannot link the other's types, so the
answer is the one `CLAUDE.md` already gives for a socket port: `check-supervisor.sh` ratchets the
two spellings. It does.

**`WorkspaceTopology.entries()` and `init?(entries:)` are marshalling, and the drift they can carry
is now asserted rather than ported.** The Swift projection and `document::topology`'s look like one
function written twice. They are not: the DECISION — what a split does, which tab takes focus —
moved to `document::apply` on 2026-08-16 and exists once. What is written twice is each language's
projection of ITS OWN model shape onto the shared document, and the Swift shape has to exist because
SwiftUI diffs values. Dissolving it would mean `TreeWorkspace` becoming a handle, crossed once per
frame of a divider drag.

What the two projections DO share is the field alphabet, and that was the real finding: a byte
keyed differently on the two sides is invisible to every Swift round-trip test, because a field
mis-keyed by both the writer and the reader round-trips perfectly. Two gates now cover it —
`check-shared-constants.py` ratchets `WorkspaceFields.swift` against `document::fields` letter for
letter, and `WorkspaceTopologyTests.testTheWholeTopologyCrossesToTheCrateAndBack` sends the rich
fixture through `slopdesk_ws_apply_intent` and back, which drops anything the crate keys elsewhere.

## The client UI was two products in one target, so it becomes two (2026-08-17)

`SlopDeskClientUI` splits into `SlopDeskMacUI` (AppKit, macOS) and `SlopDeskPhoneUI` (SwiftUI, iOS).
The full measurement and the boundary rules are [56-client-ui-split.md](../56-client-ui-split.md); the
three numbers that decided it are here.

**It was already two targets.** 183 files, 48 410 lines — and 72 of those files compile to NOTHING
on iOS. The macOS slice is 27 037 lines, the iOS slice 16 840, and a good share of the iOS slice is
accidental: `CodeSidebarRecommendationTips` (838 lines), `WorkspaceControlBackend` (308),
`PaneDragCoordinator` (246) and `ClientControlServer` (171) are compiled into the iOS app for a code
panel, a control socket and a pane-drag gesture that platform does not have.

**On macOS the escape hatch is already the norm.** 53 files import AppKit, with 19
`NSView`/`NSViewController` subclasses, 13 `NSViewRepresentable`, 21 hosting mounts and 32
`swiftui-introspect` sites — each of the last a place SwiftUI did not expose what was needed. Every
hard interaction has already fallen out of SwiftUI and landed in AppKit: the divider drag, the rail
drag-and-drop (both SwiftUI DnD sides failed — 2026-07-12), the satellite windows, and the shell
itself. This entry therefore REVERSES "Shell = pure SwiftUI `NavigationSplitView`" (2026-07-03),
which the code had already reversed in practice — macOS runs `SlopDeskSplitViewController` today.

**The two arguments for keeping SwiftUI on macOS do not hold here.** `#Preview`/`PreviewProvider`
across `Sources/` and `Tests/`: zero — the design loop is pixel-verify against a screenshot, which
AppKit runs identically. And of 114 `SlopDeskClientUITests` files only 11 import SwiftUI and 4 touch
a `body`: the logic is already outside the views, so the suite survives the port.

What the port actually costs is motion — 118 `withAnimation`/`.animation(` sites and 3
`matchedGeometryEffect` morphs become explicit `CAAnimation`/`NSAnimationContext`. That is work, not
risk, and it puts the timing in the same place the pixel-verify loop measures it.

**iOS keeps every feature; only the LAYOUT differs.** The phone and the iPad are not a reduced
desktop — the code panel, the simulator and Android panels, splits, the palette and the rail all
exist there, arranged for a small screen and a touch pointer. SwiftUI reaches that ceiling: the
limitations that pushed macOS out (divider drags, cross-hosting-view drag-and-drop, secondary
windows) are macOS-shaped problems.

**Which makes stage one an evacuation, not a copy.** Feature parity across two view frameworks is
only affordable if the features are not IN the view framework. So before either half is written,
everything in `SlopDeskClientUI` that is not a view type — models, reducers, socket clients, wire
codecs, policies, caches — moves to the shared logic target. Two halves each carrying their own
`SimulatorSidebarModel` (731 lines) and `AndroidSidebarModel` (833) would be one product implemented
twice, which `CLAUDE.md` bans by name. After the evacuation a UI target holds layout and actuation
only, and "the same feature, laid out differently" costs a view rather than a subsystem. It also
puts every pure-logic file in one place, which is where §4 of doc 56 starts the Rust ports.

Neither UI target imports the other. `#if os(...)` inside one is a smell — the file is in the wrong
target — with one exception: the whole-file guard that declares `SlopDeskPhoneUI` iOS-only to
`swift build`, which compiles every SwiftPM target on the host triple.
