import XCTest
@testable import SlopDeskVideoProtocol

/// STACK-DEPTH regression for the `aisd_fec_*` marshaling (``RustFECBridge``).
///
/// The marshaling must NOT consume stack proportional to the fragment count. A large HEVC
/// IDR/keyframe (1MB+) packetizes into hundreds-to-thousands of data fragments
/// (`ceil(frameSize / maxPayloadSize)`, `fragCount` is a `UInt16` up to 65535). The host runs
/// `parity()` on send and the client runs `recover()` on receive from production actor/session
/// contexts whose threads have a small (~512KB) stack — far smaller than the 8MB main-thread
/// stack the rest of the suite runs on. A per-fragment-recursive borrow (one nested
/// `withUnsafeBytes` closure per fragment) overflowed that production stack at only a few hundred
/// fragments (SIGSEGV), even though the codec bytes are correct.
///
/// These tests pin both paths against a deliberately SMALL stack so a recursion regression
/// crashes the test (SIGSEGV) instead of silently passing on the oversized main-thread stack.
final class RustFECLargeFrameStackTests: XCTestCase {
    /// A production-representative small stack (512KB), where deep per-fragment recursion in the FEC
    /// marshaling crashed. `Thread` lets us pin `stackSize` explicitly (a `DispatchQueue.global()`
    /// thread is similarly small but not configurable).
    private static let productionStackSize = 512 * 1024

    /// Carries a thrown error out of the worker `Thread` to the caller across the concurrency
    /// boundary (a plain `var` capture is not `Sendable`).
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Runs `body` on a fresh `Thread` whose stack is exactly `productionStackSize`, blocking until
    /// it finishes. Surfaces a thrown error back to the caller's thread.
    private func runOnSmallStack(
        _ body: @escaping @Sendable () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let done = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let thread = Thread {
            defer { done.signal() }
            do { try body() } catch { box.error = error }
        }
        thread.stackSize = Self.productionStackSize
        thread.start()
        done.wait()
        if let thrown = box.error { XCTFail("small-stack FEC work threw: \(thrown)", file: file, line: line) }
    }

    private func frag(_ seed: UInt8, _ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    /// `parity()` over thousands of fragments must NOT overflow the production stack. ~1181B payloads
    /// × 3000 fragments ≈ a 3.5MB frame — routine for a 4K / high-bitrate keyframe. On the buggy
    /// per-fragment recursion this SIGSEGVs on the 512KB stack; the fix runs in O(1) stack.
    func testParityOverThousandsOfFragmentsDoesNotOverflowSmallStack() {
        let fec = XORParityFEC(groupSize: 5)
        let fragments = (0..<3000).map { frag(UInt8($0 & 0xFF), 1181) }
        runOnSmallStack {
            let parity = fec.parity(forDataFragments: fragments)
            XCTAssertEqual(parity.count, (3000 + 4) / 5, "parity count = ceil(3000 / 5)")
        }
    }

    /// `recover()` over thousands of fragments (with a hole per group) must NOT overflow the
    /// production stack — this is the client receive path for a large keyframe with losses.
    func testRecoverOverThousandsOfFragmentsDoesNotOverflowSmallStack() {
        let fec = XORParityFEC(groupSize: 5)
        let count = 3000
        let data = (0..<count).map { frag(UInt8($0 & 0xFF), 1181) }
        let parity = fec.parity(forDataFragments: data)
        // Punch one hole in each group so recover() does real per-group reconstruction.
        let received: [Data?] = data.enumerated().map { $0.offset.isMultiple(of: 5) ? nil : $0.element }
        runOnSmallStack {
            let recovered = fec.recover(dataFragments: received, parityFragments: parity.map(\.self))
            XCTAssertEqual(recovered.compactMap(\.self).count, count, "every hole recovered")
            XCTAssertEqual(recovered.map(\.self), data.map { Optional($0) }, "recovered bytes match exactly")
        }
    }

    /// Parity bytes from the small-stack run must be IDENTICAL to a same-input main-thread run — the
    /// stack-safe marshaling must not perturb the wire bytes.
    func testSmallStackParityBytesMatchMainThread() {
        let fec = XORParityFEC(groupSize: 5)
        let fragments = (0..<2000).map { frag(UInt8(($0 &* 7) & 0xFF), 1181) }
        let mainThreadParity = fec.parity(forDataFragments: fragments)
        runOnSmallStack {
            let smallStackParity = fec.parity(forDataFragments: fragments)
            XCTAssertEqual(smallStackParity, mainThreadParity, "stack-safe parity must be byte-identical")
        }
    }
}
