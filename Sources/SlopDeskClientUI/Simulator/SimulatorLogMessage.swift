// SimulatorLogLine — gone; what is left is the ENVELOPE and the filter menu.
//
// The grammar it was named for is `slopdesk_devicelog::unified` and the row it produced is
// ``DeviceLogLine``, which is now the one console row both device panels use. It was never a
// different type from Android's — the same four fields, the same "keep an unrecognised line
// verbatim" rule, and one field NAME apart (`process` against `tag`) for the same slot.
//
// What stays is what is the SIMULATOR SERVER's rather than the log's: the shape of the batch it
// wraps lines in, and the levels its `log stream` child accepts. The server batches into one
// envelope per ~50 ms rather than sending a message per line, so the socket's message rate is
// bounded whatever the device is doing.

#if os(macOS)
import Foundation

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

/// The log levels the server's own `--level` accepts, in ascending severity.
///
/// This stays Swift for the same reason ``AndroidLogLevel`` does: it is a MENU, not a grammar. The
/// set is closed because it is interpolated into a query the server passes to `log stream`
/// verbatim — an invented level still UPGRADES the socket and only dies later when the child
/// process refuses it, which reads as a console that connects and never prints.
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
