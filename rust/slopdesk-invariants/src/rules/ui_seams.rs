//! The edges the UI split leaves behind: a test target's imports, the manifest edge under them, the
//! coordinator hooks both roots bind, the canvas registration, and the leaf seams' two shapes.
//!
//! Ported from the deleted `check-supervisor.sh` (`docs/56` §3.5 and stage F). What these have in
//! common is that the failure is a QUIET one — an unbound hook, a second drop-target provider, half
//! a seam registered — and every one of them happens somewhere no compiler and no test is looking.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Mac's window root. RE-AIMED 2026-08-28 from `App/MacWorkspaceRootView.swift`: the Mac shell
/// finished its own de-SwiftUI and the root is a window controller now, not a `View`. The phone's
/// twin moved the same way one commit earlier (docs/62 stage D), so the pair below still reads two
/// roots — both of them imperative, which is the arrangement `CLAUDE.md` says is the floor.
const MAC_WINDOW_ROOT: &str = "Sources/SlopDeskMacUI/App/MacWorkspaceWindowController.swift";
const PHONE_WINDOW_ROOT: &str = "Sources/SlopDeskPhoneUI/Shell/WorkspaceRootViewController.swift";
const MAC_SIDEBAR_TOGGLE: &str = "Sources/SlopDeskMacUI/Chrome/MacWindowSidebarToggle.swift";
const MAC_CONTENT_COLUMN: &str = "Sources/SlopDeskMacUI/Columns/MacContentColumn.swift";
const GHOSTTY_SEAM: &str = "ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift";
const TERMINAL_SEAM: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalRendererSeam.swift";
const VIDEO_SEAM: &str = "Sources/SlopDeskWorkspaceCore/Video/VideoWindowSeam.swift";
const MAC_APP_MAIN: &str = "Apps/ClientApp-macOS/AppMain.swift";
const PHONE_APP_MAIN: &str = "Apps/ClientApp-iOS/AppMain.swift";

/// A test target is the same edge wearing a `Tests/` prefix (`docs/56` §3.5 step 5)
///
/// The `Sources/` ban is not enough on its own: the fold is blocked by a Mac test target naming the
/// draining floor exactly as hard as by a Mac source file naming it — `SlopDeskClientUI` could not
/// become `SlopDeskPhoneUI` while ANY `SlopDeskMacUI*` target reached into it, and a
/// `@testable import` is a stronger edge than a plain one, not a weaker one.
///
/// A target's OWN tests are not the violation and are deliberately not matched: a suite saying
/// `@testable import` of the half it belongs to is a suite testing its own target. What is banned
/// is a half's test target naming the OTHER half.
///
/// ⚠️ FOUR EDGES BECAME TWO IN INCREMENT 63, and the phone's side moved OUT OF `Tests/` entirely.
/// Two of the four named `SlopDeskClientUI`, which no longer exists. And the phone's suite is no
/// longer a `SwiftPM` target at all — `SlopDeskPhoneUI` is iOS-only, so on the host triple it
/// compiles to nothing and a `Tests/` target over it could assert nothing. Leaving either stale
/// path in place would have been the exact failure this gate exists to catch: a gate that stays
/// green because the thing it greps for can no longer be spelled. So a missing directory is a STALE
/// EDGE, not a satisfied one, and the floor below says so.
///
/// ⚠️ AND THE VIDEO HALVES RIDE THE SAME EDGE. The carve gave each platform its own video view
/// target, so a Mac suite naming `SlopDeskVideoClientPhone` is the same violation as one naming
/// `SlopDeskPhoneUI` — the two arms of the file this replaced were reachable from everywhere
/// precisely because they lived in a target both sides linked.
///
/// A COORDINATOR HOOK BOUND ON ONE PLATFORM IS A DEAD ROW ON THE OTHER, and it dies quietly: every
/// actuator on `OverlayCoordinator` defaults to an empty closure, so a palette row whose hook
/// nobody bound looks exactly like a row that ran and had nothing to do. Three of them were bound
/// only by the Mac's root — the two panel toggles and the code-panel focus — which meant the
/// phone's palette listed View actions that did nothing at all. `togglePinWindow` is deliberately
/// NOT here: a phone has one window and no window level, which the palette row itself records. An
/// action that is absent on a platform is fine; an action that is listed and inert is not.
#[must_use]
pub fn a_test_target_is_the_same_edge(tree: &Tree) -> Report {
    const MAC_TESTS: &str = "Tests/SlopDeskMacUITests";
    const PHONE_TESTS: &str = "Apps/ClientApp-iOS/Tests";

    let mut report = Report::new();
    for hook in [
        "overlay.toggleSidebar =",
        "overlay.toggleCodeSidebar =",
        "overlay.focusCodePanel =",
    ] {
        for root in [MAC_WINDOW_ROOT, PHONE_WINDOW_ROOT] {
            Claim::Names {
                path: root,
                needle: hook,
                // The sentence names neither, since a table cannot carry a placeholder the claim does
                // not fill — and the finding is the pair, not either half.
                message: "a workspace root stopped binding an overlay hook — every actuator defaults to an \
                          empty closure, so an unbound hook is a palette row that lies",
            }
            .check(tree, &mut report);
        }
    }

    let claims = [
        // The floor IS the stale-ledger check: a suite that moved leaves its directory empty, and an
        // empty directory satisfies every ban written over it.
        Claim::Populated {
            roots: &[MAC_TESTS],
            extensions: SWIFT,
            minimum: 1,
            message: "this ledger names Tests/SlopDeskMacUITests, which holds {found} Swift files — the \
                      edge moved and the ledger did not (docs/56 §3.5 step 5)",
        },
        Claim::Populated {
            roots: &[PHONE_TESTS],
            extensions: SWIFT,
            minimum: 1,
            message: "this ledger names Apps/ClientApp-iOS/Tests, which holds {found} Swift files — the \
                      edge moved and the ledger did not (docs/56 §3.5 step 5)",
        },
        // `@testable ` is OPTIONAL in the pattern on purpose — a test target reaches for a UI half
        // both ways, and matching only the plain spelling would wave every crossing in the tree
        // through.
        Claim::NoneUnder {
            roots: &[MAC_TESTS],
            extensions: SWIFT,
            pattern: r"^(@testable )?import (SlopDeskPhoneUI|SlopDeskVideoClientPhone)$",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reached for the phone half from the Mac's tests — a UI half's tests name no \
                      other half (docs/56 §3.5 step 5)",
        },
        Claim::NoneUnder {
            roots: &[PHONE_TESTS],
            extensions: SWIFT,
            pattern: r"^(@testable )?import (SlopDeskMacUI|SlopDeskVideoClientMac)$",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reached for the Mac half from the phone's tests — a UI half's tests name no \
                      other half (docs/56 §3.5 step 5)",
        },
        Claim::NotDepends {
            target: "SlopDeskMacUITests",
            dependency: "SlopDeskPhoneUI",
            message: "F3 cut that edge, and an import census is a convention where a missing dependency is \
                      a compile error (docs/56)",
        },
        // AND THE WINDOW ROOT IS OFF THE DRAINING FLOOR (docs/56 §3.5, increment 56b). The rename was
        // blocked by exactly the set of `SlopDeskMacUI` files that still imported the phone half —
        // that set WAS the ledger, it reached zero, and increment 63 spent it. Re-adding one is a
        // single line that compiles green.
        //
        // Three assertions, because two of them can pass while the port is half-done: the import can
        // go while the AppKit button never arrives, and the AppKit button can arrive while the
        // SwiftUI one is kept "just in case" — one control in two languages, which CLAUDE.md bans by
        // name.
        Claim::Lacks {
            path: MAC_WINDOW_ROOT,
            pattern: "^import SlopDeskPhoneUI",
            view: View::Code,
            message: "MacWorkspaceWindowController imports the draining floor again — the window root came \
                      off it (docs/56 §3.5)",
        },
        Claim::Exists {
            path: MAC_SIDEBAR_TOGGLE,
            message: "the window's sidebar toggle is AppKit's (docs/56 §3.5)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Chrome/WindowSidebarToggle.swift",
            message: "MacWindowSidebarToggle replaced the SwiftUI toggle, never joined it (docs/56 §3.5)",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

/// The canvas registers itself in `AppKit` (`docs/56` stage F, P5)
///
/// `DropTargetFrameReader` published the canvas's SCREEN rect from inside `SplitContainer`'s
/// `GeometryReader` because the `AppKit` view hosting the canvas could not: `ContentColumn` applied
/// the island moat one level up, so the hosting view's frame and the canvas differed by it — and by
/// a DIFFERENTLY ANIMATING amount while a column collapsed. That was the last kind 3 in the ledger
/// and it was a statement about `SwiftUI`, not about geometry. The moat is `MacContentColumn`'s
/// constraints now, the difference is zero, and the registration is the three lines
/// `MacNavigatorColumn` already spends on `.sidebarList`.
///
/// ONE PROVIDER FOR ONE KEY. A re-mounted `SwiftUI` reader registering a SECOND provider does not
/// fail: which one wins is mount order, so a drag resolves against whichever view happened to
/// appear last.
///
/// AND THE MOAT DOES NOT COME BACK. It did not descend to `SlopDeskClientCore` and that was the
/// ruling, not an omission: it reads three `Slate.Metric` tokens and lays out, which is `docs/56`
/// §3's test for a DRAWING exactly inverted — and `SlopDeskClientCore` sits BELOW `SlopDeskSlate`
/// and cannot read the tokens at all. So the pin is on the MEASUREMENTS, because the measurements
/// are what the difference was made of.
///
/// The `\b` on the token names is load-bearing, and 57b paid for learning it: without it
/// `islandRadius` also matches `islandRadiusCompact`, which is `SlateProjectIsland`'s own token and
/// legitimately drawn in that target. A prefix match bans a surviving token by accident and reads
/// as the moat coming back — the gate would be red for something that is right.
#[must_use]
pub fn the_canvas_registers_itself_in_appkit(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Pane/DropTargetFrameReader.swift",
            message: "the island moat moved to MacContentColumn instead (docs/56 stage F, P5)",
        },
        Claim::Names {
            path: MAC_CONTENT_COLUMN,
            needle: "register(.canvas)",
            message: "MacContentColumn stopped registering the canvas drop target — the canvas is \
                      un-droppable, and no test goes red for it (docs/56 stage F, P5)",
        },
        Claim::Names {
            path: MAC_CONTENT_COLUMN,
            needle: "mainWindowFrame",
            message: "MacContentColumn stopped spelling mainWindowFrame — the canvas is un-droppable, and \
                      no test goes red for it (docs/56 stage F, P5)",
        },
        // `Sources` alone, the same MUTABLE-SEAM argument the installer ban below spells out:
        // "two providers for one key resolve by mount order" is a claim about a shipped process,
        // and `PaneCanvasDragControllerTests` registers a provider because that is what driving a
        // drop target from a harness requires. See [`crate::claim::SWIFT_ROOTS`].
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"register\(\.canvas\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[MAC_CONTENT_COLUMN],
            message: "{files} registers the .canvas drop target too — two providers for one key resolve by \
                      mount order (docs/56 stage F, P5)",
        },
        // Through the code view: `SplitContainer`'s header names the moat to explain why its gate is
        // gone, and a gate that cannot tell code from its own post-mortem forbids writing the
        // post-mortem.
        // The moat ban's own floor. It is the one claim in this rule with no named path — a `Sources`
        // sweep and three `Names` cannot go quiet, but a ban ROOTED in the draining target passes the
        // instant that target drains, which is precisely what `3f11c6e6` did to it. Pinned well under
        // the live count on purpose: a tripwire against an empty root, not a ratchet on the rebuild.
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            minimum: 15,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI — the moat ban below reads an \
                      empty tree and passes (docs/56 stage F, P5)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            pattern: r"Slate\.Metric\.(islandInset|islandRadius|bandInset|bandHeight|panelRailWidth)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spells the island's measurements in the draining target again — the moat is \
                      MacContentColumn's (docs/56 stage F, P5)",
        },
    ];
    check_all(tree, &claims)
}

/// One seam, ONE shape, and no second slot beside it (`docs/56` stage F, P4)
///
/// ⚠️ THIS RULE USED TO ENFORCE THE EXACT OPPOSITE OF WHAT IT NOW ENFORCES, and the reversal is
/// worth reading before anything here is edited. Each leaf seam carried TWO slots — `shared`
/// returning an `AnyView` and `nativeShared` returning the platform view — and this rule demanded
/// BOTH, on both seams, in the same words it now uses to forbid the second. Its doc said "`shared`
/// is not deprecated by `nativeShared` and must never be: deleting it does not break the Mac, which
/// is exactly why it would get deleted."
///
/// That rested on ONE premise, stated in it: `shared` was "iOS's ONLY shape — the phone has no
/// `NSView`". The phone draws in `UIKit` now and has a `UIView`, so the premise is false and the
/// deletion the rule was written to prevent became the correct move. The seams return a
/// ``PlatformView`` and nothing else.
///
/// WHAT SURVIVES UNCHANGED is the failure the rule actually exists for, which was never about
/// `SwiftUI`: REGISTERING NOTHING. The registration happens in app targets no `Package.swift`
/// builds and the embedder is compiled by no target at all — it joins the Xcode app through
/// `slopdesk-ops enable-renderer macos` — so an unregistered seam is not a compile error, has no
/// test, and ships the BUILD-STATUS placeholder where a terminal should be. Every `Matches` claim
/// below is that check, and each is now STRONGER than before: one registration cannot be half-done.
///
/// ⚠️ THE CODE VIEW, NOT THE RAW ONE, and that is not a preference here: the seams' own doc
/// comments name these symbols repeatedly to explain the collapse — this paragraph included — so a
/// raw census reports the prose as a registrar and this gate could never be written.
///
/// THE SECOND SLOT IS NOW BANNED RATHER THAN REQUIRED. `nativeShared`/`makeNative` were the
/// PLATFORM half of the pair; with the `SwiftUI` half gone they were promoted to the bare names,
/// and a re-appearing `nativeShared` means someone has re-introduced the two-slot shape — which is
/// how a hosting view gets interposed over the one surface that takes every keystroke.
///
/// THE VIDEO SEAM IS REGISTERED FROM THE APP TARGET on both platforms, because the video modules
/// never import `SlopDeskWorkspaceCore` and the app is the only place both sides can be named. It
/// is fed by one builder on purpose: the pane threads twelve injector callbacks, and a second
/// closure built beside the first is how eleven of them end up on one path and one on another.
#[must_use]
pub fn one_seam_two_shapes_one_installer(tree: &Tree) -> Report {
    let mut report = Report::new();
    for seam in [TERMINAL_SEAM, VIDEO_SEAM] {
        Claim::Names {
            path: seam,
            needle: "static var shared",
            message: "a leaf seam stopped declaring its one slot — the seam hands back a PlatformView and \
                      the canvas mounts it directly (docs/56 stage F, P4)",
        }
        .check(tree, &mut report);
        Claim::Lacks {
            path: seam,
            pattern: r"static (var nativeShared|func makeNative)",
            view: View::Code,
            message: "a leaf seam grew a second slot beside `shared` again — two slots is how a hosting \
                      view gets interposed over the surface that takes every keystroke (docs/56 stage F, P4)",
        }
        .check(tree, &mut report);
    }

    let claims = [
        Claim::Exists {
            path: GHOSTTY_SEAM,
            message: "it is the only registrar of the terminal seam and no compiler in `just check` opens \
                      it (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: GHOSTTY_SEAM,
            pattern: r"TerminalRendererFactory\.shared *=",
            message: "GhosttyRendererSeam.install() no longer sets TerminalRendererFactory.shared — an \
                      unregistered seam ships the BUILD-STATUS placeholder where the terminal should be, \
                      and no compiler in `just check` opens this file (docs/56 stage F, P4)",
        },
        // Every Swift root that ships, plus the embedder — and deliberately NOT `Tests`, which is
        // [`crate::claim::SWIFT_ROOTS`]'s third category. Assigning `shared` is how a test installs
        // a DOUBLE: `LeafSeamSlotTests` sets it to a stub, asserts `make` carries mount focus
        // through, and clears it in `tearDown`. The sentence this ban says — "a second registrar
        // resolves by mount order" — is a claim about what SHIPS, and it means nothing inside a
        // harness that owns the whole process. Widened, the ban would mean two things and would
        // fire on the suite that proves the seam works.
        Claim::NoneUnder {
            roots: &["Sources", "Apps", "ThirdParty/ghostty/integration"],
            extensions: SWIFT,
            pattern: r"TerminalRendererFactory\.(shared|nativeShared) *=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[GHOSTTY_SEAM],
            message: "{files} registers the terminal seam outside GhosttyRendererSeam.install() — one seam \
                      has one installer, and a second registrar resolves by mount order (docs/56 stage F, \
                      P4)",
        },
        // The video seam's builder, named by its RETURN TYPE rather than by the registration line: the
        // point of the rule is that ONE value feeds the mount, and a builder that stopped returning a
        // spec is the shape where callbacks start being threaded per-closure again.
        Claim::Names {
            path: MAC_APP_MAIN,
            needle: "-> MacVideoPaneSpec",
            message: "the Mac app main stopped spelling `-> MacVideoPaneSpec` — the video mount must be one \
                      builder's value, or the pane's twelve injector callbacks get threaded per closure \
                      (docs/56 stage F, P4)",
        },
        Claim::Names {
            path: MAC_APP_MAIN,
            needle: "VideoWindowFactory.shared =",
            message: "the Mac app main stopped setting VideoWindowFactory.shared — the video seam is \
                      registered from the app target or not at all (docs/56 stage F, P4)",
        },
        Claim::Lacks {
            path: MAC_APP_MAIN,
            pattern: r"VideoWindowFactory\.nativeShared *=",
            view: View::Code,
            message: "the Mac app main registers a `nativeShared` video slot again — the seam has ONE slot \
                      since the phone gained a UIView, and a second one re-admits the hosting view over the \
                      surface that takes every keystroke (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: MAC_APP_MAIN,
            pattern: r"GhosttyRendererSeam\.install\(\)",
            message: "the Mac app does not call GhosttyRendererSeam.install() — the renderer build shows \
                      the BUILD-STATUS placeholder and every test still passes (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: PHONE_APP_MAIN,
            pattern: r"GhosttyRendererSeam\.install\(\)",
            message: "the iOS app does not call GhosttyRendererSeam.install() — the renderer build shows \
                      the BUILD-STATUS placeholder and every test still passes (docs/56 stage F, P4)",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn edges(fixture: &Fixture) -> &Fixture {
        fixture.write(
            "Apps/ClientApp-iOS/Tests/PhoneTests.swift",
            "@testable import SlopDeskPhoneUI\n",
        );
        edges_without_the_phone_suite(fixture)
    }

    /// Everything but the phone's test file, so the moved-suite case can be built rather than
    /// deleted.
    fn edges_without_the_phone_suite(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                "Tests/SlopDeskMacUITests/MacColumnTests.swift",
                "@testable import SlopDeskMacUI\n",
            )
            .write(
                "Package.swift",
                "        .testTarget(\n            name: \"SlopDeskMacUITests\",\n\x20           \
                 dependencies: [\"SlopDeskMacUI\"]\n        ),\n\x20       .target(\n            name: \
                 \"SlopDeskMacUI\",\n\x20           dependencies: []\n        ),\n",
            )
            .write(
                super::MAC_WINDOW_ROOT,
                "import AppKit\noverlay.toggleSidebar = { }\noverlay.toggleCodeSidebar = { \
                 }\noverlay.focusCodePanel = { }\n",
            )
            .write(
                super::PHONE_WINDOW_ROOT,
                "import SwiftUI\noverlay.toggleSidebar = { }\noverlay.toggleCodeSidebar = { \
                 }\noverlay.focusCodePanel = { }\n",
            )
            .write(
                super::MAC_SIDEBAR_TOGGLE,
                "final class MacWindowSidebarToggle: NSView {}\n",
            )
    }

    #[test]
    fn a_test_suite_names_no_other_half_and_the_manifest_edge_stays_cut() {
        let fixture = Fixture::new("ui-seam-edges");
        edges(&fixture);
        assert!(super::a_test_target_is_the_same_edge(&fixture.tree()).is_clean());

        // A `@testable import` is a stronger edge than a plain one, not a weaker one.
        fixture.write(
            "Tests/SlopDeskMacUITests/MacColumnTests.swift",
            "@testable import SlopDeskMacUI\n@testable import SlopDeskPhoneUI\n",
        );
        assert!(!super::a_test_target_is_the_same_edge(&fixture.tree()).is_clean());

        // The manifest edge, which is what makes the one-line import compile.
        edges(&fixture);
        fixture.write(
            "Package.swift",
            "        .testTarget(\n            name: \"SlopDeskMacUITests\",\n\x20           dependencies: \
             [\"SlopDeskMacUI\", \"SlopDeskPhoneUI\"]\n        ),\n\x20       .target(\n            name: \
             \"SlopDeskMacUI\",\n\x20           dependencies: []\n        ),\n",
        );
        assert!(!super::a_test_target_is_the_same_edge(&fixture.tree()).is_clean());

        // A hook bound on one root and not the other is a palette row that lies.
        edges(&fixture);
        fixture.write(
            super::PHONE_WINDOW_ROOT,
            "import SwiftUI\noverlay.toggleSidebar = { }\n",
        );
        assert!(!super::a_test_target_is_the_same_edge(&fixture.tree()).is_clean());
    }

    /// A suite that moved leaves nothing behind, and nothing satisfies every ban written over it.
    /// This is the `|| continue` the shell carried until increment 63.
    #[test]
    fn a_moved_suite_is_a_stale_ledger_rather_than_a_pass() {
        let fixture = Fixture::new("ui-seam-moved");
        edges_without_the_phone_suite(&fixture);
        assert!(!super::a_test_target_is_the_same_edge(&fixture.tree()).is_clean());
    }

    /// Both files each case may dirty are rewritten, so a case starts from the clean tree rather
    /// than from the previous case's break — plus the filler that clears the moat ban's floor,
    /// which is the same reason `design_ratchets`' fixture writes a phone tree rather than a file.
    ///
    /// The canvas file is `SplitCanvasView` since docs/62 stage E.0; it was `SplitContainer`, and a
    /// fixture naming the deleted spelling reads as a live path to the next person here.
    fn canvas(fixture: &Fixture) -> &Fixture {
        for index in 0..15 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Pane/Filler{index}.swift"),
                "import UIKit\nfinal class Filler: UIView {}\n",
            );
        }
        fixture
            .write(
                super::MAC_CONTENT_COLUMN,
                "dropTargets.register(.canvas) { mainWindowFrame }\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
                "final class SplitCanvasView: UIView {}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/DesignSystem/SlateProjectIsland.swift",
                "struct SlateProjectIsland: View {}\n",
            )
    }

    #[test]
    fn one_provider_registers_the_canvas_and_the_moat_stays_in_appkit() {
        let fixture = Fixture::new("ui-seam-canvas");
        canvas(&fixture);
        assert!(super::the_canvas_registers_itself_in_appkit(&fixture.tree()).is_clean());

        // Two providers for one key resolve by mount order, which is not a failure anybody sees.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
            "dropTargets.register(.canvas) { frame }\n",
        );
        assert!(!super::the_canvas_registers_itself_in_appkit(&fixture.tree()).is_clean());

        // The `\b` that 57b paid for: `islandRadiusCompact` is a surviving token and must pass.
        canvas(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/DesignSystem/SlateProjectIsland.swift",
            "let r = Slate.Metric.islandRadiusCompact\n",
        );
        assert!(super::the_canvas_registers_itself_in_appkit(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskPhoneUI/DesignSystem/SlateProjectIsland.swift",
            "let r = Slate.Metric.islandRadius\n",
        );
        assert!(!super::the_canvas_registers_itself_in_appkit(&fixture.tree()).is_clean());
    }

    /// The moat ban is ROOTED in the draining target, so a drained target satisfies it by holding
    /// nothing — the failure `3f11c6e6` actually caused, and the one the count cannot show.
    #[test]
    fn a_drained_phone_target_fails_the_moat_ban_rather_than_satisfying_it() {
        let fixture = Fixture::new("ui-seam-canvas-drained");
        fixture.write(
            super::MAC_CONTENT_COLUMN,
            "dropTargets.register(.canvas) { mainWindowFrame }\n",
        );
        let report = super::the_canvas_registers_itself_in_appkit(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("reads an empty tree and passes")),
            "the floor is what fires, not one of the named claims: {:?}",
            report.violations()
        );
    }

    fn seams(fixture: &Fixture) -> &Fixture {
        // ONE slot per seam. The fixture used to seed three shapes here — `shared`, `nativeShared`
        // and `makeNative` — because the rule REQUIRED all three; it now forbids the last
        // two.
        let shapes = "static var shared\n";
        fixture
            .write(super::TERMINAL_SEAM, shapes)
            .write(super::VIDEO_SEAM, shapes)
            .write(super::GHOSTTY_SEAM, "TerminalRendererFactory.shared = { … }\n")
            .write(
                super::MAC_APP_MAIN,
                "func build() -> MacVideoPaneSpec { … }\nVideoWindowFactory.shared = { … }\n\
                 GhosttyRendererSeam.install()\n",
            )
            .write(super::PHONE_APP_MAIN, "GhosttyRendererSeam.install()\n")
            // Rewritten with the rest, so a case starts from the clean tree rather than from the
            // previous case's break.
            .write("Apps/ClientApp-macOS/SeamPatch.swift", "enum SeamPatch {}\n")
            .write("Sources/SlopDeskWorkspaceCore/Terminal/SeamNotes.swift", "enum SeamNotes {}\n")
    }

    #[test]
    fn the_seam_registers_whole_and_the_video_pair_comes_from_one_builder() {
        let fixture = Fixture::new("ui-seam-shapes");
        seams(&fixture);
        assert!(super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // An unregistered seam ships the BUILD-STATUS placeholder, and no compiler opens this file.
        fixture.write(super::GHOSTTY_SEAM, "enum GhosttyRendererSeam {}\n");
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // A second registrar, which resolves by mount order rather than by anyone's intent.
        seams(&fixture);
        fixture.write(
            "Apps/ClientApp-macOS/SeamPatch.swift",
            "TerminalRendererFactory.nativeShared = { … }\n",
        );
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // The prose that names the door is NOT a registrar — the reason this reads the code view,
        // and the reason the rule's own doc comment can spell `nativeShared` while banning
        // it.
        seams(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/SeamNotes.swift",
            "// TerminalRendererFactory.nativeShared = the slot that used to sit beside `shared`\n",
        );
        assert!(super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // ⚠️ THE CASE THIS RULE REVERSED ON. A seam that re-grows the second slot is now the
        // FAILURE, where the same fixture was the rule's clean state before the phone
        // gained a UIView.
        seams(&fixture);
        fixture.write(super::VIDEO_SEAM, "static var shared\nstatic var nativeShared\n");
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // And the app main re-registering the second slot, the other half of the same reversal.
        seams(&fixture);
        fixture.write(
            super::MAC_APP_MAIN,
            "func build() -> MacVideoPaneSpec { … }\nVideoWindowFactory.shared = { … \
             }\nVideoWindowFactory.nativeShared = { … }\nGhosttyRendererSeam.install()\n",
        );
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());
    }
}
