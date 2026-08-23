//! The edges the UI split leaves behind: a test target's imports, the manifest edge under them, the
//! coordinator hooks both roots bind, the canvas registration, and the leaf seams' two shapes.
//!
//! Ported from `scripts/check-supervisor.sh` (`docs/56` §3.5 and stage F). What these have in
//! common is that the failure is a QUIET one — an unbound hook, a second drop-target provider, half
//! a seam registered — and every one of them happens somewhere no compiler and no test is looking.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const MAC_WINDOW_ROOT: &str = "Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift";
const PHONE_WINDOW_ROOT: &str = "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift";
const MAC_SIDEBAR_TOGGLE: &str = "Sources/SlopDeskMacUI/Chrome/MacWindowSidebarToggle.swift";
const MAC_CONTENT_COLUMN: &str = "Sources/SlopDeskMacUI/Columns/MacContentColumn.swift";
const GHOSTTY_SEAM: &str = "ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift";
const TERMINAL_SEAM: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalRenderingView.swift";
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
            message: "MacWorkspaceRootView imports the draining floor again — the window root came off it \
                      (docs/56 §3.5)",
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

/// One seam, two shapes, and neither half registered alone (`docs/56` stage F, P4)
///
/// Each leaf seam offers `shared` (`SwiftUI`, and iOS's ONLY shape — the phone has no `NSView`) and
/// `nativeShared` (`AppKit`, the view the Mac canvas adds as a subview instead of burying under an
/// `NSHostingView` that claims the hit-test over the one surface taking every keystroke). The
/// failure this gate exists for is REGISTERING HALF: a build that sets only `shared` ships a
/// terminal the Mac canvas cannot mount natively, and one that sets only `nativeShared` ships iOS
/// the BUILD-STATUS placeholder. Neither is a compile error and neither has a test — the
/// registration happens in an app target no `Package.swift` builds.
///
/// ⚠️ THE CODE VIEW, NOT THE RAW ONE, and that is not a preference here: the embedder's doc
/// comments name `TerminalRendererFactory.nativeShared` five times to explain the seam, so a raw
/// census reports the prose as a registrar and this gate could never be written.
///
/// The embedder is compiled by NO `Package.swift` target — it joins the Xcode app through
/// `slopdesk-ops enable-renderer macos` — so a rename that leaves its path dangling would silently
/// empty the census rather than fail it. It is asked for first.
///
/// BOTH SHAPES SURVIVE ON BOTH SEAMS. `shared` is not deprecated by `nativeShared` and must never
/// be: deleting it does not break the Mac, which is exactly why it would get deleted. And ONE
/// INSTALLER SETS BOTH — the app target used to spell `TerminalRendererFactory.shared = …` itself,
/// which is a shape it can only ever set one of.
///
/// THE VIDEO PAIR COMES FROM ONE BUILDER. Its two registrations DO live in the app target (the
/// video module never imports `SlopDeskWorkspaceCore`, so the app is the only place both halves can
/// be named), and they are fed by one `-> MacVideoWindowView` function on purpose: the pane threads
/// twelve injector callbacks, and two closures built side by side is how eleven of them end up on
/// one path. `AnyView(MacVideoWindowView(` is the shape of that re-inlining, so it is the thing
/// banned.
///
/// ⚠️ THE TYPE IS `MacVideoWindowView` SINCE THE VIDEO CARVE. It was `VideoWindowView` while one
/// two-armed file served both platforms; the Mac half took the `Mac` prefix and the phone kept the
/// bare name, per the house convention. This gate is spelled against the MAC app main and so names
/// the MAC type — a needle left reading `-> VideoWindowView` would match nothing here and go red
/// for the rename rather than for the re-inlining it exists to catch.
///
/// AND BOTH APPS INSTALL THE TERMINAL SEAM THE ONE WAY. iOS registers only the `SwiftUI` half —
/// that is `install()`'s own `#if os(macOS)` and not the app's business — but it must still go
/// through it.
#[must_use]
pub fn one_seam_two_shapes_one_installer(tree: &Tree) -> Report {
    let mut report = Report::new();
    for seam in [TERMINAL_SEAM, VIDEO_SEAM] {
        for shape in [
            "static var shared",
            "static var nativeShared",
            "static func makeNative",
        ] {
            Claim::Names {
                path: seam,
                needle: shape,
                message: "a leaf seam stopped declaring one of its two shapes — one seam has two shapes, \
                          picked by which framework is drawing (docs/56 stage F, P4)",
            }
            .check(tree, &mut report);
        }
    }

    let claims = [
        Claim::Exists {
            path: GHOSTTY_SEAM,
            message: "it is the only registrar of the terminal seam and no compiler in `make check` opens \
                      it (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: GHOSTTY_SEAM,
            pattern: r"TerminalRendererFactory\.shared *=",
            view: View::Code,
            message: "GhosttyRendererSeam.install() no longer sets TerminalRendererFactory.shared — half a \
                      seam registered is a placeholder terminal on one platform (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: GHOSTTY_SEAM,
            pattern: r"TerminalRendererFactory\.nativeShared *=",
            view: View::Code,
            message: "GhosttyRendererSeam.install() no longer sets TerminalRendererFactory.nativeShared — \
                      half a seam registered is a placeholder terminal on one platform (docs/56 stage F, P4)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Apps", "ThirdParty/ghostty/integration"],
            extensions: SWIFT,
            pattern: r"TerminalRendererFactory\.(shared|nativeShared) *=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[GHOSTTY_SEAM],
            message: "{files} registers the terminal seam outside GhosttyRendererSeam.install() — that is \
                      how one half gets set and the other forgotten (docs/56 stage F, P4)",
        },
        Claim::Names {
            path: MAC_APP_MAIN,
            needle: "-> MacVideoWindowView",
            message: "the Mac app main stopped spelling `-> MacVideoWindowView` — the video seam's two \
                      mounts must be one builder's value (docs/56 stage F, P4)",
        },
        Claim::Names {
            path: MAC_APP_MAIN,
            needle: "VideoWindowFactory.shared =",
            message: "the Mac app main stopped setting VideoWindowFactory.shared — the video seam's two \
                      mounts must be one builder's value (docs/56 stage F, P4)",
        },
        Claim::Names {
            path: MAC_APP_MAIN,
            needle: "VideoWindowFactory.nativeShared =",
            message: "the Mac app main stopped setting VideoWindowFactory.nativeShared — the video seam's \
                      two mounts must be one builder's value (docs/56 stage F, P4)",
        },
        Claim::Lacks {
            path: MAC_APP_MAIN,
            pattern: r"AnyView\(MacVideoWindowView\(",
            view: View::Code,
            message: "the video pane is built inside the `shared` closure again — the AppKit mount then \
                      carries whatever callbacks that copy happens to thread (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: MAC_APP_MAIN,
            pattern: r"GhosttyRendererSeam\.install\(\)",
            view: View::Code,
            message: "the Mac app does not call GhosttyRendererSeam.install() — the renderer build shows \
                      the BUILD-STATUS placeholder and every test still passes (docs/56 stage F, P4)",
        },
        Claim::Matches {
            path: PHONE_APP_MAIN,
            pattern: r"GhosttyRendererSeam\.install\(\)",
            view: View::Code,
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
    /// than from the previous case's break.
    fn canvas(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::MAC_CONTENT_COLUMN,
                "dropTargets.register(.canvas) { mainWindowFrame }\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/SplitContainer.swift",
                "struct SplitContainer: View {}\n",
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
            "Sources/SlopDeskPhoneUI/Pane/SplitContainer.swift",
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

    fn seams(fixture: &Fixture) -> &Fixture {
        let shapes = "static var shared\nstatic var nativeShared\nstatic func makeNative\n";
        fixture
            .write(super::TERMINAL_SEAM, shapes)
            .write(super::VIDEO_SEAM, shapes)
            .write(
                super::GHOSTTY_SEAM,
                "TerminalRendererFactory.shared = { … }\nTerminalRendererFactory.nativeShared = { … }\n",
            )
            .write(
                super::MAC_APP_MAIN,
                "func build() -> MacVideoWindowView { … }\nVideoWindowFactory.shared = { … }\n\
                 VideoWindowFactory.nativeShared = { … }\nGhosttyRendererSeam.install()\n",
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

        // Half a seam registered is a placeholder terminal on one platform, and nothing goes red.
        fixture.write(super::GHOSTTY_SEAM, "TerminalRendererFactory.shared = { … }\n");
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // A second registrar, which is how one half gets set and the other forgotten.
        seams(&fixture);
        fixture.write(
            "Apps/ClientApp-macOS/SeamPatch.swift",
            "TerminalRendererFactory.nativeShared = { … }\n",
        );
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // The prose that names the door is NOT a registrar — the reason this reads the code view.
        seams(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/SeamNotes.swift",
            "// TerminalRendererFactory.nativeShared = the AppKit half\n",
        );
        assert!(super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());

        // And the re-inlined video pane, which carries whatever callbacks that copy threads.
        seams(&fixture);
        fixture.write(
            super::MAC_APP_MAIN,
            "func build() -> MacVideoWindowView { … }\nVideoWindowFactory.shared = { \
             AnyView(MacVideoWindowView(pane: pane)) }\nVideoWindowFactory.nativeShared = { … \
             }\nGhosttyRendererSeam.install()\n",
        );
        assert!(!super::one_seam_two_shapes_one_installer(&fixture.tree()).is_clean());
    }
}
