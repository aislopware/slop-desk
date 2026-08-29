import CSlopDeskFFI

// What is left of the PATH-1 mux in Swift: three names the UI and the workspace layer SAY, and no
// machinery at all. `docs/63` stage G.3 moved the client mux — the two sockets, the envelope codec,
// the channel table, the admission rules, the per-channel window and both sub-channels — into
// `rust/slopdesk-clientnet` and `rust/slopdesk-muxnet`, reached through `slopdesk_mux_transport_*`.
// The eight files that used to sit beside this one are gone, and so is `Sources/SlopDeskTransport`'s
// whole `Mux/` machinery.
//
// These three stay because each has a live caller OUTSIDE the mux and each is VOCABULARY — a name a
// switch statement or a bound reads — rather than a second implementation of anything. That is the
// same carve `docs/63` G.4 makes for the `WireMessage` enum: the value the UI switches on is Swift,
// the behaviour behind it is Rust's.

/// What a mux channel is FOR (`MuxChannelOpen.channelClass`, docs/45 §5.1).
///
/// Read by `WorkspaceStore+WorkspaceMirror` when it opens the workspace document's channel, and
/// passed straight through `slopdesk_mux_transport_open`'s `channel_class` byte. An unknown class
/// from a newer peer is refused by the host with `accepted: false`, never guessed at: guessing would
/// route a workspace channel into the PTY spawn path and fork a shell nobody asked for.
public enum MuxChannelClass: UInt8, Sendable, CaseIterable {
    /// The PTY channel. One shell per sessionID; a second open on a live one JOINS it.
    case pane = 0
    /// The workspace-document channel: at most ONE per mux connection, CONTROL sub-channel only
    /// (the DATA sub-channel the open also creates stays idle).
    case workspace = 1
    // 2 is spoken for and served by nobody: a peer that sends it is refused like any other class
    // this host does not route. The next class to land takes 3, so one byte never names two things.
}

/// WHY a peer closed one channel — the half of a `channelClose` that decides what the other end may
/// do next.
///
/// Above the transport a close is a stream that ended, and the two reasons a host closes a PANE
/// channel demand opposite answers. The reason is ADVICE about recovery, never permission to skip
/// the teardown: every value closes the channel identically. An absent body and an unrecognised
/// byte both read as ``retired`` — the conservative reading, which withholds the automatic re-dial
/// rather than inventing one.
///
/// The raw byte now arrives through `MuxClientTransport`'s ended callback rather than out of a
/// Swift envelope decoder, so ``init(rawValue:)``'s failure case is reached by a byte a newer host
/// invented; `SlopDeskClient.hostChannelCloseReason` is the public read.
public enum MuxCloseReason: UInt8, Sendable, Equatable, CaseIterable {
    /// The channel names something the peer no longer has: the document reaped the pane, or that
    /// side is done with it. Re-opening under the same session id is a fresh SPAWN, so nothing
    /// automatic may dial it again — recovery is an explicit user re-dial.
    case retired = 0
    /// Only THIS subscriber's attachment ended — the pane, its shell and its other members are
    /// untouched (a laggard removed to protect the session). Re-opening resumes a session the host
    /// still holds, so it is a reattach rather than a spawn; what it must not be is a reflex,
    /// because an instant re-dial re-joins to be evicted again.
    case subscriberEvicted = 1
}

/// The two flow-control bounds a caller outside the mux still has to know.
///
/// Both are ASKED for rather than typed, from `rust/slopdesk-wire`'s `mux::flow`, which reads each
/// env override once. That was already true before the port and it is the reason this enum survived
/// it: a window typed on both sides of a boundary is the cheapest possible way for two processes to
/// disagree, and the disagreement that matters — a host window below the client's grant threshold —
/// presents as a channel that stalls forever on its first flood rather than as a mistake anyone can
/// see.
///
/// The other five constants the Rust door vends are read INSIDE the mux now, so they are not
/// re-exported here. A constant with no Swift caller is a second spelling that compiles.
public enum MuxFlowControl {
    /// Split cap for client→host `.input` frames (paste). `MuxClientTransport` does not read this —
    /// `slopdesk_mux_transport_send_input` splits at the same cap on the Rust side — but
    /// `ConnectGate` sizes its own input bound from it, so the two agree by asking one source.
    ///
    /// Cross-clamped against the env-tunable window at its source, so a low `SLOPDESK_MUX_WINDOW`
    /// can never reintroduce the frame ≥ window/2 dead zone on the input direction.
    public static var maxDataMessagePayloadBytes: Int { Int(slopdesk_mux_flow_constant(1)) }

    /// The PROVABLY-SAFE payload cap for host `.output` frames — where the credit progress
    /// invariant is enforced. window/2 minus a 16-byte margin (≥ the 13-byte `.output` header),
    /// cross-clamped against the merge cap so env-tuning either knob cannot produce a deadlocking
    /// combination. Read by `ReplayBuffer`'s cold-reattach path, which must not hand the transport
    /// a frame the window cannot clear.
    public static var maxOutputFramePayloadBytes: Int { Int(slopdesk_mux_flow_constant(5)) }
}
