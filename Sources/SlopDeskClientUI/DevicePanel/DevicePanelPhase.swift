#if os(macOS)
import SlopDeskProtocol

/// What a device panel's sidebar is showing, before it shows any device at all.
///
/// The two panels reach their bridge the same way — a metadata `ensure` verb answers a
/// ``MetadataCodec/ServiceEndpoint``, the sidebar polls it, and the answer is one of four states.
/// Both had their own enum with these exact four cases and the same associated values, and their own
/// copy of the mapping from endpoint to case. That mapping has one non-obvious rule in it (a `ready`
/// endpoint with no usable address degrades to `.offline` rather than trapping on a zero port), which
/// is precisely the kind that gets fixed on one side and not the other.
///
/// What genuinely differs is what each state MEANS — `.unavailable` is "no `adb`" for one panel and
/// "no `baguette` binary" for the other, and the ensure verb is 22 vs 21. That is per-panel prose, so
/// it stays on each panel's typealias where its reader is.
enum DevicePanelPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (app offline) or a host too old to
    /// know the verb. Keep polling: the connection may come up.
    case offline
    /// The host is still bringing the bridge up — spinner, keep polling.
    case starting
    /// The host cannot provide the bridge at all — render the install hint. Still polled (slowly):
    /// installing the missing tool mid-session is picked up without a restart.
    case unavailable
    /// The bridge is reachable at this address. Everything else the panel does hangs off it.
    case ready(host: String, port: UInt16)

    /// One ensure round's endpoint → the phase to render. Pure.
    ///
    /// A `ready` endpoint whose address is unusable — no host string, or port `0` — degrades to
    /// ``offline`` rather than being trusted: the panel would otherwise dial nowhere and sit on a
    /// spinner with no poll left to rescue it, and `.offline` is exactly the state that keeps polling.
    static func resolve(
        _ endpoint: MetadataCodec.ServiceEndpoint?, host: String?,
    ) -> Self {
        guard let endpoint else { return .offline }
        switch endpoint.state {
        case .unavailable: return .unavailable
        case .starting: return .starting
        case .ready:
            guard let host, !host.isEmpty, endpoint.port != 0 else { return .offline }
            return .ready(host: host, port: endpoint.port)
        }
    }

    /// The address to dial, or `nil` in every state that has none.
    var address: (host: String, port: UInt16)? {
        guard case let .ready(host, port) = self else { return nil }
        return (host, port)
    }
}
#endif
