// PaneDropReceiver — the SwiftUI `DropDelegate` behind the external-drag overlay on a pane
// (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`).
//
// One receiver is attached per ``PaneContainer`` via `.onDrop(of:delegate:)`. It owns the drag lifecycle:
//   1. validate — a drag must carry a supported type (`.fileURL` / `.url` / `.text`), else the receiver
//      declines and NO overlay appears (validate-then-drop: a hostile / unsupported drag is the normal
//      case, never a crash).
//   2. classify — on entry it loads the pasteboard's item providers (`NSItemProvider`, cross-platform) into
//      a ``DropPayloadClassifier/Payload`` and reduces it to one ``DroppedContent`` (folder vs file is
//      resolved HERE from the file URL's `isDirectory`; this is the only platform-touching layer). The
//      classified content drives the overlay's allowed-zone gating (``DropActionResolver/allowedZones(for:)``).
//   3. hover — `dropUpdated` maps `info.location` through the SHARED ``PaneDropZoneLayout`` (draw == hit, so
//      the `.contentShape`-before-`.position` trap is mooted) and lights the zone the cursor is over, but
//      ONLY if that zone is allowed for the dragged content (a file can't land on the green New-Tab half).
//   4. commit — `performDrop` resolves the `(zone, content)` cell to a ``DropAction`` and actuates it against
//      the injected store / live terminal / overlay: a verbatim PTY inject, a terminal-rooted new
//      tab / split (the store's ``WorkspaceStore/openTerminalRooted(at:split:leading:launchGrace:)`` ingress,
//      with the host-resolved advisory toast), or the host-open verb. Nothing is actuated on hover —
//      commit-on-`performDrop` only.
//
// HEADLESS-SAFE: the receiver itself imports no AppKit-private. The geometry + policy are the pure
// ``PaneDropZoneLayout`` / ``DropActionResolver`` from `SlopDeskWorkspaceCore`, so the gating is unit-tested
// there without a GUI; the terminal-rooted `cd`-actuation lives behind the store ingress, unit-tested against
// the `FakePaneSession` sink (`OpenTerminalRootedStoreTests`). The live drag/overlay render is the Phase-3
// HW-fidelity target the plan flags.

#if canImport(SwiftUI)
import Foundation
import SlopDeskWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Overlay state model

/// The per-pane drag state the overlay renders from and the receiver mutates: the classified payload of the
/// in-flight drag (`nil` when nothing supported is hovering) + the zone the cursor is currently over.
/// `@MainActor @Observable` so the overlay re-renders as the cursor moves between
/// zones; held as `@State` by ``PaneContainer`` (per-pane, `.id(PaneID)`-keyed).
@MainActor
@Observable
final class PaneDropOverlayModel {
    /// The classified content of the drag hovering THIS pane, or `nil` when no supported drag is over it.
    /// Drives ``isActive`` (overlay visibility) and ``allowedZones`` (which blobs can light up).
    var content: DroppedContent?

    /// The zone the cursor is over RIGHT NOW — only ever an *allowed* zone (the receiver refuses to set a
    /// disabled one), or `nil` when the cursor is in a gap between zones. The overlay saturates this one.
    var activeZone: DropZone?

    /// Monotonically-increasing token stamped on each new drag entry (`beginClassification`) and bumped on
    /// every `reset()` (drop committed / cursor left). The async pasteboard classify captures the value live
    /// at `dropEntered`; if a `reset()` bumped it before the classify resolves, the late write is recognised
    /// as STALE and dropped (``applyClassified(_:generation:)``). Without this guard a slow `.url`/`.text`
    /// provider load — or a fast enter→exit — would re-set `content` AFTER the overlay was cleared, flipping
    /// ``isActive`` back to `true` and stranding the full-pane overlay faded-in with no drag present (the
    /// post-reset async-race class — cf. the present-storm / identity-churn lessons).
    private(set) var generation: Int = 0

    /// Whether the overlay should be shown — a supported drag is hovering this pane.
    var isActive: Bool { content != nil }

    /// The zones the current content can act on (the others render muted + non-targetable). Derived from the
    /// pure policy table so the overlay gating can never drift from ``DropActionResolver/resolve(zone:content:)``.
    var allowedZones: Set<DropZone> {
        guard let content else { return [] }
        return DropActionResolver.allowedZones(for: content)
    }

    /// Begin a new classification cycle: bump ``generation`` and hand the new current value back for the
    /// caller's async `Task` to capture. Only a classify whose captured generation still equals the live
    /// ``generation`` may write ``content`` (see ``applyClassified(_:generation:)``).
    func beginClassification() -> Int {
        generation &+= 1
        return generation
    }

    /// Apply a freshly-classified `content` IFF the stamping `generation` is still current — the post-reset
    /// async-race guard. The `dropEntered` classify `Task` captures the generation from
    /// ``beginClassification()`` and calls this on completion; if a `reset()` bumped the generation meanwhile
    /// (the drag committed or left the pane), the write is DROPPED so a late classify can never re-activate
    /// the overlay after it was cleared.
    func applyClassified(_ content: DroppedContent?, generation: Int) {
        guard generation == self.generation else { return }
        self.content = content
    }

    /// Clear the drag state (drop finished / cursor left the pane) so the overlay fades out. Bumps
    /// ``generation`` so any classify still in flight is invalidated (a late resolve can't strand the overlay).
    func reset() {
        content = nil
        activeZone = nil
        generation &+= 1
    }
}

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

    /// The content types this receiver accepts — a file/folder URL, a web URL, or plain text. Mirrors the
    /// ``DropPayloadClassifier`` precedence (file → url → text). Exposed so ``PaneContainer`` passes the
    /// identical list to `.onDrop(of:)`.
    static let acceptedTypes: [UTType] = [.fileURL, .url, .text]

    // MARK: Lifecycle

    /// Accept the drag iff it is enabled, the dropped-on terminal pane is NOT read-only, AND it carries a
    /// supported type — otherwise decline so no overlay shows (validate-then-drop). READ-ONLY gate (parity
    /// with the ``TerminalViewModel/sendInput(_:)`` paste halt): a read-only pane refuses every drop, so the
    /// affordance never appears and no inject / open-in-place can land. `terminalModel` is nil for a
    /// chooser pane (read-only doesn't apply). `hasItemsConforming(to:)` is a pure query; the read-only read
    /// hops to the main actor, where every `DropDelegate` callback is already delivered.
    func validateDrop(info: DropInfo) -> Bool {
        guard enabled, info.hasItemsConforming(to: Self.acceptedTypes) else { return false }
        let terminalModel = terminalModel
        return MainActor.assumeIsolated { terminalModel?.isReadOnly != true }
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

    /// On every move, hit-test the cursor against the SHARED layout and light the zone under it — but only
    /// when that zone is *allowed* for the dragged content (a disabled cell never becomes active). Returns a
    /// `.copy` proposal over an allowed zone, `.forbidden` in a gap / over a disabled zone (so a release
    /// there does not fire `performDrop`). The overlay itself stays up (driven by `content`) regardless.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let model = model
        let layout = layout
        return MainActor.assumeIsolated {
            let hovered = layout.zone(at: info.location)
            let allowed = hovered.flatMap { model.allowedZones.contains($0) ? $0 : nil }
            model.activeZone = allowed
            return DropProposal(operation: allowed != nil ? .copy : .forbidden)
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
                Self.actuate(action, store: store, terminalModel: terminalModel, overlay: overlay, paneID: paneID)
            }
            return true
        }
    }

    // MARK: - Actuation

    /// Carry out a resolved ``DropAction`` against the store / live terminal / overlay. The pure policy
    /// (``DropActionResolver``) decided WHAT; this turns it into the concrete call, reusing the existing
    /// actuators (the verbatim PTY funnel, the store's terminal-rooted `cd` ingress, the host-open verb)
    /// — no new engine — and layers the host-resolved advisory toast on the
    /// folder → New-Tab `cd`. `static` so it captures no non-Sendable `self`.
    ///
    /// FOCUS-FIRST: `paneID` is the pane the cursor was dropped onto. We focus it BEFORE actuating so the
    /// active-pane-reading ingress (`splitActivePane`) targets the
    /// dropped-on pane — a drop never moves focus on its own, so a Split-Left/Right or Open-In-Place drop
    /// onto a NON-focused sibling would otherwise split / replace the focused pane instead of this one. The
    /// focus is a no-op when the pane is already active (or has since closed — `focusPaneTree` self-guards).
    /// `internal` (not `private`) so `PaneDropReceiverActuateTests` can drive it without a real `DropInfo`.
    @MainActor
    static func actuate(
        _ action: DropAction,
        store: WorkspaceStore,
        terminalModel: TerminalViewModel?,
        overlay: OverlayCoordinator?,
        paneID: PaneID,
    ) {
        // READ-ONLY gate (parity with the paste halt): a read-only terminal pane is inert to drops — no
        // verbatim inject, no open-in-place host verb, no terminal-rooted tab/split. Belt-and-suspenders with
        // `validateDrop` (which suppresses the overlay) AND the single defence on the open-in-place `hostOpen`
        // path, which — unlike `injectText` → `sendInput` — does NOT self-gate read-only. `terminalModel` is
        // nil for a chooser pane, where read-only doesn't apply, so those drops are unaffected.
        guard terminalModel?.isReadOnly != true else { return }
        store.focusPaneTree(paneID)
        switch action {
        case let .injectText(text):
            // VERBATIM UTF-8 into THIS focused pane's PTY (never `SendKeysParser`). `sendInput` self-gates
            // read-only (rings the beep + drops), so a read-only pane can't be written by a drop.
            terminalModel?.sendInput(Data(text.utf8))
        case let .newTabCd(folder):
            // A dropped folder opens a fresh terminal tab rooted there; the path is HOST-resolved, so advise.
            store.openTerminalRooted(at: folder, split: false, leading: false)
            overlay?.pushToast(cwdAdvisoryToast(for: folder))
        case let .splitInjectPath(path, leading):
            store.openTerminalRooted(at: path, split: true, leading: leading)
        case let .hostOpen(path):
            // Open-In-Place on the HOST — fire the SAME host-open verb (verb 9, `MetadataClient.openPath`)
            // the ⌘-click path uses; `TerminalLeafView` has already wired this callback (+ its failure toast).
            terminalModel?.onRequestOpenHostPath?(path)
        }
    }

    /// The host-resolved advisory toast for a dropped folder → New-Tab `cd`: we are a REMOTE
    /// terminal, so the dropped path is resolved on the HOST and may not exist there — advise,
    /// never block. A fixed `id` de-dupes repeated drops to one toast (the warp `object_id` discipline).
    @MainActor
    private static func cwdAdvisoryToast(for path: String) -> Toast {
        Toast(
            id: "drop-cwd",
            flavor: .attention,
            title: "cd'd on host",
            body: "\(path) is resolved on the host; it may not exist there.",
        )
    }
}

// MARK: - Pasteboard → DroppedContent (the platform layer)

/// Extracts the supported item providers from a `DropInfo` and loads them into a ``DroppedContent``. Built
/// on the main actor (the providers come off a `DropInfo`); the loads themselves suspend off-actor through
/// `NSItemProvider`'s completion handlers. `folder` vs `file` is resolved HERE from the file URL's
/// `isDirectory` (the pure ``DropPayloadClassifier`` never touches the disk).
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

    /// Reduce the loaded providers to one ``DroppedContent`` (file → url → text precedence), or `nil` when
    /// nothing supported / non-empty resolves (validate-then-drop).
    func classify() async -> DroppedContent? {
        var files: [DropPayloadClassifier.FileEntry] = []
        for provider in fileProviders {
            guard let url = await provider.loadURLValue(), url.isFileURL else { continue }
            files.append(.init(path: url.path, isDirectory: Self.isDirectory(url)))
        }

        var urls: [String] = []
        for provider in urlProviders {
            // A file URL can also surface under `.url`; keep only true web URLs here (files already handled).
            guard let url = await provider.loadURLValue(), !url.isFileURL else { continue }
            urls.append(url.absoluteString)
        }

        var text: String?
        if files.isEmpty, urls.isEmpty {
            for provider in textProviders {
                if let value = await provider.loadTextValue() {
                    text = value
                    break
                }
            }
        }

        return DropPayloadClassifier.classify(.init(files: files, urls: urls, text: text))
    }

    /// Whether `url` points at a directory — resolved from the URL's resource values, falling back to its
    /// path shape (`hasDirectoryPath`) when the disk can't answer. Local to the dragging client, so the stat
    /// is cheap and safe (the dropped item lives on THIS Mac).
    private static func isDirectory(_ url: URL) -> Bool {
        if let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory {
            return isDir
        }
        return url.hasDirectoryPath
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
