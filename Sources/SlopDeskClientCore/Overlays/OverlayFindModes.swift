// OverlayFindModes — which ``FindModePill`` a cross-tab search is wearing, and what a tap on one means.
//
// ``FindModePill`` is the VOCABULARY — the three chips, their letters and which surface offers which.
// This is the STATE behind it for the global-search surfaces: two booleans, the pill→flag map, and the
// one rule that made the map worth naming.
//
// ⚠️ WHOLE-WORD IS NOT OFFERED HERE, AND THAT IS A DECISION, NOT AN OMISSION. Cross-tab search runs over
// a scrollback MIRROR rather than over libghostty's own buffer, and the two engines do not agree about
// where a word ends — so the chip is absent from ``FindModePill/globalSearch`` and a tap that somehow
// reached it changes nothing. Both shells spelled that `case .wholeWord: return` by hand, which is a
// decision typed twice: one half re-deciding it the other way is a search that silently answers a
// different question depending on which device asked.
//
// ``toggle(_:)`` ANSWERS WHETHER ANYTHING MOVED rather than returning `Void`, so the shell's own two
// consequences — re-lighting the chip and re-running the query — hang off one `guard` instead of each
// half re-deriving "was that the inert case?".
//
// A VALUE TYPE, invisible to `Observation` by construction: the surfaces that hold one keep it as a
// local mirror of the store's retained flags and redraw themselves, which is exactly what their headers
// say they do.

/// The two find flags a cross-tab search carries, and the pill each one answers to.
public struct OverlayFindModes: Equatable, Sendable {
    /// Whether the query is matched case-sensitively.
    public var caseSensitive: Bool
    /// Whether the query is read as a regular expression rather than as literal text.
    public var isRegex: Bool

    public init(caseSensitive: Bool = false, isRegex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.isRegex = isRegex
    }

    /// Whether `mode`'s chip is lit. `.wholeWord` is never lit here — see the file header.
    public func isOn(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: caseSensitive
        case .regex: isRegex
        case .wholeWord: false
        }
    }

    /// Flips `mode`, answering whether the flags actually changed.
    ///
    /// `false` for `.wholeWord` — a case ``FindModePill/globalSearch`` cannot produce, which reads
    /// `false` and returns rather than trapping.
    @discardableResult
    public mutating func toggle(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: caseSensitive.toggle()
        case .regex: isRegex.toggle()
        case .wholeWord: return false
        }
        return true
    }
}
