import Foundation

/// The loading veil's WAIT — late on the way up, immediate on the way down — written once for every
/// stage that has one.
///
/// The asymmetry is the whole point, and it is why a stage keeps its own copy of the model's
/// loading flag instead of reading it. A caller re-runs this whenever `isAwaiting` changes and
/// cancels the previous run, so a pending veil for a stream that arrived in time never appears at
/// all. Waiting on the way DOWN would instead leave grey over a picture that is already there.
///
/// It stays Swift because it is structured concurrency — a sleep and a cancellation check, which is
/// the one shape a door cannot carry (`docs/67` §5's `SwiftRuntime` floor). What crosses is the
/// DELAY, and there are two of them: 400 ms for the simulator, measured against its 0.09 s first
/// keyframe, and 600 ms for the Android bridge against its 0.83 s. `docs/62` §7 read those two
/// numbers as one duplication; they are two measurements, and merging them would throw both away.
/// The duplication was the WAIT, which existed in three spellings and is now this one.
package enum DeviceVeilWait {
    /// Whether the veil should be showing after the wait, or `nil` when it was cancelled and the
    /// caller must not write anything.
    package static func state(isAwaiting: Bool, after delay: Duration) async -> Bool? {
        guard isAwaiting else { return false }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return nil }
        return true
    }
}
