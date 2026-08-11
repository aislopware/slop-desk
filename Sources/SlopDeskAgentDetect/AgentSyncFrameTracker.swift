import Foundation

/// Tracks whether the PTY byte stream fed so far ends INSIDE an open synchronized update
/// (`CSI ? 2026 h` … `CSI ? 2026 l`, DEC private mode 2026) — i.e. whether the terminal grid
/// built from those bytes is a FRAME the program has finished painting, or a half-applied one.
///
/// ## Why the detection engine needs this
/// An inline TUI repaints by moving the cursor around the live widget region and rewriting it in
/// place, erasing lines (`CSI K`) before it writes their replacement. Mode 2026 is the program
/// SAYING SO: "hold rendering, this grid is inconsistent until I close the frame". Claude Code
/// wraps every repaint in one (344 frames in a 53 KB captured `AskUserQuestion` session).
///
/// ``PaneScreenScanner`` reads the grid on a ~300 ms timer against whatever bytes the PTY read
/// loop happened to hand over, which lands mid-frame whenever a repaint spans a chunk boundary.
/// The manifest engine then reads a screen that momentarily has no dialog footer on it and calls
/// a pane blocked on a modal IDLE — and because the dialog's own option list carries the `❯`
/// pointer, the winning fallback is `live_prompt_box`, whose `visible_idle` is the ONE screen
/// verdict strong enough to clear an authoritative hook block. Result: one blocked → idle →
/// blocked lap per repaint, each lap a fresh attention edge and a false completion (user-reported
/// 2026-08-11: Tab-switching between `AskUserQuestion` questions walked the mark idle ↔ blocked).
///
/// Deferring costs nothing: the model is CUMULATIVE, so the very next scan (≤ 100 ms while the
/// hold stands) sees the closed frame and a consistent grid, and the previous verdict stands in
/// the meantime — a repaint changes what is on screen, not what the agent is doing. The sibling
/// of ``PaneScreenScanner``'s `awaitingRepaintAfterRebuild` guess, at frame granularity.
///
/// ## Shape
/// A byte-at-a-time state machine, so a `CSI ? 2026 h` SPLIT across two `observe` calls still
/// registers (the whole point — the split is what causes the tear). String sequences (OSC / DCS /
/// SOS / PM / APC) are skipped opaquely so an embedded `?2026h` inside a title cannot open a
/// frame, matching ``SyncUpdateFrameCollapser``. Pure + total: any byte sequence is tolerated,
/// the parameter buffer is bounded, nothing traps.
///
/// 2026 is a FLAG, not a counter — the spec does not define nesting, and terminals treat the last
/// `h`/`l` as the state. `ESC c` (RIS) closes any open frame: a full reset ends the repaint.
public struct AgentSyncFrameTracker: Sendable, Equatable {
    /// Bound on one CSI's collected parameter bytes (a hostile stream must not grow this).
    static let maxParamBytes = 64

    private enum State: Equatable {
        case ground
        case escape
        /// Collecting a CSI's parameter + intermediate bytes.
        case csi
        /// Inside an OSC/DCS/SOS/PM/APC body (skipped opaquely).
        case string
        /// Saw `ESC` inside a string body — a `\` completes ST.
        case stringEscape
    }

    private var state: State = .ground
    private var params: [UInt8] = []
    /// TRUE while the CSI being collected overflowed ``maxParamBytes`` (its final byte is ignored).
    private var paramsOverflowed = false
    /// TRUE when the current string body is OSC (BEL also terminates it).
    private var stringIsOSC = false

    /// TRUE while the bytes observed so far end inside an OPEN synchronized update.
    public private(set) var isFrameOpen = false

    /// Bumped every time a frame OPENS. Two scans that both see a frame open are looking at the
    /// same frame only if this matches — a caller timing out an over-long frame must key its
    /// deadline on this, or a continuous repaint stream (each scan a different, perfectly
    /// well-formed frame) reads as ONE frame stuck open and trips the timeout forever after.
    public private(set) var frameGeneration: UInt64 = 0

    public init() {}

    /// Drops parse + frame state (a grid REBUILD replays a fresh stream — the old parser position
    /// describes bytes that are no longer in the model).
    public mutating func reset() {
        state = .ground
        params.removeAll(keepingCapacity: true)
        paramsOverflowed = false
        stringIsOSC = false
        isFrameOpen = false
        frameGeneration = 0
    }

    /// Fold one chunk of raw PTY output — exactly the bytes the screen model was fed, in order.
    public mutating func observe(_ bytes: Data) {
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }

            case .escape:
                switch byte {
                case UInt8(ascii: "["):
                    params.removeAll(keepingCapacity: true)
                    paramsOverflowed = false
                    state = .csi
                case UInt8(ascii: "]"):
                    stringIsOSC = true
                    state = .string
                case UInt8(ascii: "P"),
                     UInt8(ascii: "X"),
                     UInt8(ascii: "^"),
                     UInt8(ascii: "_"):
                    stringIsOSC = false
                    state = .string
                case UInt8(ascii: "c"):
                    // RIS — a full reset ends any repaint in progress.
                    isFrameOpen = false
                    state = .ground
                case 0x1B:
                    state = .escape
                default:
                    state = .ground
                }

            case .csi:
                // Parameter (0x30–0x3F) and intermediate (0x20–0x2F) bytes precede the final
                // byte (0x40–0x7E). Anything else is a malformed sequence — drop back to ground.
                if (0x30...0x3F).contains(byte) || (0x20...0x2F).contains(byte) {
                    if params.count < Self.maxParamBytes { params.append(byte) } else { paramsOverflowed = true }
                } else if (0x40...0x7E).contains(byte) {
                    applyCSIFinal(byte)
                    state = .ground
                } else if byte == 0x1B {
                    // ⚠️ ESC ABORTS the sequence and BEGINS the next one (VT500 parser: `esc` is
                    // an anywhere-transition). Falling to `.ground` here would eat this ESC, so the
                    // `[` after it reads as a plain byte and the whole `CSI ? 2026 h` that follows
                    // an aborted sequence goes unseen — a repaint that never registers as a frame.
                    params.removeAll(keepingCapacity: true)
                    paramsOverflowed = false
                    state = .escape
                } else {
                    state = .ground
                }

            case .string:
                if stringIsOSC, byte == 0x07 { state = .ground } else if byte == 0x1B { state = .stringEscape }

            case .stringEscape:
                if byte == UInt8(ascii: "\\") { state = .ground } else if byte != 0x1B { state = .string }
            }
        }
    }

    /// Applies the collected CSI: a DECSET/DECRST (`?…h` / `?…l`) whose parameter list contains
    /// mode 2026 opens / closes the frame. Everything else is ignored.
    private mutating func applyCSIFinal(_ final: UInt8) {
        defer {
            params.removeAll(keepingCapacity: true)
            paramsOverflowed = false
        }
        guard !paramsOverflowed,
              final == UInt8(ascii: "h") || final == UInt8(ascii: "l"),
              params.first == UInt8(ascii: "?")
        else { return }
        // No intermediates: a `?…$p` (DECRQM) must not be read as a mode SET.
        guard !params.dropFirst().contains(where: { (0x20...0x2F).contains($0) }) else { return }
        // swiftlint:disable:next optional_data_string_conversion
        let fields = String(decoding: params.dropFirst(), as: UTF8.self)
            .split(separator: ";")
            .compactMap { Int($0) }
        guard fields.contains(2026) else { return }
        let open = final == UInt8(ascii: "h")
        // A re-`h` inside an already-open frame is not a new frame (2026 is a flag, not a counter).
        if open, !isFrameOpen { frameGeneration &+= 1 }
        isFrameOpen = open
    }
}
