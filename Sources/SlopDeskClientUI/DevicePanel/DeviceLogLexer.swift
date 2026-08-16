#if os(macOS)

/// The three reads both device consoles' line grammars start with: take a whitespace-delimited
/// token, and decide whether it LOOKS like a date or a time.
///
/// The grammars themselves stay apart, and should — `logcat -v time` puts a priority letter and a
/// `Tag( pid):` header where `log stream --style compact` puts a severity token and a
/// `Process[pid:tid]`, and a console that guessed between them would mis-colour every row of one
/// device. What was never different is the lexing: both consume `rest` the same way, and both check
/// SHAPE rather than value, for the same reason — validating the calendar or the clock here would
/// reject a log written across a timezone change, and the value is never read anyway.
///
/// The date's LENGTH is the one parameter, because it is the one real difference: `logcat` prints no
/// year (`08-04`) and the unified log does (`2026-08-04`). It is a parameter rather than a second
/// function so that the "digits and dashes, exactly this long" rule has one spelling.
enum DeviceLogLexer {
    /// The next whitespace-delimited run, consumed from `rest`. `nil` at end of input.
    static func token(_ rest: inout Substring) -> Substring? {
        let start = rest.drop(while: \.isWhitespace)
        guard !start.isEmpty else { return nil }
        let end = start.firstIndex(where: \.isWhitespace) ?? start.endIndex
        rest = start[end...]
        return start[..<end]
    }

    /// `08-04` (`length: 5`) or `2026-08-04` (`length: 10`). Shape only; the value is never read.
    static func isDate(_ token: Substring, length: Int) -> Bool {
        token.count == length && token.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// `13:50:19.565`. Shape, not value — same reasoning as ``isDate(_:length:)``.
    static func isTime(_ token: Substring) -> Bool {
        token.count >= 8 && token.first?.isNumber == true
            && token.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." }
    }
}
#endif
