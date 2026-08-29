// DeviceStageVeil — the simulator stage's "is a veil up, and which one", delayed and de-duplicated.
//
// A stage with no picture on it has to say WHICH of the two reasons that is, and it has to wait before
// saying anything at all: a stream that arrives in 90 ms must never flash a spinner on its way in.
// Both shells wrote the same three parts around ``SimulatorPresentation`` — a delay restarted on the
// EDGE of `isAwaitingStream`, a `showsLoading` flag the model cannot see, and a by-VALUE guard so the
// spinner is not rebuilt several times a second for a veil that did not change.
//
// ⚠️ THE DELAY IS KEYED ON A `Bool`, and the two shells were keying it on a STRING minted from that
// `Bool` (`isAwaiting ? "awaiting" : "settled"`) through two differently-named copies of one keyed-task
// holder. The key here is the flag itself, which is what `.task(id:)` meant and what the Android stage
// already spells as its own `veilKey`. Restarting on every observation callback instead of on the edge
// would turn the grace period into a veil that never appears.
//
// ⚠️ THE READING IS ASKED FOR, NEVER CARRIED. ``reading(for:)`` goes back to the model each time,
// because it also runs at the end of a delayed sleep — a copy taken when the follow fired would be
// stale by then. That also means this type must NOT be where the model's tracked reads happen: the
// stage's own `read` block owns those, and a read moved in here would silently stop the follow.

import Foundation
import SlopDeskDevicePanels

@MainActor
package final class DeviceStageVeil {
    private var delay: Task<Void, Never>?
    /// The flag the running delay was started for, or `nil` if none is.
    private var key: Bool?
    /// The model's loading state DELAYED — this view's own state, which is exactly why it cannot be
    /// read out of the model inside ``reading(for:)``.
    private var showsLoading = false
    private var drawn = SimulatorStageState.live

    package init() {}

    /// Restart the veil's delay if `isAwaiting` has MOVED, then call `draw` once the delay resolves to
    /// a new answer. A wait for a stream that arrived in time is cancelled before its veil is ever
    /// written.
    package func settle(isAwaiting: Bool, draw: @escaping @MainActor () -> Void) {
        guard key != isAwaiting else { return }
        key = isAwaiting
        delay?.cancel()
        delay = Task { @MainActor [weak self] in
            guard let state = await SimulatorPresentation.loadingVeil(isAwaiting: isAwaiting),
                  !Task.isCancelled, let self else { return }
            showsLoading = state
            draw()
        }
    }

    /// The state the stage should be wearing, or `nil` when it is already wearing it.
    ///
    /// The guard comes BEFORE the build on purpose: this is asked from two followers and from the end
    /// of every delayed sleep, so a caller that built first would mint a fresh spinner several times a
    /// second for a veil nobody changed.
    package func reading(for model: SimulatorSidebarModel) -> SimulatorStageState? {
        let state = SimulatorPresentation.stage(
            isSelected: model.selection != nil, showsLoading: showsLoading,
            isAwaitingStream: model.isAwaitingStream, hasVideo: model.hasVideo,
        )
        guard drawn != state else { return nil }
        drawn = state
        return state
    }

    /// The stage is going away. A sleeping delay holds a closure into a view tree that is about to be
    /// gone, and the latch outlives nothing else, so ending it here is the whole teardown story — which
    /// is why neither stage has an `unmount` step for the veil.
    deinit { delay?.cancel() }
}
