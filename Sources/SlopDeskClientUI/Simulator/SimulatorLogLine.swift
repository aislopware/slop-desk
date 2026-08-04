// SimulatorLogLine — the device's unified log, decoded. Pure: an envelope in, rows out.
//
// The server batches into one `{"type":"log","lines":[…]}` envelope per ~50 ms rather than sending a
// message per line, so the socket's message rate is bounded whatever the device is doing. That is
// also why the parse lives here and not in the connection: a busy device produces thousands of these
// a minute and every one of them is a string this code has to be right about.
//
// `--style compact` is what the panel asks for, because it is the only style whose shape is fixed
// enough to colour by severity:
//
//     2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [subsystem:category] message
//     └─ date    └─ time      │  └─ process[pid:tid]            └─ the rest
//                            └─ severity
//
// A line that does NOT match is kept verbatim rather than dropped. `log stream` emits its own
// banners ("getpwuid_r did not find a match for uid 501", the column header) and a swallowed banner
// is a console that looks like it silently lost the first second of output.

#if os(macOS)
import Foundation

/// One rendered console row.
struct SimulatorLogLine: Identifiable, Equatable {
    /// Assigned by the model, monotonic. Not derived from the text: two identical lines a second
    /// apart are two rows, and a content-hash id would collapse them into one.
    var id: UInt64 = 0
    /// `13:50:19.565`, or empty for a line this parse did not recognise.
    var time = ""
    var severity: Severity = .plain
    /// The emitting process, without its `[pid:tid]` suffix — that pair is noise at a sidebar's
    /// width and the process name is the part anyone scans for.
    var process = ""
    var message = ""

    /// The five buckets the console inks. Coarser than the log's own type alphabet on purpose: the
    /// question a console answers at a glance is "is anything wrong", and eight tints answer it
    /// worse than three.
    enum Severity: Equatable {
        case fault
        case error
        case info
        case debug
        case plain
    }

    /// `log stream --style compact`, one line. Never fails — an unrecognised line becomes a `plain`
    /// row carrying the whole text as its message.
    static func parse(_ text: String) -> Self {
        var line = Self()
        var rest = Substring(text)

        guard let date = token(&rest), isDate(date),
              let time = token(&rest), isTime(time),
              let type = token(&rest), isSeverityToken(type),
              let source = token(&rest)
        else {
            line.message = text
            return line
        }
        line.time = String(time)
        line.severity = severity(for: type)
        line.process = String(process(in: source))
        line.message = String(rest.drop(while: \.isWhitespace))
        return line
    }

    // MARK: The grammar

    /// The next whitespace-delimited run, consumed from `rest`. `nil` at end of input.
    private static func token(_ rest: inout Substring) -> Substring? {
        let start = rest.drop(while: \.isWhitespace)
        guard !start.isEmpty else { return nil }
        let end = start.firstIndex(where: \.isWhitespace) ?? start.endIndex
        rest = start[end...]
        return start[..<end]
    }

    /// `2026-08-04`. Shape only — the value is never read, so a date the panel cannot interpret is
    /// still a date, and validating the calendar here would reject a log written across a timezone.
    private static func isDate(_ token: Substring) -> Bool {
        token.count == 10 && token.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// `13:50:19.565`. Same reasoning as ``isDate``: shape, not value.
    private static func isTime(_ token: Substring) -> Bool {
        token.count >= 8 && token.first?.isNumber == true
            && token.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." }
    }

    /// One or two letters, capital first — `E`, `Df`, `Db`. Checked so a line whose third token
    /// happens to be a word does not become a severity nobody sent.
    private static func isSeverityToken(_ token: Substring) -> Bool {
        (1...2).contains(token.count) && token.first?.isUppercase == true
            && token.allSatisfy(\.isLetter)
    }

    /// The alphabet, counted off ten thousand real lines (2026-08-04): `Db` debug, `Df` default,
    /// `E` error, `I` info, `A` activity, `F` fault. `Df` is deliberately NOT inked — default is the
    /// ordinary case and the largest share of a busy device's output after debug, so tinting it
    /// would light up most of the console and leave the errors no louder than everything else.
    private static func severity(for token: Substring) -> Severity {
        switch token {
        case "F": .fault
        case "E": .error
        case "I": .info
        case "Db",
             "A": .debug
        default: .plain
        }
    }

    /// `Unity2025Poster[76037:219b94d]` → `Unity2025Poster`. A process with no bracket (some
    /// kernel-side emitters) is passed through whole.
    private static func process(in token: Substring) -> Substring {
        guard let bracket = token.firstIndex(of: "[") else { return token }
        return token[..<bracket]
    }
}

/// What arrives on the log socket. Two shapes and a catch-all, decoded the same validate-then-drop
/// way as every other untrusted payload here.
enum SimulatorLogMessage: Equatable {
    /// The server has the `log stream` child up. Worth its own case: it is the only signal that
    /// separates "connected but the device is quiet" from "connected and nothing works".
    case started
    case lines([String])
    case unknown

    static func decode(_ text: String) -> Self {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String
        else { return .unknown }
        switch type {
        case "log_started": return .started
        case "log": return .lines(root["lines"] as? [String] ?? [])
        default: return .unknown
        }
    }
}

/// The log levels the server's own `--level` accepts, in ascending severity. The set is closed
/// because it is interpolated into a query the server passes to `log stream` verbatim: an invented
/// level upgrades the socket and then dies when the child process refuses it, which reads as a
/// console that connects and never prints.
enum SimulatorLogLevel: String, CaseIterable, Identifiable {
    case debug
    case info
    case notice
    case error
    case fault

    var id: String { rawValue }

    /// Title case for the menu. The wire value stays lowercase — this is display only.
    var title: String { rawValue.capitalized }
}
#endif
