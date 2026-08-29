//! A verb names its platform once, and the surface that runs it decides once.
//!
//! Ported from the deleted `check-supervisor.sh`. The palette, the binding registry and the canvas
//! drag are three id spaces over one set of commands, and each was written twice at some point: a
//! row that restated its own route, a chord whose platform was a compile-time `#if` invisible from
//! the row, a renderer that re-derived the tear-off's ordering by hand. Every rule here says the
//! same thing about one of them — the decision lives in ONE place, and where that place is a Rust
//! table, the two id spaces must name the same rows.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The palette's catalog — the Swift half of the verb id space.
const SWIFT_PALETTE: &str = "Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift";
/// The registry — the Swift half of the chord id space.
const SWIFT_BINDINGS: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift";
/// Where a chord's overrides and the memo of the resolved table live.
const BINDING_OVERRIDES: &str =
    "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift";

/// A tear-off is two ordered steps, and the canvas drag decides once
///
/// `PaneCanvasDragController.commitDestination` records the drop placement on the drag coordinator
/// BEFORE `store.detachPaneToWindow`, because `detachedPanes` changes SYNCHRONOUSLY inside that
/// call and the satellite-window coordinator reads the placement as it opens the window. Reversed,
/// the window still opens — it just opens at the centre-cascade instead of under the cursor, and
/// only when the reader wins the race. An occasional wrong-place window is the worst failure shape
/// there is, and until this declaration descended out of `SplitContainer` it was pinned by nothing
/// but a comment.
///
/// ## And no renderer may spell it again
/// The canvas has two drawings; each one CALLS this controller. A renderer naming a commit verb
/// itself has re-derived the fork — and, on the tear-off, the ORDERING — by hand, which is the "one
/// implementation, never two" failure a rewrite commits by accident.
///
/// ## ⚠️ A SKIPPED RENDERER IS NOT A SATISFIED ONE
/// The loop below skips a renderer that does not exist, so a row may be written ahead of the
/// drawing it names. That tolerance has a cost, and `3f11c6e6`/`bbb9845d` charged it: the phone
/// canvas was renamed `SplitContainer.swift` → `SplitCanvasView.swift`, the `continue` swallowed
/// the missing path, and all six verb bans stopped checking the phone WITHOUT ONE FAILURE. A
/// `Claim::Exists` per renderer is therefore paired with the skip — the skip keeps the ban list
/// well-formed while the `Exists` is what goes red, so a rename must re-aim this row instead of
/// quietly disarming it. Same shape as a `Claim::Populated` beside a `NoneUnder`, at the per-path
/// scale (docs/62 stage E.0).
#[must_use]
pub fn the_canvas_drag_decides_once(tree: &Tree) -> Report {
    /// Where the drag's decisions are spelled.
    const DRAG_CTL: &str = "Sources/SlopDeskClientCore/Pane/PaneCanvasDragController.swift";
    /// The verbs that belong to the controller and to nobody else.
    const VERBS: &[(&str, &str)] = &[
        ("detachPaneToWindow", r"detachPaneToWindow\("),
        ("recordPlacement", r"recordPlacement\("),
        (
            "resolveTreeExternalDestination",
            r"resolveTreeExternalDestination\(",
        ),
        (
            "resolveSpringLoadedTreeDestination",
            r"resolveSpringLoadedTreeDestination\(",
        ),
        ("updateSolvedLayout", r"updateSolvedLayout\("),
        ("updateContainerBounds", r"updateContainerBounds\("),
    ];
    /// The two drawings of the canvas, each of which must CALL rather than restate.
    ///
    /// RE-AIMED 2026-08-28. The phone row read `Pane/SplitContainer.swift` until `3f11c6e6`
    /// demolished the `SwiftUI` phone and `bbb9845d` rebuilt the canvas as
    /// `Pane/SplitCanvasView.swift` (docs/62 stage E.0). The rename did not turn this rule red
    /// — the `continue` below skipped the absent path and all six verb bans went VACUOUS on the
    /// phone half, which is why the `Claim::Exists` pair now sits beside the loop.
    const RENDERERS: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
        "Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift",
    ];

    let mut claims = vec![
        Claim::Exists {
            path: DRAG_CTL,
            message: "the canvas drag's decisions have nowhere to be spelled once (docs/56 §3)",
        },
        // Comments stripped: the ordering is a fact about CODE, and both verbs are named in this
        // file's own header.
        Claim::Before {
            path: DRAG_CTL,
            first: r"recordPlacement\(",
            second: r"detachPaneToWindow\(",
            view: View::Code,
            message: "the tear-off detaches BEFORE recording the placement — the satellite opens at the \
                      cascade, and only sometimes (docs/56 §3)",
        },
    ];
    for renderer in RENDERERS {
        claims.push(Claim::Exists {
            path: renderer,
            message: "a canvas renderer named by the drag ban is gone — re-aim the row at the file that \
                      replaced it, because the ban below SKIPS an absent renderer instead of failing \
                      (docs/56 §3, docs/62 stage E.0)",
        });
    }
    for (verb, pattern) in VERBS {
        for renderer in RENDERERS {
            // A renderer that does not exist yet is skipped, so a row can be written ahead of the
            // drawing it names — 56c's sentence, which went unapplied to its own siblings twice.
            if !tree.has(renderer) {
                continue;
            }
            claims.push(Claim::Lacks {
                path: renderer,
                pattern,
                view: View::Code,
                message: match *verb {
                    "detachPaneToWindow" => {
                        "a canvas renderer calls detachPaneToWindow() itself — the canvas drag is \
                         PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                    "recordPlacement" => {
                        "a canvas renderer calls recordPlacement() itself — the canvas drag is \
                         PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                    "resolveTreeExternalDestination" => {
                        "a canvas renderer calls resolveTreeExternalDestination() itself — the canvas drag \
                         is PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                    "resolveSpringLoadedTreeDestination" => {
                        "a canvas renderer calls resolveSpringLoadedTreeDestination() itself — the canvas \
                         drag is PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                    "updateSolvedLayout" => {
                        "a canvas renderer calls updateSolvedLayout() itself — the canvas drag is \
                         PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                    _ => {
                        "a canvas renderer calls updateContainerBounds() itself — the canvas drag is \
                         PaneCanvasDragController's one decision (docs/56 §3)"
                    },
                },
            });
        }
    }
    check_all(tree, &claims)
}

/// A palette row declares its platform, exactly once
///
/// The three window verbs the phone cannot run — the satellite pair and the window level — used to
/// be listed there anyway: one hook no phone root binds, and one run arm that is a macOS-only `#if`
/// with nothing in the else. Both are invisible from the row, and both answer a keystroke by doing
/// nothing.
///
/// `slopdesk_workspace::palette_rows` is where that fact lives now, and it can only close the hole
/// if it names the SAME verbs the catalog serves. An id on one side only is the failure: a Swift
/// row the table never heard of is listed unconditionally (the far side fails OPEN on purpose, so a
/// typo cannot delete a verb in silence), and a Rust row no catalog serves is a rule about nothing.
///
/// And the gate does not come back. A row whose platform is DATA has no business branching on one:
/// `detachPane`'s run arm carried the `#if` this table replaced, and re-adding one anywhere in the
/// catalog would make a row half-listed again.
#[must_use]
pub fn a_palette_verb_names_its_platform_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::SameSet {
            label: "palette verb ids",
            swift: Extract::raw(SWIFT_PALETTE, r#"id: "(action\.[A-Za-z]+)""#),
            rust: Extract::raw(
                "rust/slopdesk-workspace/src/palette_rows.rs",
                r#"row\("(action\.[A-Za-z]+)""#,
            ),
        },
        Claim::Lacks {
            path: SWIFT_PALETTE,
            pattern: r"^[[:space:]]*#if os\(",
            view: View::Raw,
            message: "a platform gate is back in the palette catalog — a row's platform is DATA \
                      (palette_rows.rs)",
        },
    ])
}

/// …and every keybinding is reachable from it, without a keyboard
///
/// The palette listed 33 verbs; the registry declares 77. On a Mac the gap is invisible — the menu
/// bar reaches every binding — so it survived. A phone has no menu bar, so with no hardware
/// keyboard attached the palette IS the command surface and ~45 verbs could not be said at all.
///
/// The fix is a DERIVATION, not a second catalog, and that is what this pins. `registryRows` reads
/// `WorkspaceBindingRegistry.bindings` (already platform-filtered, so no gate of its own), and
/// `coveredActions` is read off the catalog's own rows — so the join between the two id spaces
/// cannot rot, because there is no join anyone maintains. Written out as a literal set, it would go
/// stale the first time a row changed hands and nothing would say so.
///
/// The REACH itself — every binding runs from some row — is `PaletteReachesEveryBindingTests`,
/// which can ask the types. This checks the SHAPE that keeps that test cheap to satisfy honestly.
///
/// A row that names a registry verb must RUN that verb, not a second spelling of it. Twenty-four
/// rows used to carry a `.store` closure restating their `route` arm line for line, and one had
/// already drifted into a different split call. `PaletteAction` is where that was possible; the six
/// bans keep it shut.
#[must_use]
pub fn every_keybinding_is_reachable_from_the_palette(tree: &Tree) -> Report {
    /// The verbs that must stay `.binding` rows rather than growing a `PaletteAction` twin.
    const REVIVED: &[(&str, &str)] = &[
        ("toggleSidebar", "case toggleSidebar"),
        ("toggleCodeSidebar", "case toggleCodeSidebar"),
        ("focusCodePanel", "case focusCodePanel"),
        ("togglePinWindow", "case togglePinWindow"),
        ("closeWindow", "case closeWindow"),
        ("openCheatSheet", "case openCheatSheet"),
    ];

    let mut claims = vec![
        Claim::Matches {
            path: SWIFT_PALETTE,
            pattern: r"static let registryRows: \[PaletteItem\] = WorkspaceBindingRegistry\.bindings",
            view: View::Code,
            message: "the palette no longer DERIVES its registry rows — a transcribed list goes stale in \
                      silence (docs/56 §3.6)",
        },
        Claim::Matches {
            path: SWIFT_PALETTE,
            pattern: r"static let coveredActions: Set<WorkspaceAction> = Set\(declared\.compactMap",
            view: View::Code,
            message: "the palette no longer reads its covered actions off its own rows — the join between \
                      the two id spaces has become one somebody maintains (docs/56 §3.6)",
        },
    ];
    for (verb, pattern) in REVIVED {
        claims.push(Claim::Lacks {
            path: "Sources/SlopDeskClientCore/Palette/PaletteModel.swift",
            pattern,
            view: View::Code,
            message: match *verb {
                "toggleSidebar" => {
                    "toggleSidebar is a PaletteAction again — the row IS the verb (`.binding`)"
                },
                "toggleCodeSidebar" => {
                    "toggleCodeSidebar is a PaletteAction again — the row IS the verb (`.binding`)"
                },
                "focusCodePanel" => {
                    "focusCodePanel is a PaletteAction again — the row IS the verb (`.binding`)"
                },
                "togglePinWindow" => {
                    "togglePinWindow is a PaletteAction again — the row IS the verb (`.binding`)"
                },
                "closeWindow" => "closeWindow is a PaletteAction again — the row IS the verb (`.binding`)",
                _ => "openCheatSheet is a PaletteAction again — the row IS the verb (`.binding`)",
            },
        });
    }
    check_all(tree, &claims)
}

/// …and the KEYBINDING TABLE is Rust's, with no Swift half to drift from
///
/// This rule used to be a `SameSet` holding a Swift array literal equal to a Rust one over the same
/// 77 ids. That is a join maintained by hand across a language boundary — the cross-language mirror
/// `CLAUDE.md` forbids by name — and the claim that held it was the tell rather than the safeguard.
/// docs/64 moved the whole row (title, category, chord, symbol, keywords, platform) into
/// `slopdesk_workspace::bindings`, so the join has nothing left to join and becomes a FLOOR: the
/// registry declares no row at all.
///
/// The nine generated `pane.select.N` slots are the one exception, and they are exempt by SHAPE
/// rather than by name: they are minted by a `(1...9).map` whose id is INTERPOLATED, so a pattern
/// matching a literal `<noun>.<verb>` cannot see them. A loop over a formula has no Rust twin to
/// drift from, which is why it stayed.
///
/// The platform column is still what the table is FOR, and the gate does not come back — in the
/// table or in its routing. `.detachPane`'s routing arm carried the `#if` this column replaced;
/// re-adding one would make a chord half-bound again.
#[must_use]
pub fn a_keybinding_names_its_platform_once(tree: &Tree) -> Report {
    /// Where a chord's action is routed to the store.
    const BINDING_ROUTING: &str =
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift";
    /// The near side of the one table.
    const BINDING_TABLE: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingTable.swift";

    check_all(tree, &[
        Claim::Lacks {
            path: SWIFT_BINDINGS,
            pattern: r#"id: "[a-z]+\.[A-Za-z0-9]+""#,
            view: View::Code,
            message: "the registry declares a binding row again — every row is DATA in \
                      `slopdesk_workspace::bindings`, and a Swift literal beside it is the cross-language \
                      mirror docs/64 deleted",
        },
        Claim::Matches {
            path: SWIFT_BINDINGS,
            pattern: r"static let bindings: \[WorkspaceBinding\] = WorkspaceBindingTable\.current\.listed",
            view: View::Code,
            message: "the shipped table no longer comes from the one read — a registry that assembles its \
                      own rows is a second table however it is spelled",
        },
        Claim::Matches {
            path: BINDING_TABLE,
            pattern: r"slopdesk_ws_binding_rows\(mac, buffer\.baseAddress, buffer\.count\)",
            view: View::Code,
            message: "the table is not read through the whole-table door — a call per row per field is what \
                      the one crossing exists to replace",
        },
        Claim::Lacks {
            path: SWIFT_BINDINGS,
            pattern: r"^[[:space:]]*#if os\(",
            view: View::Raw,
            message: "a platform gate is back in the binding registry — a row's platform is DATA \
                      (slopdesk_workspace::bindings)",
        },
        Claim::Lacks {
            path: BINDING_ROUTING,
            pattern: r"^[[:space:]]*#if os\(",
            view: View::Raw,
            message: "a platform gate is back in the binding routing — a row's platform is DATA \
                      (slopdesk_workspace::bindings)",
        },
    ])
}

/// …and the ACTION vocabulary is one enum, typed in two languages at one site
///
/// `WorkspaceAction` stays Swift because the UI `switch`es over it to reach a store op, and
/// `slopdesk_workspace::bindings::Action` names the same vocabulary because a row has to say which
/// action it runs. That is the sanctioned "constant typed in both languages" (`pane_kind.rs` is the
/// precedent), and what makes it safe is that the join is a POSITION and there is exactly ONE site
/// that spells it: `WorkspaceActionTag.swift`.
///
/// The pin is the tag SET. A case added on one side only changes the numbers that side spells, so
/// the sets stop matching. The Rust file's other two enums (`Category`, `NamedKey`) number 0–3 and
/// 0–10, which are already inside the action range, so they widen nothing — and the Swift side's
/// `init?(tag:)` arm spells `case 0:` rather than `case .x: 0`, so only the forward direction is
/// extracted and the two directions cannot pin each other into agreement about a wrong number.
#[must_use]
pub fn the_action_vocabulary_is_typed_once(tree: &Tree) -> Report {
    /// The one site where a `WorkspaceAction` and its tag are the same thing.
    const ACTION_TAG: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionTag.swift";
    /// The Rust half of the vocabulary.
    const RUST_BINDINGS: &str = "rust/slopdesk-workspace/src/bindings.rs";

    check_all(tree, &[
        Claim::SameSet {
            label: "workspace action tags",
            swift: Extract::raw(ACTION_TAG, r"case \.[a-zA-Z]+: ([0-9]+)$"),
            rust: Extract::raw(RUST_BINDINGS, r"^    [A-Z][A-Za-z]* = ([0-9]+),$"),
        },
        Claim::Lacks {
            path: SWIFT_BINDINGS,
            pattern: r"case \.[a-zA-Z]+: [0-9]+$",
            view: View::Code,
            message: "a second tag mapping grew outside WorkspaceActionTag.swift — the single site is the \
                      whole reason a two-language enum is safe here",
        },
    ])
}

/// …and the chord table is a CONSTANT, held rather than rebuilt
///
/// The registry's table is 85 rows and its readers are the keyboard's. `resolvedChordTable` walked
/// it once per key event, and `binding(for:)` — which the walk called per row — read `allBindings`
/// again, so a computed `allBindings` meant 86 fresh 85-element arrays per keystroke, each
/// retaining four strings per element. Measured at 128µs of pure allocation per key event on an
/// M-series Mac, on the GLOBAL `.keyDown` monitor and on `TerminalKeyInterceptor`'s default
/// resolver — which is to say on every key typed into any pane.
///
/// THIS IS THE DRIFT CLASS `docs/55` §8 NAMES, one register down: nothing a test can see changes
/// when `let` goes back to `var`. Every assertion still passes, every chord still resolves, and the
/// only symptom is input latency nobody attributes to a keyword. So the four shapes that make it a
/// constant are pinned by spelling.
///
/// BREAK-TESTED against the real tree, 2026-08-22: reverting `allBindings` to a computed property
/// fails the first; restoring `allBindings.first { $0.action == action }` in `binding(for:)` fails
/// the second; deleting the `liveChordTable` memo fails the last two.
#[must_use]
pub fn the_chord_table_is_held_not_rebuilt(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: SWIFT_BINDINGS,
            pattern: r"static let allBindings: \[WorkspaceBinding\] = bindings \+ selectPaneBindings",
            view: View::Code,
            message: "allBindings is not a stored `let` — a computed one re-concatenates 85 rows per READ, \
                      and the chord table reads it 86 times per key event",
        },
        Claim::Lacks {
            path: SWIFT_BINDINGS,
            pattern: r"allBindings\.first \{ \$0\.action ==",
            view: View::Code,
            message: "the registry scans the whole table for one action again — that is the O(n) half of \
                      the O(n²) per key event; byAction is the index",
        },
        Claim::Matches {
            path: BINDING_OVERRIDES,
            pattern: r"if let liveChordTable \{ return liveChordTable \}",
            view: View::Code,
            message: "resolvedChordTable no longer reads its memo — it is a pure function of a `let` and a \
                      write-once var, rebuilt on every keystroke the app sees",
        },
        Claim::Matches {
            path: BINDING_OVERRIDES,
            pattern: r"didSet \{ liveChordTable = nil \}",
            view: View::Code,
            message: "activeOverrides no longer invalidates the memo on write — a rebind would not take \
                      effect until relaunch",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The controller in its ordered form, and two renderers that only call it.
    fn drag(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskClientCore/Pane/PaneCanvasDragController.swift",
                "func commitDestination() {\n    paneDrag.recordPlacement(frame)\n    \
                 store.detachPaneToWindow(source)\n}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
                "dragController.commit(destination)\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift",
                "dragController.commit(destination)\n",
            );
    }

    #[test]
    fn the_tear_off_records_before_it_detaches() {
        let fixture = Fixture::new("surface-drag");
        drag(&fixture);
        assert!(super::the_canvas_drag_decides_once(&fixture.tree()).is_clean());

        // Reversed: the window opens at the cascade, and only when the reader wins the race.
        fixture.write(
            "Sources/SlopDeskClientCore/Pane/PaneCanvasDragController.swift",
            "func commitDestination() {\n    store.detachPaneToWindow(source)\n    \
             paneDrag.recordPlacement(frame)\n}\n",
        );
        assert!(!super::the_canvas_drag_decides_once(&fixture.tree()).is_clean());

        // And a renderer that re-derives the fork by hand.
        drag(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift",
            "store.detachPaneToWindow(source)\n",
        );
        assert!(!super::the_canvas_drag_decides_once(&fixture.tree()).is_clean());
    }

    /// A renamed renderer must FAIL, not disarm its own bans.
    ///
    /// This is the break-test for `3f11c6e6`'s actual damage: the phone canvas moved to a new file
    /// name, the ban loop's `continue` skipped it, and six verb bans went vacuous in silence.
    /// Seeding the rename — write the Mac renderer, leave the phone one absent — must be RED.
    #[test]
    fn a_renamed_renderer_is_red_rather_than_skipped() {
        let fixture = Fixture::new("surface-drag-rename");
        drag(&fixture);
        assert!(super::the_canvas_drag_decides_once(&fixture.tree()).is_clean());

        // The rename, as it actually landed: the old path is gone and no row was re-aimed.
        fixture.remove("Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift");
        let report = super::the_canvas_drag_decides_once(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("SKIPS an absent renderer"))
        );
    }

    #[test]
    fn a_half_listed_verb_is_red_in_either_id_space() {
        let fixture = Fixture::new("surface-palette");
        fixture
            .write(
                super::SWIFT_PALETTE,
                "PaletteItem(id: \"action.detachPane\")\nPaletteItem(id: \"action.splitRight\")\nstatic let \
                 registryRows: [PaletteItem] = WorkspaceBindingRegistry.bindings\nstatic let \
                 coveredActions: Set<WorkspaceAction> = Set(declared.compactMap { item in\n",
            )
            .write(
                "rust/slopdesk-workspace/src/palette_rows.rs",
                "row(\"action.detachPane\", Platform::Mac),\nrow(\"action.splitRight\", Platform::Both),\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Palette/PaletteModel.swift",
                "enum PaletteAction {\n    case binding(WorkspaceAction)\n}\n",
            );
        assert!(super::a_palette_verb_names_its_platform_once(&fixture.tree()).is_clean());
        assert!(super::every_keybinding_is_reachable_from_the_palette(&fixture.tree()).is_clean());

        // A verb the platform table never heard of would be listed unconditionally.
        fixture.write(
            super::SWIFT_PALETTE,
            "PaletteItem(id: \"action.detachPane\")\nPaletteItem(id: \
             \"action.splitRight\")\nPaletteItem(id: \"action.pinWindow\")\nstatic let registryRows: \
             [PaletteItem] = WorkspaceBindingRegistry.bindings\nstatic let coveredActions: \
             Set<WorkspaceAction> = Set(declared.compactMap { item in\n",
        );
        assert!(!super::a_palette_verb_names_its_platform_once(&fixture.tree()).is_clean());

        // And a gate back in the catalog, which makes a row half-listed again.
        fixture.write(
            super::SWIFT_PALETTE,
            "PaletteItem(id: \"action.detachPane\")\nPaletteItem(id: \"action.splitRight\")\n#if \
             os(macOS)\n#endif\nstatic let registryRows: [PaletteItem] = \
             WorkspaceBindingRegistry.bindings\nstatic let coveredActions: Set<WorkspaceAction> = \
             Set(declared.compactMap { item in\n",
        );
        assert!(!super::a_palette_verb_names_its_platform_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_row_that_restates_its_route_is_red() {
        let fixture = Fixture::new("surface-revived");
        fixture
            .write(
                super::SWIFT_PALETTE,
                "static let registryRows: [PaletteItem] = WorkspaceBindingRegistry.bindings\nstatic let \
                 coveredActions: Set<WorkspaceAction> = Set(declared.compactMap { item in\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Palette/PaletteModel.swift",
                "enum PaletteAction {\n    case toggleSidebar\n}\n",
            );
        assert!(!super::every_keybinding_is_reachable_from_the_palette(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_chord_table_stays_a_constant() {
        let fixture = Fixture::new("surface-chords");
        fixture
            .write(
                super::SWIFT_BINDINGS,
                "public static let allBindings: [WorkspaceBinding] = bindings + selectPaneBindings\n",
            )
            .write(
                super::BINDING_OVERRIDES,
                "didSet { liveChordTable = nil }\nif let liveChordTable { return liveChordTable }\n",
            );
        assert!(super::the_chord_table_is_held_not_rebuilt(&fixture.tree()).is_clean());

        // A computed `allBindings`: 86 fresh 85-element arrays per keystroke, and no test can see it.
        fixture.write(
            super::SWIFT_BINDINGS,
            "public static var allBindings: [WorkspaceBinding] { bindings + selectPaneBindings }\n",
        );
        assert!(!super::the_chord_table_is_held_not_rebuilt(&fixture.tree()).is_clean());

        // And the memo dropped, which costs a rebuild per key event.
        fixture
            .write(
                super::SWIFT_BINDINGS,
                "public static let allBindings: [WorkspaceBinding] = bindings + selectPaneBindings\n",
            )
            .write(super::BINDING_OVERRIDES, "return chordTable(from: bindings)\n");
        assert!(!super::the_chord_table_is_held_not_rebuilt(&fixture.tree()).is_clean());
    }

    /// The registry read from the one table, and nowhere else.
    fn one_table(fixture: &Fixture) {
        fixture
            .write(
                super::SWIFT_BINDINGS,
                "public static let bindings: [WorkspaceBinding] = \
                 WorkspaceBindingTable.current.listed\nWorkspaceBinding(id: \"pane.select.\\(n)\", action: \
                 .selectPane(n))\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingTable.swift",
                "slopdesk_ws_binding_rows(mac, buffer.baseAddress, buffer.count)\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift",
                "case .splitRight: store.splitActivePane(.right)\n",
            );
    }

    #[test]
    fn a_swift_row_literal_puts_the_mirror_back() {
        let fixture = Fixture::new("surface-binding-table");
        one_table(&fixture);
        assert!(super::a_keybinding_names_its_platform_once(&fixture.tree()).is_clean());

        // One row typed back into the registry is the whole defect: a second table, however short.
        fixture.write(
            super::SWIFT_BINDINGS,
            "public static let bindings: [WorkspaceBinding] = \
             WorkspaceBindingTable.current.listed\nWorkspaceBinding(id: \"pane.splitRight\", action: \
             .splitRight)\n",
        );
        assert!(!super::a_keybinding_names_its_platform_once(&fixture.tree()).is_clean());

        // And the interpolated nine stay legal — a loop has no twin to drift from.
        one_table(&fixture);
        assert!(super::a_keybinding_names_its_platform_once(&fixture.tree()).is_clean());

        // A registry that assembles its own rows is a second table under another name.
        fixture.write(
            super::SWIFT_BINDINGS,
            "public static let bindings: [WorkspaceBinding] = declared.filter { $0.shown }\n",
        );
        assert!(!super::a_keybinding_names_its_platform_once(&fixture.tree()).is_clean());

        // The gate does not come back in the routing either.
        one_table(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift",
            "#if os(macOS)\ncase .detachPane: store.detachPaneToWindow()\n#endif\n",
        );
        assert!(!super::a_keybinding_names_its_platform_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_action_added_on_one_side_only_is_red() {
        const ACTION_TAG: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionTag.swift";
        const RUST_BINDINGS: &str = "rust/slopdesk-workspace/src/bindings.rs";

        let fixture = Fixture::new("surface-action-tags");
        fixture
            .write(
                ACTION_TAG,
                "        case .splitRight: 0\n        case .splitDown: 1\n        case 0: self = \
                 .splitRight\n",
            )
            .write(RUST_BINDINGS, "    SplitRight = 0,\n    SplitDown = 1,\n")
            .write(
                super::SWIFT_BINDINGS,
                "public static let bindings: [WorkspaceBinding] = []\n",
            );
        assert!(super::the_action_vocabulary_is_typed_once(&fixture.tree()).is_clean());

        // A verb the crate grew and the enum has not: the tag sets stop matching.
        fixture.write(
            RUST_BINDINGS,
            "    SplitRight = 0,\n    SplitDown = 1,\n    SplitSideways = 2,\n",
        );
        assert!(!super::the_action_vocabulary_is_typed_once(&fixture.tree()).is_clean());

        // A second mapping site is the drift the single site exists to prevent.
        fixture
            .write(RUST_BINDINGS, "    SplitRight = 0,\n    SplitDown = 1,\n")
            .write(
                super::SWIFT_BINDINGS,
                "public static let bindings: [WorkspaceBinding] = []\n        case .splitRight: 0\n",
            );
        assert!(!super::the_action_vocabulary_is_typed_once(&fixture.tree()).is_clean());
    }
}
