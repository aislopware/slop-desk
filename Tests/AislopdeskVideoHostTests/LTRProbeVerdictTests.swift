#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// WF-7 (#9) PURE LTR-probe verdict mapping. The probe's VTCompressionSession is HW-gated and never
/// instantiated here (it HANGS headlessly — same rule as the rest of `VideoEncoder`); this covers
/// ONLY the pure `interpretLTRProbe` status→verdict logic that turns the captured OSStatus values
/// into the single-word verdict logged on the Mac Studio host.
final class LTRProbeVerdictTests: XCTestCase {

    // EnableLTR never reached (session-create or pixel-buffer alloc failed first) → unknown (re-run).
    func testEnableNotReachedIsUnknown() {
        XCTAssertEqual(VideoEncoder.interpretLTRProbe(enableStatus: nil), .unknown)
    }

    // EnableLTR rejected (the EXPECTED outcome on HEVC since it shipped H.264-only) → unsupported.
    // -12900 is kVTPropertyNotSupportedErr; any non-noErr EnableLTR is unsupported.
    func testEnableRejectedIsUnsupported() {
        XCTAssertEqual(VideoEncoder.interpretLTRProbe(enableStatus: -12900), .unsupported)
        XCTAssertEqual(VideoEncoder.interpretLTRProbe(enableStatus: -1), .unsupported)
    }

    // EnableLTR took but the seeding keyframe encode failed → can't establish an LTR ref → unsupported.
    func testKeyframeEncodeFailureIsUnsupported() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(enableStatus: noErr, keyframeEncodeStatus: -12909),
            .unsupported)
    }

    // EnableLTR + the documented kCFBooleanTrue ForceLTRRefresh form took AND a real LTR frame carried
    // the RequireLTRAcknowledgementToken attachment → supported (the only fully-trustworthy verdict).
    func testDocumentedBooleanFormWithAckTokenSupported() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(
                enableStatus: noErr, keyframeEncodeStatus: noErr,
                forceLTRBooleanStatus: noErr, sawAckToken: true),
            .supported)
    }

    // API accepted the documented form but NO LTR ack-token was emitted → ambiguous, NOT supported.
    // (Guards against over-reporting "supported" on a no-op property accept — the WF-7 audit finding.)
    func testBooleanAcceptedButNoAckTokenIsAmbiguous() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(
                enableStatus: noErr, keyframeEncodeStatus: noErr,
                forceLTRBooleanStatus: noErr, sawAckToken: false),
            .ambiguous)
    }

    // Boolean form rejected but the CFNumber retry took → ambiguous (non-documented form), regardless
    // of the ack-token (the documented contract did not hold, so it is never "supported").
    func testCFNumberFormOnlyIsAmbiguous() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(
                enableStatus: noErr, keyframeEncodeStatus: noErr,
                forceLTRBooleanStatus: -12902, forceLTRNumberStatus: noErr, sawAckToken: true),
            .ambiguous)
    }

    // Both ForceLTRRefresh forms rejected → unsupported (keep the compact-IDR fallback).
    func testBothForceFormsRejectedIsUnsupported() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(
                enableStatus: noErr, keyframeEncodeStatus: noErr,
                forceLTRBooleanStatus: -12902, forceLTRNumberStatus: -12902),
            .unsupported)
    }

    // Boolean form rejected and the CFNumber retry was NOT attempted (nil) → unsupported.
    func testBooleanRejectedNoRetryIsUnsupported() {
        XCTAssertEqual(
            VideoEncoder.interpretLTRProbe(
                enableStatus: noErr, keyframeEncodeStatus: noErr,
                forceLTRBooleanStatus: -12902, forceLTRNumberStatus: nil),
            .unsupported)
    }

    // Defaults: a bare `enableStatus: noErr` (later statuses default to noErr, sawAckToken defaults
    // false) reads as AMBIGUOUS — API accepted but no ack-token observed. Confirms `.supported` is
    // never reached without an explicitly-observed LTR ack-token.
    func testDefaultsNoAckTokenIsAmbiguous() {
        XCTAssertEqual(VideoEncoder.interpretLTRProbe(enableStatus: noErr), .ambiguous)
    }

    // Verdict rawValues are exactly the single words the host log emits (the user greps these).
    func testRawValuesMatchLoggedWords() {
        XCTAssertEqual(VideoEncoder.LTRProbeVerdict.supported.rawValue, "supported")
        XCTAssertEqual(VideoEncoder.LTRProbeVerdict.unsupported.rawValue, "unsupported")
        XCTAssertEqual(VideoEncoder.LTRProbeVerdict.ambiguous.rawValue, "ambiguous")
        XCTAssertEqual(VideoEncoder.LTRProbeVerdict.unknown.rawValue, "unknown")
    }
}
#endif
