import Foundation

/// Behaviour-preserving config resolver — the single bridge between the GUI Settings system (W12+)
/// and the ~192 `SLOPDESK_*` flags the host/client tune themselves with.
///
/// WHY: today every flag is read directly off `ProcessInfo.processInfo.environment` at a `static let`
/// (or fire-time) site, each with its own parse/clamp/reject idiom. Settings can't reach those reads.
/// `EnvConfig` interposes a process-wide OVERLAY: a `[String: String]` populated at `main()` (from a
/// `video-prefs.json` sidecar for the host daemon, or from the client's live prefs) BEFORE any
/// `static let` is forced. A site that resolves `EnvConfig.string(key)` instead of
/// `ProcessInfo.processInfo.environment[key]` then sees env → overlay → (its own default), so a
/// setting can override a flag without an env var.
///
/// PRECEDENCE (decision #16): a real `ProcessInfo` env var ALWAYS wins over the settings overlay,
/// which wins over the compile-time default — `env → overlay → default`. This matches the host
/// sidecar's gap-fill (`rust/slopdesk-videohostd`'s `env::Overlay` skips a key a real env var already
/// set, and folds `rawOverrides` last, exactly as this tier does) and
/// the "an explicit env override is honoured" contract: a deliberate `SLOPDESK_*=…` on the command
/// line is the operator's escape hatch and is never silently overridden by a persisted setting. (The
/// `rawOverrides` a user types in the Settings UI are part of the OVERLAY tier — they still yield to a
/// real env var, by the same rule.)
///
/// THE LOAD-BEARING INVARIANT: with an EMPTY overlay, `EnvConfig.string(k)` is byte-identical to
/// `ProcessInfo.processInfo.environment[k]` — the same `Optional<String>`. So the golden-pinned
/// controllers (`QPController`, `LiveCongestionController`, …) resolve their compile-time defaults
/// EXACTLY as before when no overlay is set; the golden corpus, generated with no `SLOPDESK_*` env,
/// is unchanged. `EnvConfigTests` proves this against the legacy expression for the polarity idioms
/// and missing / `"0"` / `"1"` / garbage values.
///
/// THREAD-SAFETY: the overlay is set ONCE at process start (`main()`), before the concurrent video
/// pipeline spins up and before any consumer's `static let` is forced (Swift lazily initialises a
/// `static let` on first access). After that it is read-only for the process lifetime — the same
/// "static env, fixed for the lifetime" contract the existing sites already document. We do not add
/// a lock for what is a write-once-at-launch / read-many value; mutating it after launch is a
/// programmer error, not a supported runtime knob (decision #10: no live reload).
public enum EnvConfig {
    /// The settings overlay, populated once at `main()` (sidecar / live prefs) before any consumer's
    /// `static let` is forced. EMPTY in tests / the golden generator ⇒ pure-`ProcessInfo` behaviour.
    public nonisolated(unsafe) static var overlay: [String: String] = [:]

    /// Resolve a raw config string: ProcessInfo env → overlay → `nil` (decision #16). A real env var
    /// ALWAYS wins over the settings overlay (matching the host sidecar gap-fill + the "explicit env
    /// override is honoured" contract); the overlay only fills a key the operator did NOT set on the
    /// command line. The ONE primitive every typed accessor and every migrated call site funnels
    /// through. With an EMPTY overlay this is, by construction, `ProcessInfo.processInfo.environment[key]`
    /// (env present ⇒ env; env absent ⇒ overlay is empty ⇒ `nil`) — the behaviour-preservation proof.
    public static func string(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key] { return v }
        return overlay[key]
    }

    // MARK: Polarity-faithful boolean idioms

    //
    // The codebase has exactly two boolean env idioms (CLAUDE.md "watch the default idiom"):
    //   • default-ON  → `env[x] != "0"` (any value but "0" — including unset — keeps it on)
    //   • default-OFF → `env[x] == "1"` (only the literal "1" enables; unset / anything else off)
    // These two helpers reproduce each comparison verbatim over the resolved string, so a migrated
    // site keeps its exact truth table. `bool(_:default:)` dispatches to the matching helper.

    /// Default-ON idiom: TRUE unless the resolved value is exactly `"0"`. Mirrors `env[k] != "0"`.
    public static func boolDefaultOn(_ key: String) -> Bool {
        string(key) != "0"
    }

    /// Default-OFF idiom: TRUE only when the resolved value is exactly `"1"`. Mirrors `env[k] == "1"`.
    public static func boolDefaultOff(_ key: String) -> Bool {
        string(key) == "1"
    }

    /// Resolve a boolean honouring the project's polarity: `default == true` ⇒ the default-ON
    /// (`!= "0"`) idiom; `default == false` ⇒ the default-OFF (`== "1"`) idiom. A convenience for NEW
    /// sites (W13 UI); existing sites that already hand-write `!= "0"` / `== "1"` migrate by routing
    /// their lookup through ``string(_:)`` (or one of the two explicit helpers) so no truth table moves.
    public static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        defaultValue ? boolDefaultOn(key) : boolDefaultOff(key)
    }

    // MARK: Typed accessors (additive — for NEW sites / W13 UI)

    //
    // `int(_:default:min:max:)` and `double(_:default:min:max:)` USED to live here, as a generic
    // spelling of the validate-then-default idiom for "roughly a dozen knobs across several
    // targets". They were deleted on 2026-08-22, and the count in that phrase was the whole reason
    // they lasted: it was ZERO. Every hit outside this file was in `EnvConfigTests`, and the sites
    // the doc comment named — `LiveCongestionController`, `FPSGovernor` — had each kept a private
    // copy of the same guard rather than calling these. So the pair was a third implementation of a
    // rule with no callers, sitting under a comment asserting it had a dozen.
    //
    // The rule itself did not go away; it moved to where it can only be written once. It is
    // `slopdesk_video::congestion`'s own validated read now, and the host that used to reach it
    // through a C door is `rust/slopdesk-videohostd`, which calls it in-process (docs/61 §5). The
    // LOOKUP stays here — ``string(_:)`` is the env → overlay precedence, which is this type's whole
    // job and is not a policy any door should hold.
    //
    // Anything NEW that needs a validated number resolves its text through ``string(_:)`` and hands
    // it to the crate that owns the rule; the CLAMPING reading is `slopdesk_video::qp_control`'s, on
    // the same terms. Do not grow a third generic accessor here — that is exactly what these two
    // were.

    /// Resolve a `RawRepresentable` (e.g. an enum) by its raw string, falling back to `def` on an
    /// unknown / unset value. Validate-then-default: an unrecognised value never traps.
    public static func enumValue<T: RawRepresentable>(_ key: String, default def: T) -> T where T.RawValue == String {
        guard let s = string(key), let v = T(rawValue: s) else { return def }
        return v
    }
}
