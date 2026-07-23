// TabBadgePresentationTests — pins the pure view-side badge map. `StatusPresentation.tabBadge` resolves
// each `TabBadgeKind` to its ONE-SHAPE fill-fraction reading (working = dashed `◌`, awaiting =
// ring+dot `◉`, done/error = the solid disc + knockout, busy = hollow `○`, OSC 9;4 = ring + pie at
// the real fraction, privilege = glyph-in-ring), and `tabBadgeLabel` gives every kind a distinct
// non-empty AX/tooltip string. Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream.
// Each test fails if the two helpers don't exist, so none is tautological. (Tints are deliberately NOT
// asserted here — `Color` equality is provider-fragile; the reading CLASS is the load-bearing spec,
// with the visual tint left to the snapshot.)

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

    /// The pie reading's carried fraction, or `.none` when the kind isn't the pie at all (a `nil`
    /// fraction inside the pie is a real state — indeterminate — so the two must stay distinguishable).
    private func pieFraction(of kind: TabBadgeKind, progressFraction: Double? = nil) -> Double?? {
        if case let .ringPie(fraction, _) = StatusPresentation.tabBadge(
            kind, progressFraction: progressFraction,
        ) { return fraction }
        return Double??.none
    }

    /// Whether the kind renders the hollow ring `○` (the quiet busy-shell tier).
    private func isHollowRing(_ kind: TabBadgeKind) -> Bool {
        if case .ringHollow = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// `.running` (a WORKING agent) ⇒ the dashed working `◌` — the only reading that moves at all;
    /// never the hollow command ring, never a glyph.
    func testRunningIsTheWorkingRing() {
        XCTAssertTrue(isWorkingRing(.running))
        XCTAssertNil(glyphName(of: .running), "the working ring is a bespoke reading, not an SF-symbol")
        XCTAssertFalse(isHollowRing(.running), "working is the agent's dashed ring, not the command ring")
    }

    /// `.awaitingInput` ⇒ the awaiting ring (ring + centre dot + halo) — distinct from BOTH the
    /// working ring (an ignored question must not read as progress) and the error ring (a question is
    /// not a failure).
    func testAwaitingIsItsOwnRing() {
        XCTAssertTrue(isAwaitingRing(.awaitingInput))
        XCTAssertFalse(isWorkingRing(.awaitingInput))
        XCTAssertFalse(isErrorRing(.awaitingInput))
    }

    /// `.commandRunning` (an OSC 9;4 progress load) ⇒ the pie reading carrying the REAL fraction
    /// through untouched — NOT the agent's working ring (command ≠ agent), not a glyph. An
    /// indeterminate report (no fraction) stays the pie reading with a `nil` sweep (the bare ring).
    func testCommandRunningIsThePieAtTheRealFraction() {
        XCTAssertEqual(pieFraction(of: .commandRunning, progressFraction: 0.68), .some(.some(0.68)))
        XCTAssertEqual(pieFraction(of: .commandRunning), .some(.none), "indeterminate = pie with no sweep")
        XCTAssertFalse(isWorkingRing(.commandRunning), "a program's progress must not use the agent reading")
        XCTAssertNil(glyphName(of: .commandRunning))
    }

    /// `.commandBusy` (a plain busy shell) ⇒ the hollow ring `○` — running, uninstrumented; the
    /// fraction input is ignored (no pie without an explicit progress report).
    func testCommandBusyIsTheHollowRing() {
        XCTAssertTrue(isHollowRing(.commandBusy))
        XCTAssertEqual(
            pieFraction(of: .commandBusy, progressFraction: 0.5), Double??.none,
            "a plain busy shell never sweeps a pie",
        )
        XCTAssertNil(glyphName(of: .commandBusy))
    }

    /// The pie fraction is consumed ONLY by `.commandRunning` — handing a fraction to any other kind
    /// must not bend its reading (the working agent stays dashed, done stays the solid disc).
    func testFractionDoesNotLeakIntoOtherReadings() {
        if case .ringPie = StatusPresentation.tabBadge(.running, progressFraction: 0.4) {
            XCTFail("the agent reading must ignore a stray fraction")
        }
        XCTAssertTrue(isDoneRing(.finished))
        if case .ringPie = StatusPresentation.tabBadge(.finished, progressFraction: 0.4) {
            XCTFail("a terminal reading must ignore a stray fraction")
        }
    }

    // MARK: - The working flicker (the one animation in the system)

    /// The stepped duty-cycle: full strength on the high plateau, the 0.75 floor on the low one, and
    /// the ramp between them QUANTIZED to hard steps (a ramp instant must sit strictly between the
    /// plateaus, on a 1/10 grid — no continuous easing). Anchored to the fixed epoch, so the phase is
    /// deterministic.
    func testWorkingFlickerIsSteppedDutyCycle() {
        func at(_ phase: Double) -> Double {
            StatusRing.flickerOpacity(at: Date(timeIntervalSinceReferenceDate: phase * 3.4))
        }
        XCTAssertEqual(at(0.0), 1.0)
        XCTAssertEqual(at(0.35), 1.0, "the high plateau holds through 36%")
        XCTAssertEqual(at(0.60), 0.75, "the low plateau holds 50%…86%")
        XCTAssertEqual(at(0.85), 0.75)
        let ramp = at(0.43)
        XCTAssertLessThan(ramp, 1.0)
        XCTAssertGreaterThan(ramp, 0.75)
        // The quantization: a mid-ramp value lands exactly on the 1/10 step grid between the plateaus.
        let step = (1.0 - ramp) / 0.25 * 10
        XCTAssertEqual(step, step.rounded(), accuracy: 1e-9, "ramp frames are hard 1/10 steps")
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
