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
    // MARK: - The crossing

    /// Every zone crosses with its own word. WHICH word is `slopdesk_workspace::drop_zone`'s and
    /// pinned there; what only Swift can get wrong is a zone whose code never reaches the door, which
    /// would come back as an unlabelled blob rather than as a wrong one.
    func testEveryZoneCrossesWithItsOwnWord() {
        let labels = DropZone.allCases.map(DropZonePresentation.label)
        XCTAssertFalse(labels.contains(where: \.isEmpty), "a zone crossed unlabelled")
        XCTAssertEqual(Set(labels).count, labels.count, "two blobs that read alike are one target twice")
    }

    /// The marks come back as a DIAMETER and a point, and the clamp crosses with them: a pane
    /// mid-layout answers with a degenerate box, and a negative dimension must never reach a framework
    /// (SwiftUI logs it, AppKit draws garbage).
    func testTheMarksCrossClampedAndAtDiameter() {
        let size = CGSize(width: 800, height: 600)
        let shape = PaneDropZoneLayout(size: size).shape(for: .insertPath)
        let marks = DropZonePresentation.marks(.insertPath, in: size)
        XCTAssertEqual(marks.blobSize.width, shape.radiusX * 2, accuracy: 0.001, "drawn at DIAMETER")
        XCTAssertEqual(marks.labelCenter, shape.center, "a central circle labels its own centre")

        for zone in DropZone.allCases {
            let degenerate = DropZonePresentation.marks(zone, in: CGSize(width: -40, height: -10))
            XCTAssertGreaterThanOrEqual(degenerate.blobSize.width, 0, "\(zone) crossed inverted")
            XCTAssertGreaterThanOrEqual(degenerate.blobSize.height, 0, "\(zone) crossed inverted")
        }
    }

    /// The claim the label inset has to make is not "half an x-radius" — it is "the label is ON the
    /// pane". So this sweeps EVERY zone at three pane sizes and asserts the crossed point lands inside
    /// the box, which is what the clip rectangle would otherwise eat.
    func testEveryZoneLabelCrossesBackInsideThePaneBox() {
        let sizes = [
            CGSize(width: 400, height: 300),
            CGSize(width: 1600, height: 900),
            CGSize(width: 220, height: 180),
        ]
        for size in sizes {
            for zone in DropZone.allCases {
                let point = DropZonePresentation.marks(zone, in: size).labelCenter
                XCTAssertTrue(
                    (0...size.width).contains(point.x) && (0...size.height).contains(point.y),
                    "\(zone)'s label at \(point) falls outside the \(size) pane",
                )
            }
        }
    }

    /// The four ink verdicts come back from ONE call, so a renderer cannot draw a lit blob under a
    /// faded word. WHICH rung each state picks is the crate's; what is pinned here is that the rung
    /// BYTES resolve to distinct cases and that the ring's alpha rides along rather than being a branch
    /// either renderer writes out.
    func testTheWashCrossesWholeAndTheRungBytesResolveDistinctly() {
        let hovered = DropZonePresentation.wash(.splitRight, active: true, allowed: true)
        XCTAssertEqual(hovered.ink, .ok)
        XCTAssertEqual(hovered.labelInk, .primary)
        XCTAssertGreaterThan(hovered.strokeOpacity, 0, "the ring is what says release now")

        let resting = DropZonePresentation.wash(.splitRight, active: false, allowed: true)
        XCTAssertEqual(resting.ink, .accent)
        XCTAssertEqual(resting.labelInk, .secondary)
        XCTAssertEqual(resting.strokeOpacity, 0, "only the hovered zone rings")

        let barred = DropZonePresentation.wash(.newTab, active: false, allowed: false)
        XCTAssertEqual(barred.ink, .accentMuted, "a disabled blob must not stay green")
        XCTAssertEqual(barred.labelInk, .tertiary)
    }

    /// Every zone crosses with a wash at a drawable alpha — a rung that came back at zero would be a
    /// blob nobody can see, which reads as an overlay that failed to appear rather than as a wrong ink.
    func testEveryZoneCrossesWithADrawableWash() {
        for zone in DropZone.allCases {
            for allowed in [true, false] {
                let wash = DropZonePresentation.wash(zone, active: false, allowed: allowed)
                XCTAssertGreaterThan(wash.opacity, 0, "\(zone) allowed=\(allowed) crossed invisible")
                XCTAssertLessThanOrEqual(wash.opacity, 1)
            }
        }
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
