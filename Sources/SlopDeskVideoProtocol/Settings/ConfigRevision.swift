// ConfigRevision — the one observable edge for "the config file moved".
//
// ``AppConfig/current`` is a plain global behind a lock: every consumer is a synchronous accessor on
// a hot path and none of them wants an actor hop. That makes it unobservable, which is fine for the
// ninety-odd settings read once per action — and not fine for the handful a view must re-read WHILE
// it is on screen (auto-secure-input, the secure-input chip, the satellite pointer grant, the
// auto-hide mode). Those used to ride `Defaults`' own change stream; the settings are not in
// `Defaults` any more.
//
// So the edge is published here rather than the value: one counter, bumped exactly when a reload
// resolved to a DIFFERENT configuration. A view reads `generation` alongside whatever `SettingsKey`
// it actually wants, and Observation re-arms it. That is deliberately coarse — one bump wakes every
// arm — because it fires only when the user saved their file and came back to the app, and because
// the alternative is publishing ninety properties to make four of them live.
//
// Nothing bumps this on its own. ``ConfigFile/reload(_:)`` does, AFTER its equality guard: a bump on
// every activation would re-fire every arm on every ⌘Tab, which is the flash that guard exists to
// prevent.

import Observation

/// The "config file moved" edge, as an observable counter.
@preconcurrency
@MainActor
@Observable
public final class ConfigRevision {
    /// The app's one revision. A global mirroring a global — a per-window instance would leave the
    /// other window's arms asleep.
    public static let shared = ConfigRevision()

    /// How many times the resolved configuration has CHANGED this launch. The number itself means
    /// nothing; being read inside a tracked block is the whole of it.
    public private(set) var generation = 0

    public init() {}

    /// Announce that ``AppConfig/current`` now resolves differently. `&+=` because a wrap after
    /// 2⁶³ edits is still a change, and a trap there would be absurd.
    public func bump() {
        generation &+= 1
    }
}
