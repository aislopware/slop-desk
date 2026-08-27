// DevicePanelRules — the decisions both device panels make, and the marshalling behind them.
//
// The RULES live in `slopdesk_devicepanel`: one ensure round's endpoint → the phase to render, how
// soon to ask again, what to do about a selection with no video yet, and whether an arriving frame
// is worth telling the observable layer. What is left on this side is turning a `String?` into
// bytes and a kind byte back into a case.
//
// ## Why they moved
//
// They were written TWICE, in the same language: `AndroidSidebarModel` and `SimulatorSidebarModel`
// each carried a byte-identical `phase(for:host:)` and a byte-identical poll backoff, over two
// enums whose cases matched case for case. The panels differ in transport, in vocabulary and in
// every measured constant — a mirror over `adb` is not a WebSocket to `baguette` — but not in what
// an ENSURE verb's answer means. That part is one implementation now, and `DevicePanelPhase` is
// one type, with each panel's old name kept as an alias so each surface still reads in its own words.

import CSlopDeskFFI
import SlopDeskProtocol

/// The readiness phases a device panel renders. One value per distinct surface — each column's body
/// switches over this and nothing else.
package enum DevicePanelPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (the app is offline) or a host too
    /// old to know the verb — or it answered ready with nothing dialable. Keep polling: the
    /// connection may come up.
    case offline
    /// The host is still bringing the service up — spinner, keep polling.
    case starting
    /// The tool the service needs is not installed on the host — render the install hint. Still
    /// polled, slowly: a `just provision` run (or an SDK install) mid-session is
    /// picked up without a restart.
    case unavailable
    /// The service is reachable at this address. Everything else the panel does hangs off it.
    case ready(host: String, port: UInt16)
}

/// What to do about a selected device that has not produced a frame yet.
package enum DeviceStreamVerdict: Equatable {
    /// The device is ready — open (or re-open) the mirror now.
    case connect
    /// Not ready yet, patience left — keep the veil up and look again shortly.
    case wait
    /// The device left the list entirely. Say so and go back; there is nothing to look at.
    case gone
    /// Patience ran out on a RUNNING device — the stall message, with the retry button.
    case stalled
    /// Patience ran out on a device that never reached its running state.
    case neverReady
}

/// The crossing: scalars in, a kind back.
package enum DevicePanelRules {
    /// One ensure round's endpoint → the phase to render.
    ///
    /// A `ready` endpoint with no usable address degrades to ``DevicePanelPhase/offline``, never a
    /// trap — the rule's own, including the emptiness test on `host`, which is why the string
    /// crosses rather than a `Bool` derived from it here.
    package static func phase(
        for endpoint: MetadataCodec.ServiceEndpoint?, host: String?,
    ) -> DevicePanelPhase {
        let address = Array((host ?? "").utf8)
        let kind = address.withUnsafeBufferPointer { bytes in
            slopdesk_device_panel_phase(
                endpoint != nil,
                endpoint?.stateByte ?? 0,
                endpoint?.port ?? 0,
                bytes.baseAddress,
                bytes.count,
            )
        }
        switch kind {
        case UInt8(SLOPDESK_DEVICE_PANEL_STARTING): return .starting
        case UInt8(SLOPDESK_DEVICE_PANEL_UNAVAILABLE): return .unavailable
        case UInt8(SLOPDESK_DEVICE_PANEL_READY):
            // Restating a premise the door already held: it answers `ready` only for an endpoint
            // whose port is non-zero over a host that is neither nil nor empty. The `guard` is what
            // makes the two optionals total on this side, not a second copy of the test.
            guard let host, let endpoint else { return .offline }
            return .ready(host: host, port: endpoint.port)
        default: return .offline
        }
    }

    /// How many poll intervals `phase` waits before the ensure verb is asked again — `0` stops the
    /// loop, which is what a reached service does to the loop that was looking for it.
    package static func pollBackoff(_ phase: DevicePanelPhase) -> Int {
        let kind: Int32 =
            switch phase {
            case .offline: SLOPDESK_DEVICE_PANEL_OFFLINE
            case .starting: SLOPDESK_DEVICE_PANEL_STARTING
            case .unavailable: SLOPDESK_DEVICE_PANEL_UNAVAILABLE
            case .ready: SLOPDESK_DEVICE_PANEL_READY
            }
        return Int(slopdesk_device_panel_poll_backoff(UInt8(kind)))
    }

    /// The verdict for a selected device, where `isRunning` is `nil` for a device the latest list no
    /// longer carries.
    package static func streamVerdict(
        isRunning: Bool?, withinGrace: Bool,
    ) -> DeviceStreamVerdict {
        let kind = slopdesk_device_panel_stream_verdict(
            isRunning != nil, isRunning ?? false, withinGrace,
        )
        switch kind {
        case UInt8(SLOPDESK_DEVICE_PANEL_CONNECT): return .connect
        case UInt8(SLOPDESK_DEVICE_PANEL_WAIT): return .wait
        case UInt8(SLOPDESK_DEVICE_PANEL_STALLED): return .stalled
        case UInt8(SLOPDESK_DEVICE_PANEL_NEVER_READY): return .neverReady
        default: return .gone
        }
    }

    /// Whether an arriving frame has anything to tell the observable layer.
    ///
    /// Called on EVERY frame, so it must be free once the first has landed: `@Observable` notifies
    /// on assignment rather than on change, and a handler that writes `hasVideo = true` per access
    /// unit invalidates every view reading it at the frame rate.
    package static func videoArrivalIsNews(hasVideo: Bool, isAwaitingStream: Bool) -> Bool {
        slopdesk_device_panel_video_is_news(hasVideo, isAwaitingStream)
    }
}
