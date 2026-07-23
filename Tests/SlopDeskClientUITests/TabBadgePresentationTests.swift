// TabBadgePresentationTests — pins the pure view-side badge map. `StatusPresentation.tabBadge`
// resolves each `TabBadgeKind` to its otty reading (busy = the one muted spinner, awaiting = the
// raised hand, error = the warning triangle, completed = the check, finished = the dot, privilege =
// small text glyphs), and `tabBadgeLabel` gives every kind a distinct non-empty AX/tooltip string.
// Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. (Tints are deliberately
// NOT asserted — `Color` equality is provider-fragile; the reading CLASS is the load-bearing spec.)

import SFSafeSymbols
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    private func isSpinner(_ kind: TabBadgeKind) -> Bool {
        if case .spinner = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func symbol(of kind: TabBadgeKind) -> SFSymbol? {
        if case let .symbol(symbol, _) = StatusPresentation.tabBadge(kind) { return symbol }
        return nil
    }

    private func isDot(_ kind: TabBadgeKind) -> Bool {
        if case .dot = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func glyphText(of kind: TabBadgeKind) -> String? {
        if case let .glyph(text, _) = StatusPresentation.tabBadge(kind) { return text }
        return nil
    }

    /// Every busy tier — a working agent, an instrumented command, a plain busy shell — is the ONE
    /// muted spinner (otty does not colour-grade motion).
    func testEveryBusyTierIsTheSpinner() {
        XCTAssertTrue(isSpinner(.running))
        XCTAssertTrue(isSpinner(.commandRunning))
        XCTAssertTrue(isSpinner(.commandBusy))
    }

    /// `.awaitingInput` ⇒ the raised hand — distinct from both motion (an ignored question must not
    /// read as progress) and the error triangle (a question is not a failure).
    func testAwaitingIsTheRaisedHand() {
        XCTAssertEqual(symbol(of: .awaitingInput), .handRaisedFill)
        XCTAssertFalse(isSpinner(.awaitingInput))
    }

    /// `.error` ⇒ the warning triangle — static (it waits on you), never the hand.
    func testErrorIsTheTriangle() {
        XCTAssertEqual(symbol(of: .error), .exclamationmarkTriangleFill)
    }

    /// `.completed` (task done, unseen) ⇒ the check; `.finished` (an unseen shell finish) ⇒ the
    /// smaller dot — two distinct weights of "news", per `tab-badge.png`.
    func testDoneTierSplitsCheckAndDot() {
        XCTAssertEqual(symbol(of: .completed), .checkmarkCircleFill)
        XCTAssertTrue(isDot(.finished))
        XCTAssertFalse(isDot(.completed))
    }

    /// The privilege markers stay small text in the shell's dialect.
    func testPrivilegeMarkersAreTextGlyphs() {
        XCTAssertEqual(glyphText(of: .sudo), "#")
        XCTAssertEqual(glyphText(of: .caffeinate), "∞")
    }

    /// Every kind carries a non-empty, distinct AX/tooltip label so the icon-only badge is legible/testable.
    func testEveryKindHasADistinctNonEmptyLabel() {
        let kinds: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
            .caffeinate, .sudo,
        ]
        let labels = kinds.map { StatusPresentation.tabBadgeLabel($0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no blank badge labels")
        XCTAssertEqual(Set(labels).count, kinds.count, "labels are distinct per kind")
    }
}
