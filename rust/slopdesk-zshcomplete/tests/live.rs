//! The half no fixture can check: a LIVE zsh agreeing with the `compadd` scan.
//!
//! [`slopdesk_zshcomplete::parse`]'s own tests pin the reader against captured records, which is
//! the right test for a pure function and is blind to the one thing that can actually rot — the
//! override's flag scan. `compadd`'s flags cluster the way getopt's do, and a token-level reader
//! silently drops most of what `_arguments` sends. Only a real shell exercises that.
//!
//! Hermetic, and deliberately so. The first version of this suite asserted things about `ls --`,
//! which offers dozens of long options under GNU coreutils and none at all under the BSD `ls` a Mac
//! ships — a test of the machine, not of the code. What runs instead is a completion function this
//! file defines, replaying the exact clustered shapes that were found in real captures, so an
//! assertion here is about the scan and about nothing else.
#![expect(
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::path::Path;
use std::time::{Duration, Instant};

use slopdesk_zshcomplete::{Answer, ZshComplete};

/// A completion whose every `compadd` call is one of the forms that broke a naive parser.
///
/// - `-D _probe_names` — the pass `_describe` makes BEFORE the one carrying descriptions. It adds
///   nothing to the line, so reporting it would duplicate every candidate without its description.
/// - `-2V -default- -d … -a …` — a boolean clustered in front of a flag whose argument is the NEXT
///   word, with the matches and their descriptions both arriving as ARRAY NAMES that only exist in
///   this function's frame.
/// - `-qS=` — a boolean clustered in front of a flag whose argument is ATTACHED, and the argument
///   is `=`, which is what turns `color` into `color=`.
/// - `-p sub/` — the hidden prefix that makes a path candidate land in the directory already typed.
const PRELUDE: &str = r"
_slopdesk_probe() {
  local -a _probe_names _probe_desc
  _probe_names=(alpha beta gamma)
  _probe_desc=('alpha  -- the first' 'beta  -- the second' 'gamma  -- the third')
  compadd -D _probe_names -a _probe_names
  compadd -2V -default- -J -default- -X '[probe]' -d _probe_desc -a _probe_names
  compadd -qS= -- color
  compadd -p 'sub/' -- leaf
}
compdef _slopdesk_probe slopdeskprobe
";

/// The bridge, or `None` on a machine with no zsh to bridge to.
fn bridge() -> Option<ZshComplete> {
    let shell = [
        "/bin/zsh",
        "/usr/bin/zsh",
        "/usr/local/bin/zsh",
        "/opt/homebrew/bin/zsh",
    ]
    .into_iter()
    .find(|path| Path::new(path).exists())?;
    Some(ZshComplete::new(shell).hermetic(PRELUDE))
}

/// Asks until the shell is warm, or gives up. The first request only STARTS the shell — that is the
/// design, not a flake — so a caller that needs an answer has to ask more than once.
fn ask(bridge: &ZshComplete, buffer: &str) -> Vec<(String, String, Option<String>)> {
    let cwd = env!("CARGO_MANIFEST_DIR");
    let cursor = u32::try_from(buffer.chars().count()).unwrap_or(u32::MAX);
    let until = Instant::now() + Duration::from_secs(60);
    loop {
        match bridge.complete(cwd, buffer, cursor) {
            Answer::NotReady if Instant::now() < until => std::thread::sleep(Duration::from_millis(20)),
            Answer::Groups(groups) => {
                return groups
                    .iter()
                    .flat_map(|group| {
                        group
                            .candidates
                            .iter()
                            .map(move |item| (group.prefix.clone(), item.text.clone(), item.detail.clone()))
                    })
                    .collect();
            },
            other => panic!("the captive shell never answered: {other:?}"),
        }
    }
}

/// The whole reason the scan is per-CHARACTER rather than per-token. Every assertion below names
/// one clustered form; a parser that mis-reads any of them drops that call silently, so a MISSING
/// candidate is the failure this test exists to catch.
#[test]
fn a_real_zsh_answers_through_every_clustered_flag_form() {
    let Some(bridge) = bridge() else { return };
    let found = ask(&bridge, "slopdeskprobe a");

    // `-2V -default- … -d _probe_desc -a _probe_names`: the array names expanded in the caller's
    // frame, and the description array read alongside the match array.
    assert!(
        found.contains(&(
            "a".to_owned(),
            "alpha".to_owned(),
            Some("alpha  -- the first".to_owned())
        )),
        "the described pass was dropped: {found:?}"
    );
    // The `-D` pass adds nothing to the line, so it must not appear a second time WITHOUT its
    // description — which is exactly what reporting it would produce.
    assert_eq!(
        found
            .iter()
            .filter(|(_ignored, text, _also)| text == "alpha")
            .count(),
        1,
        "the `-D` filtering pass was reported as candidates: {found:?}"
    );
    // zsh filters against the line, so `beta` and `gamma` are correctly absent for `a` — the
    // capture reports what the completion system decided and never widens it.
    assert!(
        !found
            .iter()
            .any(|(_ignored, text, _also)| text == "beta" || text == "gamma"),
        "a candidate zsh had already ruled out was reported: {found:?}"
    );
}

/// `-qS=` and `-p sub/`: an ATTACHED flag argument, and the hidden prefix. Both change what an
/// accepted candidate inserts, so a parser that skips either produces a candidate that writes the
/// wrong text onto the user's command line — the one failure this design refuses to risk.
#[test]
fn a_real_zsh_composes_the_affixes_that_change_what_gets_inserted() {
    let Some(bridge) = bridge() else { return };
    let found = ask(&bridge, "slopdeskprobe c");
    assert!(
        found.iter().any(|(_ignored, text, _also)| text == "color="),
        "the attached `-S =` was dropped: {found:?}"
    );

    let found = ask(&bridge, "slopdeskprobe sub/l");
    assert!(
        found.iter().any(|(_ignored, text, _also)| text == "sub/leaf"),
        "the hidden prefix was dropped: {found:?}"
    );
    assert!(
        found.iter().any(|(prefix, _text, _also)| prefix == "sub/l"),
        "the replaced prefix is the WHOLE typed word, so the hidden prefix composes: {found:?}"
    );
}

/// A shell this build has no capture half for is a PERMANENT no, and it must be distinguishable
/// from a shell that is merely still warming up — a client that cannot tell them apart either
/// retries for ever or gives up on a shell that was about to answer.
#[test]
fn a_shell_that_is_not_zsh_is_a_different_answer_from_one_that_is_not_ready() {
    let bridge = ZshComplete::new("/bin/bash");
    assert_eq!(bridge.complete("/tmp", "ls -", 4), Answer::NotZsh);
    // And nothing was spawned: the answer is immediate and repeatable.
    assert_eq!(bridge.complete("/tmp", "ls -", 4), Answer::NotZsh);
}
