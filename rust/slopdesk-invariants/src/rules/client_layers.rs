//! The layer boundary the two renderers share — `SlopDeskClientCore` draws nothing, and spells no
//! ink.
//!
//! Ported from the deleted `check-supervisor.sh`. This is the rule the macOS/iOS split rests on:
//! the presentation logic is read by an `AppKit` renderer and a `UIKit` one, so a decision that
//! arrives as anything a view owns — a modifier, a subclass, a layer — is a decision the other half
//! has to re-spell.
//!
//! ⚠️ THAT SENTENCE SAID "and a `SwiftUI` one" UNTIL 2026-08-28, and it was the rule's stated
//! reason rather than a passing detail. The premise died when the phone crossed to UIKit; the rule
//! did not, and is stronger for it. See [`presentation_logic_draws_nothing_both`].

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// `SlopDeskClientCore` IS THE PRESENTATION LOGIC, AND IT DRAWS NOTHING.
///
/// The whole point of the layer is that both renderers can read it: `SlopDeskMacUI` builds `AppKit`
/// out of it and `SlopDeskPhoneUI` builds `UIKit` out of it, so a decision spelled here is spelled
/// once for both. What ends that is any view VOCABULARY reaching this layer — the moment a `Color`,
/// an `NSColor` or an opacity is expressible here, the next decision lands as ink instead of a
/// value and the half that did not spell it has to re-derive it. That is the exact shape of every
/// pair docs/55 §8 lists. This rule was TRUE of the tree for the whole split and was never written
/// down; three separate ports were told it was a ratchet when it was only a habit.
///
/// ## ⚠️ THE PREMISE DIED AND THE `SwiftUI` HALF OF THE RULE MOVED, 2026-08-28
///
/// This was written as "an `AppKit` renderer and a `SwiftUI` one", and its first claim banned
/// `import SwiftUI` from this one target — a per-target ban, because at the time the framework was
/// still live on the phone and this layer was the boundary it must not cross. Both halves of that
/// premise are gone: the phone is UIKit, and `SwiftUI` measures ZERO across `Sources`, `Apps` and
/// `Tests` alike. So the ban was not narrowed or re-aimed, it was WIDENED out of this file into
/// [`ui_split::no_declarative_framework_survives`](super::ui_split::no_declarative_framework_survives),
/// which reads every Swift root. Keeping a copy here would leave a ban that can never be the one to
/// fire.
///
/// The layer law is unaffected and, if anything, harder now: a boundary between two IMPERATIVE
/// renderers cannot even express the "arrives as a modifier" failure, so what the ink ban below
/// protects is the LAYER rather than an asymmetry between two frameworks. It goes on being green —
/// the count is 0 today, and the gate is what makes it stay 0.
#[must_use]
pub fn presentation_logic_draws_nothing_both(tree: &Tree) -> Report {
    let claims = [Claim::NoneUnder {
        roots: &["Sources/SlopDeskClientCore"],
        extensions: &["swift"],
        pattern: r"Color\(|\.opacity\(|NSColor\(|UIColor\(",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "SlopDeskClientCore spelled ink — the design floor is SlopDeskSlate, which sits ABOVE it \
                  (DESIGN.md)",
    }];
    check_all(tree, &claims)
}

/// A DOMAIN target names a view framework only at a seam somebody argued for.
///
/// The rule above bans view frameworks from `SlopDeskClientCore` outright. Below it the bar is
/// deliberately weaker: a domain target may hold the SEAM a renderer mounts, because the
/// alternative is a protocol whose only implementation lives one target up and a second copy of the
/// domain types it reads. What it may not hold is a TENTH such file arriving unnoticed — every
/// entry in [`DOMAIN_VIEW_FRAMEWORK_SEAMS`] was argued for in its own file's header, and an
/// unlisted import is a file that skipped the argument.
///
/// A separate rule rather than a third claim on the one above, because the two have different
/// SUBJECTS: that one is about a layer that draws nothing, this one is about a layer that draws
/// only where it said it would. Folding them would also make every fixture in this file seed a
/// hundred filler paths to clear this rule's vacuity floors, which is how a test stops testing what
/// it names.
#[must_use]
pub fn domain_layers_hold_only_named_view_seams(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: DOMAIN_LAYERS,
            extensions: &["swift"],
            pattern: r"^\s*import (SwiftUI|AppKit|UIKit)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: DOMAIN_VIEW_FRAMEWORK_SEAMS,
            message: "{files} — a DOMAIN target imported a view framework and is not one of the nine seams \
                      that already do. Either the file belongs up in SlopDeskMacUI / SlopDeskPhoneUI, or it \
                      is a tenth seam and belongs in DOMAIN_VIEW_FRAMEWORK_SEAMS with the reason written \
                      beside it (docs/56 §3, docs/00 'Core / shell split')",
        },
        // ⚠️ THE FLOOR IS PER-TARGET, for `ui_split`'s reason and not for tidiness. The ban above is
        // a ban with nothing required alongside it, so a root that globbed to zero files would
        // satisfy it perfectly — a gate that passes by reading nothing. ONE combined floor would not
        // catch that either: `SlopDeskWorkspaceCore` alone clears any number `SlopDeskDevicePanels`
        // could contribute, so the smaller half could drain silently. Both floors sit well under
        // today's counts (191 and 51), because what they exist to catch is a target that VANISHED,
        // not one that shrank — and this port's whole direction is to make them shrink.
        Claim::Populated {
            roots: &["Sources/SlopDeskWorkspaceCore"],
            extensions: &["swift"],
            minimum: 80,
            message: "SlopDeskWorkspaceCore holds only {found} Swift files — the view-framework ban over it \
                      is reading almost nothing, so check the target was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskDevicePanels"],
            extensions: &["swift"],
            minimum: 20,
            message: "SlopDeskDevicePanels holds only {found} Swift files — the view-framework ban over it \
                      is reading almost nothing, so check the target was not renamed or moved",
        },
    ];
    check_all(tree, &claims)
}

/// A VIEW target reaches a door through a readout, not through the header.
///
/// `docs/55` §6, "What the imperative UI changed at this boundary, and what it did not": the client
/// crossing to AppKit and UIKit changed nothing on the Rust side and exactly one thing on the Swift
/// side — how OFTEN a door is called. Rule 2 of the three that follow is this one. A door reached
/// from a view file is a door nobody can exercise without a window server, and it puts §4c's
/// marshalling next to a `layout()` pass where the call rate is a drawing decision rather than a
/// state change. The readouts in `SlopDeskClientCore` / `SlopDeskWorkspaceCore` are where a door is
/// called once, stored, and tested headless.
///
/// This is a LAYER law, not a framework one, which is why it is registered here rather than beside
/// the FFI-artifact rules: `SwiftUI` had the same rule and enforced it by accident, because a body
/// that called a door re-ran per invalidation and the pain arrived as jank. An imperative view
/// holds its answer in a stored property, so the same mistake is now SILENT — the call rate is fine
/// and the layer is wrong.
///
/// ## The one exception, and the shape of a legitimate future one
///
/// A door whose ARGUMENT is a platform type the readout layer cannot name. Today that is one file
/// and two doors: `MacMetalLayerBackedView` takes an `NSEvent.Phase`, so the call can only live
/// where `AppKit` is visible. Both are scalar-in/scalar-out with no memory crossing (§4's "entry
/// that takes no memory at all"), and they exist so a wire-stable CoreGraphics encoding is not
/// spelled twice in two languages. A second entry has to clear the same two bars: the argument is
/// unnameable below, and nothing crosses but scalars.
///
/// ## ⚠️ THE ALLOWLIST IS KEYED ON A PATH, SO THE PATH IS CLAIMED
///
/// An `exempt` entry naming a file that has been renamed does not fail — it silently stops
/// exempting anything, and if the rename also moved the call out of the roots the ban goes quiet
/// with nothing left to catch. That is the shape `command_surface`'s renderer loop was found in:
/// `SplitContainer.swift` → `SplitCanvasView.swift` disarmed six verb bans and stayed green. So the
/// exemption is paired with an `Exists` and a `Mentions` on the same path — a rename is red HERE,
/// naming the file, instead of widening the ban to nothing.
///
/// The view is comment-stripped for the usual reason and a measured one: six of the eight files a
/// naive grep matches are PROSE naming a door — a header explaining that the drop-zone fractions
/// live in Rust — and a raw read would fire on all six and be disabled by whoever hit it first.
#[must_use]
pub fn view_targets_reach_doors_through_readouts(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: VIEW_TARGETS,
            extensions: &["swift"],
            pattern: r"^\s*import CSlopDeskFFI|\bslopdesk_[a-z0-9_]+",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: PLATFORM_ARGUMENT_DOORS,
            message: "{files} — a view file reached the FFI header directly. Doors are called from a \
                      SlopDeskClientCore / SlopDeskWorkspaceCore readout, which is what keeps the view \
                      layer thin and testable without a window server. The one exception is a door whose \
                      ARGUMENT is a platform type the readout layer cannot name, and it is listed in \
                      PLATFORM_ARGUMENT_DOORS with the reason beside it (docs/55 §6 'What the imperative UI \
                      changed at this boundary')",
        },
        // ⚠️ THE EXEMPTION'S OWN TRIPWIRE. Rename the file and the entry below exempts nothing —
        // which is not a failure, it is a WIDENING. These two claims make the rename red instead.
        Claim::Exists {
            path: PLATFORM_ARGUMENT_DOORS[0],
            message: "the one view file allowed to call a door is gone — re-aim PLATFORM_ARGUMENT_DOORS at \
                      the file that replaced it, because a stale allowlist entry stops exempting and stops \
                      being noticed (docs/55 §6)",
        },
        Claim::Mentions {
            path: PLATFORM_ARGUMENT_DOORS[0],
            names: &["slopdesk_cg_scroll_phase_code", "slopdesk_cg_momentum_phase_code"],
            message: "MacMetalLayerBackedView stopped calling {entry} — if the scroll-phase encoding moved \
                      below the view, DELETE its allowlist entry rather than leaving an exemption that now \
                      covers a file with no reason to be exempt (docs/55 §6)",
        },
        // The floors are per-target for `domain_layers_hold_only_named_view_seams`'s reason: this is
        // a ban with nothing required beside it, so a root that globbed to nothing satisfies it
        // perfectly. `3f11c6e6` drained `SlopDeskPhoneUI` to zero and no ban over it went red. The
        // numbers sit well under today's 87 / 32 / 4 / 1 — a tripwire against a target that VANISHED,
        // never a ratchet on a rebuild that is meant to shrink. `SlopDeskVideoClientPhone` holds ONE
        // file, so 1 is the only honest floor it can carry, and that is still the whole job here.
        Claim::Populated {
            roots: &["Sources/SlopDeskMacUI"],
            extensions: &["swift"],
            minimum: 30,
            message: "SlopDeskMacUI holds only {found} Swift files — the door ban over it is reading almost \
                      nothing, so check the target was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: &["swift"],
            minimum: 8,
            message: "SlopDeskPhoneUI holds only {found} Swift files — the door ban over it is reading \
                      almost nothing, so check the target was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskVideoClientMac"],
            extensions: &["swift"],
            minimum: 2,
            message: "SlopDeskVideoClientMac holds only {found} Swift files — the door ban over it is \
                      reading almost nothing, so check the target was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskVideoClientPhone"],
            extensions: &["swift"],
            minimum: 1,
            message: "SlopDeskVideoClientPhone holds only {found} Swift files — the door ban over it is \
                      reading nothing at all, so check the target was not renamed or moved",
        },
    ];
    check_all(tree, &claims)
}

/// The four targets ABOVE the presentation layer — the renderers, which call no door.
const VIEW_TARGETS: &[&str] = &[
    "Sources/SlopDeskMacUI",
    "Sources/SlopDeskPhoneUI",
    "Sources/SlopDeskVideoClientMac",
    "Sources/SlopDeskVideoClientPhone",
];

/// The ONE view file that may call a door, because the argument is a type the layer below cannot
/// name.
///
/// `slopdesk_cg_scroll_phase_code` and `slopdesk_cg_momentum_phase_code` take an `NSEvent.Phase`.
/// Both are scalar-in/scalar-out with no memory crossing, and both exist so the wire-stable
/// CoreGraphics phase encoding is spelled in Rust only (`docs/55` §6). The phone's
/// `MetalLayerBackedView` is deliberately NOT here: it carried a dead `import CSlopDeskFFI` with no
/// door behind it until `3391e574`, and an allowlist entry for a file that calls nothing is an
/// exemption waiting to be used for something else.
const PLATFORM_ARGUMENT_DOORS: &[&str] = &["Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift"];

/// The two targets BELOW the presentation layer — the domain, shared by both renderers.
///
/// `SlopDeskWorkspaceModel` is deliberately absent: it holds value types and imports no framework
/// at all today, so a ban over it would have nothing to exempt and would be a rule nobody could
/// read a reason out of. It is covered by `package_graph`'s layering instead.
const DOMAIN_LAYERS: &[&str] = &["Sources/SlopDeskWorkspaceCore", "Sources/SlopDeskDevicePanels"];

/// The NINE files in the domain layers that may name a view framework, and why each may.
///
/// `SlopDeskClientCore` above them draws nothing at all, which is the rule directly above this one.
/// Below it the bar is different and weaker on purpose: a domain target may hold the SEAM a
/// renderer mounts, because the alternative is a protocol whose only implementation lives one
/// target up and a second copy of the domain types it reads. What it may not hold is a tenth of
/// them arriving unnoticed — every entry here was argued for in the file's own header, and an
/// unlisted import is a file that skipped the argument.
///
/// Three kinds, and the kind decides whether a future entry is legitimate:
/// * **A frame surface** — `SimulatorScreenSurface`, `AndroidScreenNSView`. An `NSView` whose whole
///   body reads domain types (layout, gesture, video format, key map), so it sits with them and the
///   `NSViewRepresentable` stays up in `SlopDeskMacUI`. Moving these UP would ADD an import edge,
///   not remove one; their headers record that measurement.
/// * **A headless-build seam** — `TerminalRenderingView`, `VideoWindowSeam`. A protocol plus a thin
///   mount point that exists so the headless build never links libghostty or `VideoToolbox`.
/// * **A platform read** — `ClientPasteboard`, `DeviceKeyEvent`, `PhoneKey`,
///   `PaneFocusCoordinator`, `TerminalViewModel`. Reading a key, a pasteboard or the first
///   responder off the platform. These are the entries most likely to be wrong later: a READ is
///   floor, but a DECISION taken beside one belongs in Rust, and `TerminalViewModel` at ~1,230 code
///   lines is the one to look at first.
///
/// ⚠️ THE GATE IN EACH IS `canImport(...)`, NEVER `os(macOS)` — `ui_split` holds that separately,
/// and the reason is in `SimulatorScreenSurface`'s header: the question is whether there is an
/// `NSView` to subclass, which is a framework question rather than a product one.
const DOMAIN_VIEW_FRAMEWORK_SEAMS: &[&str] = &[
    "Sources/SlopDeskWorkspaceCore/Video/VideoWindowSeam.swift",
    "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift",
    "Sources/SlopDeskWorkspaceCore/Terminal/TerminalRenderingView.swift",
    "Sources/SlopDeskWorkspaceCore/Terminal/ClientPasteboard.swift",
    "Sources/SlopDeskWorkspaceCore/iOS/PaneFocusCoordinator.swift",
    "Sources/SlopDeskWorkspaceCore/iOS/PhoneKey.swift",
    "Sources/SlopDeskDevicePanels/Input/DeviceKeyEvent.swift",
    "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift",
    "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
];

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    const CORE: &str = "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift";

    /// A BAN with nothing required alongside it, so the only way to know it reads anything at all
    /// is to make it fire.
    ///
    /// The `import SwiftUI` case that used to sit in the middle of this test went with the claim it
    /// seeded — the ban is
    /// [`ui_split::no_declarative_framework_survives`](super::super::ui_split::no_declarative_framework_survives)'s
    /// now, and it is proved over there against every Swift root rather than this one target.
    #[test]
    fn an_ink_literal_in_the_shared_layer_is_caught() {
        let fixture = Fixture::new("client-core-draws-nothing");
        fixture.write(CORE, "import Foundation\nfunc rank() -> Int { 0 }\n");
        assert!(super::presentation_logic_draws_nothing_both(&fixture.tree()).is_clean());

        fixture.write(CORE, "import Foundation\nlet bed = NSColor(white: 0, alpha: 1)\n");
        let report = super::presentation_logic_draws_nothing_both(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("spelled ink")),
            "{report:?}"
        );
    }

    /// The domain ban has to be shown doing BOTH halves of its job, because they fail in opposite
    /// directions: a new file that imports a framework must be caught, and one of the nine that
    /// already do must NOT be — an exemption list nobody proves is honoured is a list that could be
    /// spelled wrong and would never say so.
    #[test]
    fn a_view_framework_below_the_split_is_caught_unless_it_is_a_named_seam() {
        let fixture = Fixture::new("domain-view-framework-seams");
        seed_domain_floors(&fixture);
        assert!(super::domain_layers_hold_only_named_view_seams(&fixture.tree()).is_clean());

        // A NAMED seam, spelled exactly as the list spells it, stays clean.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
            "#if canImport(AppKit)\nimport AppKit\n#endif\n",
        );
        assert!(
            super::domain_layers_hold_only_named_view_seams(&fixture.tree()).is_clean(),
            "the exemption list is not being honoured — check the paths in it",
        );

        // A TENTH one is the whole point of the rule.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceRail.swift",
            // UIKit rather than SwiftUI, which is not cosmetic: SwiftUI is banned from every Swift
            // root now, so seeding it here would prove this rule against a shape that can no longer
            // reach it.
            "import UIKit\nfinal class Rail: UIView {}\n",
        );
        let report = super::domain_layers_hold_only_named_view_seams(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("WorkspaceRail.swift")),
            "{report:?}"
        );
    }

    /// A drained target satisfies the ban perfectly, so the floor is the half of the rule that
    /// notices. Per-target, because one combined count would let the smaller half vanish under the
    /// larger one.
    #[test]
    fn a_domain_target_that_vanished_is_named_rather_than_passing() {
        let fixture = Fixture::new("domain-floor-vacuity");
        fixture.write("Sources/SlopDeskWorkspaceCore/Only.swift", "import Foundation\n");
        let report = super::domain_layers_hold_only_named_view_seams(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("SlopDeskWorkspaceCore holds only 1 Swift files")),
            "{report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("SlopDeskDevicePanels holds only 0 Swift files")),
            "the smaller half has to be counted on its own, or it can drain to nothing: {report:?}",
        );
    }

    /// Three directions, because the rule fails in three: a view file that calls a door must be
    /// caught, the allowlisted file must NOT be, and the allowlist entry itself must be red when
    /// the path under it moves — which is the failure that presents as green everywhere else.
    #[test]
    fn a_door_called_from_a_view_file_is_caught_unless_its_argument_is_a_platform_type() {
        let fixture = Fixture::new("view-targets-call-no-door");
        seed_view_floors(&fixture);
        fixture.write(
            super::PLATFORM_ARGUMENT_DOORS[0],
            "import CSlopDeskFFI\nfunc code() -> UInt32 { slopdesk_cg_scroll_phase_code(0) + \
             slopdesk_cg_momentum_phase_code(0) }\n",
        );
        assert!(
            super::view_targets_reach_doors_through_readouts(&fixture.tree()).is_clean(),
            "the exemption is not being honoured — check the path in PLATFORM_ARGUMENT_DOORS",
        );

        // A view file reaching the header is the ban's whole subject.
        fixture.write(
            "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift",
            "import CSlopDeskFFI\nlet rung = slopdesk_git_line_rung(handle)\n",
        );
        let report = super::view_targets_reach_doors_through_readouts(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("MacSidebarHeader.swift")),
            "{report:?}"
        );

        // PROSE naming a door is not a call, and six live headers do exactly this — a raw read would
        // fire on all of them and the rule would be turned off by the first person it stopped.
        fixture.write(
            "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift",
            "// The ladder is slopdesk_workspace::git_line's, asked for by rung.\nlet rung = 0\n",
        );
        assert!(super::view_targets_reach_doors_through_readouts(&fixture.tree()).is_clean());

        // And the rename: the allowlist stops exempting, so the ban would go quiet with nothing to
        // catch. It has to be red HERE, naming the path.
        fixture.remove(super::PLATFORM_ARGUMENT_DOORS[0]);
        let report = super::view_targets_reach_doors_through_readouts(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("the one view file allowed to call a door is gone")),
            "{report:?}"
        );
    }

    /// A drained view target satisfies the door ban perfectly. Per-target for the domain floors'
    /// reason: `SlopDeskMacUI` alone clears any number the two video shells could contribute.
    #[test]
    fn a_view_target_that_vanished_is_named_rather_than_passing() {
        let fixture = Fixture::new("view-target-floor-vacuity");
        fixture.write(super::PLATFORM_ARGUMENT_DOORS[0], "let code = 0\n");
        let report = super::view_targets_reach_doors_through_readouts(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("SlopDeskPhoneUI holds only 0 Swift files")),
            "{report:?}"
        );
    }

    /// Enough files under each view root to clear all four floors, plus the allowlisted file's own
    /// content, so a test about the BAN is never really reporting a floor.
    fn seed_view_floors(fixture: &Fixture) {
        for (root, count) in [
            ("Sources/SlopDeskMacUI", 30),
            ("Sources/SlopDeskPhoneUI", 8),
            ("Sources/SlopDeskVideoClientMac", 2),
            ("Sources/SlopDeskVideoClientPhone", 1),
        ] {
            for file in 0..count {
                fixture.write(&format!("{root}/Filler{file}.swift"), "import Foundation\n");
            }
        }
    }

    /// Enough plain, framework-free files under each domain root to clear both floors, so a test
    /// about the BAN is never really reporting the floor.
    fn seed_domain_floors(fixture: &Fixture) {
        for index in 0..super::DOMAIN_LAYERS.len() {
            let (root, count) = match index {
                0 => ("Sources/SlopDeskWorkspaceCore", 80),
                _ => ("Sources/SlopDeskDevicePanels", 20),
            };
            for file in 0..count {
                fixture.write(&format!("{root}/Filler{file}.swift"), "import Foundation\n");
            }
        }
    }
}
