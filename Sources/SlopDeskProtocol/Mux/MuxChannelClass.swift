import Foundation

/// What a mux channel is FOR (`MuxChannelOpen.channelClass`, docs/45 §5.1).
///
/// The field has been encoded, decoded and golden-pinned since the mux landed — and read nowhere.
/// That made it a free seam: the workspace document rides an ordinary `channelOpen` with a different
/// class byte, so no envelope changed shape and no existing client noticed.
///
/// An unknown class from a newer peer is refused with `accepted: false`, never guessed at. Guessing
/// would route a workspace channel into the PTY spawn path and fork a shell nobody asked for.
public enum MuxChannelClass: UInt8, Sendable, CaseIterable {
    /// The PTY channel. One shell per sessionID; a second open on a live one JOINS it.
    case pane = 0
    /// The workspace-document channel: at most ONE per mux connection, CONTROL sub-channel only
    /// (the DATA sub-channel `openChannel` also creates stays idle).
    case workspace = 1
    /// A READ-ONLY subscriber on a pane another client already holds (docs/45 §8.4). The host joins
    /// it to the existing session — one PTY, N readers — and DROPS its `input` frames while still
    /// crediting them; it contributes nothing to the pane's size fold. Refused when no such pane is
    /// live — an observer joins something, it never creates one.
    case paneObserver = 2
}
