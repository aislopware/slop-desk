//! The release pipeline, as one program instead of eight shell scripts.
//!
//! ## What was here before
//! `shipped-tools.sh`, `tool-stamps.sh`, `bump-tool-versions.sh`, `bump-version.sh`,
//! `changelog-section.sh`, `render-changelog.sh`, `cut-release.sh`, `check-commit-msg.sh` and
//! `package-release.sh` — 1 503 lines of bash, one `source`d data file, and a `python3 -c` that
//! existed only to parse a JSON document the shell above it had just printed by hand.
//!
//! They shared everything: the tool table, the semver arithmetic, the conventional-commit grammar,
//! the `[package]`-anchored manifest read. In shell that sharing cost a `source` line per reader
//! and a second copy of `awk '$1 == t { print $2 }'` per question. Here the sharing is a module
//! boundary, and every one of those decidable halves has a test beside it — which is the thing the
//! shell versions could not have. Their break-tests were prose in a comment; these are
//! [`commitmsg::tests`], [`bump::tests`], [`changelog::tests`], [`sites::tests`] and the rest, and
//! `cargo test` runs them on every commit.
//!
//! ## What is still a process, and why
//! [`crate::proc`] spawns `xcodebuild`, `codesign`, `notarytool`, `hdiutil`, `ditto`, `tar`,
//! `xcodegen`, `git` and `git-cliff`. Every one of those is a thing a compiled program genuinely
//! cannot do itself. Nothing else shells out: the digests, the JSON, the version arithmetic, the
//! file rewriting and the Mach-O check are all in-process, which is where the wall-clock went.
//! It started here and moved up a level when [`crate::gates`] and [`crate::ops`] turned out to
//! need the same four functions — a seam three module families share is not the release's.
//!
//! ## The order a cut runs in
//! ```text
//! cut  →  changelog render --tag vX     (the notes, from the commit log)
//!      →  changelog section X           (the gate: no section, no tag)
//!      →  bump-product X                (the six PRODUCT sites)
//!      →  bump-tools                    (each sidecar that its stamp says moved)
//!      →  git commit + git tag          (never a push)
//! ```

pub mod bump;
pub mod changelog;
pub mod commitmsg;
pub mod pack;
pub mod sites;
pub mod stamps;
pub mod tools;
