/// Why a video session ended with NO rebuild — the pane leaves its live surface and says why.
///
/// Two ends, two sentences. A host that ANSWERED and said no is `helloAck(accepted: false)`; a host
/// that never answered inside ``KeepaliveTiming/helloDeadline`` is nothing listening at the
/// address the pane dialled — no `slopdesk-videohostd` on that machine, or one on other ports —
/// and the fix for each is different enough that telling the user the wrong one costs them the
/// evening. Both are terminal: the rebuild path (a received `bye`) is for a host that will be back.
public enum VideoSessionRefusal: Sendable, Equatable {
    /// `helloAck(accepted: false)`: the window is gone on the host, or the two halves disagree
    /// about the protocol (the mux mint-failure refusal included).
    case rejectedByHost
    /// No control datagram at all inside ``KeepaliveTiming/helloDeadline`` of activation.
    case hostUnreachable
}
