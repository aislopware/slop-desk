import CSlopDeskFFI

/// One keybinding action the terminal surface answers to, as a value this side can typo-check.
///
/// ## Why this exists, and why it is not just a `String`
///
/// The surface's executor (`slopdesk_term_surface_binding_action`) answers a spelling it does not
/// recognise by **doing nothing and returning `false`**. A typo does not raise, it makes a keystroke
/// quietly stop working — and `"scroll_page_lines:\(delta)"` written at seven call sites is seven
/// chances at that. So the grammar has exactly one home, `slopdesk_terminal::surface_action`, and
/// this side never spells an action: it names a verb as a NUMBER the compiler checks, hands the
/// argument across, and CARRIES the string Rust wrote back.
///
/// The round trip (numbers out, a string back, the string parsed again at the executor) looks
/// indirect and is deliberate. The alternative — a typed enum crossing the boundary — would have to
/// be spelled in Swift as well as Rust, which is two spellings of one grammar and the exact failure
/// this replaces. See `docs/55` §4 for the byte-count convention every door here follows.
///
/// ⚠️ The `code` values are a CONTRACT with `slopdesk_ffi::store_shape::spell`, whose doc comment
/// carries the same table. Append only; never renumber.
public enum TerminalBindingAction: Equatable, Sendable {
    /// Scroll the viewport by a signed number of ROWS (negative is toward older scrollback).
    case scrollLines(Int)
    /// Scroll by a signed fraction of a page — `0.5` for `⌃d`/`⌃u`, `0.9` for `⌃f`/`⌃b`.
    ///
    /// Crosses as thousandths, so the value the executor sees cannot be a NaN.
    case scrollFraction(Double)
    /// Hop to the `delta`-th OSC 133 prompt (negative is toward older output).
    case jumpToPrompt(Int)
    /// Move the selection's free end one step.
    case adjustSelection(Edge)
    /// Jump to the oldest retained row.
    case scrollToTop
    /// Jump to the newest row, where output lands.
    case scrollToBottom
    /// Put an absolute SCREEN row at the viewport's top.
    case scrollToRow(Int)

    /// Which way ``TerminalBindingAction/adjustSelection(_:)`` moves.
    public enum Edge: Int, Equatable, Sendable {
        case up = 0
        case down = 1
        case left = 2
        case right = 3
    }

    /// The `(code, argument)` pair this action crosses as.
    private var crossing: (code: UInt8, argument: Int64) {
        switch self {
        case let .scrollLines(rows): (1, Int64(rows))
        // Rounded rather than truncated so `0.9` cannot arrive as `899` on a platform whose
        // `Double` literal lands a hair below.
        case let .scrollFraction(fraction): (2, Int64((fraction * 1000).rounded()))
        case let .jumpToPrompt(delta): (3, Int64(delta))
        case let .adjustSelection(edge): (4, Int64(edge.rawValue))
        case .scrollToTop: (5, 0)
        case .scrollToBottom: (6, 0)
        case let .scrollToRow(row): (7, Int64(row))
        }
    }

    /// The action as the surface spells it, or `""` for an argument outside its verb's range.
    ///
    /// An empty string is not an action: the executor refuses it, which is the honest outcome for an
    /// argument Rust would have had to clamp. Firing a clamped action would scroll somewhere nobody
    /// asked to go, which is worse than a dead key.
    public var wire: String {
        let (code, argument) = crossing
        return TerminalActionBuffer.read { out, capacity in
            slopdesk_ws_binding_action(code, argument, out, capacity)
        }
    }
}

/// The §4 two-attempt buffer dance, in one place.
///
/// Every `slopdesk_*` door that answers a string uses the same protocol — the return is the byte
/// count NEEDED, so a caller either has its answer or knows exactly how big to retry. Two attempts
/// and never a loop: the second call is handed the size the first one asked for, and nothing can
/// change the answer in between.
enum TerminalActionBuffer {
    /// Runs `door` against a buffer, retrying once at the size it asks for.
    static func read(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
        func attempt(_ capacity: Int) -> (bytes: [UInt8], written: Int) {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
            return (out, written)
        }
        // Generous by an order of magnitude; the retry exists to be correct rather than to be used.
        var answer = attempt(64)
        if answer.written > answer.bytes.count { answer = attempt(answer.written) }
        guard answer.written > 0, answer.written <= answer.bytes.count else { return "" }
        return String(bytes: answer.bytes[..<answer.written], encoding: .utf8) ?? ""
    }
}
