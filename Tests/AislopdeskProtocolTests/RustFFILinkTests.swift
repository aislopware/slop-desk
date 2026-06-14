import XCTest
@testable import AislopdeskProtocol

/// Proves the Rust `aislopdesk-ffi` staticlib links into the Swift build and its C ABI is
/// callable end-to-end (Swift → `CAislopdeskFFI` module → `libaislopdesk_ffi.a`). This is
/// the keystone for the Swift→Rust swap: every codec/controller delegation rides the same
/// path proven here.
final class RustFFILinkTests: XCTestCase {
    func testStaticLibLinksAndIsCallable() {
        XCTAssertEqual(RustFFI.seqDistance(10, 3), 7)
        XCTAssertEqual(RustFFI.seqDistance(3, 10), -7)
        XCTAssertEqual(RustFFI.seqDistance(0, 0), 0)
        // Wrap-around: 1 - 0xFFFF_FFFF == 2 in 32-bit sequence space.
        XCTAssertEqual(RustFFI.seqDistance(1, 0xFFFF_FFFF), 2)
    }
}
