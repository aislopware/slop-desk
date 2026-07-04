import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Per-session colour identity (2026-07-04): the accent slot must be a PURE function of the session's
/// persisted UUID — same session, same colour, every launch, no storage.
final class SessionAccentTests: XCTestCase {
    private func id(_ uuid: String) throws -> SessionID {
        try SessionID(raw: XCTUnwrap(UUID(uuidString: uuid)))
    }

    func testIndexIsStableAndPinned() throws {
        // Pinned rolls of the shipped FNV-1a fold — a hash change would silently recolour every
        // restored session, so the exact values are frozen here.
        XCTAssertEqual(try SessionAccent.index(for: id("00000000-0000-0000-0000-000000000000")), 5)
        XCTAssertEqual(try SessionAccent.index(for: id("11111111-2222-3333-4444-555555555555")), 5)
        XCTAssertEqual(try SessionAccent.index(for: id("A9DC76FF-6188-78DC-E8AB-9DF2FC986701")), 4)
    }

    func testIndexStaysInPaletteRangeAndActuallyVaries() throws {
        var seen = Set<Int>()
        for byte in 0..<32 {
            let suffix = String(format: "%012X", byte)
            let index = try SessionAccent.index(for: id("00000000-0000-0000-0000-\(suffix)"))
            XCTAssertTrue((0..<SessionAccent.paletteCount).contains(index))
            seen.insert(index)
        }
        XCTAssertGreaterThan(seen.count, 2, "the UUID must actually drive the slot, not collapse")
    }

    func testSameIDAlwaysSameIndex() {
        let session = SessionID()
        XCTAssertEqual(SessionAccent.index(for: session), SessionAccent.index(for: session))
    }
}
