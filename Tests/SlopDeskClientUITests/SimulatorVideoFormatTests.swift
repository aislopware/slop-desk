// SimulatorVideoFormatTests — proves CoreMedia accepts what the server actually sends.
//
// The fixtures are MEASURED off a live `baguette serve` streaming an iPhone 17 Pro: the avcC record
// verbatim, and access units of the observed shape (one 4-byte-length-prefixed NAL). A synthetic
// record would prove only that the parser agrees with itself.
//
// Hang-safe by construction: `CMVideoFormatDescription`, `CMBlockBuffer` and `CMSampleBuffer` are
// data objects. Nothing here creates a decompression session, a display layer or a Metal device —
// the thing that decodes lives in the view and is never built in a test.

#if os(macOS)
import CoreMedia
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class SimulatorVideoFormatTests: XCTestCase {
    /// The record as it arrived: version 1, High profile, level 5.1, 4-byte NAL lengths, one 22-byte
    /// SPS and one 4-byte PPS.
    private let measuredAVCC = Data([
        0x01, 0x64, 0x00, 0x33, 0xFF, 0xE1,
        0x00, 0x16,
        0x27, 0x64, 0x00, 0x33, 0xAC, 0x13, 0x14, 0x3C, 0x04, 0xC0, 0x14, 0x9E,
        0x6A, 0x9A, 0x81, 0x01, 0x01, 0x03, 0xC2, 0x01, 0x08, 0xF8,
        0x01,
        0x00, 0x04,
        0x28, 0xEE, 0x3C, 0xB0,
    ])

    private func measuredConfiguration() throws -> SimulatorWireProtocol.AVCConfiguration {
        try XCTUnwrap(SimulatorWireProtocol.parseAVCConfiguration(measuredAVCC))
    }

    func testTheMeasuredRecordParsesToOneSPSAndOnePPS() throws {
        let configuration = try measuredConfiguration()
        XCTAssertEqual(configuration.parameterSets.count, 2)
        XCTAssertEqual(configuration.parameterSets[0].count, 22)
        XCTAssertEqual(configuration.parameterSets[1].count, 4)
        XCTAssertEqual(configuration.nalUnitHeaderLength, 4)
        // High profile, level 5.1 — `avc1.640033`, which VideoToolbox decodes in hardware.
        XCTAssertEqual(configuration.profile, 0x64)
        XCTAssertEqual(configuration.levelIndication, 0x33)
    }

    func testCoreMediaAcceptsTheMeasuredRecordAndReportsTheDeviceResolution() throws {
        // The end-to-end claim of this layer: the bytes the server sends make a real format
        // description. The dimensions come from the SPS, so a wrong parse shows up here as a wrong
        // (or absent) resolution rather than as a silent decode failure later.
        let description = try XCTUnwrap(
            SimulatorVideoFormat.formatDescription(for: measuredConfiguration()),
        )
        XCTAssertEqual(SimulatorVideoFormat.dimensions(of: description), CGSize(width: 1206, height: 2622))
    }

    func testAConfigurationWithNoParameterSetsMakesNoDescription() {
        let empty = SimulatorWireProtocol.AVCConfiguration(
            parameterSets: [], nalUnitHeaderLength: 4, profile: 0x64, levelIndication: 0x33,
        )
        XCTAssertNil(SimulatorVideoFormat.formatDescription(for: empty))
    }

    func testGarbageParameterSetsAreRefusedByCoreMediaRatherThanTrusted() {
        // The untrusted-input rule reaching past our own parser: a well-formed avcC wrapper can still
        // carry a nonsense SPS, and the answer must be nil, not a description that decodes noise.
        let nonsense = SimulatorWireProtocol.AVCConfiguration(
            parameterSets: [Data([0xFF, 0xFF, 0xFF, 0xFF])], nalUnitHeaderLength: 4,
            profile: 0, levelIndication: 0,
        )
        XCTAssertNil(SimulatorVideoFormat.formatDescription(for: nonsense))
    }

    // MARK: Sample buffers

    /// One access unit of the observed shape: a 4-byte big-endian length followed by that many bytes.
    private func accessUnit(payloadLength: Int) -> Data {
        var unit = Data()
        var length = UInt32(payloadLength).bigEndian
        withUnsafeBytes(of: &length) { unit.append(contentsOf: $0) }
        unit.append(Data(repeating: 0x41, count: payloadLength))
        return unit
    }

    func testAnAccessUnitBecomesASampleBufferCarryingItsBytes() throws {
        let description = try XCTUnwrap(
            SimulatorVideoFormat.formatDescription(for: measuredConfiguration()),
        )
        let unit = accessUnit(payloadLength: 64)
        let sample = try XCTUnwrap(
            SimulatorVideoFormat.sampleBuffer(
                accessUnit: unit, formatDescription: description, isKeyframe: true,
            ),
        )
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), unit.count)
        XCTAssertTrue(CMSampleBufferIsValid(sample))
        XCTAssertEqual(CMSampleBufferGetFormatDescription(sample), description)
    }

    func testTheSampleOwnsACopyRatherThanPointingAtCallerMemory() throws {
        // The access unit's `Data` dies with the receive callback while the sample buffer lives on in
        // the display layer's queue. Pointing at that storage would be a use-after-free that only
        // shows up as intermittent corrupt frames.
        let description = try XCTUnwrap(
            SimulatorVideoFormat.formatDescription(for: measuredConfiguration()),
        )
        var sample: CMSampleBuffer?
        do {
            var unit = accessUnit(payloadLength: 32)
            sample = SimulatorVideoFormat.sampleBuffer(
                accessUnit: unit, formatDescription: description, isKeyframe: true,
            )
            unit.resetBytes(in: 0..<unit.count)
        }
        let buffer = try XCTUnwrap(try CMSampleBufferGetDataBuffer(XCTUnwrap(sample)))
        var readable = 0
        var pointer: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(
            CMBlockBufferGetDataPointer(
                buffer, atOffset: 4, lengthAtOffsetOut: &readable, totalLengthOut: nil,
                dataPointerOut: &pointer,
            ),
            noErr,
        )
        // 0x41 is the fill the unit was built with; zeroes would mean the wipe reached the sample.
        XCTAssertEqual(pointer.map { UInt8(bitPattern: $0.pointee) }, 0x41)
    }

    func testEverySampleAsksToBeDisplayedImmediately() throws {
        // No timing, no control timebase: this is an interactive mirror, and a frame held back for
        // smoothness is a frame of added latency on a device someone is tapping.
        let description = try XCTUnwrap(
            SimulatorVideoFormat.formatDescription(for: measuredConfiguration()),
        )
        for isKeyframe in [true, false] {
            let sample = try XCTUnwrap(SimulatorVideoFormat.sampleBuffer(
                accessUnit: accessUnit(payloadLength: 16), formatDescription: description,
                isKeyframe: isKeyframe,
            ))
            let attachments = try XCTUnwrap(
                CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
            )
            XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
            // A delta frame is not a seek point, and says so.
            XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool, isKeyframe ? nil : true)
        }
    }

    func testAnEmptyAccessUnitMakesNoSample() throws {
        let description = try XCTUnwrap(
            SimulatorVideoFormat.formatDescription(for: measuredConfiguration()),
        )
        XCTAssertNil(SimulatorVideoFormat.sampleBuffer(
            accessUnit: Data(), formatDescription: description, isKeyframe: true,
        ))
    }
}
#endif
