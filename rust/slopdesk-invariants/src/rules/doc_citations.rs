//! The two directions of the same question: the code cites the docs, and the docs cite the code.
//!
//! Both are silent when they rot. A ``DocC link`` that names nothing renders as plain text; a doc
//! that names a deleted file reads exactly like one that names a live file. Neither compiler, and
//! no test in either language, has an opinion about either.
//!
//! These were the last three sections of the deleted `check-supervisor.sh`, and the ones its own
//! comment said would "port next". Each needed a corpus the crate had no shape for at the time — an
//! identifier census over every Swift file in the tree, and `CLAUDE.md`'s own read-first table
//! expanded into a doc list — which is what [`known_identifiers`] and [`read_first_docs`] are.

use std::collections::BTreeSet;
use std::fs;

use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The trees whose Swift VOUCHES for a name.
///
/// `ThirdParty/ghostty/integration` is in it because the embedder Swift is real declarations that
/// no `Package.swift` target compiles, and a doc may legitimately cite one.
const VOUCHING_ROOTS: [&str; 4] = ["Sources", "Tests", "Apps", "ThirdParty/ghostty/integration"];

/// The trees whose Swift comments are SCANNED for links.
const SCANNED_ROOTS: [&str; 2] = ["Sources", "Tests"];

/// Framework symbols `DocC` resolves through an import, which this repo therefore never declares.
///
/// Keep it short, and add to it only for a symbol Apple actually ships.
const DOCC_EXTERNAL: [&str; 3] = ["SwiftUICore", "CGDisplayGammaTable", "CGEventTap"];

/// A doc may name a file it is telling you was DELETED.
///
/// `docs/51` §"What this deleted" is the pattern, and the whole value of that section is that it
/// spells the name out. Each entry here is one such tombstone, and stays only as long as its
/// sentence does.
///
/// The block after the first is `docs/59`'s subject in its entirety. That document records the
/// PROJECTION — the six handles that carried `MuxChannelSession` and `HostServer` into Rust one
/// seam at a time — and `docs/60` F.9 finished the job by deleting both, the four faces and the
/// four `slopdesk-ffi` doors that reached them. Repointing those names at the crates that replaced
/// them would make the document lie about what it is describing: the whole point of a projection
/// record is which Swift file each handle was cut out of.
/// The third block is `docs/60` Batch B's, and it is the same argument one step further out. Those
/// two targets were hostd's ENDS of the superd and screend wires, and the documents that name them
/// are recording which end each rule used to live on. `docs/51` and `docs/52` describe a protocol
/// by walking both sides of it; repointing hostd's side at `slopdesk-superclient` where the
/// sentence says "and Swift resolved it through `NSTemporaryDirectory()`" would make the doc claim
/// a Rust crate did something it never did.
/// The fourth block is `docs/62`'s, and it is the smallest case of the same argument: stage A's
/// "Moves" line names the `App` struct it replaced, by the path it was at, because the whole
/// content of that line is which file each half of `PhoneAppDelegate`/`PhoneSceneDelegate` was cut
/// out of. Repointing it at either successor would make the sentence claim the rewrite moved
/// something that was already there. The two phone files after it are that same line's argument at
/// the scale of the whole document: §2.4's table has a column for what each representable BECAME,
/// and two of its "Invariant rules re-aimed" paragraphs exist to say which path a claim used to
/// name before the controller replaced it. Repointing either at its successor deletes the only fact
/// the row carries — a before/after ledger whose "before" column has been rewritten to the "after"
/// is not a ledger, and the rules those paragraphs re-aim are the ones a reader has to find.
/// ⚠️ THIS LIST IS THIS RULE'S ALONE, and it does NOT exempt a Swift COMMENT.
/// `repo_invariants::source_comments_cite_files_that_exist` is the other half of the same
/// question and carries no list at all, on purpose — it is SHAPE, so it cannot decay. A comment
/// recording a deleted file is not fixed by an entry here; it is fixed by not spelling a backticked
/// PATH, which that rule's own doc says stays legal. Adding the name here instead silently does
/// nothing.
const PATH_TOMBSTONES: [&str; 27] = [
    "Sources/SlopDeskHost/PTYReadLoop.swift",
    "Sources/SlopDeskHost/HostEnvironment.swift",
    "Sources/SlopDeskHost/HostServer.swift",
    "Sources/SlopDeskHost/MuxChannelSession.swift",
    "Sources/SlopDeskHost/PaneFanout.swift",
    "Sources/SlopDeskHost/PaneOutbox.swift",
    "Sources/SlopDeskHost/PaneResizeFold.swift",
    "Sources/SlopDeskHost/PaneTruths.swift",
    "Sources/slopdesk-hostd/main.swift",
    "rust/slopdesk-ffi/src/mux_resize.rs",
    "rust/slopdesk-ffi/src/pane_fanout.rs",
    "rust/slopdesk-ffi/src/pane_outbox.rs",
    "rust/slopdesk-ffi/src/pane_truths.rs",
    "Sources/SlopDeskSupervisor/SupervisorPaths.swift",
    "Sources/SlopDeskSupervisor/SupervisorMessages.swift",
    "Sources/SlopDeskSupervisor/SupervisorDoors.swift",
    "Sources/SlopDeskSupervisor/SupervisorFrame.swift",
    "Sources/SlopDeskSupervisor/SupervisorClient.swift",
    "Sources/SlopDeskSupervisor/SupervisorConnection.swift",
    "Sources/SlopDeskSupervisor/RustServicePaths.swift",
    "Sources/SlopDeskSupervisor/FileDescriptorPassing.swift",
    "Sources/SlopDeskScreen/ScreenClient.swift",
    "Sources/SlopDeskScreen/ScreenPaths.swift",
    "Sources/SlopDeskScreen/ScreenProtocol.swift",
    "Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift",
    "Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift",
    "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift",
];

/// The docs that are read-first regardless of the table — the entry points and the design law.
const ALWAYS_LIVE: [&str; 3] = ["docs/README.md", "docs/00-overview.md", "DESIGN.md"];

/// Every name this repo DECLARES, plus every Swift file basename.
///
/// Comments are stripped, so a name kept alive only by other comments does not vouch for itself.
/// The basenames are in because several links legitimately name a file that groups a vocabulary
/// rather than a type.
///
/// The corpus comes off the tree rather than off git's index: the question is "does this repo
/// declare the name", and a file added but not yet staged declares it just as much as a committed
/// one.
#[must_use]
pub fn known_identifiers(tree: &Tree) -> BTreeSet<String> {
    let mut known: BTreeSet<String> = DOCC_EXTERNAL.iter().map(|name| (*name).to_owned()).collect();
    for root in VOUCHING_ROOTS {
        for (path, source) in tree.under(root) {
            if path.extension().is_none_or(|extension| extension != "swift") {
                continue;
            }
            if let Some(stem) = path.file_stem().and_then(|value| value.to_str()) {
                known.insert(stem.to_owned());
            }
            known.extend(text::capture_set(source.code(), "([A-Za-z_][A-Za-z0-9_]*)"));
        }
    }
    known
}

/// Every symbol a ``double-backtick`` span in a Swift comment names.
///
/// A single-backtick span is prose; only the DOUBLE backtick promises a symbol in this doc graph,
/// so only it is checked. A slash-separated path is checked component by component, and a `(…)`
/// argument list is dropped — `` ``Store/apply(_:)`` `` names `Store` and `apply`.
#[must_use]
pub fn cited_symbols(comment_text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in comment_text.lines() {
        let trimmed = line.trim_start();
        if !(trimmed.starts_with("//") || trimmed.starts_with('*')) {
            continue;
        }
        let mut rest = line;
        while let Some(open) = rest.find("``") {
            let after = &rest[open + 2..];
            let Some(close) = after.find("``") else {
                break;
            };
            let raw = &after[..close];
            rest = &after[close + 2..];
            for part in raw.split('/') {
                let part = part.split('(').next().unwrap_or(part).trim();
                if !part.is_empty()
                    && part
                        .chars()
                        .next()
                        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                    && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    found.push(part.to_owned());
                }
            }
        }
    }
    found
}

/// A ``DocC link`` must name something this repo declares.
///
/// The rule is not tidiness: a port moves the implementation out of Swift and deletes the original
/// (`CLAUDE.md`), and the doc that described it keeps the old spelling — so a reader chasing
/// ``HostOutputSniffer`` or ``TerminalQueryStripper`` greps Swift, finds nothing, and concludes the
/// machinery is gone rather than that it now lives in `rust/slopdesk-superd` /
/// `rust/slopdesk-sanitize`. 65 such links had accumulated when this check was written, across four
/// ports and three deleted view layers. A Rust item is cited the way the rest of the tree cites one
/// — `name` plus its crate path.
#[must_use]
pub fn every_docc_link_resolves(tree: &Tree) -> Report {
    let mut report = Report::new();
    let known = known_identifiers(tree);
    if known.is_empty() {
        report.fail("no Swift identifier was read out of the tree — this rule is blind");
        return report;
    }

    let mut dangling: Vec<String> = Vec::new();
    for root in SCANNED_ROOTS {
        for (path, source) in tree.under(root) {
            if path.extension().is_none_or(|extension| extension != "swift") {
                continue;
            }
            for symbol in cited_symbols(&source.text) {
                if !known.contains(&symbol) {
                    dangling.push(format!("{}\t{symbol}", path.display()));
                }
            }
        }
    }
    if !dangling.is_empty() {
        for site in &dangling {
            eprintln!("{site}");
        }
        report.fail(
            "a ``link`` names a symbol this repo does not declare — cite a ported item as `name` + crate \
             path",
        );
    }
    report
}

/// Every doc `CLAUDE.md`'s read-first table sends a reader to, plus the three that are always live.
///
/// BOTH spellings the table uses. The sidecar row reads "`docs/51` superd · `52` screend · `53`
/// dropd · `54` inspectord · `48` androidd" — five docs, and only the first carries the `docs/`
/// prefix. Reading the prefixed form alone covered one of the five and looked complete doing it,
/// which is the same failure as any extraction that matches less than its comment claims.
///
/// Returns the resolved docs and the tokens that resolved to nothing.
#[must_use]
pub fn read_first_docs(tree: &Tree) -> (Vec<String>, Vec<String>) {
    let Some(claude) = tree.get("CLAUDE.md") else {
        return (Vec::new(), vec!["CLAUDE.md".to_owned()]);
    };
    let mut tokens: BTreeSet<String> = text::capture_set(&claude.text, "docs/([0-9]{2}[a-z0-9-]*)");
    tokens.extend(text::capture_set(&claude.text, "`([0-9]{2})`"));

    let mut live: Vec<String> = Vec::new();
    let mut unresolved: Vec<String> = Vec::new();
    let docs: Vec<String> = tree
        .under("docs")
        .filter_map(|(path, _)| path.to_str().map(str::to_owned))
        .collect();
    for token in tokens {
        let prefix = format!("docs/{token}");
        let matched: Vec<&String> = docs
            .iter()
            .filter(|path| {
                path.starts_with(&prefix)
                    && std::path::Path::new(path)
                        .extension()
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("md"))
            })
            .collect();
        if matched.is_empty() {
            unresolved.push(prefix);
        } else {
            live.extend(matched.into_iter().cloned());
        }
    }
    for extra in ALWAYS_LIVE {
        if tree.has(extra) {
            live.push(extra.to_owned());
        }
    }
    live.sort_unstable();
    live.dedup();
    (live, unresolved)
}

/// `CLAUDE.md`'s read-first table names a doc that is not there.
///
/// A token that resolves to nothing spends the table's authority on a file nobody can open. The
/// shell dropped one in silence for as long as the table existed.
#[must_use]
pub fn the_read_first_table_resolves(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (live, unresolved) = read_first_docs(tree);
    if !unresolved.is_empty() {
        for token in &unresolved {
            eprintln!("{token}");
        }
        report.fail("CLAUDE.md's read-first table names a doc that does not exist");
    }
    if live.is_empty() {
        report.fail(
            "the read-first table resolved to NO doc at all — the extraction in this gate has gone stale",
        );
    }
    report
}

/// A read-first doc cites a file, and that file exists.
///
/// The mirror of [`every_docc_link_resolves`]: the docs cite CODE, and nothing was reading those
/// citations. `docs/00`'s "Core / shell split" told every reader that Swift owns the wire and that
/// the only non-Swift code is a C target deleted weeks earlier — the opposite of `CLAUDE.md`'s
/// rule, in the one paragraph a newcomer is pointed at first (`DECISIONS.md` 2026-08-16).
///
/// Scoped to file PATHS rooted at a real top-level directory, and to the docs `CLAUDE.md` sends a
/// reader to. Both bounds are deliberate. A bare `Overlays/PaletteView.swift` is ordinary shorthand
/// for a path relative to its package, and resolving that guess is how a gate earns false
/// positives; a rooted path either exists or the doc is lying. And a doc nobody is told to read is
/// history: `29-NIGHT-HANDOFF.md` names dozens of files that are gone, correctly, because that is
/// what a handoff from March records.
///
/// The root set is read off the filesystem, not spelled out. The hand-written alternation it
/// replaced had drifted both ways at once: `manifests` and `research` no longer existed, so two of
/// its ten branches could never match, and `hid-bridge` — which does — was never in it, so any path
/// cited into that tree was exempt without anyone deciding it should be.
#[must_use]
pub fn every_cited_path_exists(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (live, _) = read_first_docs(tree);
    let Some(roots) = top_level_directories(tree) else {
        report.fail("the repository root could not be read — no path citation could be scoped");
        return report;
    };
    if roots.is_empty() {
        report.fail("the repository root holds no directory — the extraction in this gate has gone stale");
        return report;
    }

    let pattern = format!("`(({})/[A-Za-z0-9_./+-]+\\.[a-z]+)`", roots.join("|"));
    let mut cited: BTreeSet<String> = BTreeSet::new();
    for doc in &live {
        if let Some(source) = tree.get(doc) {
            cited.extend(text::capture_set(&source.text, &pattern));
        }
    }
    if cited.is_empty() {
        report
            .fail("no file path is cited by any read-first doc — the extraction in this gate has gone stale");
        return report;
    }

    let missing: Vec<&String> = cited
        .iter()
        .filter(|path| !tree.root().join(path).exists())
        .filter(|path| !PATH_TOMBSTONES.contains(&path.as_str()))
        .collect();
    if !missing.is_empty() {
        for path in &missing {
            eprintln!("{path}");
        }
        report.fail(
            "a read-first doc cites a file that does not exist — repoint it, or add it to PATH_TOMBSTONES",
        );
    }
    report
}

/// The repository's top-level directory names, which bound what counts as a rooted path.
fn top_level_directories(tree: &Tree) -> Option<Vec<String>> {
    let mut found: Vec<String> = fs::read_dir(tree.root())
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| !name.starts_with('.'))
        .collect();
    found.sort_unstable();
    Some(found)
}

#[cfg(test)]
mod tests {
    use super::{
        cited_symbols, every_cited_path_exists, every_docc_link_resolves, the_read_first_table_resolves,
    };
    use crate::tests::Fixture;

    /// A single backtick is prose; a double one is a promise.
    #[test]
    fn only_double_backticks_are_links() {
        let cited = cited_symbols("// see `notAPromise` and ``RealSymbol``\n");
        assert_eq!(cited, vec!["RealSymbol".to_owned()]);
    }

    /// A path link names each of its components, and an argument list is not one.
    #[test]
    fn a_path_link_names_every_component() {
        let cited = cited_symbols("/// ``WorkspaceStore/apply(_:)`` does the thing\n");
        assert_eq!(cited, vec!["WorkspaceStore".to_owned(), "apply".to_owned()]);
    }

    /// A link outside a comment is code, not a citation — a string holding backticks is not a doc.
    #[test]
    fn a_link_outside_a_comment_is_not_read() {
        assert!(cited_symbols("let banner = \"``NotALink``\"\n").is_empty());
    }

    /// The ported case: a name the tree stopped declaring.
    #[test]
    fn a_link_to_a_deleted_type_is_red() {
        let fixture = Fixture::new("docc-dangling");
        fixture.write("Sources/A/Live.swift", "enum LiveThing {}\n");
        fixture.write(
            "Sources/A/Doc.swift",
            "/// See ``LiveThing`` and ``HostOutputSniffer``.\nlet x = 1\n",
        );
        assert!(!every_docc_link_resolves(&fixture.tree()).is_clean());

        let clean = Fixture::new("docc-clean");
        clean.write("Sources/A/Live.swift", "enum LiveThing {}\n");
        clean.write("Sources/A/Doc.swift", "/// See ``LiveThing``.\nlet x = 1\n");
        assert!(every_docc_link_resolves(&clean.tree()).is_clean());
    }

    /// A name kept alive only by other COMMENTS does not vouch for itself.
    #[test]
    fn a_comment_does_not_declare_a_name() {
        let fixture = Fixture::new("docc-comment-vouch");
        fixture.write(
            "Sources/A/Ghost.swift",
            "// GhostType used to live here\nlet x = 1\n",
        );
        fixture.write("Sources/A/Doc.swift", "/// See ``GhostType``.\nlet y = 2\n");
        assert!(!every_docc_link_resolves(&fixture.tree()).is_clean());
    }

    /// A Swift FILE vouches for its own basename — several links name a vocabulary file.
    #[test]
    fn a_file_basename_vouches() {
        let fixture = Fixture::new("docc-basename");
        fixture.write("Sources/A/PaneVocabulary.swift", "let x = 1\n");
        fixture.write("Sources/A/Doc.swift", "/// See ``PaneVocabulary``.\nlet y = 2\n");
        assert!(every_docc_link_resolves(&fixture.tree()).is_clean());
    }

    /// Both spellings the read-first table uses, and a token that resolves to nothing.
    #[test]
    fn the_table_is_read_in_both_spellings() {
        let fixture = Fixture::new("read-first");
        fixture.write("CLAUDE.md", "read `docs/51` superd · `52` screend\n");
        fixture.write("docs/51-process-supervision.md", "x\n");
        fixture.write("docs/52-screend.md", "y\n");
        assert!(the_read_first_table_resolves(&fixture.tree()).is_clean());

        let broken = Fixture::new("read-first-gone");
        broken.write("CLAUDE.md", "read `docs/51` superd · `52` screend\n");
        broken.write("docs/51-process-supervision.md", "x\n");
        assert!(!the_read_first_table_resolves(&broken.tree()).is_clean());
    }

    /// A rooted citation either exists or the doc is lying; a bare relative one is shorthand.
    ///
    /// The fixture's own citations are assembled with `concat!` rather than written out, because
    /// this file is INSIDE `comments-cite-real-files`' corpus: a backticked source path spelled
    /// here is a path claim that rule would rightly demand resolve, and the whole point of the
    /// fixture is that one of them does not. Same answer `one-home-per-operation` gives to the
    /// same problem.
    #[test]
    fn a_read_first_doc_may_not_cite_a_deleted_file() {
        let live = concat!("`Sources/", "A/Live.swift`");
        let relative = concat!("`Overlays/", "Relative.swift`");
        let gone = concat!("`Sources/", "A/Gone.swift`");

        let fixture = Fixture::new("cited-paths");
        fixture.write("CLAUDE.md", "read `docs/51`\n");
        fixture.write("Sources/A/Live.swift", "let x = 1\n");
        fixture.write(
            "docs/51-process-supervision.md",
            &format!("see {live} and {relative}\n"),
        );
        assert!(every_cited_path_exists(&fixture.tree()).is_clean());

        let broken = Fixture::new("cited-paths-gone");
        broken.write("CLAUDE.md", "read `docs/51`\n");
        broken.write("Sources/A/Live.swift", "let x = 1\n");
        broken.write(
            "docs/51-process-supervision.md",
            &format!("see {live} and {gone}\n"),
        );
        assert!(!every_cited_path_exists(&broken.tree()).is_clean());
    }
}
