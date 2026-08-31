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

/// The one file carrying every rule's provenance — the `origin:` column.
const RULE_REGISTRY: &str = "rust/slopdesk-invariants/src/rules/mod.rs";

/// Framework symbols `DocC` resolves through an import, which this repo therefore never declares.
///
/// Keep it short, and add to it only for a symbol Apple actually ships.
const DOCC_EXTERNAL: [&str; 4] = [
    "SwiftUICore",
    "CGDisplayGammaTable",
    "CGEventTap",
    "UILayoutPriority",
];

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
/// The third block is `docs/60` Batch B's, and it is the same argument one step further out: those
/// two targets were hostd's ENDS of the superd and screend wires, and `docs/51` and `docs/52`
/// describe a protocol by walking both sides of it. Ten of its eleven entries are gone as of
/// `tombstones-bury-something`'s first run — the whole `SlopDeskSupervisor` group and two of the
/// three `SlopDeskScreen` files — because those sentences were rewritten and the exemptions
/// outlived them by however long nobody looked. `ScreenClient.swift` is what the argument still
/// has: `docs/52` names it as the end screend's protocol was cut out of, so repointing it at
/// `slopdesk-screenclient` would make the doc claim a Rust crate did something it never did.
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
/// The sixth block is `docs/62` §2.4's again, at the width the rule could finally see. That table
/// is a wrapper LEDGER — a row per representable, an "after" column that reads "deleted." /
/// "dissolves." / "added as a subview" — and every "before" in it is cited with a `:LINE` suffix,
/// which is exactly what [`cited_paths`] did not read until it was widened. Three of the seven have
/// a successor under a different name (`PhoneSimulatorScreenView`, `PhoneAndroidScreenView`,
/// `CodeSidebarWebViewPool`) and repointing at any of them is the phone block's error one more
/// time: the row's whole content is which file the controller was cut out of.
/// ⚠️ THIS LIST IS THIS RULE'S ALONE, and it does NOT exempt a Swift COMMENT.
/// `repo_invariants::source_comments_cite_files_that_exist` is the other half of the same
/// question and carries no list at all, on purpose — it is SHAPE, so it cannot decay. A comment
/// recording a deleted file is not fixed by an entry here; it is fixed by not spelling a backticked
/// PATH, which that rule's own doc says stays legal. Adding the name here instead silently does
/// nothing.
const PATH_TOMBSTONES: [&str; 29] = [
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
    "Sources/SlopDeskScreen/ScreenClient.swift",
    "Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift",
    "Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift",
    "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift",
    // `docs/63`'s block, and the fifth instance of the same argument. §G.3 moved the whole PATH-1
    // client mux to Rust in one pass, and every surviving citation of the four paths below is a
    // BEFORE, not a pointer: `docs/59` §1's projection table names them in its Swift column beside
    // the `mux/flow.rs` and `mux/channels.rs` that replaced them, `docs/63` §G.3's inventory lists
    // them as the files the stage deletes, `docs/59` §6's entry is struck through and corrected in
    // place, and `docs/60` §1 quotes that struck entry while §7 recites what
    // `one-frame-one-doorman` asserted before this stage re-pointed it. Repointing any of them at a
    // successor would make a ledger's "before" column read as its "after", which is the same defect
    // the phone block above records.
    "Sources/SlopDeskProtocol/Mux/ChannelTable.swift",
    "Sources/SlopDeskProtocol/Mux/MuxFlowControl.swift",
    "Sources/SlopDeskTransport/Mux/MuxNWConnection.swift",
    "Sources/SlopDeskTransport/Mux/MuxRoutingCore.swift",
    // The replay class, retired ahead of its stage. `docs/20` records that a `struct ReplayBuffer`
    // stood in the wire contract from WF-2 and what replaced it, `docs/63` §G.5 names the file it
    // deleted and quotes the grep that settled it had no caller, and `docs/55` §4b's handle table
    // reads as a past-tense record of the one multi-slot instance the boundary ever had. Each is a
    // BEFORE for the same reason the four paths above are: repointing them at
    // `rust/slopdesk-wire`'s `replay` module would have the doc say a Rust crate was the thing the
    // sentence is explaining the retirement of.
    "Sources/SlopDeskTransport/ReplayBuffer.swift",
    // `docs/62` §2.4's wrapper ledger and the two paragraphs that continue it, all seven cited with
    // a `:LINE` suffix and therefore invisible to this rule until the extraction was widened.
    "Sources/SlopDeskVideoClientPhone/VideoLayerRepresentable.swift",
    "Sources/SlopDeskPhoneUI/Pane/PaneMoveEscapeResponder.swift",
    "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift",
    "Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift",
    "Sources/SlopDeskPhoneUI/CodeSidebar/CodeSidebarWebView.swift",
    "Sources/SlopDeskWorkspaceCore/Terminal/TerminalRenderingView.swift",
    "Apps/ClientApp-iOS/Tests/SidebarAutoHideWiringTests.swift",
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
///
/// ## ⚠️ IT RETURNS THE TREE'S HALF ALONE, AND THAT IS THE POINT
/// This used to seed itself with [`DOCC_EXTERNAL`] before reading a single file, which put four
/// names this repo by definition does NOT declare — that constant's own doc says so — into a set
/// whose job is to answer "does this repo declare the name". The consequence was not a wrong answer
/// on any link. It was that [`every_docc_link_resolves`]' blind guard could never fire: the guard
/// asks whether a Swift identifier was read out of the tree, and four constants answered yes for
/// it. Point the roots at a directory that has been renamed, or change the extension filter, and
/// the rule would have gone on reporting clean over an empty corpus. The union belongs at the one
/// call site that resolves links, AFTER the floor.
#[must_use]
pub fn known_identifiers(tree: &Tree) -> BTreeSet<String> {
    let mut known: BTreeSet<String> = BTreeSet::new();
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
///
/// ## The floor is a COUNT, not an emptiness
/// A `!known.is_empty()` guard is satisfied by one name, and this corpus is twenty-six thousand of
/// them off four roots. Every way this rule goes blind takes most of that with it — a renamed
/// `VOUCHING_ROOTS` entry, an extension filter that stops matching, a `code()` view that starts
/// returning nothing — and every one of them leaves a set that is small rather than empty. So the
/// floor is a number well under the live corpus and far above any of those outcomes, and
/// [`DOCC_EXTERNAL`] is unioned in only AFTER it: those four are names the repo does not declare,
/// and counting them toward "the tree was read" is what let the old guard answer for the tree.
#[must_use]
pub fn every_docc_link_resolves(tree: &Tree) -> Report {
    /// Well under the twenty-six thousand names four live roots declare, and far above what any
    /// root, filter or view going wrong would leave behind.
    const CORPUS_FLOOR: usize = 5_000;

    let mut report = Report::new();
    let mut known = known_identifiers(tree);
    if known.len() < CORPUS_FLOOR {
        report.fail(format!(
            "only {} Swift identifiers were read out of {} — this rule is blind",
            known.len(),
            VOUCHING_ROOTS.join(", ")
        ));
        return report;
    }
    known.extend(DOCC_EXTERNAL.iter().map(|name| (*name).to_owned()));

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

    let cited = cited_paths(tree, &live, &roots);
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

/// Which tombstones stopped burying anything, and which of the two ways each one died.
///
/// Kept apart from the rule so it can be tested against a SMALL list. Inlining the check into
/// [`every_cited_path_exists`] was the obvious move and the wrong one: that rule's fixtures cite
/// one or two paths, so all thirty-odd real entries would read unspent and every "clean" fixture
/// would assert red. A ledger's liveness half has to be reachable without the ledger.
fn unspent_tombstones(cited: &BTreeSet<String>, root: &std::path::Path, entries: &[&str]) -> Vec<String> {
    let mut dead = Vec::new();
    for entry in entries {
        let buried = !root.join(entry).exists();
        let named = cited.contains(*entry);
        let why = match (named, buried) {
            (false, true) => "no read-first doc cites it any more",
            (true, false) => "the file is back — the citation resolves on its own",
            (false, false) => "the file is back AND nothing cites it",
            (true, true) => continue,
        };
        dead.push(format!("  {entry} — {why}"));
    }
    dead
}

/// Every tombstone still buries something.
///
/// [`PATH_TOMBSTONES`] is the one list in this module that CHANGES what a pass does, and until now
/// it was the only suppression list in the crate with no half asking whether its entries still
/// suppress. That is the same defect one level up from the rule it serves: an exemption outliving
/// its reason reads exactly like a rule with nothing to report. Two ways an entry dies, and the
/// message says which — the sentence that named it was rewritten, or the file came back and the
/// citation resolves without any help. `every_allowlist_entry_is_alive` is this rule's twin over in
/// `shared_constants`, and the two exist for the same reason.
///
/// A tombstone's whole justification is a SENTENCE in a document. When that sentence goes, the
/// entry is not merely unused — it is a standing permission for a doc to cite a deleted file
/// silently, which is precisely what [`every_cited_path_exists`] exists to refuse.
#[must_use]
pub fn every_tombstone_still_buries_something(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (live, _) = read_first_docs(tree);
    let Some(roots) = top_level_directories(tree) else {
        report.fail("the repository root could not be read — no tombstone could be checked");
        return report;
    };
    let cited = cited_paths(tree, &live, &roots);
    if cited.is_empty() {
        report.fail(
            "no file path is cited by any read-first doc — this rule cannot tell a live tombstone from a \
             dead one, and would call every entry dead",
        );
        return report;
    }

    let dead = unspent_tombstones(&cited, tree.root(), &PATH_TOMBSTONES);
    if !dead.is_empty() {
        report.fail(format!(
            "a tombstone buries nothing —\n{}\nEach entry is one document's sentence about a file that was \
             DELETED, and it stays only as long as that sentence does. Delete the entry, and the paragraph \
             above it that exists to justify it.",
            dead.join("\n")
        ));
    }
    report
}

/// Every rooted file path the given docs cite, with any `:LINE` suffix dropped.
///
/// ONE function because both path rules read the same set and disagreeing about it is a defect, not
/// a duplication: [`every_cited_path_exists`] asks which of these is gone, and
/// [`every_tombstone_still_buries_something`] asks which entry no longer appears here. Widening one
/// side alone would make every newly-visible citation red in the first rule and its own exemption
/// read unspent in the second.
///
/// The `:LINE` suffix is why this was widened. `` `docs/62`'s §2.4 `` cites a wrapper by path and
/// first line, which is this repo's own idiom — `repo_invariants::live_docs_cite_files_that_exist`
/// has stripped `:[\d,+-]+` since it was written. Requiring the closing backtick immediately after
/// the extension made this rule blind to nineteen citations across the read-first corpus, seven of
/// which named a file deleted in the phone port: an extraction narrower than the idiom it reads is
/// a rule that reports nothing and looks clean doing it.
fn cited_paths(tree: &Tree, docs: &[String], roots: &[String]) -> BTreeSet<String> {
    let pattern = format!(
        "`(({})/[A-Za-z0-9_./+-]+\\.[a-z]+)(?::[0-9,+-]+)?`",
        roots.join("|")
    );
    let mut cited: BTreeSet<String> = BTreeSet::new();
    for doc in docs {
        if let Some(source) = tree.get(doc) {
            cited.extend(text::capture_set(&source.text, &pattern));
        }
    }
    cited
}

/// Every `§` a rule's provenance cites, paired with the doc it was cited into.
///
/// The scan is positional rather than a single regex, because an `origin` names a doc once and then
/// several sections of it — `docs/51 §6.5, §6.7, §1` is three citations into one document, and
/// `docs/45 §5.3, docs/55 §8` switches documents halfway. A `§` with no `docs/` before it belongs
/// to something this rule does not read (`CLAUDE.md §Rules`, a shell script's own numbering) and is
/// dropped rather than attached to whatever document came later.
fn cited_sections(origin: &str) -> Vec<(String, String)> {
    let mut cited = Vec::new();
    let mut doc: Option<String> = None;
    let bytes = origin.as_bytes();
    let mut index = 0;
    while index < origin.len() {
        if origin[index..].starts_with("docs/") {
            let rest = &origin[index + "docs/".len()..];
            let end = rest
                .find(|c: char| !c.is_ascii_alphanumeric() && !"_.-".contains(c))
                .unwrap_or(rest.len());
            doc = Some(rest[..end].trim_end_matches('.').to_owned());
            index += "docs/".len() + end;
            continue;
        }
        if origin[index..].starts_with('§') {
            let rest = origin[index + '§'.len_utf8()..].trim_start();
            // A section runs to the next comma, because that is where every multi-section origin in
            // the registry breaks: `§4, step 4`, `§4c, §8`, `§5, step 5b`.
            let token = rest.split(',').next().unwrap_or(rest).trim();
            if let Some(named) = doc.as_ref()
                && !token.is_empty()
            {
                cited.push((named.clone(), token.to_owned()));
            }
            index += '§'.len_utf8();
            continue;
        }
        index += 1;
        while index < origin.len() && (bytes[index] & 0xC0) == 0x80 {
            index += 1;
        }
    }
    cited
}

/// The heading and bold-lead lines of a document — the only lines a section number can be ON.
///
/// Both spellings are the tree's, not a guess: `docs/51` writes `## 6.4 …` and `**2.3 — …**`, and
/// `docs/61` writes `## §1 …`. Restricting to marker lines is what makes this a rule about sections
/// rather than about mentions — `docs/62` names `§4.4` in a paragraph nine hundred lines below the
/// hazard it is about, and a citation satisfied by that prose is satisfied by a sentence, which is
/// the failure this whole family exists to refuse.
fn section_markers(text: &str) -> Vec<&str> {
    text.lines()
        .filter(|line| line.starts_with('#') || line.starts_with("**"))
        .collect()
}

/// Whether `section` is spelled as a marker on `line`.
///
/// Two forms, because the tree writes both: the section LEADS the marker (`## 6.4 The shim …`), or
/// it rides in it behind a `§` (`### Hazard 8 (§4.8) — …`). The boundary refuses a longer number,
/// so a citation to `§4` is not satisfied by a document that only has `§4.1`: that is the exact
/// shape of a renumbering, and answering it "found" would make this rule agree with the drift.
fn marks_section(line: &str, section: &str) -> bool {
    let lead = line
        .trim_start_matches('#')
        .trim_start()
        .trim_start_matches('*')
        .trim_start()
        .trim_start_matches('§');
    let ends_cleanly = |rest: &str| {
        let mut chars = rest.chars();
        match chars.next() {
            None => true,
            Some('.') => !chars.next().is_some_and(|next| next.is_ascii_digit()),
            Some(next) => !next.is_ascii_alphanumeric(),
        }
    };
    if let Some(rest) = lead.strip_prefix(section)
        && ends_cleanly(rest)
    {
        return true;
    }
    line.match_indices('§').any(|(at, _)| {
        let rest = line[at + '§'.len_utf8()..].trim_start();
        rest.strip_prefix(section).is_some_and(ends_cleanly)
    })
}

/// Every `§` the rule registry cites names a section the document actually has.
///
/// The registry carries a provenance column — an `origin:` on every rule, past three hundred and
/// sixty of them, saying which document it was read out of — and until now nothing read it. The
/// count is in `docs/DECISIONS.md`, dated; spelling it here would be the rot one door down.
/// `main.rs --list` PRINTS it and that is the whole of its life. A citation is the only thing
/// standing between a rule and the sentence that justifies it, so a citation that resolves to
/// nothing is a rule whose reason cannot be found: the next reader opens the document, searches for
/// §6, and has to decide from the code alone whether the rule is still wanted.
///
/// It had rotted eleven ways. `docs/48 §4` and `docs/49 §6` cited a numbering those two documents
/// have never had at any commit — the origins were written against the numbered checks of the shell
/// scripts the rules were ported from, and `docs/51 §3b` still carried its script's own `3b` in the
/// function's doc comment. `docs/56 §3.6` cited one past the last section that exists. And seven of
/// the nine phone-hazard ratchets cited `docs/62 §4.1`–`§4.7` while only Hazards 8 and 9 carried
/// the `(§4.N)` marker their siblings did not — the document's own convention, applied to two of
/// nine.
///
/// ## The two halves this does NOT read, each on purpose
///
/// **Tree-wide citations.** Three thousand `docs/…` tokens are spelled across the source trees, and
/// scanning them all would report `docs/new.md` and `docs/x.md` — fixture filenames inside two
/// codec tests, which [`crate::tree::Source::statements`] keeps because they are string literals
/// and keeping them is what makes every other rule here work. The registry column is exact: one
/// field, one meaning, no literals that are not citations.
///
/// **Section tokens with no digit in them.** `§increment 38` and `§the one duplication still
/// standing` are checked as prose — the token has to appear in a marker line — but a bare word
/// after a `§` is not turned into a numeric claim.
///
/// ## ⚠️ THE DOCUMENTS ARE READ RAW, AND THE REGISTRY IS NOT
///
/// The same admission [`super::gate_health::the_gate_census_names_every_gate`] carries: the
/// registry side reads [`crate::tree::Source::statements`], so a commented-out `Rule` block cites
/// nothing, and the DOCUMENT side reads raw text because a Markdown heading is prose by
/// construction. A satisfier reading prose is the thing this crate refuses; the exception is when
/// the subject IS the prose, and it is written here so the next sweep does not "fix" it into a rule
/// that can never fire.
#[must_use]
pub fn every_cited_section_exists(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(registry) = report.source(tree, RULE_REGISTRY, "there would be no provenance to check") else {
        return report;
    };
    let origins = text::capture_all(registry.statements(), r#"origin: "([^"]*)""#);
    if origins.is_empty() {
        report.fail(format!(
            "{RULE_REGISTRY}: no `origin:` field parsed — this rule is blind"
        ));
        return report;
    }

    let mut checked = 0_usize;
    for origin in &origins {
        for (doc, section) in cited_sections(origin) {
            let named = tree.paths().find(|path| {
                path.parent()
                    .is_some_and(|parent| parent == std::path::Path::new("docs"))
                    && path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| {
                            name == doc || name.strip_prefix(&doc).is_some_and(|rest| rest.starts_with('-'))
                        })
            });
            let Some(named) = named else {
                report.fail(format!(
                    "`{origin}` cites docs/{doc}, and the tree has no such document — a rule whose \
                     provenance names nothing is a rule nobody can decide to delete"
                ));
                continue;
            };
            let Some(source) = tree.get(&named.to_string_lossy()) else {
                continue;
            };
            let markers = section_markers(&source.text);
            let numeric = section
                .split_whitespace()
                .next()
                .is_some_and(|word| word.chars().any(|c| c.is_ascii_digit()));
            let wanted: Vec<String> = if numeric {
                let head = section.split_whitespace().next().unwrap_or(&section);
                // A range cites both ends — `§1-3` is three sections, and the two that are written
                // down are the ones a reader navigates by.
                if head.contains('-')
                    && head
                        .split('-')
                        .all(|part| part.chars().any(|c| c.is_ascii_digit()))
                {
                    head.split('-').map(str::to_owned).collect()
                } else {
                    vec![head.to_owned()]
                }
            } else {
                vec![section.clone()]
            };
            for want in wanted {
                checked += 1;
                let found = if numeric {
                    markers.iter().any(|line| marks_section(line, &want))
                } else {
                    let lowered = want.to_lowercase();
                    markers.iter().any(|line| line.to_lowercase().contains(&lowered))
                };
                report.fail_if(
                    !found,
                    format!(
                        "`{origin}` cites §{want} of {} and that document has no such section — repoint the \
                         origin at a heading that exists, or give the heading the marker the citation \
                         already promises a reader will find",
                        named.display()
                    ),
                );
            }
        }
    }

    // The vacuity floor every reader in this crate owes: a renamed field, a registry that stopped
    // spelling `§`, or a marker convention this scan does not know would leave it checking nothing
    // and reporting clean.
    report.fail_if(
        checked < 60,
        format!(
            "only {checked} section citations parsed out of {RULE_REGISTRY} — this rule is reading an empty \
             set"
        ),
    );
    report
}

/// The repository's top-level directory names, which bound what counts as a rooted path.
///
/// `repo_invariants::live_docs_cite_files_that_exist` asks the same question over a different
/// corpus and reads this too — the hand-written alternation it used to carry is exactly the one
/// this function replaced, and keeping a second copy of the answer is how the first one drifted.
pub(super) fn top_level_directories(tree: &Tree) -> Option<Vec<String>> {
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
        cited_paths, cited_sections, cited_symbols, every_cited_path_exists, every_cited_section_exists,
        every_docc_link_resolves, marks_section, section_markers, the_read_first_table_resolves,
        unspent_tombstones,
    };
    use crate::tests::Fixture;

    /// A registry with enough live citations to clear the vacuity floor, plus whatever is under
    /// test.
    ///
    /// The floor is 60, and every fixture here would otherwise trip it before reaching the citation
    /// it is about — which is the guard doing its job, and useless for testing anything else.
    fn registry(extra: &str) -> String {
        let mut text = String::from("pub fn registry() -> Vec<Rule> {\n    vec![\n");
        for _ in 0..60 {
            text.push_str("        Rule { name: \"r\", origin: \"docs/99 §2\", check: m::f },\n");
        }
        text.push_str(extra);
        text.push_str("    ]\n}\n");
        text
    }

    /// The document every fixture cites into, carrying the sections the padding needs.
    const PADDING_DOC: &str = "# 99 — a doc\n\n## 1. First\n\n## 2. Second\n";

    /// An origin names a doc once and several sections of it; a `§` before any doc is not ours.
    #[test]
    fn a_section_belongs_to_the_doc_named_before_it() {
        assert_eq!(cited_sections("docs/51 §6.5, §6.7, §1"), vec![
            ("51".to_owned(), "6.5".to_owned()),
            ("51".to_owned(), "6.7".to_owned()),
            ("51".to_owned(), "1".to_owned()),
        ]);
        assert_eq!(cited_sections("docs/45 §5.3, docs/55 §8"), vec![
            ("45".to_owned(), "5.3".to_owned()),
            ("55".to_owned(), "8".to_owned())
        ]);
        assert!(
            cited_sections("CLAUDE.md §Rules, docs/55").is_empty(),
            "a § with no docs/ before it is another document's numbering"
        );
    }

    /// A citation to §4 is not answered by a document that only has §4.1.
    #[test]
    fn a_longer_number_does_not_satisfy_a_shorter_citation() {
        assert!(marks_section("## 4. The safety argument", "4"));
        assert!(!marks_section("### 4.1 The first hazard", "4"));
        assert!(marks_section("### Hazard 8 (§4.8) — the ratchets", "4.8"));
        assert!(marks_section("**2.3 — the duplicate**", "2.3"));
        assert!(marks_section("## §1 The cascade", "1"));
    }

    /// A section named in a PARAGRAPH is not a section — which is the layer that decides it.
    ///
    /// [`marks_section`] answers about a line it is handed and would say yes to the prose below;
    /// what refuses it is [`section_markers`], which never hands that line over. Asserting this on
    /// `marks_section` passes for the wrong reason, and `docs/62`'s own `§4.4` mention nine hundred
    /// lines under the hazard is the live case.
    #[test]
    fn a_section_named_in_prose_is_not_a_marker() {
        let doc = "## 4. The safety argument\n\nrather than against §4's guess: §4.4's rule is the one.\n";
        assert_eq!(section_markers(doc), vec!["## 4. The safety argument"]);
        assert!(!section_markers(doc).iter().any(|line| marks_section(line, "4.4")));
    }

    /// The ported case: a citation to a section the document does not have.
    #[test]
    fn a_citation_to_a_section_that_was_never_written_is_red() {
        let fixture = Fixture::new("origin-dangling-section");
        fixture.write("docs/99-padding.md", PADDING_DOC);
        fixture.write("docs/98-thin.md", "# 98 — a doc\n\n## The shape\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/mod.rs",
            &registry("        Rule { name: \"x\", origin: \"docs/98 §4\", check: m::g },\n"),
        );
        let report = every_cited_section_exists(&fixture.tree());
        assert!(!report.is_clean());
        assert!(format!("{report:?}").contains("§4"), "{report:?}");

        let clean = Fixture::new("origin-live-section");
        clean.write("docs/99-padding.md", PADDING_DOC);
        clean.write("docs/98-thin.md", "# 98 — a doc\n\n## The shape\n");
        clean.write(
            "rust/slopdesk-invariants/src/rules/mod.rs",
            &registry("        Rule { name: \"x\", origin: \"docs/98 §the shape\", check: m::g },\n"),
        );
        assert!(every_cited_section_exists(&clean.tree()).is_clean());
    }

    /// A provenance naming a document the tree does not have is red before any section is looked
    /// for.
    #[test]
    fn a_citation_into_a_deleted_document_is_red() {
        let fixture = Fixture::new("origin-deleted-doc");
        fixture.write("docs/99-padding.md", PADDING_DOC);
        fixture.write(
            "rust/slopdesk-invariants/src/rules/mod.rs",
            &registry("        Rule { name: \"x\", origin: \"docs/97 §1\", check: m::g },\n"),
        );
        let report = every_cited_section_exists(&fixture.tree());
        assert!(!report.is_clean());
        assert!(format!("{report:?}").contains("no such document"), "{report:?}");
    }

    /// A registry this scan cannot read is reported, not passed.
    #[test]
    fn a_registry_that_spells_no_origin_is_red() {
        let fixture = Fixture::new("origin-blind");
        fixture.write("docs/99-padding.md", PADDING_DOC);
        fixture.write(
            "rust/slopdesk-invariants/src/rules/mod.rs",
            "pub fn registry() -> Vec<Rule> {\n    vec![]\n}\n",
        );
        let report = every_cited_section_exists(&fixture.tree());
        assert!(!report.is_clean());
        assert!(format!("{report:?}").contains("blind"), "{report:?}");
    }

    /// The two ways a tombstone dies, and the one way it stays alive.
    #[test]
    fn a_tombstone_is_spent_only_while_it_is_cited_and_the_file_is_gone() {
        let fixture = Fixture::new("tombstone-liveness");
        fixture.write("Sources/A/Back.swift", "// it came back\n");
        let root = fixture.tree();
        let cited = [
            "Sources/A/Gone.swift".to_owned(),
            "Sources/A/Back.swift".to_owned(),
        ]
        .into_iter()
        .collect();

        assert!(
            unspent_tombstones(&cited, root.root(), &["Sources/A/Gone.swift"]).is_empty(),
            "cited, and the file is gone — the entry is doing its job"
        );

        let resurrected = unspent_tombstones(&cited, root.root(), &["Sources/A/Back.swift"]);
        assert_eq!(resurrected.len(), 1);
        assert!(resurrected[0].contains("the file is back"), "{resurrected:?}");

        let uncited = unspent_tombstones(&cited, root.root(), &["Sources/A/Unnamed.swift"]);
        assert_eq!(uncited.len(), 1);
        assert!(uncited[0].contains("no read-first doc cites it"), "{uncited:?}");
    }

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

    /// A file declaring enough names to clear [`super::every_docc_link_resolves`]' corpus floor.
    ///
    /// The floor is a count, so a two-file fixture cannot reach it by being correct — it reaches it
    /// by being big, which is what a real tree is. The padding declares nothing a link in these
    /// tests names and carries no comment, so it vouches for its own names and for nothing else.
    fn vouching_corpus(fixture: &Fixture) {
        let text = (0..6_000).fold(String::new(), |mut text, index| {
            use std::fmt::Write as _;
            let _ = writeln!(text, "let padding{index} = 1");
            text
        });
        fixture.write("Sources/Padding/Corpus.swift", &text);
    }

    /// The ported case: a name the tree stopped declaring.
    #[test]
    fn a_link_to_a_deleted_type_is_red() {
        let fixture = Fixture::new("docc-dangling");
        vouching_corpus(&fixture);
        fixture.write("Sources/A/Live.swift", "enum LiveThing {}\n");
        fixture.write(
            "Sources/A/Doc.swift",
            "/// See ``LiveThing`` and ``HostOutputSniffer``.\nlet x = 1\n",
        );
        assert!(!every_docc_link_resolves(&fixture.tree()).is_clean());

        let clean = Fixture::new("docc-clean");
        vouching_corpus(&clean);
        clean.write("Sources/A/Live.swift", "enum LiveThing {}\n");
        clean.write("Sources/A/Doc.swift", "/// See ``LiveThing``.\nlet x = 1\n");
        assert!(every_docc_link_resolves(&clean.tree()).is_clean());
    }

    /// A name kept alive only by other COMMENTS does not vouch for itself.
    #[test]
    fn a_comment_does_not_declare_a_name() {
        let fixture = Fixture::new("docc-comment-vouch");
        vouching_corpus(&fixture);
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
        vouching_corpus(&fixture);
        fixture.write("Sources/A/PaneVocabulary.swift", "let x = 1\n");
        fixture.write("Sources/A/Doc.swift", "/// See ``PaneVocabulary``.\nlet y = 2\n");
        assert!(every_docc_link_resolves(&fixture.tree()).is_clean());
    }

    /// A corpus that came back SMALL is a rule that has gone blind, and it says so.
    ///
    /// The old guard was `!known.is_empty()`, and it was seeded with four framework constants
    /// before a file was read — so it answered "the tree was read" for a tree that had not
    /// been. This is that seeding, undone: a fixture with one Swift file declares a handful of
    /// names, which is under the floor, and the rule reds instead of vouching for the one link
    /// it can see.
    #[test]
    fn a_corpus_under_the_floor_is_blind_rather_than_clean() {
        let fixture = Fixture::new("docc-blind");
        fixture.write("Sources/A/Doc.swift", "/// See ``SwiftUICore``.\nlet x = 1\n");
        let report = every_docc_link_resolves(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report.violations()[0].contains("this rule is blind"),
            "{:?}",
            report.violations()
        );
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

    /// A citation carrying a line number is still a citation.
    ///
    /// `docs/62` §2.4 cites every wrapper as `path.swift:15`, and the extraction that required the
    /// closing backtick against the extension read seven deleted files as nothing at all.
    #[test]
    fn a_line_numbered_citation_is_read_like_any_other() {
        let live = concat!("`Sources/", "A/Live.swift:15`");
        let gone = concat!("`Sources/", "A/Gone.swift:47-51`");

        let fixture = Fixture::new("cited-paths-lines");
        fixture.write("CLAUDE.md", "read `docs/51`\n");
        fixture.write("Sources/A/Live.swift", "let x = 1\n");
        fixture.write("docs/51-process-supervision.md", &format!("see {live}\n"));
        assert!(every_cited_path_exists(&fixture.tree()).is_clean());

        let broken = Fixture::new("cited-paths-lines-gone");
        broken.write("CLAUDE.md", "read `docs/51`\n");
        broken.write("Sources/A/Live.swift", "let x = 1\n");
        broken.write(
            "docs/51-process-supervision.md",
            &format!("see {live} and {gone}\n"),
        );
        assert!(!every_cited_path_exists(&broken.tree()).is_clean());
    }

    /// The coupling: one extraction, so a line-numbered citation keeps its tombstone alive.
    ///
    /// This is the test a one-sided widening fails. If [`cited_paths`] stripped the suffix for
    /// `every_cited_path_exists` only, `Gone.swift` would be exempt AND its entry would read
    /// "no read-first doc cites it any more" in the same pass.
    #[test]
    fn a_line_numbered_citation_keeps_its_tombstone_spent() {
        let gone = concat!("`Sources/", "A/Gone.swift:47-51`");

        let fixture = Fixture::new("cited-paths-lines-tombstone");
        fixture.write("CLAUDE.md", "read `docs/51`\n");
        fixture.write("docs/51-process-supervision.md", &format!("gone: {gone}\n"));
        let tree = fixture.tree();
        let cited = cited_paths(&tree, &["docs/51-process-supervision.md".to_owned()], &[
            "Sources".to_owned(),
        ]);

        assert!(
            cited.contains("Sources/A/Gone.swift"),
            "the suffix is dropped, not the citation: {cited:?}"
        );
        assert!(
            unspent_tombstones(&cited, tree.root(), &["Sources/A/Gone.swift"]).is_empty(),
            "the tombstone is still spent"
        );
    }
}
