import AislopdeskClient
import Foundation

// MARK: - ConnectionPresenter (raw transport state → human, actionable copy)

/// Pure presentation policy for the app-global connection surfaces (the connect-gate card + the
/// toolbar status label). The transport layer surfaces raw error payloads ("POSIXErrorCode(rawValue:
/// 61): Connection refused", NWError dumps) — useful for debugging, useless for deciding what to DO.
/// This maps them to actionable strings while keeping the raw payload available as a tooltip
/// (``rawDetail(for:)``), and renders the reconnect campaign honestly ("attempt 3 of 20") so a
/// mid-session drop reads differently from a first connect.
///
/// A `nonisolated` enum of pure functions — fully unit-testable, no view, no actor.
public enum ConnectionPresenter {
    /// The supervisor's give-up ceiling, mirrored from ``ReconnectManager/maxReconnectAttempts`` (the
    /// single source of truth, in the lower module) so "attempt N of M" can never drift from EITHER the
    /// app-global supervisor (``AppConnection``, which reads this) or the per-pane transport campaign
    /// (``ReconnectManager``, which owns it). One constant — change it once, everyone follows.
    public static let maxReconnectAttempts = ReconnectManager.maxReconnectAttempts

    /// Maps a raw transport failure payload to an actionable message. Substring-matched (the payloads
    /// are `String(describing:)` dumps with no stable structure); unknown payloads pass through
    /// verbatim — never hide information we cannot improve.
    public static func friendlyFailure(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("refused") {
            return "Connection refused — is aislopdesk-hostd running on the host?"
        }
        if lower.contains("no route") || lower.contains("ehostunreach") {
            return "No route to host — check the address and that both machines share a network or VPN."
        }
        if lower.contains("timed out") || lower.contains("etimedout") || lower.contains("timeout") {
            return "Timed out — the host didn't answer. Check the port and any firewall."
        }
        if lower.contains("network is down") || lower.contains("enetdown") {
            return "Network is down — check Wi-Fi or Ethernet."
        }
        if lower.contains("nosuchrecord") || lower.contains("dns") || lower.contains("hostname") {
            return "Hostname not found — check the host name."
        }
        if lower.contains("reset") {
            return "Connection reset — the host daemon may have crashed. Restart aislopdesk-hostd."
        }
        // The TCP connected but the aislopdesk handshake didn't complete — wrong daemon, a version
        // mismatch, or a bad mux preamble (AislopdeskTransportError.handshakeFailed's errorDescription
        // carries the word "handshake"). Distinct from "refused": something IS listening, it just isn't
        // a compatible aislopdesk-hostd.
        if lower.contains("handshake") {
            return "The host answered but isn't a compatible aislopdesk host — check it's running "
                + "aislopdesk-hostd and that the versions match."
        }
        // A clean drop mid-session (receiveFailed → "Connection lost", or an EOF / closed-by-peer): the
        // link is gone, not refused. Auto-reconnect handles a transient drop; a terminal .failed here
        // means it gave up — say so and offer Retry.
        if lower.contains("connection lost") || lower.contains("connection closed")
            || lower.contains("eof") || lower.contains("not connected") || lower.contains("enotconn")
            || lower.contains("broken pipe") || lower.contains("epipe")
        {
            return "Connection lost — the host or network dropped. Check the host is up, then Retry."
        }
        // A bare "Connection failed" (NWConnection failed before readiness with no more specific cause):
        // enrich it with the first thing to check rather than leaving the terse transport phrase.
        if lower == "connection failed" {
            return "Couldn't reach the host — check the address and port, and that aislopdesk-hostd is running."
        }
        return raw
    }

    /// The gate card's status line. Sentence-cased, actionable, and honest about which state this is:
    /// a first "Connecting…" is not a "Reconnecting — attempt 3 of 20".
    public static func headline(for status: ConnectionStatus) -> String {
        switch status {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected"
        case let .reconnecting(attempt, _):
            attempt > 0
                ? "Reconnecting — attempt \(attempt) of \(maxReconnectAttempts)"
                : "Reconnecting…"
        case .unreachable:
            "Unreachable — the host stopped answering. Check it, then Retry."
        case let .failed(raw):
            friendlyFailure(raw)
        }
    }

    /// The raw transport payload worth a tooltip — non-`nil` ONLY when ``friendlyFailure(_:)``
    /// actually rewrote it (a passthrough message would just duplicate the headline).
    public static func rawDetail(for status: ConnectionStatus) -> String? {
        guard case let .failed(raw) = status, friendlyFailure(raw) != raw else { return nil }
        return raw
    }

    /// The compact toolbar form: campaign progress without the prose, and a failure never dumps its
    /// raw payload into the menu-bar label (the gate card carries the actionable copy).
    public static func shortLabel(for status: ConnectionStatus) -> String {
        switch status {
        case let .reconnecting(attempt, _) where attempt > 0:
            "reconnecting \(attempt)/\(maxReconnectAttempts)"
        case .failed:
            "failed"
        default:
            status.label
        }
    }
}
