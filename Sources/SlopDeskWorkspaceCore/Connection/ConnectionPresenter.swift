import CSlopDeskFFI
import Foundation
import SlopDeskClient
import SlopDeskWorkspaceModel

// MARK: - ConnectionPresenter (raw transport state → human, actionable copy)

/// Presentation policy for the app-global connection surfaces (the connect-gate card + the toolbar
/// status label), as a face over `slopdesk_workspace::connection`.
///
/// The transport layer surfaces raw error payloads ("POSIXErrorCode(rawValue: 61): Connection
/// refused", NWError dumps) — useful for debugging, useless for deciding what to DO. The rules crate
/// maps them to actionable strings while keeping the raw payload available as a tooltip
/// (``rawDetail(for:)``), and renders the reconnect campaign honestly ("attempt 3 of 20") so a
/// mid-session drop reads differently from a first connect.
///
/// The three WORDS come back in ONE crossing (``words(for:)``), because every surface that draws a
/// status draws it beside its own fallback: the gate card wants the headline, the toolbar wants the
/// compact form, and both want the plain state name underneath. Three doors would have been three
/// crossings for one line of text — the same retreat ``SettingsCatalog`` already made.
public enum ConnectionPresenter {
    /// The supervisor's give-up ceiling, from ``ReconnectManager/maxReconnectAttempts`` (the single
    /// source of truth, in the lower module) so "attempt N of M" can never drift from EITHER the
    /// app-global supervisor (``AppConnection``, which reads this) or the per-pane transport campaign
    /// (``ReconnectManager``, which owns it).
    ///
    /// It crosses as an ARGUMENT to every door that phrases a retry. A `const` on the Rust side would
    /// be a second place to change it, and the one that could not see this one move.
    public static let maxReconnectAttempts = ReconnectManager.maxReconnectAttempts

    /// Maps a raw transport failure payload to an actionable message. Substring-matched (the payloads
    /// are `String(describing:)` dumps with no stable structure); unknown payloads pass through
    /// verbatim — never hide information we cannot improve.
    public static func friendlyFailure(_ raw: String) -> String {
        headline(for: .failed(raw))
    }

    /// The gate card's status line. Sentence-cased, actionable, and honest about which state this is:
    /// a first "Connecting…" is not a "Reconnecting — attempt 3 of 20".
    public static func headline(for status: ConnectionStatus) -> String {
        words(for: status).headline
    }

    /// The compact toolbar form: campaign progress without the prose, and a failure never dumps its
    /// raw payload into the menu-bar label (the gate card carries the actionable copy).
    public static func shortLabel(for status: ConnectionStatus) -> String {
        words(for: status).shortLabel
    }

    /// The plain state name — what ``ConnectionStatus/label`` is, and what every compact reading
    /// falls back to.
    public static func statusLabel(for status: ConnectionStatus) -> String {
        words(for: status).statusLabel
    }

    /// The raw transport payload worth a tooltip — non-`nil` ONLY when the classifier actually
    /// rewrote it (a passthrough message would just duplicate the headline).
    ///
    /// The door answers a yes/no and never hands the payload back: this side is already holding the
    /// string it passed in, and a copy made only to be compared with the one it came from is the
    /// crossing `rust/slopdesk-devicepanel`'s charter names.
    public static func rawDetail(for status: ConnectionStatus) -> String? {
        guard case let .failed(raw) = status else { return nil }
        var bytes = Array(raw.utf8)
        let rewritten = bytes.withUnsafeMutableBufferPointer {
            slopdesk_connection_has_raw_detail(
                SLOPDESK_CONNECTION_STATUS_FAILED, $0.baseAddress, $0.count,
            )
        }
        return rewritten ? raw : nil
    }

    /// The three registers of one status, in one crossing: the gate card's headline, the compact
    /// toolbar form, and the plain state name.
    public static func words(
        for status: ConnectionStatus,
    ) -> (headline: String, shortLabel: String, statusLabel: String) {
        let terms = status.terms
        var raw = Array(terms.raw.utf8)
        let blob = raw.withUnsafeMutableBufferPointer { payload in
            wsAnswerBytes { out, cap in
                slopdesk_connection_words(
                    terms.code, terms.attempt, UInt32(max(0, maxReconnectAttempts)),
                    payload.baseAddress, payload.count, out, cap,
                )
            }
        }
        let runs = wsRuns(blob, count: 3)
        return (headline: runs[0], shortLabel: runs[1], statusLabel: runs[2])
    }
}

public extension ConnectionStatus {
    /// This status in `slopdesk_ffi::connection`'s vocabulary: which state, how far the campaign has
    /// got, and the transport's own failure payload.
    ///
    /// Three flat values rather than the enum, because the two things a door needs from a
    /// `.reconnecting` or a `.failed` are exactly the ones the case carries — and `nextRetry` is a
    /// `Date` the countdown ticks against, which no word ever names.
    var terms: (code: UInt32, attempt: UInt32, raw: String) {
        switch self {
        case .disconnected: (SLOPDESK_CONNECTION_STATUS_DISCONNECTED, 0, "")
        case .connecting: (SLOPDESK_CONNECTION_STATUS_CONNECTING, 0, "")
        case .connected: (SLOPDESK_CONNECTION_STATUS_CONNECTED, 0, "")
        case let .reconnecting(attempt, _):
            (SLOPDESK_CONNECTION_STATUS_RECONNECTING, UInt32(max(0, attempt)), "")
        case .unreachable: (SLOPDESK_CONNECTION_STATUS_UNREACHABLE, 0, "")
        case let .failed(raw): (SLOPDESK_CONNECTION_STATUS_FAILED, 0, raw)
        }
    }
}
