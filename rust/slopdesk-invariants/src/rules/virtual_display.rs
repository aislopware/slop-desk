//! What a `HiDPI` virtual display IS, and it is `slopdesk_video::virtual_display`'s.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const RUST_CORE: &str = "rust/slopdesk-video/src/virtual_display.rs";

/// The daemon that IS the GUI host — `docs/61`.
///
/// A directory rather than a file: `vdisplay` holds the descriptor and its teardown order today,
/// and which module holds which half of a session is still moving. The ban is scoped to the daemon
/// and NOT to [`RUST_CORE`], which is where every one of these numbers is supposed to be spelled.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// THE VIRTUAL DISPLAY'S ARITHMETIC, and it is `slopdesk-video`'s.
///
/// `VirtualDisplay.swift` split where its own header said it split: above the line was synchronous
/// `WindowServer` Mach IPC that only real hardware can exercise, below it was the
/// point↔pixel↔millimetre math that decides every field the descriptor is filled with. `docs/61`
/// deleted that file and the six `slopdesk_vd_*` doors it called; the lower half is
/// `slopdesk-video`'s, and the IPC half is `rust/slopdesk-videohostd`'s `vdisplay`, which reaches
/// `CGVirtualDisplay` through `slopdesk-apple-cgvirtualdisplay` and asks the crate for every
/// number it fills in. That is the same split, one language later — so the rule is re-aimed at the
/// daemon rather than dropped, and the Swift half of it is stated tree-wide in
/// [`crate::rules::deleted_video_swift`].
///
/// The floors are part of it. `Geometry::new` hands back the FLOORED point grid and scale beside
/// the derived pixels precisely so the caller has no floor of its own — a floor spelled twice is
/// drift no rule about literals could see. The daemon's `.max(1)` on a SCALE it read from a real
/// display is not that: it is clamping a framework answer before handing it over, which is the one
/// thing the caller is for. What the ban names is the crate's own constants coming back.
///
/// This one is worth a rule beyond the usual reason. Both deleted Swift types carried a header
/// comment saying "Matches the core" — against a Rust core that DID NOT EXIST, which
/// The Swift minter had also been asserting for a `slopdesk_core::virtual_display_geometry`
/// nothing ever built. Four keys of `golden/golden_vectors.json` were pinned by that comment and
/// read by nothing, and one of them drifted for a year. A claim about where logic lives is worth
/// exactly as much as the check that enforces it, so the claim is a check now.
///
/// Every number below fails SILENTLY when it is respelled. An over-budget framebuffer makes the
/// descriptor apply and leave `displayID` at 0. A millimetre size off by a rounding step moves the
/// reported DPI across the `HiDPI` eligibility line and the display comes up soft. A virtual
/// display placed over a real one makes `WindowServer` reflow the user's actual monitor
/// arrangement. A refresh mode that is not advertised is never granted, and the capture beats
/// against the commit with nothing in any log.
///
/// The ban reads [`View::CodeBeforeTests`] because `vdisplay`'s own tests assert against the pixel
/// budgets by their values — proving the daemon asks the crate is exactly what those tests are for,
/// and a ban that fired on them would be a ban on the proof.
#[must_use]
pub fn virtual_display(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: RUST_CORE,
            message: "the point↔pixel↔millimetre math behind a HiDPI virtual display — the pixel-limit \
                      refusal, the reported density, the placement past every real display and the \
                      advertised modes, decided once",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["virtual_display"],
            message: "the daemon stopped asking {entry} — the point grid, the backing pixels, the \
                      millimetre size, the chip budget and the advertised modes are rust/slopdesk-video's, \
                      and a descriptor filled from a second answer applies cleanly and leaves displayID at \
                      0 (docs/61 §3)",
        },
        // The numbers, respelled. `golden/golden_vectors.json` pins the millimetre conversion by
        // BIT PATTERN, so a second `25.4` beside the call that vends one is not a duplicate
        // constant — it is a second rounding order that the corpus can only catch on the side that
        // reads it, and the side that read it was missing for a year. The chip budgets are here for
        // the same reason one step earlier: `chip_pixel_limit` maps a CPU brand to one of them, and
        // a daemon that names 7680 itself has decided which chip it is running on.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"25\.4|\b6144\b|\b7680\b|\b163\.0\b|\bMM_PER_INCH\b|\bMAX_ADVERTISED_HZ\b|\bWIDE_PIXEL_LIMIT\b|\bBASE_PIXEL_LIMIT\b",
            all: &[],
            unless: &[],
            view: View::CodeBeforeTests,
            exempt: &[],
            message: "the daemon spells the virtual display's arithmetic again in {files} — the chip \
                      budgets, the millimetres-per-inch conversion, the reported density and the \
                      advertised-mode ceiling are slopdesk_video::virtual_display's, and a millimetre size \
                      off by a rounding step brings the display up soft (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The daemon as it stands: an IPC shell whose every number is a call into the crate.
    const SHELL: &str = "\
use slopdesk_apple_cgvirtualdisplay::{VirtualDisplay, private_classes_available};
use slopdesk_video::virtual_display::{Geometry, chip_pixel_limit};

pub fn geometry(point_width: i32, point_height: i32, cpu_brand: &str) -> Geometry {
    Geometry::new(point_width, point_height, SCALE, chip_pixel_limit(cpu_brand))
}

pub fn bring_up(display: &VirtualDisplay, geometry: &Geometry, fps: i32) -> Option<u32> {
    if geometry.exceeds_pixel_limit() {
        return None;
    }
    let (width_mm, height_mm) = geometry.size_in_millimeters(DEFAULT_TARGET_PPI);
    display.apply(geometry.pixel_width(), geometry.pixel_height(), width_mm, height_mm)
}
";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::RUST_CORE, "pub fn refresh_rates() {}\n")
            .write("rust/slopdesk-videohostd/src/vdisplay.rs", SHELL);
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

    /// The arithmetic, decided in the daemon again — a rounding order and a chip budget back as the
    /// literals a comment used to claim were "the core"'s, in the one language left to type them
    /// in.
    #[test]
    fn a_respelled_virtual_display_number_is_caught() {
        let fixture = seeded("virtual-display-literals");
        fixture.write(
            "rust/slopdesk-videohostd/src/vdisplay.rs",
            &SHELL.replace(
                "geometry.size_in_millimeters(DEFAULT_TARGET_PPI)",
                "(f64::from(geometry.pixel_width()) / 163.0 * 25.4, 0.0)",
            ),
        );
        says(&fixture, "spells the virtual display's arithmetic again");

        let fixture = seeded("virtual-display-chip-budget");
        fixture.write(
            "rust/slopdesk-videohostd/src/vdisplay.rs",
            &SHELL.replace("chip_pixel_limit(cpu_brand)", "7680"),
        );
        says(&fixture, "spells the virtual display's arithmetic again");
    }

    /// A test that asserts the crate's budget by its value is the daemon PROVING it asks, which is
    /// why the ban reads only what sits above `#[cfg(test)]`.
    #[test]
    fn a_budget_asserted_in_the_daemons_own_test_is_not_a_respelling() {
        let fixture = seeded("virtual-display-test-assert");
        fixture.append(
            "rust/slopdesk-videohostd/src/vdisplay.rs",
            "#[cfg(test)]\nmod tests {\n    #[test]\n    fn a_wide_chip_takes_the_wide_budget() {\n        \
             assert_eq!(tight.pixel_width(), 7680);\n    }\n}\n",
        );
        assert!(super::virtual_display(&fixture.tree()).is_clean());
    }

    /// The same drift one step earlier: the daemon stopped asking at all, and the crate the whole
    /// rule folds through gone.
    #[test]
    fn a_daemon_that_stops_asking_or_a_deleted_core_is_caught() {
        let fixture = seeded("virtual-display-unasked");
        fixture.write(
            "rust/slopdesk-videohostd/src/vdisplay.rs",
            &SHELL.replace(
                "use slopdesk_video::virtual_display::{Geometry, chip_pixel_limit};",
                "",
            ),
        );
        says(&fixture, "the daemon stopped asking");

        let fixture = seeded("virtual-display-core-deleted");
        fixture.remove(super::RUST_CORE);
        says(&fixture, "decided once");
    }

    /// A `MentionsUnder` over a directory that stripped to nothing must FAIL rather than pass — a
    /// drained daemon is the healthiest-looking answer this gate can print, and it means nothing.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_ask() {
        let fixture = Fixture::new("virtual-display-daemon-drained");
        fixture.write(super::RUST_CORE, "pub fn refresh_rates() {}\n");
        assert!(!super::virtual_display(&fixture.tree()).is_clean());
    }
}
