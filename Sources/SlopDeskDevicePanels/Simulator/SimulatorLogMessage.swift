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

import CSlopDeskFFI
import Foundation

/// What arrives on the log socket. Two shapes and a catch-all.
///
/// The CASES stay here, because they are what the connection's `switch` reads. The GRAMMAR is
/// `slopdesk_devicepanel::sim_log`, reached through the door below: an untrusted payload parsed on
/// this side was the last `JSONSerialization` call in the simulator's half of the panel, and a
/// decoder for a wire this side does not control belongs where the rest of them already are.
package enum SimulatorLogMessage: Equatable {
    /// The server has the `log stream` child up. Worth its own case: it is the only signal that
    /// separates "connected but the device is quiet" from "connected and nothing works".
    case started
    case lines([String])
    case unknown

    package static func decode(_ text: String) -> Self {
        var blob = DevicePanelBlob { out, cap in
            devicePanelLend(text) { bytes, count in
                slopdesk_sim_log_message(bytes, count, out, cap)
            }
        }
        // A refusal is a `type` this build has no case for — or a payload that is not the envelope
        // at all. It costs the panel that MESSAGE and never the socket: a newer server that adds a
        // shape must not read as a console that connected and then died.
        guard !blob.isRefusal else { return .unknown }
        guard blob.byte() == UInt8(SLOPDESK_SIM_LOG_LINES) else { return .started }
        // The count rides inside the blob because an EMPTY batch is a real answer — the server
        // sends one when a filter matches nothing — and it must not read as the refusal.
        let count = blob.count32()
        return .lines(blob.texts(count))
    }
}

/// The log levels the server's own `--level` accepts, in ascending severity.
///
/// This stays Swift for the same reason ``AndroidLogLevel`` does: it is a MENU, not a grammar. The
/// set is closed because it is interpolated into a query the server passes to `log stream`
/// verbatim — an invented level still UPGRADES the socket and only dies later when the child
/// process refuses it, which reads as a console that connects and never prints.
package enum SimulatorLogLevel: String, CaseIterable, Identifiable {
    case debug
    case info
    case notice
    case error
    case fault

    package var id: String { rawValue }

    /// Title case for the menu. The wire value stays lowercase — this is display only.
    package var title: String { rawValue.capitalized }
}
