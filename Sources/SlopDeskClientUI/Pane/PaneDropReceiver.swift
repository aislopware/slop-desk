// PaneDropReceiver — the SwiftUI `DropDelegate` behind the external-drag overlay on a pane
// (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`).
//
// One receiver is attached per ``PaneContainer`` via `.onDrop(of:delegate:)`. It owns the drag lifecycle:
//   1. validate — a drag must carry a supported type (`.fileURL` / `.url` / `.text`), else the receiver
//      declines and NO overlay appears (validate-then-drop: a hostile / unsupported drag is the normal
//      case, never a crash).
//   2. classify — on entry it LOADS the pasteboard's item providers (`NSItemProvider`, cross-platform) and
//      hands each result to ``PaneDropProviderPolicy``, which reduces them to one ``DroppedContent``
//      (folder vs file is resolved from the file URL's `isDirectory` — the one place the disk is touched).
//      The classified content drives the overlay's allowed-zone gating
//      (``DropActionResolver/allowedZones(for:)``).
//   3. hover — `dropUpdated` maps `info.location` through the SHARED ``PaneDropZoneLayout`` (draw == hit, so
//      the `.contentShape`-before-`.position` trap is mooted) and lights the zone the cursor is over, but
//      ONLY if that zone is allowed for the dragged content (a file can't land on the green New-Tab half).
//   4. commit — `performDrop` resolves the `(zone, content)` cell to a ``DropAction`` and actuates it against
//      the injected store / live terminal / overlay: a verbatim PTY inject, a terminal-rooted new
//      tab / split (the store's ``WorkspaceStore/openTerminalRooted(at:split:leading:launchGrace:)`` ingress,
//      with the host-resolved advisory toast), or the host-open verb. Nothing is actuated on hover —
//      commit-on-`performDrop` only.
//
// WHAT IS LEFT HERE IS THE `DropInfo`. After docs/56 every answer the callbacks reach for is below them:
// the accept/decline gate and the hover verdict are ``PaneDropGate``, the pasteboard precedence is
// ``PaneDropProviderPolicy``, its LOADING is ``PaneDropProviderBundle``, the commit is
// ``PaneDropActuator``, and the geometry was already the shared
// ``PaneDropZoneLayout`` / ``DropActionResolver``. That is not tidiness — an `NSDraggingDestination` and a
// `UIDropInteractionDelegate` are the same five callbacks over a different event object, and every rule
// that stayed inside one of them would have to be written again, correctly, on the other side.
//
// The bundle came down an increment after the precedence did (docs/56 56c), and the reason it did not
// go with it is worth keeping: the loading was called "the platform's" because it is async, and async
// is not a framework. `NSItemProvider` is Foundation, so all three drop paths already share it. Only
// the three `itemProviders(for:)` calls at the foot of this file are SwiftUI's.
//
// HEADLESS-SAFE: the receiver itself imports no AppKit-private, and the gating is unit-tested without a GUI
// (`SlopDeskClientCoreTests`, `SlopDeskWorkspaceCoreTests`); the terminal-rooted `cd`-actuation lives behind
// the store ingress, unit-tested against the `FakePaneSession` sink (`OpenTerminalRootedStoreTests`). The
// live drag/overlay render is the Phase-3 HW-fidelity target the plan flags.

#if canImport(SwiftUI)
import Foundation
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop delegate

/// The `DropDelegate` attached to a pane. `DropDelegate` is NOT a `@MainActor` protocol, so this struct is
/// nonisolated; it reaches its `@MainActor` ``PaneDropOverlayModel`` + the `@MainActor` store / terminal /
/// overlay through `MainActor.assumeIsolated` (every `DropDelegate` callback is delivered on the main thread)
/// and a `@MainActor` `Task` for the async pasteboard loads. Every injected dependency is a `@MainActor`
/// reference type (Sendable), so the struct stays Sendable across those hops.
struct PaneDropReceiver: DropDelegate {
    /// THIS pane's id — the pane being dragged ONTO (the overlay covers the pane under the cursor and its
    /// zones act on THAT pane). On commit the receiver focuses it FIRST so the active-pane-reading store
    /// ingress (`splitActivePane`) resolves to the dropped-on pane, not whichever pane
    /// happened to be focused — a drop never changes focus on its own (the pane is focused only on tap), so
    /// without this a Split / Open-In-Place drop onto a non-focused sibling would split/replace the WRONG pane.
    let paneID: PaneID
    /// The pane's drop-zone geometry — the SHARED source of truth the overlay also draws from (draw == hit).
    let layout: PaneDropZoneLayout
    /// The overlay state to drive (classified content + active zone).
    let model: PaneDropOverlayModel
    /// The workspace store the terminal-rooted (`newTabCd` / `splitInjectPath`) actions drive — reusing the
    /// existing `openTerminalRooted` ingress.
    let store: WorkspaceStore
    /// THIS (dropped-on) pane's live terminal model (`nil` for a chooser pane): the verbatim PTY funnel
    /// for `injectText` + the host-open callback for `hostOpen`. Since commit focuses ``paneID`` first,
    /// this is also the active pane by the time the action runs. The receiver never builds a `cd` itself; the
    /// canonical `cd` idiom lives in the store ingress (``LinkActionPolicy/changeDirectoryCommandLine(_:)``).
    let terminalModel: TerminalViewModel?
    /// The overlay coordinator the host-resolved advisory toast is pushed into (folder → New-Tab `cd`).
    /// `nil` outside the scene root (tests) — a no-op then.
    let overlayCoordinator: OverlayCoordinator?

    // MARK: Lifecycle

    /// Accept the drag iff ``PaneDropGate/acceptsDrag(carriesSupportedType:isReadOnly:)`` says so —
    /// otherwise decline so no overlay shows (validate-then-drop). SwiftUI's contribution is the ONE query
    /// the gate cannot make itself: `hasItemsConforming(to:)` over ``PaneDropGate/acceptedTypes``. That is a
    /// pure query; the read-only read hops to the main actor, where every `DropDelegate` callback is already
    /// delivered.
    func validateDrop(info: DropInfo) -> Bool {
        let carriesSupportedType = info.hasItemsConforming(to: PaneDropGate.acceptedTypes)
        let terminalModel = terminalModel
        return MainActor.assumeIsolated {
            PaneDropGate.acceptsDrag(
                carriesSupportedType: carriesSupportedType,
                isReadOnly: terminalModel?.isReadOnly,
            )
        }
    }

    /// On entry, kick off the async classification of the pasteboard; the overlay appears once `content` is
    /// set (a few ms later — the loads are local). (`model` is bound as a local so the async `Task` captures
    /// the `Sendable` `@MainActor` model, not the non-`Sendable` receiver.)
    func dropEntered(info: DropInfo) {
        let model = model
        MainActor.assumeIsolated {
            // Stamp this entry with a fresh generation the classify Task captures; a `dropExited`/`performDrop`
            // reset bumps the generation so a classify that resolves AFTER the reset is dropped as stale rather
            // than re-activating the overlay (the strand-the-overlay race).
            let generation = model.beginClassification()
            let bundle = PaneDropProviderBundle(info: info)
            Task { @MainActor in await model.applyClassified(bundle.classify(), generation: generation) }
        }
    }

    /// On every move, hit-test the cursor against the SHARED layout and hand the hit to
    /// ``PaneDropGate/hoverZone(_:allowedZones:)``, which lights it only when the dragged content can act on
    /// it (a disabled cell never becomes active). `nil` back means FORBIDDEN — a gap, or a disabled zone —
    /// so a release there does not fire `performDrop`; the `DropProposal` is the only part of this SwiftUI
    /// owns. The overlay itself stays up (driven by `content`) regardless.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let model = model
        let layout = layout
        return MainActor.assumeIsolated {
            let target = PaneDropGate.hoverZone(layout.zone(at: info.location), allowedZones: model.allowedZones)
            model.activeZone = target
            return DropProposal(operation: target != nil ? .copy : .forbidden)
        }
    }

    /// Cursor left the pane without dropping — clear the overlay.
    func dropExited(info _: DropInfo) {
        let model = model
        MainActor.assumeIsolated { model.reset() }
    }

    /// Commit: resolve the `(active zone, content)` cell to a ``DropAction`` and actuate it. The overlay is
    /// cleared immediately; the payload is RE-loaded authoritatively (not trusting the hover-time class) and
    /// the resolved action actuated against the (Sendable, `@MainActor`) store / terminal / overlay bound as
    /// locals (so the `Task` never captures the non-Sendable `DropInfo`-derived state). Returns `true` when
    /// there is an active (allowed) zone to act on, `false` for a release in a gap (nothing to do).
    func performDrop(info: DropInfo) -> Bool {
        let model = model
        let store = store
        let terminalModel = terminalModel
        let overlay = overlayCoordinator
        let paneID = paneID
        return MainActor.assumeIsolated {
            guard let zone = model.activeZone else {
                model.reset()
                return false
            }
            let bundle = PaneDropProviderBundle(info: info)
            model.reset()
            Task { @MainActor in
                guard let content = await bundle.classify(),
                      let action = DropActionResolver.resolve(zone: zone, content: content)
                else { return }
                PaneDropActuator.actuate(
                    action, store: store, terminalModel: terminalModel, overlay: overlay, paneID: paneID,
                )
            }
            return true
        }
    }
}

// MARK: - The one line of this that is SwiftUI's

// THE ADAPTER IS THE WHOLE PLATFORM LAYER, and it is three lines. ``PaneDropProviderBundle`` — the
// load loop, the file → url → text precedence, the lazy text group and both `NSItemProvider`
// continuations — is `SlopDeskClientCore`'s, because an `NSItemProvider` is Foundation's object and
// not SwiftUI's: `DropInfo`, `NSDraggingInfo` and `UIDropSession` all hand you the same one. What
// each framework genuinely owns is only how you ASK it for the three groups, which is this.
extension PaneDropProviderBundle {
    /// The three provider groups off a SwiftUI `DropInfo`. The type list is
    /// ``PaneDropGate/acceptedTypes``'s in the same order the classifier reduces them, spelled
    /// per-group here because `itemProviders(for:)` takes one group at a time.
    init(info: DropInfo) {
        self.init(
            fileProviders: info.itemProviders(for: [.fileURL]),
            urlProviders: info.itemProviders(for: [.url]),
            textProviders: info.itemProviders(for: [.text]),
        )
    }
}
#endif
