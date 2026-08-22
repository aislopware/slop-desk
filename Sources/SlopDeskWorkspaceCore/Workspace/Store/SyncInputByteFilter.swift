import CSlopDeskFFI
import Foundation

// MARK: - SyncInputByteFilter (keyboard-only mirror hygiene for the sync-input fan-out)

/// Strips the NON-KEYBOARD sequences out of an input chunk before ``WorkspaceStore/fanSyncInput(from:_:)``
/// mirrors it into sibling panes.
///
/// ## Why
/// The sync-input tap rides ``TerminalViewModel/sendInput(_:)`` — the pane's single OUT funnel — which
/// carries MORE than keystrokes: the terminal emulator answers its shell's queries (CPR `ESC[row;colR`,
/// DA `ESC[?…c`, XTWINOPS `ESC[8;…t`, DECRPM `ESC[?…$y`, kitty-flags `ESC[?…u`, OSC color/clipboard
/// replies, DCS `XTGETTCAP` replies) and streams mouse reports (`ESC[<…M/m`, `ESC[M…`) and focus events
/// (`ESC[I`/`ESC[O`) through the same path. Those bytes are answers to questions only the SOURCE pane's
/// shell asked; mirrored into a sibling shell that never asked, they type garbage onto its command line —
/// and the next mirrored `↩` EXECUTES it (observed in the field: a scroll burst + a window report ran as
/// a command in the sibling).
///
/// ## What survives
/// Everything a keyboard or paste actually produces: plain bytes/UTF-8, control bytes, `ESC`-prefixed
/// keys (SS3 `ESC O …`, CSI arrows/nav/`~`-keys, kitty `CSI code;mods u` — the non-private form),
/// bracketed-paste wrappers + body (`type once, run everywhere` covers paste).
///
/// A face over `slopdesk-sanitize`'s `syncinput`, which reads this grammar through the same scanner the
/// replay passes share. This file used to hand-roll `parseCSI` and `stringSequenceEnd` under a
/// "mirror, don't share" comment, which made it a SIXTH copy of a grammar `vtscan` exists to have
/// exactly one of — and the one copy on the INPUT path, where a disagreement about where a sequence ends
/// does not merely render wrong, it runs as a command in someone else's shell.
///
/// The accepted gaps and the truncated-tail convention are documented on the Rust side, where the
/// decisions now live. PURE + `nonisolated`.
public enum SyncInputByteFilter {
    /// Returns `data` with terminal-reply and mouse/focus-report sequences removed.
    /// The strip only ever REMOVES bytes, so the chunk's own length is the answer's ceiling and the first
    /// guess is exact arithmetic rather than an estimate. Probing with a null output instead ran the whole
    /// `vtscan` pass twice over the same chunk to learn a number already in hand — measured 14.4 µs against
    /// 7.5 µs on an 8 KiB mirrored paste, and 0.37 µs against 0.32 µs on a keystroke burst. The `needed >
    /// cap` arm below is docs/55 §4's retry and is unreachable at this guess; it stays so a future grammar
    /// that could GROW a chunk costs a second scan rather than a truncated one, which on this path would
    /// mean half a paste landing in a sibling shell.
    public static func keyboardOnly(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { input -> Data in
            guard !input.isEmpty else { return Data() }
            var room = [UInt8](repeating: 0, count: input.count)
            let needed = room.withUnsafeMutableBufferPointer { out in
                slopdesk_sync_input_keyboard_only(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            // Nothing survived the strip — a chunk that was pure reports, or an empty one.
            guard needed > 0 else { return Data() }
            guard needed > input.count else {
                room.removeLast(input.count - needed)
                return Data(room)
            }
            var wider = [UInt8](repeating: 0, count: needed)
            let written = wider.withUnsafeMutableBufferPointer { out in
                slopdesk_sync_input_keyboard_only(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            return written == needed ? Data(wider) : Data()
        }
    }
}
