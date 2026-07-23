// TabBadgePresentationTests — pins the pure view-side badge map. `StatusPresentation.tabBadge` resolves
// each `TabBadgeKind` to its ONE-SHAPE ring reading (working = dashed ring, awaiting = ring+halo,
// done = ring+check, error = ring+cross, progress = muted ring, privilege = glyph-in-ring; the plain
// busy shell keeps the sub-ring micro-dot), and `tabBadgeLabel` gives every kind a distinct non-empty
// AX/tooltip string. Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. Each test
// fails if the two helpers don't exist, so none is tautological. (Tints are deliberately NOT asserted
// here — `Color` equality is provider-fragile; the reading CLASS is the load-bearing spec, with the
// visual tint left to the snapshot.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    /// The SF-symbol name a kind carries inside its ring, or `nil` for the pure ring readings.
    private func glyphName(of kind: TabBadgeKind) -> String? {
        if case let .ringGlyph(name, _) = StatusPresentation.tabBadge(kind) { return name }
        return nil
    }

    private func isWorkingRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringWorking = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isAwaitingRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringAwaiting = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isDoneRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringDone = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isErrorRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringError = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isProgressRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringProgress = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// Whether the kind renders the bare STATIC micro-dot (the quiet busy-shell tier; no ring).
    private func isStaticDot(_ kind: TabBadgeKind) -> Bool {
        if case .dot = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// `.running` (a WORKING agent) ⇒ the dashed working ring — the only spinning-class reading;
    /// never a static dot, never a glyph.
    func testRunningIsTheWorkingRing() {
        XCTAssertTrue(isWorkingRing(.running))
        XCTAssertNil(glyphName(of: .running), "the working ring is a bespoke reading, not an SF-symbol")
        XCTAssertFalse(isStaticDot(.running), "working is live — never the static dot")
    }

    /// `.awaitingInput` ⇒ the awaiting ring (ring + centre dot + halo) — distinct from BOTH the
    /// working ring (an ignored question must not read as progress) and the error ring (a question is
    /// not a failure).
    func testAwaitingIsItsOwnRing() {
        XCTAssertTrue(isAwaitingRing(.awaitingInput))
        XCTAssertFalse(isWorkingRing(.awaitingInput))
        XCTAssertFalse(isErrorRing(.awaitingInput))
    }

    /// `.commandRunning` (an OSC 9;4 progress load) ⇒ the muted progress ring — NOT the agent's
    /// working ring (command ≠ agent), not a dot, not a glyph.
    func testCommandRunningIsTheMutedProgressRing() {
        XCTAssertTrue(isProgressRing(.commandRunning))
        XCTAssertFalse(isWorkingRing(.commandRunning), "a program's progress must not use the agent reading")
        XCTAssertNil(glyphName(of: .commandRunning))
    }

    /// `.commandBusy` (a plain busy shell) ⇒ the bare STATIC muted micro-dot — no ring (the ring is
    /// earned by an agent or an explicit progress report).
    func testCommandBusyIsBareStaticDot() {
        XCTAssertTrue(isStaticDot(.commandBusy))
        XCTAssertFalse(isProgressRing(.commandBusy), "a plain busy shell earns no ring")
        XCTAssertNil(glyphName(of: .commandBusy))
    }

    /// The done tier — the flash AND the unread marker — is ONE reading: the ring + check. The unread
    /// state must never decay to an at-rest accent dot (colour = live data; a seen row shows nothing).
    func testDoneTierIsTheCheckRing() {
        XCTAssertTrue(isDoneRing(.completed))
        XCTAssertTrue(isDoneRing(.finished))
    }

    /// `.error` ⇒ the ring + cross — static (it waits on you), never the awaiting reading.
    func testErrorIsTheCrossRing() {
        XCTAssertTrue(isErrorRing(.error))
        XCTAssertFalse(isAwaitingRing(.error))
    }

    /// `.caffeinate` ⇒ the coffee cup inside the muted ring (a sleep-blocking session at rest).
    func testCaffeinateIsCoffeeGlyphInRing() {
        XCTAssertEqual(glyphName(of: .caffeinate), "cup.and.saucer.fill")
    }

    /// `.sudo` ⇒ the shield inside the muted ring (a privileged session at rest).
    func testSudoIsShieldGlyphInRing() {
        XCTAssertEqual(glyphName(of: .sudo), "shield.lefthalf.filled")
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

    // MARK: - Progress readout (the OSC 9;4 taskbar-style determinate percent)

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
