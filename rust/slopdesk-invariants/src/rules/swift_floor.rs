//! The floor `docs/63` §6 stated and `docs/67` turned into a list: every Swift file that decides
//! something without going through a door is named here, with the reason it is not going to move.
//!
//! ## The method, and the one that lies
//!
//! The obvious census — a file with no `import AppKit`/`UIKit` and no literal `slopdesk_` in it —
//! is a PER-FILE test for a door, and almost no Swift file calls a door directly. It calls a
//! sibling FACE (`MirrorFold`, `SupervisionFold`, `TabBadgeGating`, `StoreRollup`…) which holds the
//! `slopdesk_` call. Run that way the workspace store reads as twelve thousand portable lines, and
//! every one of them is fiction.
//!
//! So the face set is built FIRST, out of the tree, and subtracted: a file is a candidate only if
//! it is non-UI, holds no door, AND names no face. That leaves the files below.
//!
//! ## The row that was a deferral, and is not here
//!
//! `docs/67` §5 carried a seventh reason, `DevicePanelLane`, for the one `import Network` socket
//! `docs/63` §6 had explicitly deferred — "the device-panel and proxy lanes are their own campaigns
//! and are not scoped here". That campaign landed: the handshake, the framing and the two lanes are
//! `rust/slopdesk-devicelink`, reached through the `slopdesk_device_ws_*` and
//! `slopdesk_device_bridge_*` doors, and the Swift file that held the state machine is deleted. A
//! deferral is not a floor, so it does not get a variant kept warm against the next one — every
//! reason below is a reason a file STAYS.
//!
//! ## What this rule is not
//!
//! It is not the census. Encoding "count the undelegated lines" as a gate would be a second
//! implementation of a shell pipeline and a fragile one — the numbers move with every commit and a
//! threshold would be argued down rather than defended. What is ratchetable is the SET: a new
//! candidate is a file somebody has to classify, and classifying it is the work `docs/67` §2 says
//! actually finds things. Both directions are checked, because a floor entry that no longer
//! qualifies is stale bookkeeping and reads exactly like a satisfied one.

use std::collections::BTreeSet;

use crate::claim::{Claim, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// Why a file is on the floor. The variant is the REASON, so a file that fits none of them does not
/// belong on the list at all — which is the question a new candidate forces someone to answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Floor {
    /// CoreGraphics path data. `docs/63` §6's floor by name.
    DrawingArt,
    /// Drives a Swift or Foundation primitive with no counterpart that can cross a C ABI —
    /// `withObservationTracking`, `Task`, `AsyncStream`, `DispatchQueue`, `NWConnection`,
    /// `JSONEncoder`, `ProcessInfo`, `async` re-entrancy, the first-responder generation, a virtual
    /// clock. `docs/67` §6 closes `docs/65` §5's parked triad here.
    SwiftRuntime,
    /// The NEAR side of the FFI boundary: the arena cursor, the delivery retry, the handle's
    /// `Sendable` claim, the lent-text pair, and the seams that decide what does NOT need to cross.
    /// A door's caller cannot itself be behind a door.
    ///
    /// `SimulatorFrameSink` is the second kind: `docs/55` §4b asks whether the far side READS the
    /// part that is big, and a sink that holds an avcC record, a JPEG seed and one keyframe for
    /// replay would have Rust copy an IDR in and out to be told which one it was.
    CallingConvention,
    /// `WebKit`. `docs/63` §6's floor by name.
    WebKit,
    /// The vocabulary the wire, the config or the ABI is typed in on this side, plus the module
    /// docs that carry no code at all.
    Vocabulary,
    /// A decision `AppKit` and `UIKit` would each otherwise write, hoisted so the two cannot
    /// disagree. What it decides is PRESENTATION; the value is that it is written once for
    /// both.
    ShellDeDuplication,
}

/// Every file the census names, and why it stays. Kept sorted by path.
const FLOOR: &[(&str, Floor)] = &[
    ("Sources/SlopDeskArena/ArenaText.swift", Floor::CallingConvention),
    (
        "Sources/SlopDeskArena/FFIDelivery.swift",
        Floor::CallingConvention,
    ),
    ("Sources/SlopDeskClaudeCode/TerminalMode.swift", Floor::Vocabulary),
    ("Sources/SlopDeskClient/ClientError.swift", Floor::Vocabulary),
    (
        "Sources/SlopDeskClient/EventBroadcaster.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskClientCore/App/ClientTerminalPalette.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/App/WorkspaceChromeState.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Chrome/AndroidMarkPath.swift",
        Floor::DrawingArt,
    ),
    (
        "Sources/SlopDeskClientCore/Chrome/ConnectionTelemetry.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Chrome/PanelChromeCopy.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFontSchemeHandler.swift",
        Floor::WebKit,
    ),
    (
        "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarKeyboardState.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Overlays/HoverSelectionGate.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Overlays/PeekReplyCopy.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Pane/AutotypeSeam.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Pane/BuildStatusPlaceholderCopy.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Pane/PanePointer.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Pane/SatelliteWindowKeyState.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Pane/TerminalTouchSelection.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Panel/DeviceBezelGeometry.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Panel/PanelChromeActions.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Rail/NavigatorChromeCopy.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskClientCore/Support/ObservationFollow.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskDevicePanels/Shared/DevicePanelDelivery.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskDevicePanels/Shared/DeviceSectionReading.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskDevicePanels/Shared/DeviceVeilWait.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskDevicePanels/Simulator/SimulatorFrameSink.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskInspector/NWByteChannelConformance.swift",
        Floor::SwiftRuntime,
    ),
    ("Sources/SlopDeskNet/NWByteChannel.swift", Floor::SwiftRuntime),
    (
        "Sources/SlopDeskProtocol/CodecBytes.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskProtocol/Metadata/MetadataVerb.swift",
        Floor::Vocabulary,
    ),
    ("Sources/SlopDeskProtocol/SlopDeskError.swift", Floor::Vocabulary),
    ("Sources/SlopDeskProtocol/WireMessage.swift", Floor::Vocabulary),
    (
        "Sources/SlopDeskSlate/PaneDropPreviewArt.swift",
        Floor::DrawingArt,
    ),
    ("Sources/SlopDeskSlate/PaneGrabPillArt.swift", Floor::DrawingArt),
    ("Sources/SlopDeskSlate/SlatePlate.swift", Floor::DrawingArt),
    ("Sources/SlopDeskSlate/SlateVectorArt.swift", Floor::DrawingArt),
    ("Sources/SlopDeskSlate/SlateVectorDraw.swift", Floor::DrawingArt),
    (
        "Sources/SlopDeskTerminal/TerminalChromeAppearance.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskTransport/MessageChannel.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskTransport/Mux/RustHandle.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskVideoClient/SlopDeskVideoClient.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoClient/VideoClientTransport.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoProtocol/Settings/ConfigRevision.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskVideoProtocol/Settings/LentText.swift",
        Floor::CallingConvention,
    ),
    (
        "Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoProtocol/SlopDeskVideoProtocol.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoProtocol/VideoChannel.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskVideoProtocol/VideoProtocolError.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Connection/PermissionStatus.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Metadata/MetadataRequestRegistry.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Support/DeadlineLatch.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Support/DebugTrace.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Support/SidecarJSON.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Video/RemoteGUIDisplay.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Video/VideoWindowSeam.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/DesktopWindowPresentation.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/AutoHideTabsPanelMode.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/WindowSizeMode.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/AgentHookEnforcer.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/AppearanceApplier.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/OnLaunchBehavior.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/iOS/FocusGenerationGuard.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceCore/iOS/ManualRepeatScheduler.swift",
        Floor::SwiftRuntime,
    ),
    (
        "Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeIdentity.swift",
        Floor::Vocabulary,
    ),
    (
        "Sources/SlopDeskWorkspaceModel/Reading/ConnectionAlarm.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceModel/Reading/GitInk.swift",
        Floor::ShellDeDuplication,
    ),
    (
        "Sources/SlopDeskWorkspaceModel/Reading/ToastMarkRung.swift",
        Floor::ShellDeDuplication,
    ),
];

/// A file's Swift declarations, as face names: `enum X`, `struct X`, `final class X` at the head of
/// a line, behind any of the three access modifiers a sibling can still reach through.
///
/// `package` is not optional here, and reading only `public` was this rule's first bug: 184 of the
/// tree's 657 face declarations are `package`, which is the DEFAULT spelling for a type shared
/// inside one module family. Missing them booked pure forwarders — `SimulatorScreenLayout`, whose
/// every body is one call into `package enum DevicePanelGeometry` — as undelegated floor.
///
/// Nested types are deliberately missed — the leading-`^` anchor is what keeps this to the types a
/// sibling can NAME without qualifying, which is how a face is actually reached.
fn declared_types(code: &str, into: &mut BTreeSet<String>) {
    for line in code.lines() {
        let rest = ["public ", "package ", "internal "]
            .iter()
            .find_map(|modifier| line.strip_prefix(modifier))
            .unwrap_or(line);
        for keyword in ["enum ", "struct ", "final class "] {
            let Some(name) = rest.strip_prefix(keyword) else {
                continue;
            };
            let name: String = name.chars().take_while(|c| c.is_alphanumeric()).collect();
            if name.chars().next().is_some_and(char::is_uppercase) {
                into.insert(name);
            }
        }
    }
}

/// Whether `code` names `face` as a whole word rather than as a fragment of a longer identifier.
fn names(code: &str, face: &str) -> bool {
    let bytes = code.as_bytes();
    let mut from = 0;
    while let Some(offset) = code.get(from..).and_then(|rest| rest.find(face)) {
        let start = from + offset;
        let end = start + face.len();
        let before = start.checked_sub(1).and_then(|index| bytes.get(index).copied());
        let after = bytes.get(end).copied();
        let boundary =
            |byte: Option<u8>| byte.is_none_or(|byte| !byte.is_ascii_alphanumeric() && byte != b'_');
        if boundary(before) && boundary(after) {
            return true;
        }
        from = end;
    }
    false
}

/// Every Swift file under `Sources/` that decides something without reaching a door — non-UI, no
/// `slopdesk_` call, and naming no face that holds one.
fn candidates(tree: &Tree) -> BTreeSet<String> {
    let mut faces = BTreeSet::new();
    let mut swift = Vec::new();
    for (path, source) in tree.under("Sources") {
        if path.extension().is_none_or(|extension| extension != "swift") {
            continue;
        }
        let Some(path) = path.to_str() else {
            continue;
        };
        let code = source.statements();
        if code.contains("slopdesk_") {
            declared_types(code, &mut faces);
            continue;
        }
        swift.push((path.to_owned(), code));
    }

    swift
        .into_iter()
        .filter(|(_, code)| {
            !code.lines().any(|line| {
                let line = line.trim_start();
                line.starts_with("import AppKit") || line.starts_with("import UIKit")
            }) && !faces.iter().any(|face| names(code, face))
        })
        .map(|(path, _)| path)
        .collect()
}

/// The floor is exactly the census, in both directions.
///
/// A file OFF the list that qualifies is an unclassified decision — somebody has to say which of
/// [`Floor`]'s reasons it is, or move it. A file ON the list that no longer qualifies is stale
/// bookkeeping, and stale bookkeeping reads exactly like a satisfied entry, which is the failure
/// every ledger in this crate is written to make impossible.
///
/// One deletion rides along, because the census cannot see it. `HeadlessTerminalSurface` conformed
/// to `TerminalSurface`, which holds a door — so a resurrected copy would NAME a face and be
/// filtered out of the candidate set before any of the above ran. It is banned by path instead.
#[must_use]
pub fn the_swift_floor_is_exactly_what_is_booked(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[Claim::Absent {
        path: "Sources/SlopDeskTerminal/HeadlessTerminalSurface.swift",
        message: "{files} is back — the headless terminal client is rust/slopdesk-client since docs/63 G.5, \
                  and a non-rendering Swift byte sink is a second one (docs/67 §2)",
    }]);
    let found = candidates(tree);
    let booked: BTreeSet<&str> = FLOOR.iter().map(|&(path, _)| path).collect();

    for path in &found {
        report.fail_if(
            !booked.contains(path.as_str()),
            format!(
                "{path} decides something without reaching a door and is not booked in docs/67 §5 — \
                 classify it under one of the six reasons in `swift_floor::Floor`, or move the decision to \
                 Rust"
            ),
        );
    }
    for path in &booked {
        report.fail_if(
            !found.contains(*path),
            format!(
                "{path} is booked as docs/67 §5 floor but no longer qualifies (it gained a door, a face, a \
                 UI import, or was deleted) — drop the entry rather than leaving a ledger that reads as \
                 satisfied"
            ),
        );
    }
    report
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::tests::Fixture;

    /// A tree with one face, one file that reaches it, one UI file — and EVERY booked path, since
    /// the rule checks both directions and a fixture missing an entry would fail on the entry
    /// rather than on the drift the test is seeding.
    fn floor(fixture: &Fixture) -> &Fixture {
        for &(path, _) in super::FLOOR {
            fixture.write(path, "import Foundation\n");
        }
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/MirrorFold.swift",
                "import CSlopDeskFFI\npublic enum MirrorFold {\n    static func f() { \
                 slopdesk_mirror_fold() }\n}\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Reader.swift",
                "import Foundation\nfunc read() { MirrorFold.f() }\n",
            )
            .write(
                "Sources/SlopDeskMacUI/MacView.swift",
                "import AppKit\nfinal class MacView: NSView {}\n",
            )
    }

    #[test]
    fn a_file_that_reaches_a_face_is_not_a_candidate() {
        let fixture = Fixture::new("swift-floor-faces");
        floor(&fixture);
        let found = super::candidates(&fixture.tree());
        assert!(
            !found.contains("Sources/SlopDeskWorkspaceCore/Reader.swift"),
            "a file calling MirrorFold is delegated, not undelegated — the naive census's 43x error"
        );
        assert!(
            !found.contains("Sources/SlopDeskWorkspaceCore/MirrorFold.swift"),
            "the face itself holds the door"
        );
        assert!(
            !found.contains("Sources/SlopDeskMacUI/MacView.swift"),
            "an AppKit file is the presentation layer and is never a candidate"
        );
        assert_eq!(
            found.len(),
            super::FLOOR.len(),
            "which leaves exactly the booked files"
        );
    }

    #[test]
    fn a_new_undelegated_file_is_red_until_somebody_classifies_it() {
        let fixture = Fixture::new("swift-floor-new");
        floor(&fixture);
        assert!(
            super::the_swift_floor_is_exactly_what_is_booked(&fixture.tree())
                .violations()
                .iter()
                .all(|violation| !violation.contains("Rogue.swift")),
        );

        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Rogue.swift",
            "import Foundation\npublic enum Rogue {\n    static func decide() -> Bool { true }\n}\n",
        );
        let report = super::the_swift_floor_is_exactly_what_is_booked(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("Rogue.swift")),
            "a file deciding something with no door and no face must be classified or moved"
        );
    }

    /// The one thing the census provably cannot catch: a file whose conformance names a face.
    #[test]
    fn the_headless_surface_stays_deleted_even_though_it_would_name_a_face() {
        let fixture = Fixture::new("swift-floor-headless");
        floor(&fixture);
        let path = "Sources/SlopDeskTerminal/HeadlessTerminalSurface.swift";
        fixture.write(
            "Sources/SlopDeskTerminal/TerminalSurface.swift",
            "import CSlopDeskFFI\npublic struct TerminalSurface {\n    static func f() { \
             slopdesk_grid_rect() }\n}\n",
        );
        fixture.write(
            path,
            "import Foundation\nfinal class HeadlessTerminalSurface: TerminalSurface {}\n",
        );
        assert!(
            !super::candidates(&fixture.tree()).contains(path),
            "naming TerminalSurface hides it from the census — which is why the ban is by path"
        );
        assert!(
            super::the_swift_floor_is_exactly_what_is_booked(&fixture.tree())
                .violations()
                .iter()
                .any(|violation| violation.contains("HeadlessTerminalSurface")),
            "a second headless client in Swift must be red"
        );
    }

    /// The rule's own first bug: reading only `public` missed 184 of the tree's 657 faces, and
    /// booked pure forwarders into a `package enum` as undelegated floor.
    #[test]
    fn a_package_face_is_a_face() {
        let mut faces = BTreeSet::new();
        super::declared_types(
            "public enum A {}\npackage enum B {}\ninternal struct C {}\nfinal class D {}\npackage final \
             class E {}\n",
            &mut faces,
        );
        assert_eq!(
            faces.iter().map(String::as_str).collect::<Vec<_>>(),
            ["A", "B", "C", "D", "E"],
            "every access modifier a sibling can still reach through declares a face"
        );
    }

    #[test]
    fn a_face_name_inside_a_longer_identifier_is_not_a_reference() {
        assert!(super::names("MirrorFold.f()", "MirrorFold"));
        assert!(super::names("let x: [MirrorFold] = []", "MirrorFold"));
        assert!(
            !super::names("MirrorFoldingRules.f()", "MirrorFold"),
            "a prefix match would call half the tree delegated"
        );
        assert!(!super::names("SlopDeskMirrorFold.f()", "MirrorFold"));
    }

    #[test]
    fn a_stale_entry_is_a_violation_rather_than_a_pass() {
        let fixture = Fixture::new("swift-floor-stale");
        floor(&fixture);
        // The booked file gains a door, which is exactly what a successful port looks like — and
        // leaving it booked afterwards would keep the ledger green over a fact that changed.
        fixture.write(
            super::FLOOR[0].0,
            "import CSlopDeskFFI\npublic enum ArenaText {\n    static func f() { slopdesk_arena_text() \
             }\n}\n",
        );
        let report = super::the_swift_floor_is_exactly_what_is_booked(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains(super::FLOOR[0].0)),
            "a floor entry that no longer qualifies must be dropped, not left reading as satisfied"
        );
    }
}
