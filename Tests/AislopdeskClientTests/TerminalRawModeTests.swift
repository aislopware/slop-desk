#if canImport(Darwin)
import Darwin
#endif
import Foundation
import XCTest
@testable import AislopdeskTTY

/// Raw-mode safety: the termios save/restore logic must restore the original attributes
/// exactly, and the window-size mapping (SIGWINCH → resize) must read/write a tty's
/// winsize correctly. Exercised against a real openpty() pair so the POSIX semantics the
/// CLI depends on are actually validated (the executable itself is not importable, so the
/// load-bearing primitives live in the testable AislopdeskTTY library).
final class TerminalRawModeTests: XCTestCase {
    /// Opens a pty pair, returns (master, slave). Caller closes both.
    private func openPTYPair() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw XCTSkip("openpty unavailable: errno \(errno)")
        }
        return (master, slave)
    }

    // MARK: - Save / restore round-trip

    func testRawAttributesDifferFromCookedThenRestoreIsExact() throws {
        let (master, slave) = try openPTYPair()
        defer { close(master)
            close(slave)
        }

        // The SLAVE end is a tty; capture its cooked attributes.
        let original = try TerminalRawMode.currentAttributes(fd: slave)

        // Raw attributes must actually differ (echo + canonical cleared by cfmakeraw).
        let raw = TerminalRawMode.rawAttributes(from: original)
        XCTAssertNotEqual(original.c_lflag, raw.c_lflag, "cfmakeraw must change local flags")
        XCTAssertEqual(raw.c_lflag & UInt(ECHO), 0, "raw mode must disable ECHO")
        XCTAssertEqual(raw.c_lflag & UInt(ICANON), 0, "raw mode must disable canonical mode")

        // VMIN=1 / VTIME=0 (blocking single-byte reads).
        withUnsafeBytes(of: raw.c_cc) { buf in
            XCTAssertEqual(buf[Int(VMIN)], 1, "VMIN must be 1")
            XCTAssertEqual(buf[Int(VTIME)], 0, "VTIME must be 0")
        }

        // Apply raw, then restore the original; the read-back must equal the original.
        try TerminalRawMode.applyAttributes(raw, fd: slave)
        let afterRaw = try TerminalRawMode.currentAttributes(fd: slave)
        XCTAssertEqual(afterRaw.c_lflag & UInt(ECHO), 0, "ECHO should be off after applying raw")

        try TerminalRawMode.applyAttributes(original, fd: slave)
        let restored = try TerminalRawMode.currentAttributes(fd: slave)
        XCTAssertEqual(restored.c_lflag, original.c_lflag, "restore must return the exact local flags")
        XCTAssertEqual(restored.c_iflag, original.c_iflag, "restore must return the exact input flags")
        XCTAssertEqual(restored.c_oflag, original.c_oflag, "restore must return the exact output flags")
        XCTAssertEqual(restored.c_cflag, original.c_cflag, "restore must return the exact control flags")
    }

    func testCurrentAttributesThrowsForNonTTY() throws {
        // A pipe read-end is not a tty → currentAttributes must throw notATTY.
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw XCTSkip("pipe unavailable") }
        defer { close(fds[0])
            close(fds[1])
        }
        XCTAssertThrowsError(try TerminalRawMode.currentAttributes(fd: fds[0])) { error in
            guard case RawModeError.notATTY = error else {
                return XCTFail("expected notATTY, got \(error)")
            }
        }
    }

    // MARK: - SIGWINCH → resize mapping (TIOCGWINSZ / TIOCSWINSZ)

    func testWindowSizeSetAndGetRoundTrip() throws {
        let (master, slave) = try openPTYPair()
        defer { close(master)
            close(slave)
        }

        // Set a known size on the master (as the host PTY / SIGWINCH handler would).
        XCTAssertTrue(TerminalRawMode.setWindowSize(fd: master, cols: 120, rows: 40, pxWidth: 960, pxHeight: 640))

        // The slave (the controlled tty) must observe the new size — this is exactly what
        // a resize message carries from the client's local terminal to the host PTY.
        guard let ws = TerminalRawMode.windowSize(fd: slave) else {
            XCTFail("windowSize returned nil for a tty")
            return
        }
        XCTAssertEqual(ws.cols, 120)
        XCTAssertEqual(ws.rows, 40)
        XCTAssertEqual(ws.pxWidth, 960)
        XCTAssertEqual(ws.pxHeight, 640)
    }

    func testWindowSizeNilForNonTTY() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw XCTSkip("pipe unavailable") }
        defer { close(fds[0])
            close(fds[1])
        }
        XCTAssertNil(TerminalRawMode.windowSize(fd: fds[0]), "windowSize must be nil for a non-tty")
    }
}
