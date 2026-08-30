//! A raw handle's lifetime is its Swift object's, and the exceptions are named.
//!
//! ## The bug this rule was written from
//!
//! `VideoMuxClientFlow` freed its `slopdesk_video_flow_*` handle inside `close()` rather than
//! `deinit`. That reads as tidy and is a use-after-free: a flow is refcounted across every pane on
//! a host, so the `@MainActor` registry that ends it is never the thread inside
//! `VideoMuxClientTransport.send`, which reads the handle under a lock and then calls the door with
//! the lock RELEASED — it must, because the door calls back. Between those two instructions the
//! pointer can be freed. Nothing on the Swift side could close that gap: a lock held across a door
//! deadlocks through the release callback, which the register and unregister doors may run on the
//! caller's thread.
//!
//! ## Why `deinit` is the only free site that needs no argument
//!
//! Every caller reaches an object through a strong reference, so ARC has already proved the object
//! outlives any call on it. A free in `deinit` is therefore a free nobody can be racing, for free,
//! with no lock and no discipline anyone has to remember. A free ANYWHERE else is a claim about
//! which threads exist and what they are doing — sometimes a true claim, never an obvious one, and
//! never one the next edit to a distant file will re-check.
//!
//! ## What to do instead when a resource must end early
//!
//! Two doors, which `slopdesk_pane_driver_*` already had and `slopdesk_video_flow_*` now has: a
//! `_close` that tears the resource down and leaves the HANDLE valid, so a call already in flight
//! gets a cheap refusal, and a `_free` that runs only from `deinit`, where ARC has done the proof.
//! Ending a resource and releasing its handle are two different operations whenever the resource
//! outlives, or is shared beyond, the one thread that ends it.
//!
//! ## The ledger
//!
//! So the rule is: every `slopdesk_*_free(` call in `Sources/` is inside a `deinit`, unless the
//! file is booked below with the proof that makes it safe. Both directions are checked — a booked
//! file that has since moved its free into `deinit` is stale bookkeeping, and stale bookkeeping
//! reads exactly like a satisfied entry.

use std::collections::{BTreeMap, BTreeSet};

use crate::report::Report;
use crate::tree::Tree;

/// The proof a file offers for freeing outside `deinit`. The variant is the ARGUMENT, so a file
/// that fits none of them has not got one — which is the question a new entry forces someone to
/// answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Proof {
    /// The handle never leaves the stack frame that opened it: one function opens it, uses it and
    /// `defer`s the free, and stores it nowhere. No second thread can hold what was never
    /// published, so there is nothing for a free to race. This is the STRONGEST shape on the
    /// list — stronger than a stored handle freed in `deinit` — and a scan door should prefer
    /// it.
    ScopedToOneCall,
    /// Every call that touches the handle, the free included, rides ONE serial queue, and the file
    /// nils the stored pointer before the free so a later hop finds nothing. The queue is the lock
    /// that a door call cannot be holding, because the door is called from the queue itself.
    SerialConfinement,
    /// Exactly one site other than the free ever dereferences the handle, and the free cannot run
    /// concurrently with it. A callback context that outlives the handle is retained separately, so
    /// the far side never reaches back through the freed pointer.
    SingleToucher,
}

/// Every file that frees a handle outside `deinit`, and the proof it stands on. Kept sorted by
/// path.
const BOOKED: &[(&str, Proof)] = &[
    (
        "Sources/SlopDeskClientCore/Control/ClientControlHost.swift",
        Proof::SingleToucher,
    ),
    (
        "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
        Proof::SerialConfinement,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
        Proof::ScopedToOneCall,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift",
        Proof::ScopedToOneCall,
    ),
];

/// The byte ranges of every `deinit { … }` body in `code`, brace-matched.
///
/// Brace-matching rather than indentation, because a `deinit` that closes over a queue or unwraps
/// an optional nests, and a line test would call the free inside `if let handle { … }` an escape.
fn deinit_bodies(code: &str) -> Vec<(usize, usize)> {
    let bytes = code.as_bytes();
    let mut bodies = Vec::new();
    let mut from = 0;
    while let Some(offset) = code.get(from..).and_then(|rest| rest.find("deinit")) {
        let start = from + offset;
        from = start + "deinit".len();
        // A whole word, so `weakDeinit` or a `deinitialise` helper is not a body.
        let before = start.checked_sub(1).and_then(|index| bytes.get(index).copied());
        let after = bytes.get(from).copied();
        let boundary =
            |byte: Option<u8>| byte.is_none_or(|byte| !byte.is_ascii_alphanumeric() && byte != b'_');
        if !boundary(before) || !boundary(after) {
            continue;
        }
        let Some(open) = code
            .get(from..)
            .and_then(|rest| rest.find('{'))
            .map(|at| from + at)
        else {
            continue;
        };
        let mut depth = 0_usize;
        for (index, byte) in code.bytes().enumerate().skip(open) {
            match byte {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        bodies.push((open, index));
                        from = index;
                        break;
                    }
                },
                _ => {},
            }
        }
    }
    bodies
}

/// Every `slopdesk_*_free(` door `code` calls from outside a `deinit` body.
fn frees_outside_deinit(code: &str) -> BTreeSet<String> {
    let bodies = deinit_bodies(code);
    let mut escapes = BTreeSet::new();
    let mut from = 0;
    while let Some(offset) = code.get(from..).and_then(|rest| rest.find("slopdesk_")) {
        let start = from + offset;
        let door: String = code[start..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        from = start + door.len();
        if !door.ends_with("_free") || !code[from..].starts_with('(') {
            continue;
        }
        if !bodies.iter().any(|&(open, close)| open < start && start < close) {
            escapes.insert(door);
        }
    }
    escapes
}

/// Every Swift file under `Sources/` that frees a handle somewhere other than its `deinit`.
fn escapees(tree: &Tree) -> BTreeMap<String, BTreeSet<String>> {
    let mut found = BTreeMap::new();
    for (path, source) in tree.under("Sources") {
        if path.extension().is_none_or(|extension| extension != "swift") {
            continue;
        }
        let Some(path) = path.to_str() else {
            continue;
        };
        let escapes = frees_outside_deinit(source.code());
        if !escapes.is_empty() {
            found.insert(path.to_owned(), escapes);
        }
    }
    found
}

/// A handle dies with the object that holds it, or the file says why not.
#[must_use]
pub fn a_handle_is_freed_only_by_its_owners_deinit(tree: &Tree) -> Report {
    let mut report = Report::default();
    let found = escapees(tree);
    let booked: BTreeSet<&str> = BOOKED.iter().map(|&(path, _)| path).collect();

    for (path, doors) in &found {
        let doors: Vec<&str> = doors.iter().map(String::as_str).collect();
        report.fail_if(
            !booked.contains(path.as_str()),
            format!(
                "{path} calls {} outside `deinit` — a handle freed anywhere else is a claim about which \
                 threads are running, and `VideoMuxClientFlow` shows what the claim costs when it is wrong. \
                 Split the teardown into a `_close` that leaves the handle valid and a `_free` in `deinit`, \
                 or book the file in `handle_lifetime::BOOKED` with the proof (docs/55, docs/63)",
                doors.join(", ")
            ),
        );
    }
    for path in &booked {
        report.fail_if(
            !found.contains_key(*path),
            format!(
                "{path} is booked as freeing outside `deinit` but no longer does (it moved the free, or was \
                 deleted) — drop the entry rather than leaving a ledger that reads as satisfied"
            ),
        );
    }
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Every booked path, because the rule checks both directions and a fixture missing one would
    /// fail on the entry rather than on the drift the test is seeding.
    fn booked(fixture: &Fixture) -> &Fixture {
        for &(path, _) in super::BOOKED {
            fixture.write(
                path,
                "import CSlopDeskFFI\nfunc end() { slopdesk_thing_free(handle) }\n",
            );
        }
        fixture
    }

    #[test]
    fn the_booked_set_is_clean() {
        let fixture = Fixture::new("handle-lifetime-clean");
        booked(&fixture);
        assert!(
            super::a_handle_is_freed_only_by_its_owners_deinit(&fixture.tree())
                .violations()
                .is_empty(),
            "the fixture must start green, or every break-test below fails on its precondition"
        );
    }

    #[test]
    fn a_free_outside_deinit_is_red_until_somebody_proves_it() {
        let fixture = Fixture::new("handle-lifetime-escape");
        booked(&fixture);
        let path = "Sources/SlopDeskVideoClient/Mux/VideoMuxClientFlow.swift";
        // The bug, exactly as it was written: tidy, and a use-after-free.
        fixture.write(
            path,
            "import CSlopDeskFFI\nfinal class Flow {\n    func close() { slopdesk_video_flow_free(handle) \
             }\n    deinit {}\n}\n",
        );
        let report = super::a_handle_is_freed_only_by_its_owners_deinit(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("VideoMuxClientFlow")),
            "freeing from a `close()` is the shape the rule exists to catch"
        );
    }

    #[test]
    fn the_fix_is_green() {
        let fixture = Fixture::new("handle-lifetime-fixed");
        booked(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/Mux/VideoMuxClientFlow.swift",
            "import CSlopDeskFFI\nfinal class Flow {\n    func close() { slopdesk_video_flow_close(handle) \
             }\n    deinit { if let handle { slopdesk_video_flow_free(handle) } }\n}\n",
        );
        assert!(
            super::a_handle_is_freed_only_by_its_owners_deinit(&fixture.tree())
                .violations()
                .is_empty(),
            "the two-door teardown is what the rule is asking for"
        );
    }

    #[test]
    fn a_stale_entry_is_a_violation_rather_than_a_pass() {
        let fixture = Fixture::new("handle-lifetime-stale");
        booked(&fixture);
        // The booked file moves its free into `deinit`, which is what a successful tightening looks
        // like — and leaving it booked keeps the ledger green over a fact that changed.
        fixture.write(
            super::BOOKED[0].0,
            "import CSlopDeskFFI\nfinal class Host {\n    deinit { slopdesk_thing_free(handle) }\n}\n",
        );
        let report = super::a_handle_is_freed_only_by_its_owners_deinit(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains(super::BOOKED[0].0)),
            "an entry that no longer qualifies must be dropped, not left reading as satisfied"
        );
    }

    /// The line test this rule deliberately is not: a free nested inside an unwrap, a closure or a
    /// queue hop is still inside the `deinit`.
    #[test]
    fn a_nested_free_is_still_inside_the_deinit() {
        assert!(
            super::frees_outside_deinit(
                "deinit {\n    queue.sync {\n        if let handle { slopdesk_a_free(handle) }\n    }\n}\n"
            )
            .is_empty()
        );
    }

    #[test]
    fn a_second_deinit_in_the_same_file_gets_its_own_body() {
        assert!(
            super::frees_outside_deinit(
                "final class A {\n    deinit { slopdesk_a_free(a) }\n}\nfinal class B {\n    deinit { \
                 slopdesk_b_free(b) }\n}\n"
            )
            .is_empty(),
            "one file often holds the box as well as the object that owns it"
        );
    }

    #[test]
    fn a_word_that_merely_starts_with_deinit_opens_no_body() {
        let escapes = super::frees_outside_deinit(
            "func deinitialise() { slopdesk_a_free(a) }\nfinal class A { deinit {} }\n",
        );
        assert_eq!(
            escapes.iter().map(String::as_str).collect::<Vec<_>>(),
            ["slopdesk_a_free"],
            "a helper named after the destructor is not the destructor"
        );
    }

    /// A door that merely CONTAINS `_free` is not a free door — `_freeze`, and anything a future
    /// crate spells with the same stem.
    #[test]
    fn only_a_door_that_ends_in_free_is_a_free() {
        assert!(super::frees_outside_deinit("func f() { slopdesk_grid_freeze(x) }\n").is_empty());
        assert_eq!(
            super::frees_outside_deinit("func f() { slopdesk_grid_free(x) }\n")
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["slopdesk_grid_free"]
        );
    }
}
