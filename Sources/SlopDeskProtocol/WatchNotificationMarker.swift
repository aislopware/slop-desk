import CSlopDeskFFI
import Foundation

// The private sentinel that lets `slopdesk watch` route its finish banner to the
// dedicated "Notify on Watch Finish" toggle instead of the generic "Allow App Notifications" master switch.
//
// `watch` finishes a wrapped command by emitting an OSC 777 desktop-notification whose TITLE field is this
// marker (`ESC ] 777 ; notify ; <marker> ; <message> ST`). The host's sniffer (`rust/slopdesk-superd/src/sniffer.rs`) parses that into
// a plain ``WireMessage/notification(title:body:)`` (NO new binary-wire format — the marker travels as the
// title string, the existing type-25 notification). On the client, the pure classifier
// (`NotificationEvent.classifyExplicit`) recognises the marker, STRIPS it, and routes the banner to
// `NotificationEvent.watchFinish` (gated by Notify on Watch Finish) rather than `.explicitOSC` (the master
// switch). `-q`/`--quiet` stays the LOCAL suppression (the watch wrapper emits no notification bytes at all).
//
// Faced HERE in the shared low-level protocol module so the CLI emitter (`SlopDeskCLICore.WatchProgress`)
// and the client router (`SlopDeskWorkspaceCore.NotificationEvent`) read ONE source of truth — which is
// `rust/slopdesk-wire`'s `osc`, the crate that both emits the banner and parses it back.

public enum WatchNotificationMarker {
    /// The control-char-framed sentinel placed in the OSC-777 notification TITLE by `slopdesk watch` on
    /// finish. Framed with `US` (0x1F, unit separator) so it can never collide with a real child-set title,
    /// and contains NO `;` so the OSC-777 `;`-split preserves it intact as a single title field.
    public static let title: String = {
        let needed = slopdesk_watch_notification_marker(nil, 0)
        guard needed > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: needed)
        let written = bytes.withUnsafeMutableBufferPointer { out in
            slopdesk_watch_notification_marker(out.baseAddress, out.count)
        }
        guard written == needed else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }()
}
