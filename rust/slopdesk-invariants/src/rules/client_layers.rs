//! The layer boundary the two renderers share — `SlopDeskClientCore` draws nothing, and spells no
//! ink.
//!
//! Ported from the deleted `check-supervisor.sh`. This is the rule the macOS/iOS split rests on:
//! the presentation logic is read by an `AppKit` renderer and a `SwiftUI` one, so a decision that
//! arrives as a modifier instead of a function is a decision the other half has to re-spell.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// `SlopDeskClientCore` IS THE PRESENTATION LOGIC, AND IT DRAWS NOTHING.
///
/// The whole point of the layer is that the two renderers can both read it: `SlopDeskMacUI` builds
/// `AppKit` out of it and `SlopDeskPhoneUI` builds `SwiftUI` out of it, so a decision spelled here
/// is spelled once for both. One `import SwiftUI` ends that — not because `SwiftUI` is unavailable
/// on the Mac, but because the moment a `View`, a `@ViewBuilder` or a `Color` is reachable from
/// this layer, the next decision lands as a modifier instead of a function and the `AppKit` half
/// has to re-spell it. That is the exact shape of every pair docs/55 §8 lists. This rule was TRUE
/// of the tree for the whole split and was never written down; three separate ports were told it
/// was a ratchet when it was only a habit. It goes in green — the count below is 0 today, and the
/// gate is what makes it stay 0.
#[must_use]
pub fn presentation_logic_draws_nothing_both(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskClientCore"],
            extensions: &["swift"],
            pattern: r"^\s*import SwiftUI",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "SlopDeskClientCore imported SwiftUI — it is the logic BOTH renderers read, so it \
                      draws nothing (docs/56 §3)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskClientCore"],
            extensions: &["swift"],
            pattern: r"Color\(|\.opacity\(|NSColor\(|UIColor\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "SlopDeskClientCore spelled ink — the design floor is SlopDeskSlate, which sits ABOVE \
                      it (DESIGN.md)",
        },
    ];
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

    /// Both arms are BANS with nothing required alongside them, so the only way to know either one
    /// reads anything at all is to make it fire.
    #[test]
    fn a_view_import_or_an_ink_literal_in_the_shared_layer_is_caught() {
        let fixture = Fixture::new("client-core-draws-nothing");
        fixture.write(CORE, "import Foundation\nfunc rank() -> Int { 0 }\n");
        assert!(super::presentation_logic_draws_nothing_both(&fixture.tree()).is_clean());

        fixture.append(CORE, "import SwiftUI\n");
        let report = super::presentation_logic_draws_nothing_both(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("imported SwiftUI")),
            "{report:?}"
        );

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
            "import SwiftUI\nstruct Rail: View { var body: some View { EmptyView() } }\n",
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
