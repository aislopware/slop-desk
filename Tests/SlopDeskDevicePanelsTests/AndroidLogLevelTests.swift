// AndroidLogLineTests — gone; what is left is the FILTER MENU.
//
// The grammar's cases live in `rust/slopdesk-devicelog/src/logcat.rs`, including the pid-width
// regression this file existed for: `logcat` right-aligns the pid into a fixed-width field, so
// `( 1234):` splits the header across two whitespace-delimited tokens while `(12345):` closes inside
// the first one, and a parser that handles only the narrow one silently drops the entire message of
// every wide-pid line. The marshalling is ``DeviceLogLineTests``.
//
// The SET moved too, and later: `AndroidLogLevel` used to spell its own five letters against
// androidd's six, so `F` — fatal — was a filter the menu could not produce. What that letter is
// worth, and what androidd will refuse, is pinned in `rust/slopdesk-androidd/src/protocol.rs`; the
// crossing is pinned in `rust/slopdesk-ffi/src/android_log_level.rs`. What is asserted HERE is the
// part that is still Swift's: that every level androidd offers arrives, in order, and reaches the
// menu with a name on it rather than a bare letter.

#if os(macOS)
import XCTest
@testable import SlopDeskDevicePanels

final class AndroidLogLevelTests: XCTestCase {
    func testTheMenuIsAndroiddsOwnFilterAlphabetIncludingFatal() {
        // The letter is interpolated into `*:<level>` and reaches an argument vector; `logcat`
        // treats an unparsable filter spec as a fatal error, which reads as a console that connects
        // and immediately dies. The menu cannot be a superset of what androidd accepts — and it
        // must not be a subset either, which is what it was: a level nobody can pick is a level
        // nobody has.
        XCTAssertEqual(AndroidLogLevel.allCases.map(\.rawValue), ["V", "D", "I", "W", "E", "F"])
    }

    /// The named constants are call-site convenience, not a second declaration of the set. If one
    /// of them names a letter androidd would refuse, `setLogLevel` would send a spec that kills the
    /// `logcat` child — so each has to be a level the alphabet actually carries.
    func testEveryNamedLevelIsOneTheAlphabetCarries() {
        let named: [AndroidLogLevel] = [.verbose, .debug, .info, .warning, .error, .fatal]
        for level in named {
            XCTAssertTrue(
                AndroidLogLevel.allCases.contains(level),
                "\(level.rawValue) is named here but is not a level androidd accepts",
            )
        }
    }

    /// The labels are the one part of this that stayed Swift, on `docs/55` §6's vocabulary line —
    /// so the thing that can rot is a level arriving from the crate with nothing naming it. The
    /// menu would draw the bare letter, which is honest and unreadable; this fails first.
    func testEveryOfferedLevelHasAName() {
        XCTAssertEqual(AndroidLogLevel.warning.title, "Warning")
        XCTAssertEqual(AndroidLogLevel.fatal.title, "Fatal")
        for level in AndroidLogLevel.allCases {
            XCTAssertNotEqual(
                level.title,
                level.rawValue,
                "level \(level.rawValue) crossed with no title — name it in AndroidLogLevel.title",
            )
        }
    }
}
#endif
