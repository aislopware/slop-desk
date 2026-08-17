// AndroidLogLine — gone; what is left is the FILTER MENU.
//
// The grammar it was named for is `slopdesk_devicelog::logcat` and the row it produced is
// ``DeviceLogLine``, which is now the one console row both device panels use. It was never a
// different type from the simulator's — the same four fields, the same "keep an unrecognised line
// verbatim" rule, and one field NAME apart (`tag` against `process`) for the same slot.
//
// The parse moved for the reason `docs/55` gives: it ran over text a program on the far side of a
// device wrote, thousands of lines a minute, on the socket read path, asking `Character.isNumber`
// per grapheme cluster and building four `String`s a row.

#if os(macOS)

/// The priorities `logcat`'s own filter spec accepts, in ascending severity.
///
/// This stays Swift because it is a MENU, not a grammar: five cases, a title each, and nothing to
/// parse. The set is closed because the letter is interpolated into `*:<level>` and reaches an
/// argument vector — `logcat` treats an unparsable filter spec as a fatal error, which reads as a
/// console that connects and immediately dies. The host validates the same set again; this is the
/// menu, not the guarantee.
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
