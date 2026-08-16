import SlopDeskNet

/// The inspector's event lane IS the shared ``NWByteChannel`` — the second TCP connection
/// (`docs/00` ③, `docs/16` §3), multiplexed on the same WireGuard tunnel beside the terminal PTY
/// stream. Framing is ``InspectorFrameDecoder`` / ``InspectorCodec`` one layer up.
///
/// The actor moved to `SlopDeskNet` because PATH-4's file transfer had a byte-for-byte copy of it.
/// What stays here is this line: ``ByteChannel`` is the inspector's own vocabulary, and the pure
/// tests still swap in ``LoopbackByteChannel`` for determinism.
extension NWByteChannel: ByteChannel {}
