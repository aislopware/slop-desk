//! One rule implemented in both languages, four times over — and the two crossings that were shaped
//! like loops.
//!
//! Ported from the deleted `check-supervisor.sh`. In three of the four twins the two copies were
//! not even reached by the same inputs — one side had the callers and the other had the tests —
//! which is the arrangement in which a divergence can never show up as a red anything. What regrows
//! a pair is not a whole function reappearing; it is one predicate, one cast or one line of index
//! arithmetic written by hand beside a door that already answers it.

use crate::claim::{Claim, GATE_RULES, RUST, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const REPAIR: &str = "Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift";
const PANE_SPEC: &str = "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift";
const NEW_TAB: &str = "Sources/SlopDeskWorkspaceModel/Domain/Tree/NewTabPosition.swift";
/// The bindable port, after `docs/63` §G.3 took its Swift half: ONE spelling, and this is it.
const PORT_RUST: &str = "rust/slopdesk-workspace/src/listen.rs";
const REPLAY_BUFFER: &str = "Sources/SlopDeskTransport/ReplayBuffer.swift";
const NERD_FONT: &str = "Sources/SlopDeskFontFaces/NerdSymbolFont.swift";

/// The tree repair pass is Rust, and what regrows is one predicate
///
/// The pair never shadowed itself because the two halves fired on DIFFERENT EVENTS — Swift's copy
/// on file load, the crate's on every intent. A workspace that closed cleanly came back a different
/// shape after a relaunch, with every test on both sides green, because each half was
/// self-consistent. It is `slopdesk_workspace::tree_ops::repaired` now (`docs/55` §8).
///
/// What grows a second implementation back is not a whole function reappearing — that would be
/// seen. It is one PREDICATE or one re-seed STRING restated by hand, which is how the divergence
/// started: `isVideo` was `self == .desktop` on one side and a crate predicate on the other,
/// agreeing by coincidence right up until a third video-ish kind would have split them.
///
/// The bans read the file COMMENT-STRIPPED: this file's header EXPLAINS the divergence and has to
/// quote the predicate it names to be worth reading. A gate that cannot tell the code from the
/// post-mortem forbids writing the post-mortem, which is the one artefact that stops the next port
/// repeating it. (Caught on the shell's first run of this gate, 2026-08-20 — the doc comment
/// matched.)
///
/// ONE CLAIM DID NOT COME ACROSS. The shell also printed a NOTE when
/// `withTheDocumentsBlindSpotsClosed` disappeared — the named residue whose deletion needs a whole
/// `TreeWorkspace` codec in `slopdesk_workspace::persist`. A note is not a gate: it passes either
/// way, so it recorded an intention rather than checking one, and this crate has no shape for
/// "print something and succeed". The exit stays visible in that function's own name.
#[must_use]
pub fn one_tree_repair_in_rust(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: REPAIR,
            message: "TreeWorkspace.swift is gone — the launch-time repair's Swift half is a marshaller, \
                      not nothing (docs/55 §8)",
        },
        Claim::Lacks {
            path: REPAIR,
            pattern: r#"kind == \.desktop|title: "Terminal"|name: "Local""#,
            view: View::Code,
            message: "TreeWorkspace.swift restated a repair rule in code — the video predicate and the two \
                      re-seed strings are rust/slopdesk-workspace's; ask the door \
                      (slopdesk_ws_pane_kind_is_video, slopdesk_ws_default_*) (docs/55 §8)",
        },
        // And the predicate itself, wherever it lives: `PaneKind.isVideo` must ASK. It is the one the
        // repair reads to decide which panes may live in the tree at all, so a transcribed copy of it
        // is the exact defect above, one layer down.
        Claim::Names {
            path: PANE_SPEC,
            needle: "slopdesk_ws_pane_kind_is_video",
            message: "PaneKind.isVideo stopped asking slopdesk_ws_pane_kind_is_video — a transcribed \
                      predicate agrees until it does not (docs/55 §8)",
        },
    ];
    check_all(tree, &claims)
}

/// Four cross-language twins, and what grows each one back
///
/// 1. THE NEW-TAB PLACEMENT. `NewTabPosition.insertionIndex` was the three-case arithmetic and the
///    two clamps a second time, and it had NO production caller: ⌘T and ⇧⌘T send the policy as a
///    byte inside a workspace intent, and `slopdesk_workspace::tree_ops` places the tab on the far
///    side. So the Swift copy answered only its own four test cases while the crate's decided where
///    every tab actually went.
///
/// 2. THE OTHER HALF OF THE PANE-KIND CLASSIFICATION. `canReceiveText` was `self == .terminal`
///    beside a `PaneKind::can_receive_text` that no Rust caller had ever reached — one
///    classification, one half asked through a door and one half transcribed, which is precisely
///    the `MIN_WEIGHT`/`MAX_DEPTH` anti-pattern `docs/55` §8 names and says one of the two is
///    always wrong. Catches: the broadcast recipient set and the launch restore selecting different
///    panes the day a third kind lands on one side only.
///
/// 3. THE BINDABLE PORT, WHICH IS NO LONGER A TWIN. `PortValidation.port` asked the RANGE door and
///    then made its own `UInt16` conversion, while `listen::port` — which does both — had no caller
///    and said so in its own doc comment. The two agree only because `u16`'s range happens to BE
///    the accepted range: that is a fact about today's rule, not a rule. A range that stopped being
///    it — a reserved floor, a refusal of 0 — moves the predicate and leaves the near-side cast
///    agreeing with nothing. `docs/63` §G.3 deleted `PortValidation.swift` with the rest of the
///    Swift client transport and retired `slopdesk_ws_listen_port` with it, since a door outliving
///    its only caller is what `docs/55` §4b forbids. So this row asserts the SURVIVING half of the
///    same fact: the one file that holds the rule still holds it, the refusal and the conversion
///    are still one expression, and no Swift anywhere spells the range or the cast a second time. A
///    twin that became single-language is not a rule that stopped being needed — it is a rule with
///    one side left to guard, and the Swift ban is what keeps the second side from being written
///    again.
///
/// 4. THE UNREACHED HALF THAT WAS DELETED RATHER THAN PORTED. `slopdesk_workspace::session` carried
///    a `VideoPaneModes` of five public fields with no methods, no callers, no tests and no
///    re-export, while `PaneSpec.swift`'s comment said in so many words that no Rust counterpart
///    existed. Both halves of that were the defect. An unreached copy cannot be caught disagreeing,
///    because no input ever reaches both, and a comment asserting a cross-language fact is a claim
///    with no gate behind it. The modes are device-local, decoded by `Foundation` out of
///    `device-prefs.json`, and Swift is the one implementation.
///
/// The fourth ban reads BOTH crates, because `session` moved: `slopdesk-workspace` was carved into
/// four and the shape this bans lived in the half that left. Scanning only the old name would read
/// 27 files that never held it and report green forever — which is what the file floor is for.
#[must_use]
pub fn four_cross_language_twins(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: NEW_TAB,
            message: "NewTabPosition.swift is gone — the case list is a vocabulary that a settings picker, \
                      the Defaults bridge and the intent wire all read, so the Swift half is a marshaller, \
                      not nothing (docs/55 §6)",
        },
        Claim::Names {
            path: NEW_TAB,
            needle: "slopdesk_ws_new_tab_index(",
            message: "NewTabPosition.swift stopped asking slopdesk_ws_new_tab_index — the placement is \
                      rust/slopdesk-workspace's, and a Swift copy of it answers only its own tests (docs/55 \
                      §8)",
        },
        // And the arithmetic itself, in case a copy lands BESIDE the door rather than replacing it —
        // the way the isVideo divergence started. Comment-stripped, so the doc comment may go on
        // naming the clamps this method no longer performs.
        Claim::Lacks {
            path: NEW_TAB,
            pattern: r"max\(tabCount|min\(max\(|clampedActive|activeTabIndex \+ 1",
            view: View::Code,
            message: "NewTabPosition.swift restated the insertion arithmetic — the two clamps and the \
                      after-current slot are the crate's; ask the door (docs/55 §8)",
        },
        Claim::Names {
            path: PANE_SPEC,
            needle: "slopdesk_ws_pane_kind_can_receive_text(",
            message: "PaneKind.canReceiveText stopped asking slopdesk_ws_pane_kind_can_receive_text — half \
                      a classification asked and half transcribed is how the two halves come apart, with \
                      both suites green (docs/55 §8)",
        },
        // The third twin is no longer cross-language, so what is asserted is that it is no longer a
        // PAIR: one file spells the rule, the refusal and the conversion are one expression inside
        // it, and no Swift anywhere holds a second half.
        Claim::Exists {
            path: PORT_RUST,
            message: "rust/slopdesk-workspace/src/listen.rs is gone — the bindable port is one rule and \
                      this is the file it lives in (docs/55 §8, docs/63 §G.3)",
        },
        Claim::Names {
            path: PORT_RUST,
            needle: "u16::try_from(raw)",
            message: "listen::port stopped deriving the port from the conversion — the range and the cast \
                      are the same claim, and spelling them separately is the twin this rule was named for, \
                      one register down (docs/55 §8)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests", "Apps"],
            extensions: SWIFT,
            pattern: r"UInt16\(raw\)|0\.\.\.65535|1\.\.\.65535",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the listen-port rule has a Swift half again ({files}) — PortValidation composed the \
                      range door with a cast of its own and the two agreed only because u16's range happens \
                      to BE the accepted one; docs/63 §G.3 deleted that file and retired \
                      slopdesk_ws_listen_port with it, so there is one spelling and it is Rust's (docs/55 \
                      §8)",
        },
        Claim::Populated {
            roots: &["rust/slopdesk-workspace/src", "rust/slopdesk-tree/src"],
            extensions: RUST,
            minimum: 20,
            message: "rust/slopdesk-{workspace,tree}/src read as {found} files — the crate moved, so the \
                      ban beside this stopped checking anything (docs/55 §8)",
        },
        Claim::NoneUnder {
            roots: &["rust/slopdesk-workspace/src", "rust/slopdesk-tree/src"],
            extensions: RUST,
            pattern: "VideoPaneModes",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "VideoPaneModes grew back ({files}) — the latched video modes are device-local and \
                      Swift decodes them; an unreached Rust shape is worse than none, because no input \
                      reaches both halves (docs/55 §8)",
        },
    ];
    check_all(tree, &claims)
}

/// The loop-shaped crossings: a whole-collection door, not a door per member
///
/// Both pairs below are one rule asked about `n` members. Read one at a time they were a crossing
/// per member on a path that runs per reattach and per render, which is the shape
/// `slopdesk_settings_row_fields` and `slopdesk_ws_rail_disambiguated_labels` were widened out of.
/// Nothing in the type system stops a caller sliding back to `entry(at: index)` inside a `for`, and
/// no test would fail if it did — the answers are identical, only the crossing count moves.
#[must_use]
pub fn the_loop_shaped_crossings_are_whole_collection_doors(tree: &Tree) -> Report {
    let claims = [
        // The message slot's METADATA crosses once for the whole slot. Losing this call means the file
        // went back to asking per index, at `3n + 1` crossings for a slot of `n` — on a cold reattach
        // that is a whole retained history's worth.
        Claim::Names {
            path: REPLAY_BUFFER,
            needle: "slopdesk_replay_result_headers",
            message: "ReplayBuffer.swift no longer calls slopdesk_replay_result_headers — read the WHOLE \
                      message slot in one crossing, then one slopdesk_replay_result_copy per message",
        },
        // The two per-index metadata doors were DELETED, not kept beside the list door, because
        // The dead-door ratchet would have called them dead the moment Swift stopped asking. A
        // name reappearing anywhere in Swift means someone re-cut a second way to ask what the headers
        // door answers.
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: "slopdesk_replay_result_seq|slopdesk_replay_result_len",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} asks for one message's seq or length — those doors are gone; \
                      slopdesk_replay_result_headers answers the whole slot at once",
        },
        // The SHAPE, not just the names: an index range mapped over the slot is how the per-member
        // loop comes back even under different door names. The live reader walks the headers it was
        // handed.
        Claim::Lacks {
            path: REPLAY_BUFFER,
            pattern: r"\(0\.\.<count\)\.map|for index in 0\.\.<count",
            view: View::Code,
            message: "ReplayBuffer.swift walks the message slot by index again — take the headers in one \
                      crossing and enumerate those",
        },
        // `CommandBlock.statuses(of:)` is the whole-list form. `slopdesk_block_status` stays for the row
        // asking about itself, so the ban below is deliberately on the LOOP and not on the single door.
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift",
            needle: "slopdesk_block_statuses",
            message: "TerminalBlockModel.swift no longer calls slopdesk_block_statuses — \
                      CommandBlock.statuses(of:) answers a whole list in one crossing; the single door is \
                      for one row",
        },
        // The peek transcript builds inside the overlay's `body`, so a status per block is a crossing
        // per block PER RENDER — and the strings it builds are flattened straight back across the same
        // boundary on the very next line.
        //
        // Scoped to the fold's own parameter, `blocks`: the protocol's DEFAULT witness one screen down
        // is `lines.map(\.statusLabel)` and has to stay — it is the honest loop for a stand-in whose
        // label is a stored string. Banning the map outright would ban the default with it.
        Claim::Lacks {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
            pattern: r"blocks\.map\(\\\.statusLabel\)",
            view: View::Code,
            message: "PeekReply.swift maps statusLabel over its blocks again — that is one block-status \
                      door crossing per block per render; ask Line.statusLabels(of:) once",
        },
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
            needle: "statusLabels(of:",
            message: "PeekReply.swift no longer asks PeekBlockLine.statusLabels(of:) — the whole-list form \
                      is what keeps the transcript off a per-block crossing",
        },
    ];
    check_all(tree, &claims)
}

/// The Unicode private-use table is spelled ONCE, and the copy that regrew got a whole plane wrong
///
/// `rust/slopdesk-sanitize` DROPS these codepoints so an agent reads clean text; `NerdSymbolFont`
/// SPLICES the bundled face over exactly them so a person sees a glyph rather than a notdef box.
/// One Unicode fact, two opposite uses — and it was typed on both sides until 2026-08-26, where it
/// failed in the way a second copy of a range table always fails, at the ends:
///
/// * The Rust copy was missing **plane 16** outright (`U+100000–U+10FFFD`), which is where the
///   material-design icon set lives. A title carrying one of those reached an agent as the glyph
///   the strip exists to remove.
/// * It ran two codepoints past the end of plane 15, into `U+FFFFE`/`U+FFFFF` — NONCHARACTERS,
///   never private use.
///
/// Neither half could reach the other, so neither had a test that could have said so. That is the
/// arrangement `four_cross_language_twins` above describes and the reason this rule is here rather
/// than in `shared_constants`: what is shared is not a NUMBER, it is a TABLE, and it crosses whole
/// through `slopdesk_private_use_ranges` at first use.
///
/// The ban is on the BOUNDS, not on the word "private use": a range table is wrong at its edges or
/// not at all, so the edges are what may not be retyped. `View::Code` throughout, for
/// `one_tree_repair_in_rust`'s reason — the face's own header quotes the range it names, and a gate
/// that cannot tell the code from the post-mortem forbids writing the post-mortem.
#[must_use]
pub fn one_private_use_table(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: NERD_FONT,
            message: "NerdSymbolFont.swift is gone — the splice's Swift half is a marshaller over \
                      slopdesk_private_use_ranges, not nothing",
        },
        Claim::AtLeast {
            path: NERD_FONT,
            pattern: r"slopdesk_private_use_ranges",
            minimum: 1,
            message: "NerdSymbolFont.swift asks for the private-use table {found} times — it is \
                      rust/slopdesk-sanitize's, and the two copies disagreed about plane 16 the last time \
                      this file answered for itself",
        },
        // Anywhere in Swift, not just in the face: what regrows is one predicate written beside a
        // door that already answers it, and the second writer is never the file that lost the rule.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"0x10FFFD|0xF8FF|0xFFFFD",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} — a private-use range BOUND is typed in Swift. The table is \
                      rust/slopdesk-sanitize's and crosses whole through slopdesk_private_use_ranges; a \
                      second copy of it is how plane 16 went missing for a year",
        },
        // And the same ban the other way: exactly one Rust file may hold the table.
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: r"0x10_FFFD|0xF_FFFD",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-sanitize/src/plaintext.rs", GATE_RULES],
            message: "{files} — a private-use range bound is typed outside \
                      rust/slopdesk-sanitize/src/plaintext.rs, which is the one place it lives",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn the_repair_asks_rather_than_restates() {
        let fixture = Fixture::new("twins-repair");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    super::REPAIR,
                    "// kind == .desktop is what it USED to say\nrepaired(intent)\n",
                )
                .write(
                    super::PANE_SPEC,
                    "slopdesk_ws_pane_kind_is_video\nslopdesk_ws_pane_kind_can_receive_text(\n",
                );
        };
        seed(&fixture);
        // The post-mortem may quote the predicate; only code may not carry it.
        assert!(super::one_tree_repair_in_rust(&fixture.tree()).is_clean());

        fixture.append(super::REPAIR, "if kind == .desktop { return true }\n");
        assert!(!super::one_tree_repair_in_rust(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write(super::PANE_SPEC, "var isVideo: Bool { self == .desktop }\n");
        assert!(!super::one_tree_repair_in_rust(&fixture.tree()).is_clean());
    }

    fn twins(fixture: &Fixture) {
        fixture
            .write(super::NEW_TAB, "slopdesk_ws_new_tab_index(policy)\n")
            .write(
                super::PANE_SPEC,
                "slopdesk_ws_pane_kind_is_video\nslopdesk_ws_pane_kind_can_receive_text(\n",
            )
            .write(
                super::PORT_RUST,
                "pub fn port(raw: i64) -> Option<u16> { u16::try_from(raw).ok() }\n",
            );
        for index in 0..20 {
            fixture.write(
                &format!("rust/slopdesk-workspace/src/module{index}.rs"),
                "pub fn thing() {}\n",
            );
        }
    }

    #[test]
    fn each_twin_asks_and_the_unreached_shape_stays_deleted() {
        let fixture = Fixture::new("twins-four");
        twins(&fixture);
        assert!(super::four_cross_language_twins(&fixture.tree()).is_clean());

        // The arithmetic back BESIDE the door, which is how the isVideo divergence started.
        fixture.append(super::NEW_TAB, "return min(max(index, 0), tabCount)\n");
        assert!(!super::four_cross_language_twins(&fixture.tree()).is_clean());

        // The cast, written a second time in Swift — the half of the twin that came back rather than
        // the half that stayed.
        twins(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Connection/ConnectionViewModel.swift",
            "guard (1...65535).contains(raw) else { return nil }\nreturn UInt16(raw)\n",
        );
        assert!(!super::four_cross_language_twins(&fixture.tree()).is_clean());

        // And the surviving half losing the property that made it ONE answer: a range predicate and a
        // conversion spelled apart is the twin re-forming inside a single language.
        twins(&fixture);
        fixture.write(
            super::PORT_RUST,
            "pub fn port(raw: i64) -> Option<u16> { is_valid_port(raw).then(|| raw as u16) }\n",
        );
        assert!(!super::four_cross_language_twins(&fixture.tree()).is_clean());

        // The unreached shape, back.
        twins(&fixture);
        fixture.write(
            "rust/slopdesk-workspace/src/session.rs",
            "pub struct VideoPaneModes { pub scaled: bool }\n",
        );
        assert!(!super::four_cross_language_twins(&fixture.tree()).is_clean());

        // And the crate carved up under the ban's feet — the failure the floor exists for.
        let moved = Fixture::new("twins-four-moved");
        moved
            .write(super::NEW_TAB, "slopdesk_ws_new_tab_index(policy)\n")
            .write(
                super::PANE_SPEC,
                "slopdesk_ws_pane_kind_is_video\nslopdesk_ws_pane_kind_can_receive_text(\n",
            )
            .write(
                super::PORT_RUST,
                "pub fn port(raw: i64) -> Option<u16> { u16::try_from(raw).ok() }\n",
            );
        assert!(!super::four_cross_language_twins(&moved.tree()).is_clean());
    }

    fn loops(fixture: &Fixture) {
        fixture
            .write(super::REPLAY_BUFFER, "slopdesk_replay_result_headers(slot)\n")
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift",
                "slopdesk_block_statuses(list)\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
                "Line.statusLabels(of: blocks)\nlines.map(\\.statusLabel)\n",
            );
    }

    #[test]
    fn a_collection_crosses_once_rather_than_per_member() {
        let fixture = Fixture::new("twins-loops");
        loops(&fixture);
        // The protocol's DEFAULT witness maps over `lines` and has to stay.
        assert!(super::the_loop_shaped_crossings_are_whole_collection_doors(&fixture.tree()).is_clean());

        // The fold's own parameter, mapped — one crossing per block per render.
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
            "let labels = blocks.map(\\.statusLabel)\n",
        );
        assert!(!super::the_loop_shaped_crossings_are_whole_collection_doors(&fixture.tree()).is_clean());

        // A deleted per-index door, asked for again — anywhere, tests included.
        loops(&fixture);
        fixture.write(
            "Tests/TransportTests/ReplayTests.swift",
            "slopdesk_replay_result_seq(0)\n",
        );
        assert!(!super::the_loop_shaped_crossings_are_whole_collection_doors(&fixture.tree()).is_clean());

        // And the index walk, back under whatever door name.
        loops(&fixture);
        fixture.append(super::REPLAY_BUFFER, "for index in 0..<count { read(index) }\n");
        assert!(!super::the_loop_shaped_crossings_are_whole_collection_doors(&fixture.tree()).is_clean());
    }

    /// Both directions, because the pair failed in both: the face must keep ASKING, and neither
    /// language may retype a bound. A rule that only checked the Swift side would have passed
    /// happily over the Rust copy that was actually wrong.
    #[test]
    fn a_retyped_private_use_bound_is_caught_in_either_language() {
        let fixture = Fixture::new("one-private-use-table");
        fixture.write(
            super::NERD_FONT,
            "let ranges = slopdesk_private_use_ranges(nil, 0)\n",
        );
        fixture.write(
            "rust/slopdesk-sanitize/src/plaintext.rs",
            "const PRIVATE_USE: [(u32, u32); 3] = [(0xE000, 0xF8FF), (0xF_0000, 0xF_FFFD), (0x10_0000, \
             0x10_FFFD)];\n",
        );
        assert!(
            super::one_private_use_table(&fixture.tree()).is_clean(),
            "the one place the table lives is exempt, and the face asks",
        );

        // The face stops asking — which is what "I will just inline it" looks like.
        fixture.write(super::NERD_FONT, "func isPrivateUse() -> Bool { false }\n");
        let report = super::one_private_use_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("asks for the private-use table 0 times")),
            "{report:?}"
        );

        // A bound retyped in Swift, in a file that is not even the face.
        fixture.write(
            super::NERD_FONT,
            "let ranges = slopdesk_private_use_ranges(nil, 0)\n",
        );
        fixture.write(
            "Sources/SlopDeskSlate/SlateNativeText.swift",
            "let pua = 0xE000...0xF8FF\n",
        );
        let report = super::one_private_use_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("SlateNativeText.swift")),
            "{report:?}"
        );

        // And a second Rust copy, which is the half that was actually wrong.
        fixture.write("Sources/SlopDeskSlate/SlateNativeText.swift", "let x = 1\n");
        fixture.write(
            "rust/slopdesk-rowscan/src/waituntil.rs",
            "const MINE: u32 = 0x10_FFFD;\n",
        );
        let report = super::one_private_use_table(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("waituntil.rs")),
            "{report:?}"
        );
    }
}
