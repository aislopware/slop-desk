//! The gate RUNNERS — the ones that had to build, boot or execute something.
//!
//! ## Why these are here and not in `slopdesk-invariants`
//! That crate holds the rules a gate can decide by READING the tree, and its gate is `cargo test`.
//! Nothing in it may spawn `xcodebuild`, boot a simulator or run `swift test`, because a unit test
//! that takes eighty-five seconds and needs a provisioned toolchain is not a unit test. These are
//! the other half: orchestration whose verdict comes from a process, not from a pattern.
//!
//! What they have in common is what makes them worth porting together — every one of them was a
//! shell script whose only untested part was the DECIDABLE half:
//!
//! * [`stamp`] — the content stamp that lets a build gate cost nothing when no compiled input
//!   moved. It was two copies of the same eight lines of `find | shasum | shasum`, in
//!   `check-ios.sh` and `check-macos-apps.sh`, and it hashed ABSOLUTE paths — so the same tree
//!   checked out twice stamped differently and each checkout paid the eighty-five seconds again.
//! * [`swift_graph`] — the `SwiftPM` dependency closure `test-touched.sh` used to attribute a
//!   change set to test targets. It was a `python3 -c` heredoc inside a `$( … )`, so its own
//!   selection logic could not be tested without running a build.
//! * [`golden`] — the two pinned key sets over `golden/golden_vectors.json` and the byte diff. Also
//!   a `python3 -c`, and the one gate in the tree whose failure mode is a silently CHANGED wire.
//! * [`touched`], [`prepush`] — the two halves of the test cache, which share a marker pair and
//!   must agree about what "clean" means or the marker means nothing.
//! * [`xcode`] — the three xcodebuild gates: the iOS typecheck, the macOS app-shell typecheck, and
//!   the only thing in the tree that EXECUTES an assertion on the iOS triple.
//! * [`android`] — the hardware gate's tool resolution, which has to reproduce production's own
//!   search order or it proves the handshake against the wrong `adb`.
//!
//! Three more arrived with the last of the shell. [`ffi`] is `slopdesk-gate ffi`: the producer of
//! the linked port, whose decidable halves — the header's declared symbols, the transitive crate
//! closure, the two-direction bijection — were `grep -oE`, a recursive `grep | sed`, and a `comm`
//! that could not be run without building three slices. [`reach`] is the four questions only a
//! `just --dry-run` can answer, and [`supervisor`] is the hostd↔superd contract's toolchain half.
//! With them the `scripts/` directory holds no code at all: two Swift probes, a set of pins and a
//! fixture tree.
//!
//! [`corpus`] asks the same shape of question of GIT rather than of the working tree: no COMMITTED
//! terminal recording carries the machine it was made on. A recording that was made and rejected is
//! still on disk, so the working tree and the repository genuinely disagree, and only the
//! repository's answer is fixable by a change to the repository.
//!
//! [`hooks`] arrived last and is the only one that was never a script. It asks what GIT would run,
//! which is the same shape as [`reach`]'s question about `just` and unanswerable from the tree for
//! the same reason: the answer is in `.git/`, which is untracked, per-clone, and movable by
//! `core.hooksPath`. It exists because the answer had been NO for three weeks without a red line
//! anywhere — see its own header for the count.
//!
//! ## Can a COMMENT satisfy one of these? The census, so nobody re-runs it
//! `slopdesk-invariants` closed that class over the tree: a positive claim — one that must be
//! SATISFIED — answered by a sentence rather than by code. These gates read text too, so the same
//! question was asked of every reading site here, and the answer is per-site rather than global.
//! EVERY module in this directory is below, the ones that read no source text at all included,
//! because "not listed" and "listed as clean" are the same line to whoever reads this next and only
//! one of them is a fact.
//!
//! The count used to be spelled out here — "ALL ELEVEN" — and it went stale the moment
//! [`code_text`] landed, which is the module that reads the MOST source text of any of them. A list
//! that states its own length states it once and is then wrong in silence, so the length is not
//! written down any more: `slopdesk-invariants`' `census-is-complete` compares the bullets below
//! against the `pub mod` lines at the bottom of this file, in both directions.
//!
//! * [`reach`] — YES, and it is fixed. `just --dry-run` echoes a comment inside a recipe body
//!   verbatim, so `# cargo +nightly miri test` in `check` satisfied the obligation `CLAUDE.md`
//!   names as the price of `rust/slopdesk-gfsimd`'s `unsafe`. `reach::commands_only`, before the
//!   substitutions.
//! * [`golden`] — YES, and it is fixed. `readers` counted a file that named a frozen key in prose
//!   while opening the corpus, and the minter — which explains fourteen of them in comments — was
//!   excluded by PATH, closing one file rather than the class. The honest fix needs
//!   literal-preserving comment stripping, and that used to live in another cargo workspace; it is
//!   [`code_text`] in this directory now, so every candidate is read as code and the allowlist is
//!   gone. `golden::tests::every_frozen_key_in_this_tree_has_a_reader` holds the measurement.
//! * [`ffi`] — no, in both halves. A commented declaration in the header mints a symbol the built
//!   library does not export, which fails LOUD, and `path_dependencies` rejects a name carrying a
//!   `#` before it ever looks for a path.
//! * [`stamp`] — no. `products_named_in` matches `product:` and `- package:` at the START of a
//!   trimmed line, and a YAML comment puts a `#` there first.
//! * [`prepush`] — no. A commented `rust/slopdesk-x/target` adds an EXPECTED daemon, so the gate
//!   demands a binary that is not there: loud, not quiet.
//! * [`swift_graph`] — no. The closure comes from `swift package describe`, which is `SwiftPM`'s
//!   own resolution rather than a scan, so a commented `import` is not an edge.
//! * [`xcode`] — the one other module that reads SOURCE, and it is fixed too. `declared_tests`
//!   counts `func test…` across `Apps/ClientApp-iOS/Tests` and demands the simulator execute
//!   exactly that many, so a commented-out declaration INFLATED the left side and redded a run that
//!   was green — a false alarm rather than a false pass, which is why it was left standing while
//!   the honest fix meant hand-rolling a second `//` filter here. [`code_text`] is that filter,
//!   shared, so the count is over code now. Everything else it reads — `simctl list`'s JSON, the
//!   xcodebuild log, the `Executed N tests` count — is process output, which no comment in this
//!   tree can write.
//! * [`touched`] — no source read at all. The change set is `git diff --name-only` and `git
//!   ls-files --others`, the graph is `swift package describe`'s JSON: three processes.
//! * [`android`] — no. `ready_devices` parses `adb devices`, and the toolchain search asks the
//!   filesystem `is_file`, not a scanner.
//! * [`supervisor`] — no. It reads nothing; it builds the sidecar binaries the Swift suites launch
//!   and lets `cargo`'s exit code be the verdict.
//! * [`hooks`] — no, and the `#` test is the FIRST thing `declared_stages` does. A commented
//!   `default_install_hook_types:` is not a declaration `prek` would read either, so honouring it
//!   would have this gate demand files for stages nothing installs. The other half of the claim is
//!   a directory listing, which no comment can write.
//! * [`corpus`] — no, and it is the one module where a comment is the SUBJECT rather than a way
//!   around the question. It reads bytes and asks whether a fingerprint is in them, so a `//` in
//!   front of one changes nothing: a leaked user name inside a commented-out line is still that
//!   user name, still committed, still in the history. The other half of the claim is `git
//!   ls-files`, which no comment can write.
//! * [`code_text`] — the question inverts, because it is not a gate: it is the READER the two fixed
//!   entries above go through. Nothing here can be satisfied by a comment in it; what it can do is
//!   the opposite and worse — mistake CODE for a comment, and hand a gate a haystack with the thing
//!   it was looking for cut out of it. That is the one direction its own header forbids, and what
//!   its tree canary measures on every file that ships.
//! * [`digest`] — the question does not arise, and that is the answer rather than a dodge: it is
//!   the other non-gate here, and it reads no text at all. What it takes is BYTES and a path, and a
//!   comment is bytes like any other — hashing one is the point. Its framing does carry an
//!   obligation of the same shape, though, which is why it is one module and not four lines in two
//!   gates: [`stamp`] and [`ffi`] both cache on this number, and a stamp whose framing drifted
//!   between them would answer a different question in each while looking identical.
//!
//! The discriminator is the one that crate arrived at: a claim that must be SATISFIED must not read
//! prose, and a BAN may, because a comment makes a ban fail loud rather than pass quiet.
//!
//! ## The one thing that changed on the way over
//! Both stampers now hash repo-RELATIVE paths, for the reason [`super::release::stamps`] does. The
//! stamps live under `.build/`, so the first run after this port rebuilds once and is warm after.

pub mod android;
pub mod code_text;
pub mod corpus;
pub mod digest;
pub mod ffi;
pub mod golden;
pub mod hooks;
pub mod prepush;
pub mod reach;
pub mod stamp;
pub mod supervisor;
pub mod swift_graph;
pub mod touched;
pub mod xcode;
