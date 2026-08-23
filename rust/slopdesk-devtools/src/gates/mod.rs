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
//! ## The one thing that changed on the way over
//! Both stampers now hash repo-RELATIVE paths, for the reason [`super::release::stamps`] does. The
//! stamps live under `.build/`, so the first run after this port rebuilds once and is warm after.

pub mod android;
pub mod golden;
pub mod prepush;
pub mod stamp;
pub mod swift_graph;
pub mod touched;
pub mod xcode;
