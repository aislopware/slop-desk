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
// ``PaneDropProviderPolicy``, the commit is ``PaneDropActuator``, and the geometry was already the shared
// ``PaneDropZoneLayout`` / ``DropActionResolver``. That is not tidiness — an `NSDraggingDestination` and a
// `UIDropInteractionDelegate` are the same five callbacks over a different event object, and every rule
// that stayed inside one of them would have to be written again, correctly, on the other side.
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
    /// `false` on the static-mirror (ImageRenderer) path — the receiver then declines every drag so a
    /// snapshot pass never engages the live overlay.
    let enabled: Bool
    /// The workspace store the terminal-rooted (`newTabCd` / `splitInjectPath`) actions drive — reusing the
    /// existing `openTerminalRooted` ingress.
    let store: WorkspaceStore
    /// THIS (dropped-on) pane's live terminal model (`nil` for a chooser pane): the verbatim PTY funnel
    /// for `injectText` + the host-open callback for `hostOpen`. Since commit focuses ``paneID`` first,
    /// this is also the active pane by the time the action runs. The receiver never builds a `cd` itself; the
    /// canonical `cd` idiom lives in the store ingress (``LinkActionPolicy/changeDirectoryCommandLine(_:)``).
    let terminalModel: TerminalViewModel?
    /// The overlay coordinator the host-resolved advisory toast is pushed into (folder → New-Tab `cd`).
    /// `nil` outside the scene root (tests / the static mirror) — a no-op then.
    let overlayCoordinator: OverlayCoordinator?

    // MARK: Lifecycle

    /// Accept the drag iff ``PaneDropGate/acceptsDrag(enabled:carriesSupportedType:isReadOnly:)`` says so —
    /// otherwise decline so no overlay shows (validate-then-drop). SwiftUI's contribution is the ONE query
    /// the gate cannot make itself: `hasItemsConforming(to:)` over ``PaneDropGate/acceptedTypes``. That is a
    /// pure query; the read-only read hops to the main actor, where every `DropDelegate` callback is already
    /// delivered.
    func validateDrop(info: DropInfo) -> Bool {
        let carriesSupportedType = info.hasItemsConforming(to: PaneDropGate.acceptedTypes)
        let terminalModel = terminalModel
        return MainActor.assumeIsolated {
            PaneDropGate.acceptsDrag(
                enabled: enabled,
                carriesSupportedType: carriesSupportedType,
                isReadOnly: terminalModel?.isReadOnly,
            )
        }
    }

    /// On entry, kick off the async classification of the pasteboard; the overlay appears once `content` is
    /// set (a few ms later — the loads are local). A no-op when disabled. (`model` is bound as a local so the
    /// async `Task` captures the `Sendable` `@MainActor` model, not the non-`Sendable` receiver.)
    func dropEntered(info: DropInfo) {
        guard enabled else { return }
        let model = model
        MainActor.assumeIsolated {
            // Stamp this entry with a fresh generation the classify Task captures; a `dropExited`/`performDrop`
            // reset bumps the generation so a classify that resolves AFTER the reset is dropped as stale rather
            // than re-activating the overlay (the strand-the-overlay race).
            let generation = model.beginClassification()
            let bundle = ProviderBundle(info: info)
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
            let bundle = ProviderBundle(info: info)
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

// MARK: - Pasteboard → DroppedContent (the platform layer)

/// Extracts the supported item providers from a `DropInfo` and LOADS them; ``PaneDropProviderPolicy`` says
/// what the results mean. Built on the main actor (the providers come off a `DropInfo`); the loads
/// themselves suspend off-actor through `NSItemProvider`'s completion handlers. The split is the point: an
/// `NSItemProvider` load is actuation and belongs to whichever framework produced the drag, while the
/// file → url → text precedence, the "a file URL also surfaces under `.url`" filter and the folder-vs-file
/// resolution are decisions every drop path on every platform must reach identically.
@MainActor
private struct ProviderBundle {
    let fileProviders: [NSItemProvider]
    let urlProviders: [NSItemProvider]
    let textProviders: [NSItemProvider]

    init(info: DropInfo) {
        fileProviders = info.itemProviders(for: [.fileURL])
        urlProviders = info.itemProviders(for: [.url])
        textProviders = info.itemProviders(for: [.text])
    }

    /// Load the providers and reduce them to one ``DroppedContent``, or `nil` when nothing supported /
    /// non-empty resolves (validate-then-drop). Every `guard` and `if` below is a call into
    /// ``PaneDropProviderPolicy`` — what is left is the `await`.
    func classify() async -> DroppedContent? {
        var files: [DropPayloadClassifier.FileEntry] = []
        for provider in fileProviders {
            guard let url = await provider.loadURLValue(),
                  let entry = PaneDropProviderPolicy.fileEntry(for: url) else { continue }
            files.append(entry)
        }

        var urls: [String] = []
        for provider in urlProviders {
            guard let url = await provider.loadURLValue(),
                  let webURL = PaneDropProviderPolicy.webURLString(for: url) else { continue }
            urls.append(webURL)
        }

        var text: String?
        if PaneDropProviderPolicy.needsTextLoad(files: files, urls: urls) {
            for provider in textProviders {
                if let value = await provider.loadTextValue() {
                    text = value
                    break
                }
            }
        }

        return PaneDropProviderPolicy.content(files: files, urls: urls, text: text)
    }
}

// MARK: - NSItemProvider async helpers

// `@MainActor`: the provider (non-`Sendable`) is only ever touched on the main actor — `loadObject` is
// CALLED on the main actor and only its `Sendable` continuation crosses to the background completion, so the
// provider never crosses an actor boundary (Swift-6 strict-concurrency clean). `await` suspends the task
// without blocking the main actor.
private extension NSItemProvider {
    /// Async-load a `URL` (file or web) from this provider, or `nil` on failure — never throws / traps.
    @MainActor
    func loadURLValue() async -> URL? {
        guard canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Async-load a plain-`String` snippet from this provider, or `nil` on failure.
    @MainActor
    func loadTextValue() async -> String? {
        guard canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }
}
#endif
