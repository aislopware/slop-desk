//! The re-derivations a repaint must not grow back.
//!
//! Ported from `scripts/check-supervisor.sh`. None of these is visible to a test: every answer stays
//! correct, both halves stay self-consistent, and the only trace is the frame. What they have in
//! common is the shape `docs/55` §4c names — a value that reads like a FIELD and is in fact a
//! PROJECTION, sitting behind a computed `var` that a `body`, or a loop, reaches for more than once.
//!
//! That is why they are gates rather than tests. A differential test cannot see a doubled scan, and
//! a timing assertion in CI is a flake generator. Each rule states what was MEASURED, and each was
//! break-tested against the real tree by editing the file, running the rule, and restoring from a
//! `/tmp` copy — never `git checkout`, which would have discarded that file's own uncommitted work.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The store that owns the memo, and the only file allowed to read the projection.
const MIRROR_MEMO: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift";

/// The mirror's whole topology is projected ONCE per revision
///
/// `HostWorkspaceMirror.topology` is a computed property: every read copies the entire entry map and
/// re-runs `WorkspaceTopology.init(entries:)` over every cell in the document. Measured in a scratch
/// harness (`swiftc -O`), the dictionary copy alone is 6.4µs at 12 panes and 23.9µs at 48, and the
/// per-cell decode walk on top of it takes those to 10.3µs and 37.9µs — a FLOOR, since the real
/// projection also rebuilds every split tree, spec, MRU and closed tab.
///
/// `SidebarRowPresentation.reading(…)` reached it once per ROW through `store.syncInputArmed`, so a
/// sidebar of R rows paid R projections per render pass: ~126µs at 12 rows, ~1.8ms at 48. It is now
/// memoized against `workspaceMirrorRevision`, the key `tree` already trusted, and the ONE remaining
/// direct read is the memo's own miss path. A second direct read anywhere puts the whole projection
/// back on that caller's path with green tests and no compile error — `docs/55` §8's drift class.
///
/// The ceiling is TWO rather than one because the memo's miss path spells the property on both the
/// read and the store, and a ban cannot say that: the rule is not "nobody reads it" but "only the
/// memo does, and only where it must".
///
/// BREAK-TESTED 2026-08-22: adding `let t = workspaceMirror.topology` to
/// `WorkspaceStore+Intents.swift` failed the ban; removing it passed. Deleting one of the memo's two
/// reads failed the ceiling.
#[must_use]
pub fn the_mirror_topology_is_projected_once(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            // The floor under the ban. This gate has died quietly by resolving to an empty file
            // list before, and a ban over nothing passes.
            Claim::Populated {
                roots: &["Sources"],
                extensions: SWIFT,
                minimum: 200,
                message: "only {found} Swift sources — the topology-memo ban would pass on an \
                          empty haystack",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"workspaceMirror\.topology",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[MIRROR_MEMO],
                message: "{files} re-derives the WHOLE topology — the entry-map copy plus a walk of \
                          every cell, 10µs at 12 panes and 38µs at 48. Read `mirroredTopology` \
                          instead; it answers from the memo keyed on `workspaceMirrorRevision`",
            },
            Claim::AtMost {
                path: MIRROR_MEMO,
                pattern: r"workspaceMirror\.topology",
                maximum: 2,
                view: View::Code,
                message: "the store reads workspaceMirror.topology {found} times; the memo has ONE \
                          miss path. A further read belongs inside `mirroredTopology` or it is not \
                          memoized",
            },
        ],
    )
}

/// Three projections read once per pass, not three times
///
/// 1. THE DEVICE CONSOLES. `visible` is a `localizedCaseInsensitiveContains` over every retained log
///    line, and `logCapacity` is 600 on both models. Measured in a scratch `swiftc -O` harness (NOT
///    in the tree, two runs agreeing to 1%): 0.78 ms per derivation when the needle hits, 1.50 ms
///    when it MISSES — and a miss is the state every keystroke passes through. Both views read it
///    three times per pass (the emptiness test, the `animation(value:)` key, the `ForEach`), so one
///    console repaint cost 2.3–4.5 ms of main thread, and the drawer repaints on every arriving
///    line. The fix is one `let` threaded into `rows(_:)`; the gate is that `rows` stays a FUNCTION
///    taking the derived rows, because a `private var rows` can only have reached for `visible`
///    itself.
///
/// 2. THE DEVICE LISTS. The same rule one register down — `matches` answered an emptiness test and
///    then built the sections from two separate derivations, at ~1.6 µs per
///    `localizedCaseInsensitiveContains` call over two fields per device.
///
/// 3. THE PICKER. `sections` reassembles all five pill sources off the live store and then RANKS
///    every one of them. Measured against the shipped xcframework at 127 candidates over five
///    sources: 125 µs for the ranking plus 20 µs to mint the rows. `selectableRows` and
///    `displayEntries` each reached through to it, so the picker paid ~145 µs TWICE per keystroke
///    before drawing a row — and the ⌘1–9 arm paid it twice more to read one row out.
///
/// The two `visible.isEmpty` readings are banned by SHAPE. A shape ban cannot see an intent, but
/// here the shape IS the defect: there is no reading of this property that costs less than the whole
/// filter, so asking it a yes/no question is asking for the 600-row scan and throwing the rows away.
/// The ONE surviving read outside the `let` is the Copy-console verb, and that one is inside a
/// `Button` ACTION closure, so it happens on a tap rather than on a pass.
///
/// BREAK-TESTED against the real tree on 2026-08-22, each rule individually. All seven fire, each on
/// its own file only, and the restored tree reads 0.
#[must_use]
pub fn three_projections_read_once_per_pass(tree: &Tree) -> Report {
    /// The two device consoles, whose `visible` is a filter over 600 retained lines.
    const CONSOLES: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift",
        "Sources/SlopDeskPhoneUI/Panel/Android/AndroidConsoleView.swift",
    ];
    /// The two device lists, one register down.
    const LISTS: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift",
        "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift",
    ];
    /// The picker, whose `sections` ranks five sources per read.
    const PICKER: &str = "Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift";

    let mut claims = vec![
        Claim::Matches {
            path: PICKER,
            pattern: r"^ *let built = sections$",
            view: View::Code,
            message: "OpenQuicklyView: resultsList stopped binding `sections` once — every reader \
                      re-ranks all five sources (~145 µs a keystroke)",
        },
        Claim::Lacks {
            path: PICKER,
            pattern: r"^ *private var displayEntries:",
            view: View::Code,
            message: "OpenQuicklyView: `displayEntries` is back as a computed var — it is a second \
                      whole derivation of `sections`",
        },
    ];
    for console in CONSOLES {
        claims.push(Claim::Matches {
            path: console,
            pattern: r"^ *private func rows\(_ shown: \[DeviceLogLine\]\)",
            view: View::Code,
            message: "a device console's rows() stopped taking the derived lines — a \
                      `private var rows` re-runs the 600-row filter a second time",
        });
        claims.push(Claim::Lacks {
            path: console,
            pattern: r"\bvisible\.isEmpty\b",
            view: View::Code,
            message: "a device console asks `visible.isEmpty` — that runs the whole 600-row filter \
                      to answer a Bool (docs/55 §4c)",
        });
        claims.push(Claim::Matches {
            path: console,
            pattern: r"^ *let shown = visible$",
            view: View::Code,
            message: "a device console's content() stopped binding `visible` once — the 0.78–1.50 \
                      ms filter is back on every reader",
        });
    }
    for list in LISTS {
        claims.push(Claim::Matches {
            path: list,
            pattern: r"^ *private func list\(_ shown: \[(Simulator|Android)Device\]\)",
            view: View::Code,
            message: "a device list's list() stopped taking the derived devices — a \
                      `private var list` re-filters every device a second time",
        });
    }
    check_all(tree, &claims)
}

/// The doors guess, they do not probe
///
/// The first two findings of the Rust-push sweep of `Sources/SlopDeskWorkspaceCore/`. Both pin a
/// change whose ONLY symptom is latency: the code keeps compiling, every unit test keeps passing,
/// and the find bar or the folder overlay just gets slower.
///
/// ## W1. The two index doors guess, they do not probe
/// `slopdesk_folder_ranked`, `slopdesk_folder_sanitized` and `slopdesk_sync_input_keyboard_only` all
/// answer a SUBSET of what was lent, so the caller holds the exact ceiling of the answer before it
/// asks. Both faces used to call with a null output first to learn a size they could already compute
/// — and a null-output call on these doors is not free, it rebuilds the whole folder database and
/// sorts it, or runs the whole `vtscan` pass, and throws the answer away. Measured: `ranked` at the
/// shipped 200-entry cap 30.9 µs → 15.6 µs through the door (54.3 µs → 39.0 µs for the whole Swift
/// face), and the sync-input strip 14.4 µs → 7.5 µs on an 8 KiB mirrored paste. The overlay asks for
/// the ranking twice per keystroke. The GUESS is what makes the probe unnecessary, so its absence is
/// the same bug wearing a different face.
///
/// ## W2. The find door's guess is CARRIED, not a constant
/// `slopdesk_find_matches` builds its answer by scanning every row, so §4's retry costs a second
/// scan of the entire scrollback rather than a second copy. A fixed 128-record guess therefore
/// doubled every query that matched more than 128 rows — which is most of the useful ones. Measured
/// through the door over a 10 000-row / 736 KB scrollback with a query matching every row: 3.52 ms
/// per keystroke at the fixed guess against 1.83 ms at the carried one, per pane, and ⇧⌘F asks every
/// open pane at once.
///
/// Every rule reads CODE, never prose: each of these files documents the shape it no longer has, by
/// name, so a gate that matched comments would fire on the explanation of its own bug.
#[must_use]
pub fn the_index_doors_guess_they_do_not_probe(tree: &Tree) -> Report {
    /// The folder index's Swift face.
    const FRECENCY: &str = "Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift";
    /// The mirrored-paste strip's Swift face.
    const SYNCINPUT: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/SyncInputByteFilter.swift";
    /// The per-pane find bar.
    const FIND: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift";
    /// The all-panes find.
    const GLOBALFIND: &str = "Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift";

    check_all(
        tree,
        &[
            // W1a/W1b — the null-output probe, which runs the whole far-side rule and keeps
            // nothing, to learn a size the caller already has.
            Claim::Lacks {
                path: FRECENCY,
                pattern: r"\bnil, *0\b|\bnull, *0\b",
                view: View::Code,
                message: "W1a: the folder ranking probes with a NULL output again — that call \
                          rebuilds the whole folder database and sorts it, to learn a size the \
                          caller already has (docs/55 §4)",
            },
            Claim::Lacks {
                path: SYNCINPUT,
                pattern: r"\bnil, *0\b|\bnull, *0\b",
                view: View::Code,
                message: "W1b: the sync-input strip probes with a NULL output again — that call \
                          runs the whole vtscan pass and keeps nothing (docs/55 §4)",
            },
            Claim::Matches {
                path: FRECENCY,
                pattern: r"answer\(sizedAt:",
                view: View::Code,
                message: "W1c: the folder face no longer sizes its first buffer from the ceiling it \
                          holds — the index doors are back to being asked twice (docs/55 §4)",
            },
            // W2 — the guess is CARRIED across keystrokes and across panes.
            Claim::Matches {
                path: FIND,
                pattern: r"expecting: matches\.count",
                view: View::Code,
                message: "W2a: the find bar stopped carrying the previous keystroke's match count \
                          into the next scan — every query matching more than the stack guess scans \
                          the scrollback twice",
            },
            Claim::Matches {
                path: GLOBALFIND,
                pattern: r"expecting: expected",
                view: View::Code,
                message: "W2b: the global find stopped carrying a guess across panes — the first \
                          pane's answer sizes the rest, and without it every pane pays the second \
                          scan",
            },
        ],
    )
}

/// The scan, the mirror and the emptiness rule each derive once
///
/// The last three findings of the same sweep, and the third is not latency at all — it is drift, of
/// `docs/55` §8's class.
///
/// ## W3. The find scan does not re-derive a row it already has
/// Three re-derivations lived in one 90-line module, all of them per keystroke over the whole
/// scrollback. `folded()` returned a fresh `Vec<u16>` per row; `stands_alone` re-encoded the whole
/// row per HIT; and the regex path measured each column from the start of the row, which is
/// quadratic in a row with many hits. Measured against this module at the commit before, linked into
/// the same binary so both sides run the same `regex` build: 10 000 rows / 736 KB, case-insensitive
/// literal 6.3 ms → 1.2 ms; with whole-word 8.2 ms → 2.0 ms; and on ONE 160 KB row with 20 000 regex
/// hits — the shape a program prints whenever it emits an unwrapped line — 782 ms → 1.9 ms, per
/// keystroke.
///
/// The rules are shape-based on purpose. A vocabulary pin would pass the day someone reintroduced
/// the per-row allocation under a new name; what cannot come back quietly is the SIGNATURE that
/// forced it. Both halves are pinned where a ban alone would not do — banning the from-zero slice
/// would pass the day someone rewrote the walk without reintroducing that exact spelling.
///
/// ## W4. The loopback document resolves the mirror ONCE
/// `HostWorkspaceMirror.resolved` copies the whole entry map and folds the overlay and every pending
/// patch over it, and `WorkspaceIntentApplier.apply` asks its `projectKey:` closure once per pane
/// the document names — live specs UNION the reopen ring. Built inside the closure that is one
/// whole-map copy per pane, which is quadratic in the workspace. `WorkspaceMirrorBox.stageIntent`
/// hoists it and says why at its own call site; this was the sibling call site that did not.
///
/// ## W5. The launch-bytes emptiness rule has ONE author
/// Not latency: drift, of `docs/55` §8's class. `SessionTemplateEngine.launchBytes` used to trim the
/// cwd and the command itself, ahead of calling `templates::keystrokes`, which decides the same
/// thing — and the two did not agree. The crate gated the DIRECTORY untrimmed, so a whitespace-only
/// cwd was "no directory" in Swift and `cd '  '` in Rust, a line the shell answers with an error at
/// every launch. Both production callers pass `cwd: nil`, which is precisely why a pair like that
/// can sit disagreeing indefinitely.
///
/// The same reading rule holds: CODE, never prose.
#[must_use]
pub fn the_scan_and_the_mirror_derive_once(tree: &Tree) -> Report {
    /// The loopback document, which resolves the mirror per intent.
    const LOOPBACK: &str =
        "Sources/SlopDeskWorkspaceCore/Workspace/Sync/LoopbackWorkspaceDocument.swift";
    /// Where a session template becomes launch bytes.
    const TEMPLATES: &str =
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift";
    /// The row scan itself.
    const ROWFIND: &str = "rust/slopdesk-rowscan/src/find.rs";

    check_all(
        tree,
        &[
            // W3 — the three re-derivations inside one 90-line module.
            Claim::Matches {
                path: ROWFIND,
                pattern: r"fn stands_alone\(units: &\[u16\]",
                view: View::Code,
                message: "W3a: the whole-word filter takes a row again instead of the units its \
                          caller already holds — it re-encodes the whole line once per HIT",
            },
            Claim::Lacks {
                path: ROWFIND,
                pattern: r"fn folded\(.*\) *-> *Vec<u16>",
                view: View::Code,
                message: "W3b: the row scan allocates a fresh Vec<u16> per row again — a malloc and \
                          a free per row of the scrollback, per keystroke in the find bar",
            },
            Claim::Lacks {
                path: ROWFIND,
                pattern: r"utf16_units\(line\.get\(\.\.",
                view: View::Code,
                message: "W3c: the row scan measures each regex column from the start of its row \
                          again — quadratic in a row with many hits, and one long unwrapped line \
                          freezes the find bar for the better part of a second",
            },
            Claim::Matches {
                path: ROWFIND,
                pattern: r"line\.get\(counted_bytes\.\.hit\.start\(\)\)",
                view: View::Code,
                message: "W3c: the row scan no longer carries a byte cursor between regex hits on \
                          one row — each column is measured over the row's whole prefix again, \
                          which is quadratic in the row",
            },
            // The ASCII arm is the one that actually runs, and it is the difference between a table
            // walk per code unit and a mask. Its absence is not a correctness bug, which is exactly
            // why nothing else catches it.
            Claim::Matches {
                path: ROWFIND,
                pattern: "to_ascii_lowercase",
                view: View::Code,
                message: "W3d: the row scan folds every code unit through the full Unicode mapping \
                          again — a ToLowercase iterator per character of every row, per keystroke",
            },
            // W4 — hoisted above the closure, not built inside it.
            Claim::Lacks {
                path: LOOPBACK,
                pattern: r"projectKey: *\{ *box\.mirror\.resolved",
                view: View::Code,
                message: "W4: the loopback document resolves the mirror inside its projectKey \
                          closure again — one copy of the whole entry map per pane, quadratic in \
                          the workspace",
            },
            Claim::Matches {
                path: LOOPBACK,
                pattern: r"let resolved = box\.mirror\.resolved",
                view: View::Code,
                message: "W4: the loopback document no longer hoists the resolved mirror above its \
                          projectKey closure — see WorkspaceMirrorBox.stageIntent, which is the \
                          same contract",
            },
            // W5 — one author for the emptiness rule.
            Claim::Lacks {
                path: TEMPLATES,
                pattern: "trimmingCharacters",
                view: View::Code,
                message: "W5: the template engine decides emptiness itself again — \
                          `templates::keystrokes` owns that rule, and the last time both wrote it \
                          they disagreed about a whitespace-only cwd (docs/55 §8)",
            },
        ],
    )
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Enough Swift for the corpus floor, plus the memo's two allowed reads.
    fn mirror(fixture: &Fixture) {
        for index in 0..200 {
            fixture.write(&format!("Sources/Filler/Filler{index}.swift"), "let filler = 0\n");
        }
        fixture.write(
            super::MIRROR_MEMO,
            "var mirroredTopology: WorkspaceTopology {\n    \
             if let memo { return memo }\n    \
             let built = workspaceMirror.topology\n    \
             memo = workspaceMirror.topology\n    return built\n}\n",
        );
    }

    #[test]
    fn a_second_direct_projection_is_red() {
        let fixture = Fixture::new("latency-mirror");
        mirror(&fixture);
        assert!(super::the_mirror_topology_is_projected_once(&fixture.tree()).is_clean());

        // A reader outside the memo puts the whole projection on its own path.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Intents.swift",
            "let t = workspaceMirror.topology\n",
        );
        assert!(!super::the_mirror_topology_is_projected_once(&fixture.tree()).is_clean());

        // And a THIRD read inside it, which the ban cannot see.
        mirror(&fixture);
        fixture.write(
            super::MIRROR_MEMO,
            "let a = workspaceMirror.topology\nlet b = workspaceMirror.topology\n\
             let c = workspaceMirror.topology\n",
        );
        assert!(!super::the_mirror_topology_is_projected_once(&fixture.tree()).is_clean());
    }

    /// The three projections, each bound once.
    fn projections(fixture: &Fixture) {
        for console in [
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift",
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidConsoleView.swift",
        ] {
            fixture.write(
                console,
                "        let shown = visible\n    private func rows(_ shown: [DeviceLogLine]) -> some View {\n",
            );
        }
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift",
                "    private func list(_ shown: [SimulatorDevice]) -> some View {\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift",
                "    private func list(_ shown: [AndroidDevice]) -> some View {\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift",
                "        let built = sections\n",
            );
    }

    #[test]
    fn a_projection_asked_twice_is_red() {
        let fixture = Fixture::new("latency-projections");
        projections(&fixture);
        assert!(super::three_projections_read_once_per_pass(&fixture.tree()).is_clean());

        // The emptiness test, which runs the whole 600-row filter to answer a Bool.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidConsoleView.swift",
            "        let shown = visible\n    private func rows(_ shown: [DeviceLogLine]) -> some View {\n\
             if visible.isEmpty { return empty }\n",
        );
        assert!(!super::three_projections_read_once_per_pass(&fixture.tree()).is_clean());

        // And `displayEntries` back as a second whole derivation of `sections`.
        projections(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift",
            "        let built = sections\n    private var displayEntries: [Row] { sections.flatMap(\\.rows) }\n",
        );
        assert!(!super::three_projections_read_once_per_pass(&fixture.tree()).is_clean());
    }

    /// The seven `WorkspaceCore` files in their post-sweep shape.
    fn sweep(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift",
                "func ranked() { answer(sizedAt: cap) }\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Store/SyncInputByteFilter.swift",
                "func keyboardOnly() { call(buffer, buffer.count) }\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Sync/LoopbackWorkspaceDocument.swift",
                "let resolved = box.mirror.resolved\napply(projectKey: { resolved.key(for: $0) })\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift",
                "func launchBytes() { templates_keystrokes(cwd, command) }\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift",
                "find(query, expecting: matches.count)\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift",
                "find(query, expecting: expected)\n",
            )
            .write(
                "rust/slopdesk-rowscan/src/find.rs",
                "fn stands_alone(units: &[u16], at: usize) -> bool { true }\n\
                 let prefix = line.get(counted_bytes..hit.start());\n\
                 let folded = unit.to_ascii_lowercase();\n",
            );
    }

    #[test]
    fn the_removed_re_derivations_stay_removed() {
        let fixture = Fixture::new("latency-sweep");
        sweep(&fixture);
        assert!(super::the_index_doors_guess_they_do_not_probe(&fixture.tree()).is_clean()
            && super::the_scan_and_the_mirror_derive_once(&fixture.tree()).is_clean());

        // The null-output probe, which rebuilds the whole folder database and keeps nothing.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift",
            "func ranked() { call(nil, 0); answer(sizedAt: cap) }\n",
        );
        // Each break must fire on ITS OWN rule and leave the sibling clean — that is what says the
        // split above kept the two halves independent rather than merely shorter.
        assert!(!super::the_index_doors_guess_they_do_not_probe(&fixture.tree()).is_clean());
        assert!(super::the_scan_and_the_mirror_derive_once(&fixture.tree()).is_clean());

        // The per-row allocation, back under its old signature.
        sweep(&fixture);
        fixture.write(
            "rust/slopdesk-rowscan/src/find.rs",
            "fn stands_alone(units: &[u16], at: usize) -> bool { true }\n\
             fn folded(text: &str, case_sensitive: bool) -> Vec<u16> { vec![] }\n\
             let prefix = line.get(counted_bytes..hit.start());\n\
             let f = unit.to_ascii_lowercase();\n",
        );
        assert!(!super::the_scan_and_the_mirror_derive_once(&fixture.tree()).is_clean());
        assert!(super::the_index_doors_guess_they_do_not_probe(&fixture.tree()).is_clean());

        // And the second author of the emptiness rule.
        sweep(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift",
            "guard !cwd.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }\n",
        );
        assert!(!super::the_scan_and_the_mirror_derive_once(&fixture.tree()).is_clean());
    }
}
