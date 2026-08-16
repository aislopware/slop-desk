import Darwin
import XCTest
@testable import SlopDeskSupervisor

/// What is left of `SCM_RIGHTS` on the Swift side: the arithmetic, and the no-descriptor case.
///
/// ## Why there is no "a descriptor crosses" test here any more
/// Swift can no longer SEND one — ``FileDescriptorPassing/send(socket:bytes:)`` builds no ancillary
/// data, because hostd is the end that gets handed PTY masters and never the end that has one to
/// give. A test that sent an fd would have needed a Swift sender to exist purely to be tested,
/// which is the second implementation this whole change removed.
///
/// The facts those tests used to pin are pinned where the code now lives:
///
/// | Fact | Owner |
/// | --- | --- |
/// | a descriptor crosses alongside the body | `frame.rs::descriptor_crosses_alongside_the_body` |
/// | the sender keeps its own copy | `frame.rs::sender_retains_its_own_descriptor` |
/// | a released pane stays alive and re-adopts | `registry.rs`, and `SupervisedPaneSurvivalTests` |
/// | an adopted master reads, resizes, and answers `tcgetpgrp` | `PTYProcessTests`, against real superd |
///
/// The last two are now end-to-end against the real daemon rather than against a `socketpair`
/// standing in for it, which is strictly the better test: it exercises the pairing of Rust's writer
/// with Swift's reader, which is the pairing that actually ships.
final class FileDescriptorPassingTests: XCTestCase {
    private var ends: [Int32] = [-1, -1]

    override func setUpWithError() throws {
        var pair: [Int32] = [0, 0]
        try XCTSkipIf(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) != 0, "socketpair unavailable")
        ends = pair
    }

    override func tearDownWithError() throws {
        for end in ends where end >= 0 { close(end) }
        ends = [-1, -1]
        // A throwing tearDown must actually be able to throw or SwiftFormat drops `throws`.
        try XCTSkipIf(false)
    }

    // MARK: - The cmsg arithmetic

    /// Darwin aligns control messages to `uint32_t`, not to the platform word. Getting this wrong
    /// produces a buffer the kernel reads past on a 64-bit build, and it fails silently — so the
    /// formula is pinned rather than trusted.
    ///
    /// This is the one piece of `SCM_RIGHTS` that Swift still owns: the RECEIVER sizes its control
    /// buffer with it, and an undersized buffer means `MSG_CTRUNC` and a leaked master on every
    /// spawn.
    func testControlMessageArithmeticMatchesDarwinAlignment() {
        XCTAssertEqual(FileDescriptorPassing.align(0), 0)
        XCTAssertEqual(FileDescriptorPassing.align(1), 4)
        XCTAssertEqual(FileDescriptorPassing.align(4), 4)
        XCTAssertEqual(FileDescriptorPassing.align(5), 8)

        let header = MemoryLayout<cmsghdr>.size
        XCTAssertEqual(
            FileDescriptorPassing.length(payload: 4),
            FileDescriptorPassing.align(header) + 4,
            "CMSG_LEN pads the header but NOT the payload",
        )
        XCTAssertEqual(
            FileDescriptorPassing.space(payload: 4),
            FileDescriptorPassing.align(header) + 4,
            "one 4-byte payload is already aligned, so SPACE == LEN here",
        )
        XCTAssertEqual(
            FileDescriptorPassing.space(payload: 5),
            FileDescriptorPassing.align(header) + 8,
            "CMSG_SPACE rounds the payload up; CMSG_LEN does not",
        )
        XCTAssertEqual(
            FileDescriptorPassing.dataOffset(),
            FileDescriptorPassing.align(header),
            "CMSG_DATA sits immediately after the padded header",
        )
    }

    // MARK: - The plain frame

    /// The overwhelming majority of frames carry no fd, and a control buffer shorter than one
    /// header must read as "none" rather than as an error.
    func testFrameWithoutDescriptorYieldsNil() throws {
        try FileDescriptorPassing.send(socket: ends[0], bytes: [0x01, 0x02])
        let (bytes, adopted) = try FileDescriptorPassing.receive(socket: ends[1], capacity: 8)
        XCTAssertEqual(bytes, [0x01, 0x02])
        XCTAssertNil(adopted)
    }

    /// A short read is not a lost byte: `receive` returns what arrived, and the framing above it
    /// asks again. Pinned because the tag byte read depends on it.
    func testReceiveReturnsOnlyTheBytesThatArrived() throws {
        try FileDescriptorPassing.send(socket: ends[0], bytes: [0xAA])
        let (bytes, adopted) = try FileDescriptorPassing.receive(socket: ends[1], capacity: 64)
        XCTAssertEqual(bytes, [0xAA])
        XCTAssertNil(adopted)
    }
}
