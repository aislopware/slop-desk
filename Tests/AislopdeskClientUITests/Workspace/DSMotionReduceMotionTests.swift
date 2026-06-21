import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the tokenized ``DSMotion`` curves and the Reduce-Motion fallback. Under Reduce Motion the spring /
/// translate tokens fall back to the ~0.001s crossfade (so motion-sensitive users get an instant state
/// swap, not the overshoot); otherwise the supplied animation passes through. `Animation` is `Equatable`,
/// so these are exact value comparisons.
final class DSMotionReduceMotionTests: XCTestCase {
    #if canImport(SwiftUI)
    /// `resolve` returns the near-instant crossfade when Reduce Motion is on.
    func testResolveReturnsCrossfadeWhenReduceMotion() {
        XCTAssertEqual(DSMotion.resolve(DSMotion.select, reduceMotion: true), DSMotion.reducedCrossfade)
        XCTAssertEqual(DSMotion.resolve(DSMotion.layout, reduceMotion: true), DSMotion.reducedCrossfade)
        XCTAssertEqual(DSMotion.resolve(DSMotion.appear, reduceMotion: true), DSMotion.reducedCrossfade)
    }

    /// `resolve` passes the supplied animation through when Reduce Motion is off.
    func testResolveReturnsAnimationWhenNotReduceMotion() {
        XCTAssertEqual(DSMotion.resolve(DSMotion.select, reduceMotion: false), DSMotion.select)
        XCTAssertEqual(DSMotion.resolve(DSMotion.hover, reduceMotion: false), DSMotion.hover)
    }

    /// The reduced crossfade is the 0.001s easeInOut (distinct from the spring), so a Reduce-Motion swap is
    /// effectively instant.
    func testReducedCrossfadeIsDistinctFromSpring() {
        XCTAssertEqual(DSMotion.reducedCrossfade, .easeInOut(duration: 0.001))
        XCTAssertNotEqual(DSMotion.reducedCrossfade, DSMotion.select)
        XCTAssertNotEqual(DSMotion.reducedCrossfade, DSMotion.layout)
    }

    /// The token curves are the spec values (pins a re-tune as a deliberate change). `attention` is the house
    /// `repeatForever` breathe shared by the working-dot / attention-ring / glitch-caret pulses — pinned here
    /// for completeness even though those sites gate it via the `!reduceMotion` guard (NOT `resolve`), since a
    /// `repeatForever` cannot be made near-instant (the reduced fallback is to rest steady, not to crossfade).
    func testTokenCurvesPinned() {
        XCTAssertEqual(DSMotion.hover, .easeOut(duration: 0.13))
        XCTAssertEqual(DSMotion.appear, .easeOut(duration: 0.16))
        XCTAssertEqual(DSMotion.dismiss, .easeIn(duration: 0.10))
        XCTAssertEqual(DSMotion.select, .spring(response: 0.22, dampingFraction: 0.82))
        XCTAssertEqual(DSMotion.layout, .spring(response: 0.20, dampingFraction: 0.9))
        XCTAssertEqual(DSMotion.attention, .easeInOut(duration: 0.9).repeatForever(autoreverses: true))
    }

    /// `resolve` also collapses the `dismiss` token (the P5 overlay-dismiss site) under Reduce Motion, and
    /// passes the spring tokens through when off — the P5 adoption uses `select`/`layout`/`appear`/`dismiss`.
    func testResolveAllAdoptedTokens() {
        XCTAssertEqual(DSMotion.resolve(DSMotion.dismiss, reduceMotion: true), DSMotion.reducedCrossfade)
        XCTAssertEqual(DSMotion.resolve(DSMotion.hover, reduceMotion: true), DSMotion.reducedCrossfade)
        XCTAssertEqual(DSMotion.resolve(DSMotion.layout, reduceMotion: false), DSMotion.layout)
        XCTAssertEqual(DSMotion.resolve(DSMotion.appear, reduceMotion: false), DSMotion.appear)
        XCTAssertEqual(DSMotion.resolve(DSMotion.dismiss, reduceMotion: false), DSMotion.dismiss)
    }
    #endif
}
