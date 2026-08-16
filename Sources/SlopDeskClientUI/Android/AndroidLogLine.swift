// AndroidLogLine — `logcat`, decoded. Pure: a line in, a row out.
//
// The host asks for `-v time`, which is the only stock format whose shape is fixed enough to colour
// by severity without also being unreadable at a sidebar's width:
//
//     08-04 13:50:19.565 D/ActivityManager( 1234): message
//     └─ date └─ time    │ └─ tag           └─ pid  └─ the rest
//                       └─ priority
//
// `-v threadtime` was the alternative and is rejected for the same reason `docs/47` gives for
// stripping `[pid:tid]` off a simulator row: the pid/tid pair is noise in a column this narrow, and
// the TAG is what anyone actually scans for. `logcat`'s own `-v brief` drops the timestamp, which is
// the one field that makes a log worth reading after the fact.
//
// A line that does NOT match is kept verbatim rather than dropped. `logcat` emits its own banners
// ("--------- beginning of main", "--------- beginning of crash") and a swallowed banner is a console
// that looks like it silently lost the boundary between two runs — which is precisely the line
// someone reading a crash is looking for.

#if os(macOS)

/// One rendered console row.
struct AndroidLogLine: Identifiable, Equatable {
    /// Assigned by the model, monotonic. Not derived from the text: two identical lines a second
    /// apart are two rows, and a content-hash id would collapse them into one.
    var id: UInt64 = 0
    /// `13:50:19.565`, or empty for a line this parse did not recognise. The DATE is dropped — a
    /// console shows the recent past and the day is the same one in every row of it.
    var time = ""
    var severity: Severity = .plain
    /// The emitting tag, without its `( pid)` suffix.
    var tag = ""
    var message = ""

    /// The five buckets the console inks. Coarser than `logcat`'s own six letters on purpose: the
    /// question a console answers at a glance is "is anything wrong", and six tints answer it worse
    /// than three.
    ///
    /// `D` — debug — is deliberately NOT inked. It is the largest share of a busy device's output by
    /// a wide margin, so tinting it would light up most of the console and leave the errors no louder
    /// than everything else. Same call the simulator console makes for `Df`.
    enum Severity: Equatable {
        case fatal
        case error
        case warning
        case info
        case plain
    }

    /// `logcat -v time`, one line. Never fails — an unrecognised line becomes a `plain` row carrying
    /// the whole text as its message.
    static func parse(_ text: String) -> Self {
        var line = Self()
        var rest = Substring(text)

        // The slash is REQUIRED, not decoration: `logcat`'s own format string is `%c/%-8s(%5d): `, so
        // the priority letter is always followed by one. Without that check any prose whose third
        // word begins with a capital in `VDIWEFAS` — "Everything is fine" — parses as an error row
        // with a tag cut out of the middle of the word.
        guard let date = token(&rest), isDate(date),
              let time = token(&rest), isTime(time),
              let head = token(&rest), let priority = head.first, isPriority(priority),
              head.dropFirst().first == "/"
        else {
            line.message = text
            return line
        }
        line.time = String(time)
        line.severity = severity(for: priority)

        // `D/ActivityManager(` — the tag runs from the slash to the pid's opening bracket, and the
        // pid itself is right-aligned in a fixed width so the colon that ends it may be one, two or
        // several tokens away. Everything up to that colon is the header.
        line.tag = String(tagName(in: head.dropFirst(2)))
        // The rest of the header — `1234):` and whatever padding — is consumed by finding the first
        // colon that closes the bracket, which may be in this token or a later one.
        line.message = String(bodyAfterHeader(head: head, rest: rest))
        return line
    }

    // MARK: The grammar

    /// The next whitespace-delimited run, consumed from `rest`. ``DeviceLogLexer``'s, because the
    /// two consoles' grammars diverge AFTER the tokens, not at them.
    private static func token(_ rest: inout Substring) -> Substring? {
        DeviceLogLexer.token(&rest)
    }

    /// `08-04` — `logcat` prints no year, which is the one thing this grammar's date does not share
    /// with the unified log's.
    private static func isDate(_ token: Substring) -> Bool {
        DeviceLogLexer.isDate(token, length: 5)
    }

    /// `13:50:19.565`. Shape, not value — validating the clock here would reject a log written
    /// across a timezone change.
    private static func isTime(_ token: Substring) -> Bool {
        DeviceLogLexer.isTime(token)
    }

    /// `logcat`'s priority letters. Checked so a line whose third token happens to start with a
    /// capital does not become a severity nobody sent.
    private static func isPriority(_ character: Character) -> Bool {
        "VDIWEFAS".contains(character)
    }

    private static func severity(for priority: Character) -> Severity {
        switch priority {
        // `A` is `logcat`'s ASSERT, which is what a native abort prints. Same bucket as fatal:
        // both mean the process is going away.
        case "F",
             "A": .fatal
        case "E": .error
        case "W": .warning
        case "I": .info
        default: .plain
        }
    }

    /// `ActivityManager( 1234)` → `ActivityManager`. A tag with no bracket is passed through whole;
    /// an empty tag (`logcat` allows one) yields an empty string rather than a placeholder.
    private static func tagName(in header: Substring) -> Substring {
        guard let bracket = header.firstIndex(of: "(") else { return header }
        return header[..<bracket].drop(while: \.isWhitespace)
    }

    /// The message, which starts after the `):` that closes the pid.
    ///
    /// The pid is right-aligned into a fixed-width field, so its width decides where the header ends:
    /// `( 1234):` carries a space and splits the header across two tokens, while `(12345):` closes
    /// inside the first one. Both are pinned in the tests, because the wide case is the ordinary one
    /// on a device that has been up for a while and getting it wrong drops the whole message.
    ///
    /// The colon is searched for AFTER the bracket, never before it: a tag is allowed to contain one
    /// (`Choreographer:x`), and the first colon in the token would then cut the header short.
    private static func bodyAfterHeader(head: Substring, rest: Substring) -> Substring {
        if let bracket = head.firstIndex(of: "("),
           let colon = head[bracket...].firstIndex(of: ":")
        {
            let body = head[head.index(after: colon)...].drop(while: \.isWhitespace)
            // The colon closed the token. Everything after it is the message, and it is in `rest`.
            return body.isEmpty ? rest.drop(while: \.isWhitespace) : body
        }
        guard let colon = rest.firstIndex(of: ":") else { return rest.drop(while: \.isWhitespace) }
        return rest[rest.index(after: colon)...].drop(while: \.isWhitespace)
    }
}

/// The priorities `logcat`'s own filter spec accepts, in ascending severity.
///
/// The set is closed because the letter is interpolated into `*:<level>` and reaches an argument
/// vector: `logcat` treats an unparsable filter spec as a fatal error, which reads as a console that
/// connects and immediately dies. The host validates the same set again — this is a menu, not a
/// guarantee.
enum AndroidLogLevel: String, CaseIterable, Identifiable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verbose: "Verbose"
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}
#endif
