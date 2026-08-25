import CSlopDeskFFI

// MARK: - PreferenceRules (what the preference surface decides about ITSELF)

/// The three decisions the preference surface makes that no config file can state, as
/// `slopdesk-workspace::preference` answers them.
///
/// Nothing here is a SETTING. A setting is a path in `config.toml`, resolved against the Rust key
/// table before any value reaches this side — ``SettingsKey`` is the projection of that reading, and
/// no accessor of it holds a default, a domain or a repair of its own. These three are the other
/// thing: rules ABOUT the surface, which is why they were the only plain logic in
/// `SettingsKey.swift` and `PreferencesStore.swift` with anywhere to go.
///
/// No string crosses any of them. A suite name is this side's (one is built from this process's own
/// pid, the other read out of its own environment) and a hint regex is the user's own text; the
/// rules read exactly one bit of each, so what travels is that bit and what comes back names
/// POSITIONS in the arrays this side still holds — the same convention ``RecentsRing`` crosses on.
public enum PreferenceRules {
    // MARK: - Which store the app's own STATE lands in

    /// Which `UserDefaults` suite this process binds its four state keys to, or `nil` for
    /// `.standard`.
    ///
    /// `testProcess` is the per-pid suite name a test worker mints for itself; `environment` is the
    /// raw value of ``SettingsKey/defaultsSuiteEnvKey``, `nil` when the variable is unset. The
    /// PRECEDENCE between them is Rust's — the XCTest suite wins outright, and an empty environment
    /// value is no value — and this function only reads back whichever name the verdict names.
    public static func stateSuite(testProcess: String?, environment: String?) -> String? {
        let named = Array((environment ?? "").utf8)
        let source = named.withUnsafeBufferPointer { bytes in
            slopdesk_ws_state_suite_source(testProcess != nil, bytes.baseAddress, bytes.count)
        }
        switch source {
        case 1: return testProcess
        case 2: return environment
        default: return nil
        }
    }

    // MARK: - The runtime font-size band (⌘+ / ⌘- / ⌘0)

    /// The size the terminal draws at: `configured` (the file's `terminal.font-size`) plus whatever
    /// ⌘± has moved it by, held inside the zoom band NaN-faithfully.
    ///
    /// The band is NOT that key's domain — the table lets a file state `4.0…96.0`, because a file is
    /// somebody who meant it — it is the narrower one a key press may walk to.
    public static func effectiveFontSize(configured: Double, delta: Double) -> Double {
        slopdesk_ws_font_size_effective(configured, delta)
    }

    /// One press of the three zoom chords, as the byte the door reads it as.
    public enum Zoom: UInt8 {
        /// ⌘+ / ⌘= — one step bigger.
        case increase = 0
        /// ⌘- — one step smaller.
        case decrease = 1
        /// ⌘0 — back to the size the config file states.
        case reset = 2
    }

    /// The NEW runtime delta one press lands on, or `nil` when the press moves nothing.
    ///
    /// `nil` is the load-bearing half: a ⌘± held down against the edge of the band would otherwise
    /// re-publish an identical terminal configuration on every repeat, and
    /// ``TerminalConfigBroadcaster`` bumps its generation unconditionally — so every one of those
    /// would rebuild each live terminal's config and re-measure its grid. ⌘0 refuses the same way
    /// when there is no delta to reset.
    public static func zoom(configured: Double, delta: Double, _ press: Zoom) -> Double? {
        let answer = slopdesk_ws_font_zoom(configured, delta, press.rawValue)
        return answer.moved ? answer.delta : nil
    }

    // MARK: - The two parallel Hint Mode lists

    /// Zip the `controls.hint-patterns` / `controls.hint-pattern-actions` lists into the
    /// ``HintPattern`` values the assigner consumes.
    ///
    /// The file carries them as two arrays rather than an array of tables, because the common case —
    /// a pattern with no action — would otherwise be noisier to write than the whole feature is
    /// worth. So the pairing is a rule, with three cases the file's shape cannot express: an empty
    /// PATTERN is dropped (an empty regex matches everything), an action list shorter than the
    /// pattern list leaves the tail without one, and an EMPTY action is no action exactly as an
    /// absent one is.
    ///
    /// Only the emptiness of each entry crosses; the regexes and templates stay here and are read
    /// back at the positions the answer names.
    public static func hintPatterns(_ patterns: [String], actions: [String]) -> [HintPattern] {
        let patternsEmpty = patterns.map(\.isEmpty)
        let actionsEmpty = actions.map(\.isEmpty)
        // No more patterns can survive than were offered, so the first buffer is the arithmetic
        // bound rather than a guess and the size-then-retry path is never travelled.
        var slots = [SlopDeskWsHintSlot](repeating: SlopDeskWsHintSlot(), count: patterns.count)
        let count = patternsEmpty.withUnsafeBufferPointer { left in
            actionsEmpty.withUnsafeBufferPointer { right in
                slots.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_hint_patterns(
                        left.baseAddress, left.count, right.baseAddress, right.count,
                        out.baseAddress, out.count,
                    )
                }
            }
        }
        guard count <= slots.count else { return [] }
        return slots.prefix(count).compactMap { (slot: SlopDeskWsHintSlot) -> HintPattern? in
            let index = Int(slot.pattern)
            guard patterns.indices.contains(index) else { return nil }
            let action = slot.has_action && actions.indices.contains(index) ? actions[index] : nil
            return HintPattern(regex: patterns[index], action: action)
        }
    }
}
