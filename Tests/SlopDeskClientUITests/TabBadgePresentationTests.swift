// TabBadgePresentationTests — pins E6 WI-4's pure view-side badge map. `StatusPresentation.tabBadge` resolves
// each `TabBadgeKind` to the correct glyph (spinner / accent dot / tinted SF-symbol), and `tabBadgeLabel`
// gives every kind a distinct non-empty AX/tooltip string. Headless VALUE assertions — no SwiftUI render, no
// video/Metal/SCStream. Each test fails on the pre-WI-4 code (the two helpers did not exist), so none is
// tautological. (Tints are deliberately NOT asserted here — `Color` equality is provider-fragile; the symbol
// NAME + glyph SHAPE are the load-bearing spec, locked by name, with the visual tint left to the snapshot.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    /// The SF-symbol name a kind maps to, or `nil` when it renders a bespoke shape (spinner / accent dot).
    private func symbolName(of kind: TabBadgeKind) -> String? {
        if case let .symbol(name, _) = StatusPresentation.tabBadge(kind) { return name }
        return nil
    }

    private func isWorking(_ kind: TabBadgeKind) -> Bool {
        if case .working = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isCommandBusy(_ kind: TabBadgeKind) -> Bool {
        if case .commandBusy = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// Whether the kind renders the STATIC dot (the settled vocabulary; no spinner, no symbol).
    private func isStaticDot(_ kind: TabBadgeKind) -> Bool {
        if case .dot = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// `.running` (a WORKING agent) ⇒ the live spinner-ring style, not an SF-symbol and not a static dot.
    func testRunningIsLiveSpinner() {
        XCTAssertTrue(isWorking(.running))
        XCTAssertNil(symbolName(of: .running), "the orbit dot is a bespoke shape, not an SF-symbol")
        XCTAssertFalse(isStaticDot(.running), "working is live — never the static dot")
    }

    /// `.commandRunning` (an OSC 9;4 progress load) ⇒ the QUIET muted spinner-ring, distinct from the
    /// agent's `.working` style — NOT a symbol, NOT a static dot.
    func testCommandRunningIsMutedSpinner() {
        XCTAssertTrue(isCommandBusy(.commandRunning))
        XCTAssertFalse(isWorking(.commandRunning), "a program's progress must not use the agent style")
        XCTAssertNil(symbolName(of: .commandRunning))
    }

    /// `.commandBusy` (a plain busy shell) ⇒ the bare STATIC muted dot — no spinner (the ring is earned
    /// by an explicit progress report / a working agent), no symbol.
    func testCommandBusyIsBareStaticDot() {
        XCTAssertTrue(isStaticDot(.commandBusy))
        XCTAssertFalse(isCommandBusy(.commandBusy), "a plain busy shell never spins")
        XCTAssertNil(symbolName(of: .commandBusy))
    }

    /// The settled vocabulary is ALL static dots (2026-07-10 UI feedback: no character glyphs next to
    /// dots — the old checkmark/triangle/hand are gone): blocked/failed red, done-unread blue,
    /// clean-finish flash green. Tints are left to the snapshot (Color equality is provider-fragile);
    /// the SHAPE class is the load-bearing pin.
    func testSettledKindsAreStaticDotsNotCharacterGlyphs() {
        for kind in [TabBadgeKind.awaitingInput, .error, .finished, .completed] {
            XCTAssertTrue(isStaticDot(kind), "\(kind): the settled vocabulary is a static dot")
            XCTAssertNil(symbolName(of: kind), "\(kind): no character glyph in the dot vocabulary")
        }
    }

    /// `.caffeinate` ⇒ the coffee cup (a sleep-blocking session at rest).
    func testCaffeinateIsCoffeeSymbol() {
        XCTAssertEqual(symbolName(of: .caffeinate), "cup.and.saucer.fill")
    }

    /// `.sudo` ⇒ the shield (a privileged session at rest).
    func testSudoIsShieldSymbol() {
        XCTAssertEqual(symbolName(of: .sudo), "shield.lefthalf.filled")
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

    // MARK: - Progress readout (E14/K1 WI-2 — the OSC 9;4 taskbar-style determinate percent)

    /// Only a DETERMINATE (`9;4;1;<pct>`) state has a "taskbar" percent readout; an indeterminate spinner /
    /// an error / no-progress show no number. Reverting `progressPercentLabel` to always-nil fails the
    /// determinate cases.
    func testProgressPercentLabelOnlyForDeterminate() {
        XCTAssertEqual(StatusPresentation.progressPercentLabel(.determinate(percent: 40)), "40%")
        XCTAssertEqual(StatusPresentation.progressPercentLabel(.determinate(percent: 0)), "0%")
        XCTAssertEqual(StatusPresentation.progressPercentLabel(.determinate(percent: 100)), "100%")
        XCTAssertNil(StatusPresentation.progressPercentLabel(.indeterminate), "a spinner shows no percent")
        XCTAssertNil(
            StatusPresentation.progressPercentLabel(.error(percent: 80)),
            "an error shows the alert, not a number",
        )
        XCTAssertNil(StatusPresentation.progressPercentLabel(nil), "no progress → no readout")
    }

    /// The full presentation mapping: `nil` → none, indeterminate → spinner, determinate → a 0…1 bar fraction
    /// plus the "NN%" label, error → error.
    func testProgressPresentationMapping() {
        XCTAssertEqual(StatusPresentation.progressPresentation(nil), .none)
        XCTAssertEqual(StatusPresentation.progressPresentation(.indeterminate), .spinner)
        XCTAssertEqual(StatusPresentation.progressPresentation(.error(percent: 80)), .error)
        XCTAssertEqual(
            StatusPresentation.progressPresentation(.determinate(percent: 25)),
            .determinate(fraction: 0.25, label: "25%"),
        )
    }
}
