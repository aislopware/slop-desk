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
}
