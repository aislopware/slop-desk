// DeviceLogLine — ONE console row for both device panels, and the marshalling behind it.
//
// The GRAMMARS live in `slopdesk_devicelog`: `logcat -v time` in its `logcat` module, `log stream
// --style compact` in its `unified` one, over a lexer they share the way this file's predecessor
// shared one. What is left on this side is turning byte offsets into `String`s, which is the one
// thing the Rust suite — which never sees a `String` — cannot check.
//
// ## Why the parse moved
//
// It ran over text a program on the far side of a device wrote, thousands of lines a minute, on the
// socket read path. Every shape check asked `Character.isNumber` or `Character.isUppercase`, which
// are Unicode property lookups per grapheme cluster, and every field was a fresh `Substring` walk
// over a `String` the row was going to be sliced out of anyway. The door answers offsets and slices
// happen once.
//
// ## The ink scale is shared; the alphabets are not
//
// One `Severity` for both consoles, and a superset of each: `logcat` never yields `.debug` and the
// unified log never yields `.warning`, because neither alphabet has the bucket. It is one type
// because the consumer is one console renderer with one set of inks — the grammars are what stay
// apart, and they do, on the far side of two separate doors.

#if os(macOS)
import CSlopDeskFFI
import Foundation

/// How loud a row is, which is the only question a console answers at a glance.
///
/// Coarser than either source's own alphabet on purpose: `logcat` prints eight priority letters and
/// the unified log six type tokens, and six tints answer "is anything wrong" worse than three.
package enum DeviceLogSeverity: UInt8 {
    /// Uninked. Both consoles put their bulk here — `logcat`'s `D` and the unified log's `Df` are
    /// each the largest share of a busy device's output by a wide margin, so tinting them would
    /// light up most of the console and leave the errors no louder than everything else.
    case plain = 0
    /// The unified log's `Db` and `A`. `logcat` never answers this.
    case debug = 1
    case info = 2
    /// `logcat`'s `W`. The unified log never answers this.
    case warning = 3
    case error = 4
    /// `F` in both, plus `logcat`'s `A` — its ASSERT, which is what a native abort prints.
    case fatal = 5
}

/// One console row, and the two doors that fill it.
///
/// ONE type for both consoles, where there were two identical ones. What actually differed between
/// `AndroidLogLine` and `SimulatorLogLine` was a field NAME — `tag` against `process` — for the same
/// slot: whatever the emitter of the line called itself. It is `name` here, and each console view
/// still labels and inks it in its own words.
///
/// A line that does not match its grammar is kept verbatim rather than dropped: both sources emit
/// their own banners — `--------- beginning of crash`, `getpwuid_r did not find a match for uid
/// 501` — and a swallowed banner is a console that looks like it silently lost the boundary between
/// two runs, which is precisely the line someone reading a crash is looking for.
package struct DeviceLogLine: Identifiable, Equatable {
    /// Assigned by the model, monotonic. Not derived from the text: two identical lines a second
    /// apart are two rows, and a content-hash id would collapse them into one.
    package var id: UInt64 = 0
    /// `13:50:19.565`, or empty for a line the parse did not recognise. The DATE is dropped — a
    /// console shows the recent past, and the day is the same one in every row of it.
    package var time = ""
    /// Whatever emitted the line called itself: the `logcat` tag without its `( pid)`, or the
    /// process without its `[pid:tid]`. The pid pair is noise at a sidebar's width either way.
    package var name = ""
    package var message = ""
    package var severity: DeviceLogSeverity = .plain

    /// One `logcat -v time` line.
    package static func logcat(_ text: String) -> Self {
        parse(text, through: slopdesk_logcat_parse)
    }

    /// One `log stream --style compact` line.
    package static func unified(_ text: String) -> Self {
        parse(text, through: slopdesk_unified_log_parse)
    }

    /// The crossing: UTF-8 in, three slices of it back.
    ///
    /// A door that refuses — a line longer than a `UInt32` offset can name, which no source writes
    /// — leaves the row verbatim rather than half-filled, so the console still shows the text.
    private static func parse(
        _ text: String,
        through door: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<SlopDeskDeviceLogLine>?)
            -> Bool,
    ) -> Self {
        let bytes = Array(text.utf8)
        var record = SlopDeskDeviceLogLine()
        let parsed = bytes.withUnsafeBufferPointer { line in
            door(line.baseAddress, line.count, &record)
        }
        guard parsed else { return Self(message: text) }
        return Self(
            time: slice(bytes, record.time_offset, record.time_len),
            name: slice(bytes, record.name_offset, record.name_len),
            message: slice(bytes, record.message_offset, record.message_len),
            severity: DeviceLogSeverity(rawValue: record.severity) ?? .plain,
        )
    }

    /// A span the door named, cut out of the buffer it was measured against.
    ///
    /// Clamped rather than trusted: the offsets cross a C ABI, and a range past the end would be a
    /// trap in the caller rather than a wrong row. The Rust suite pins that every span it answers
    /// is already inside the line.
    private static func slice(_ bytes: [UInt8], _ offset: UInt32, _ length: UInt32) -> String {
        let start = Swift.min(Int(offset), bytes.count)
        let end = Swift.min(start + Int(length), bytes.count)
        // Lossy on purpose, and the rule's failable alternative is wrong here: a device writes
        // whatever it likes into its own log, and a row of it that is not valid UTF-8 must still
        // RENDER — with replacement characters where the bad bytes were — rather than vanish.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
#endif
