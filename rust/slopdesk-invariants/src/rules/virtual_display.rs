//! What a `HiDPI` virtual display IS, and it is `slopdesk_video::virtual_display`'s.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const RUST_CORE: &str = "rust/slopdesk-video/src/virtual_display.rs";
const SWIFT_FACE: &str = "Sources/SlopDeskVideoHost/VirtualDisplay.swift";

/// THE VIRTUAL DISPLAY'S ARITHMETIC, and it is Rust's.
///
/// `VirtualDisplay.swift` splits where its own header says it splits: above the line is
/// synchronous `WindowServer` Mach IPC that only real hardware can exercise, below it is the
/// point↔pixel↔millimetre math that decides every field the descriptor is filled with. The lower
/// half is `slopdesk-video`'s now, and the Swift `VirtualDisplayGeometry` / `VirtualDisplayPlanner`
/// are marshallers over six doors.
///
/// The floors are part of it. `slopdesk_vd_geometry` hands back the FLOORED point grid and scale
/// beside the derived pixels precisely so the near side has no `max(1, …)` of its own — a floor
/// spelled in two languages is drift no rule about literals could see.
///
/// This one is worth a rule beyond the usual reason. Both Swift types carried a header comment
/// saying "Matches the core" — against a Rust core that DID NOT EXIST, which
/// `slopdesk-corevectors` had also been asserting for a `slopdesk_core::virtual_display_geometry`
/// nothing ever built. Four keys of `golden/golden_vectors.json` were pinned by that comment and
/// read by nothing, and one of them drifted for a year. A claim about where logic lives is worth
/// exactly as much as the check that enforces it, so the claim is a check now.
///
/// Every number below fails SILENTLY when it is respelled. An over-budget framebuffer makes
/// `applySettings:` answer YES and leave `displayID` at 0. A millimetre size off by a rounding step
/// moves the reported DPI across the `HiDPI` eligibility line and the display comes up soft. A
/// virtual display placed over a real one makes `WindowServer` reflow the user's actual monitor
/// arrangement. A refresh mode that is not advertised is never granted, and the capture beats
/// against the commit with nothing in any log.
#[must_use]
pub fn virtual_display(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: RUST_CORE,
            message: "the point↔pixel↔millimetre math behind a HiDPI virtual display — the pixel-limit \
                      refusal, the reported density, the placement past every real display and the \
                      advertised modes, decided once",
        },
        Claim::Doors {
            path: SWIFT_FACE,
            entries: &[
                "slopdesk_vd_geometry",
                "slopdesk_vd_size_in_millimeters",
                "slopdesk_vd_default_target_ppi",
                "slopdesk_vd_origin_to_right",
                "slopdesk_vd_chip_pixel_limit",
                "slopdesk_vd_refresh_rates",
            ],
            message: "VirtualDisplay.swift no longer calls {entry} — the descriptor's arithmetic is \
                      slopdesk_video::virtual_display's, and the CGVirtualDisplay half is the IPC shell",
        },
        // The numbers, respelled. `golden/golden_vectors.json` pins the millimetre conversion by
        // BIT PATTERN, so a second `25.4` beside the door that vends one is not a duplicate
        // constant — it is a second rounding order that the corpus can only catch on the side that
        // reads it, and the side that read it was missing for a year. `max(1,` is here for the same
        // reason one step earlier: the floors ride back on the crossing, so a near-side one is a
        // second answer to "what is a zero-width display", not a defensive check.
        Claim::Lacks {
            path: SWIFT_FACE,
            pattern: r"25\.4|6144|7680|targetPPI: Double = 163|maxAdvertisedHz|max\(1,",
            view: View::Code,
            message: "VirtualDisplay.swift spells the virtual display's arithmetic again — the chip \
                      budgets, the millimetres-per-inch conversion, the reported density, the \
                      advertised-mode ceiling and the dimension floors are slopdesk_video::virtual_display's",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The face as it stands: two value types whose every answer is a call across.
    const FACE: &str = "\
public struct VirtualDisplayGeometry {
    private let crossing: SlopDeskVirtualDisplayGeometry
    public init(pointWidth: Int, pointHeight: Int, scale: Int = 2, maxHorizontalPixels: Int = \
                        P.unknownChipPixelLimit) {
        crossing = slopdesk_vd_geometry(Int32(pointWidth), Int32(pointHeight), Int32(scale), limit)
    }
    public var pointWidth: Int { Int(crossing.point_width) }
    public var pixelWidth: Int { Int(crossing.pixel_width) }
    public var exceedsPixelLimit: Bool { crossing.exceeds_pixel_limit }
    public func sizeInMillimeters(targetPPI: Double = slopdesk_vd_default_target_ppi()) -> CGSize {
        let mm = slopdesk_vd_size_in_millimeters(w, h, s, l, targetPPI)
        return CGSize(width: mm.width, height: mm.height)
    }
}

public enum VirtualDisplayPlanner {
    public static func originToRight(of displays: [CGRect]) -> CGPoint {
        scalars.withUnsafeBufferPointer { slopdesk_vd_origin_to_right($0.baseAddress, count) }
    }
    public static func chipPixelLimit(cpuBrand: String) -> Int {
        Int(slopdesk_vd_chip_pixel_limit(bytes.baseAddress, bytes.count))
    }
    public static func refreshRates(fps: Int) -> [Double] {
        _ = slopdesk_vd_refresh_rates(Int32(fps), out.baseAddress, out.count)
    }
}
";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::RUST_CORE, "pub fn refresh_rates() {}\n")
            .write(super::SWIFT_FACE, FACE);
        assert!(super::virtual_display(&fixture.tree()).is_clean());
        fixture
    }

    fn says(fixture: &Fixture, fragment: &str) {
        let report = super::virtual_display(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains(fragment)),
            "{report:?}"
        );
    }

    /// The arithmetic, decided in Swift again — a rounding order, a chip budget and a dimension
    /// floor back as the literals a comment used to claim were "the core"'s.
    #[test]
    fn a_respelled_virtual_display_number_is_caught() {
        let fixture = seeded("virtual-display-literals");
        fixture.write(
            super::SWIFT_FACE,
            &FACE.replace("mm.width", "Double(pixelWidth) / ppi * 25.4"),
        );
        says(&fixture, "spells the virtual display's arithmetic again");

        fixture.write(
            super::SWIFT_FACE,
            &FACE.replace("P.unknownChipPixelLimit", "7680"),
        );
        says(&fixture, "spells the virtual display's arithmetic again");

        // The floor, back on the near side — the crossing already carries it.
        fixture.write(
            super::SWIFT_FACE,
            &FACE.replace("Int32(pointWidth)", "Int32(max(1, pointWidth))"),
        );
        says(&fixture, "spells the virtual display's arithmetic again");
    }

    /// The same drift one step earlier: a door dropped off the face, and the crate the whole rule
    /// folds through gone.
    #[test]
    fn a_dropped_door_or_a_deleted_core_is_caught() {
        let fixture = seeded("virtual-display-doors");
        fixture.write(
            super::SWIFT_FACE,
            &FACE.replace("slopdesk_vd_chip_pixel_limit(", "limitForBrand("),
        );
        says(&fixture, "slopdesk_vd_chip_pixel_limit");

        fixture.remove(super::RUST_CORE);
        says(&fixture, "decided once");
    }
}
