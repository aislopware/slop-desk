//! The gate RUNNERS — the seven that had to build, boot or execute something.
//!
//! ## Why these are here and not in `slopdesk-invariants`
//! That crate holds the rules a gate can decide by READING the tree, and its gate is `cargo test`.
//! Nothing in it may spawn `xcodebuild`, boot a simulator or run `swift test`, because a unit test
//! that takes eighty-five seconds and needs a provisioned toolchain is not a unit test. These seven
//! are the other half: orchestration whose verdict comes from a process, not from a pattern.
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
//! ## Can a COMMENT satisfy one of these? The census, so nobody re-runs it
//! `slopdesk-invariants` closed that class over the tree: a positive claim — one that must be
//! SATISFIED — answered by a sentence rather than by code. These gates read text too, so the same
//! question was asked of every reading site here, and the answer is per-site rather than global.
//! ALL TEN modules are below, including the four that read no source text at all, because "not
//! listed" and "listed as clean" are the same line to whoever reads this next and only one of them
//! is a fact.
//!
//! * [`reach`] — YES, and it is fixed. `just --dry-run` echoes a comment inside a recipe body
//!   verbatim, so `# cargo +nightly miri test` in `check` satisfied the obligation `CLAUDE.md`
//!   names as the price of `rust/slopdesk-gfsimd`'s `unsafe`. `reach::commands_only`, before the
//!   substitutions.
//! * [`golden`] — YES, and it is DOCUMENTED rather than fixed. `readers` counts a file that names a
//!   frozen key in prose while opening the corpus; the honest fix needs literal-preserving comment
//!   stripping, which lives in another cargo workspace. `NOT_A_READER` says the rest, and the
//!   measurement is there: zero of the 27 frozen keys are prose-only today.
//! * [`ffi`] — no, in both halves. A commented declaration in the header mints a symbol the built
//!   library does not export, which fails LOUD, and `path_dependencies` rejects a name carrying a
//!   `#` before it ever looks for a path.
//! * [`stamp`] — no. `products_named_in` matches `product:` and `- package:` at the START of a
//!   trimmed line, and a YAML comment puts a `#` there first.
//! * [`prepush`] — no. A commented `rust/slopdesk-x/target` adds an EXPECTED daemon, so the gate
//!   demands a binary that is not there: loud, not quiet.
//! * [`swift_graph`] — no. The closure comes from `swift package describe`, which is `SwiftPM`'s
//!   own resolution rather than a scan, so a commented `import` is not an edge.
//! * [`xcode`] — the one other module that reads SOURCE, and it fails loud. `declared_tests` counts
//!   `func test…` across `Apps/ClientApp-iOS/Tests` and demands the simulator execute exactly that
//!   many, so a commented-out declaration INFLATES the left side and reds a run that was green: a
//!   false alarm, never a false pass, because the right side is `xctest`'s own summary. Measured on
//!   the tree today: 23 declarations, none of them in a comment. Left unstripped on purpose — the
//!   honest fix is the same shared literal-preserving stripper [`golden`] is waiting on, and a
//!   second hand-rolled `//` filter here is the duplication that note exists to refuse. Everything
//!   else it reads — `simctl list`'s JSON, the xcodebuild log, the `Executed N tests` count — is
//!   process output, which no comment in this tree can write.
//! * [`touched`] — no source read at all. The change set is `git diff --name-only` and `git
//!   ls-files --others`, the graph is `swift package describe`'s JSON: three processes.
//! * [`android`] — no. `ready_devices` parses `adb devices`, and the toolchain search asks the
//!   filesystem `is_file`, not a scanner.
//! * [`supervisor`] — no. It reads nothing; it builds the sidecar binaries the Swift suites launch
//!   and lets `cargo`'s exit code be the verdict.
//!
//! The discriminator is the one that crate arrived at: a claim that must be SATISFIED must not read
//! prose, and a BAN may, because a comment makes a ban fail loud rather than pass quiet.
//!
//! ## The one thing that changed on the way over
//! Both stampers now hash repo-RELATIVE paths, for the reason [`super::release::stamps`] does. The
//! stamps live under `.build/`, so the first run after this port rebuilds once and is warm after.

pub mod android;
pub mod code_text;
pub mod ffi;
pub mod golden;
pub mod prepush;
pub mod reach;
pub mod stamp;
pub mod supervisor;
pub mod swift_graph;
pub mod touched;
pub mod xcode;
