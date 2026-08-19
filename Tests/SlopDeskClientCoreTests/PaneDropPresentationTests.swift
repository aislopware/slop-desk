// PaneDropPresentationTests — the drop overlay's WORDING, its half/half partition, its label geometry and
// its ink verdict, none of which had a single test while they lived inside a SwiftUI `View`.
//
// That is the whole reason this file exists. Everything asserted below is about to have a SECOND renderer:
// an AppKit overlay must print the same five labels, tint the same two zones green, inset the same two edge
// labels and fade the same disabled blob. A copy string drifts loudly — somebody sees "Open in place" on one
// platform — but a partition or an alpha drifts SILENTLY, and the only defence against that is that both
// halves read one value and one value is pinned.
//
// The gate half is pinned for a sharper reason: `acceptsDrag` and `hoverZone` are the two places a drop can
// be let in when it must not be. A read-only pane that accepts a drag shows an affordance it will then
// refuse, and a hover that lights a DISALLOWED zone arms a release that resolves to no action at all.

import CoreGraphics
import Foundation
import SlopDeskWorkspaceCore
import UniformTypeIdentifiers
import XCTest
@testable import SlopDeskClientCore

final class PaneDropPresentationTests: XCTestCase {
    // MARK: - The five labels

    /// Every zone is spelled, exactly once, in Title Case — and "Open In-Place" keeps the capital I and the
    /// hyphen it has in the ⌘-click menu. A `CaseIterable` sweep rather than five asserts, so a SIXTH zone
    /// added to the enum cannot reach the overlay unlabelled.
    func testEveryZoneHasItsLabel() {
        let expected: [DropZone: String] = [
            .newTab: "New Tab",
            .insertPath: "Insert Path",
            .openInPlace: "Open In-Place",
            .splitLeft: "Split Left",
            .splitRight: "Split Right",
        ]
        for zone in DropZone.allCases {
            XCTAssertEqual(DropZonePresentation.label(zone), expected[zone] ?? "", "label for \(zone)")
        }
        let labels = DropZone.allCases.map(DropZonePresentation.label)
        XCTAssertEqual(Set(labels).count, labels.count, "two zones sharing a label would be unreadable")
    }

    // MARK: - The terminal-half / pane-half partition

    /// The green half is the two zones that act on the TERMINAL (a rooted new tab, an inject into the live
    /// PTY); the blue half is the three that act on the PANE TREE. Asserted as a partition — every zone on
    /// exactly one side — because the failure that matters is a zone sliding across, not the set's size.
    func testTerminalHalfPartitionsTheZones() {
        XCTAssertEqual(DropZonePresentation.terminalHalf, [.newTab, .insertPath])
        let paneHalf = Set(DropZone.allCases).subtracting(DropZonePresentation.terminalHalf)
        XCTAssertEqual(paneHalf, [.openInPlace, .splitLeft, .splitRight])
        XCTAssertTrue(
            DropZonePresentation.terminalHalf.isDisjoint(with: paneHalf),
            "a zone on both sides would tint green AND accent depending on which branch ran first",
        )
    }

    // MARK: - Label geometry

    /// The three central circles put their label at the blob's own centre.
    func testCentralZoneLabelsSitAtTheBlobCentre() {
        let shape = DropZoneShape(center: CGPoint(x: 200, y: 120), radiusX: 40, radiusY: 40)
        let size = CGSize(width: 400, height: 300)
        for zone in [DropZone.newTab, .insertPath, .openInPlace] {
            XCTAssertEqual(
                DropZonePresentation.labelCenter(zone, shape: shape, in: size), shape.center,
                "\(zone) is a central circle — nothing to inset from",
            )
        }
    }

    /// The two edge ellipses have their true centre ON the pane edge (half the blob is clipped away), so a
    /// centred label would be half off-pane. The inset is half the x-radius IN from the edge, and it must
    /// leave the label inside the pane box — which is what the range assert checks, not just the arithmetic.
    func testEdgeZoneLabelsAreInsetFromTheirEdge() {
        let size = CGSize(width: 400, height: 300)
        let left = DropZoneShape(center: CGPoint(x: 0, y: 150), radiusX: 60, radiusY: 140)
        let right = DropZoneShape(center: CGPoint(x: 400, y: 150), radiusX: 60, radiusY: 140)

        let leftLabel = DropZonePresentation.labelCenter(.splitLeft, shape: left, in: size)
        XCTAssertEqual(leftLabel, CGPoint(x: 30, y: 150))
        XCTAssertGreaterThan(leftLabel.x, left.center.x, "the left label is inset INWARD from the edge")

        let rightLabel = DropZonePresentation.labelCenter(.splitRight, shape: right, in: size)
        XCTAssertEqual(rightLabel, CGPoint(x: 370, y: 150))
        XCTAssertLessThan(rightLabel.x, right.center.x, "the right label is inset INWARD from the edge")
        XCTAssertTrue(
            (0...size.width).contains(rightLabel.x),
            "an edge label outside the pane box is a label the clip rectangle eats",
        )
    }

    /// The claim the inset has to make is not "half an x-radius" — it is "the label is ON the pane". So this
    /// sweeps EVERY zone against the real ``PaneDropZoneLayout`` (the same Rust shapes the overlay draws,
    /// not hand-written ones) at three pane sizes and asserts the point lands inside the box. A sixth zone
    /// hugging an edge is now caught twice over: `labelCenter` is exhaustive, so the compiler demands an
    /// answer for it, and this demands that the answer be somewhere the clip rectangle will not eat.
    func testEveryZoneLabelLandsInsideThePaneBox() {
        let sizes = [
            CGSize(width: 400, height: 300),
            CGSize(width: 1600, height: 900),
            CGSize(width: 220, height: 180),
        ]
        for size in sizes {
            let layout = PaneDropZoneLayout(size: size)
            for zone in DropZone.allCases {
                let point = DropZonePresentation.labelCenter(zone, shape: layout.shape(for: zone), in: size)
                XCTAssertTrue(
                    (0...size.width).contains(point.x) && (0...size.height).contains(point.y),
                    "\(zone)'s label at \(point) falls outside the \(size) pane — the clip rectangle eats it",
                )
            }
        }
    }

    /// A pane mid-layout answers with a degenerate box; a NEGATIVE dimension must never reach a framework
    /// (SwiftUI logs it, AppKit draws garbage). The clamp is the overlay's, so it is pinned here.
    func testBlobSizeClampsAwayFromNegativeDimensions() {
        let ok = DropZonePresentation.blobSize(for: .init(center: .zero, radiusX: 10, radiusY: 25))
        XCTAssertEqual(ok, CGSize(width: 20, height: 50), "a blob is drawn at DIAMETER, not radius")
        let degenerate = DropZonePresentation.blobSize(for: .init(center: .zero, radiusX: -4, radiusY: -9))
        XCTAssertEqual(degenerate, .zero, "a negative radius collapses to nothing, never inverts")
    }

    // MARK: - The ink verdict

    /// The hovered zone glows status-green at half strength REGARDLESS of which half it is on — the active
    /// branch runs before the partition, so a hovered Split-Right is as green as a hovered New Tab.
    func testActiveZoneGlowsOkOnBothHalves() {
        for zone in DropZone.allCases {
            XCTAssertEqual(
                DropZonePresentation.tint(zone, active: true, allowed: true),
                DropZoneTint(ink: .ok, opacity: 0.5),
                "the hover glow is one value for every zone (\(zone))",
            )
        }
    }

    /// A DISABLED zone is the muted neutral, and it beats the partition: a disallowed New Tab must not stay
    /// green just because it sits on the terminal half. (`active` cannot be true here — the gate refuses to
    /// activate a disallowed zone — so only the `allowed: false` arm is meaningful.)
    func testDisallowedZoneIsMutedOnBothHalves() {
        for zone in DropZone.allCases {
            XCTAssertEqual(
                DropZonePresentation.tint(zone, active: false, allowed: false),
                DropZoneTint(ink: .accentMuted, opacity: 1),
                "a disabled blob is a barely-there neutral (\(zone))",
            )
        }
    }

    /// At rest the partition decides: the terminal half washes green, the pane half washes accent, and the
    /// two alphas differ (green reads heavier at equal alpha, which is why they were tuned apart).
    func testRestingTintFollowsThePartition() {
        for zone in DropZonePresentation.terminalHalf {
            XCTAssertEqual(
                DropZonePresentation.tint(zone, active: false, allowed: true),
                DropZoneTint(ink: .ok, opacity: 0.14),
                "the terminal half is green even at rest (\(zone))",
            )
        }
        for zone in Set(DropZone.allCases).subtracting(DropZonePresentation.terminalHalf) {
            XCTAssertEqual(
                DropZonePresentation.tint(zone, active: false, allowed: true),
                DropZoneTint(ink: .accent, opacity: 0.10),
                "the pane half is accent at rest (\(zone))",
            )
        }
    }

    /// The label tracks its blob: bright on the hovered zone, secondary while allowed, faded when the zone
    /// is inert — so text never announces a target that cannot be dropped on.
    func testLabelInkTracksTheZoneState() {
        XCTAssertEqual(DropZonePresentation.labelInk(active: true, allowed: true), .primary)
        XCTAssertEqual(DropZonePresentation.labelInk(active: false, allowed: true), .secondary)
        XCTAssertEqual(DropZonePresentation.labelInk(active: false, allowed: false), .tertiary)
    }

    // MARK: - The entry gate

    /// The accepted-type list and the ``DropPayloadClassifier`` precedence are the same three groups in the
    /// same order — a type advertised but not classified would show an overlay that can resolve to nothing.
    func testAcceptedTypesAreTheThreeClassifiedGroups() {
        XCTAssertEqual(PaneDropGate.acceptedTypes, [.fileURL, .url, .text])
    }

    /// Validate-then-drop: a drag gets in only when the payload is supported and the pane is not read-only.
    /// The read-only arm is the one with teeth — it is why the affordance never appears on a locked pane —
    /// and `nil` (a chooser pane, where read-only does not apply) must NOT read as read-only.
    ///
    /// The `enabled:` arm this suite used to assert is GONE (increment 57b). It was `staticMirror`'s last
    /// caller: after 56d deleted that path the only value the parameter could take was `true`, and the one
    /// case pinned here — "a static-mirror pass never engages the live overlay" — was the suite keeping a
    /// dead branch alive, which is the exact finding 56d recorded about the flag itself.
    func testAcceptsDragNeedsEveryConditionAndTreatsNilAsWritable() {
        XCTAssertTrue(PaneDropGate.acceptsDrag(carriesSupportedType: true, isReadOnly: false))
        XCTAssertTrue(
            PaneDropGate.acceptsDrag(carriesSupportedType: true, isReadOnly: nil),
            "a chooser pane has no read-only flag — that is not a refusal",
        )
        XCTAssertFalse(
            PaneDropGate.acceptsDrag(carriesSupportedType: true, isReadOnly: true),
            "a read-only pane refuses every drop (parity with the paste halt)",
        )
        XCTAssertFalse(
            PaneDropGate.acceptsDrag(carriesSupportedType: false, isReadOnly: false),
            "an unsupported drag is declined, not crashed on",
        )
    }

    /// A hover lights a zone only when the dragged content can act on it. Both refusals return `nil`, which
    /// is what each framework turns into its FORBIDDEN proposal — so a release over a gap or over a disabled
    /// blob never reaches the commit path at all.
    func testHoverZoneLightsOnlyAllowedZones() {
        let allowed: Set<DropZone> = [.insertPath, .splitLeft]
        XCTAssertEqual(PaneDropGate.hoverZone(.insertPath, allowedZones: allowed), .insertPath)
        XCTAssertNil(PaneDropGate.hoverZone(.newTab, allowedZones: allowed), "a disabled zone never lights")
        XCTAssertNil(PaneDropGate.hoverZone(nil, allowedZones: allowed), "a gap between blobs lights nothing")
        XCTAssertNil(PaneDropGate.hoverZone(.insertPath, allowedZones: []), "nothing is allowed before classify")
    }

    // MARK: - The pasteboard precedence

    /// A Finder file drag surfaces on the `.url` group too. Keeping only TRUE web URLs there is what stops
    /// one dragged folder from also counting as a URL — which would offer the URL zones for a folder.
    func testWebURLFilterDropsFileURLs() throws {
        XCTAssertNil(
            PaneDropProviderPolicy.webURLString(for: URL(fileURLWithPath: "/Users/me/project")),
            "a file URL on the .url group is the SAME item the file group already took",
        )
        let web = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(PaneDropProviderPolicy.webURLString(for: web), "https://example.com/a")
    }

    /// The mirror rule on the file group: a non-file URL that shows up there is not a file entry.
    func testFileEntryRejectsANonFileURL() throws {
        let web = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertNil(PaneDropProviderPolicy.fileEntry(for: web))
        let file = URL(fileURLWithPath: "/Users/me/notes.txt")
        XCTAssertEqual(PaneDropProviderPolicy.fileEntry(for: file)?.path, "/Users/me/notes.txt")
    }

    /// The text group is loaded only when neither of the other two produced anything — the classifier's
    /// file → url → text precedence would discard it otherwise, making the provider round-trip unreadable.
    func testTextIsLoadedOnlyWhenNothingElseResolved() {
        XCTAssertTrue(PaneDropProviderPolicy.needsTextLoad(files: [], urls: []))
        XCTAssertFalse(
            PaneDropProviderPolicy.needsTextLoad(files: [.init(path: "/tmp/a", isDirectory: false)], urls: []),
            "a file already won the precedence — the snippet behind it can never be read",
        )
        XCTAssertFalse(PaneDropProviderPolicy.needsTextLoad(files: [], urls: ["https://example.com"]))
    }

    /// The precedence itself is ``DropPayloadClassifier``'s and stays there; this pins that the door onto it
    /// really does route through it (file beats url beats text, and a folder classifies as `.folder`).
    func testContentRoutesThroughTheClassifierPrecedence() {
        XCTAssertEqual(
            PaneDropProviderPolicy.content(
                files: [.init(path: "/Users/me/project", isDirectory: true)],
                urls: ["https://example.com"],
                text: "hello",
            ),
            .folder("/Users/me/project"),
        )
        XCTAssertEqual(
            PaneDropProviderPolicy.content(files: [], urls: ["https://example.com"], text: "hello"),
            .url("https://example.com"),
        )
        XCTAssertEqual(PaneDropProviderPolicy.content(files: [], urls: [], text: "hello"), .text("hello"))
        XCTAssertNil(
            PaneDropProviderPolicy.content(files: [], urls: [], text: nil),
            "an empty drag classifies to nothing — validate-then-drop, never a crash",
        )
    }
}
