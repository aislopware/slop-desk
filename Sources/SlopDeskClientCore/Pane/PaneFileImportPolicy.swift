// PaneFileImportPolicy — what a PICKED file does to a pane, as opposed to a DRAGGED one.
//
// Drag-and-drop was the only way to get a file into a pane, and it is not a way an iPhone has: the
// receiver (`PaneDropReceiver` / `MacPaneDropReceiver`) works, and an iPad in Split View can even feed
// it, but a phone has no drag SOURCE to feed it from. A picker is what that platform offers instead.
//
// What a picker does not have is a ZONE. A drop resolves its action from where the cursor was released
// — the five blobs of ``PaneDropZoneLayout`` — and a file chosen in a sheet was released nowhere. So
// the zone is a DECISION rather than a hit test, which is why it is here and not in whichever view
// mounts the picker: the Mac is owed the same picker (⌘O has nothing to do with panes today), and two
// surfaces choosing their own default would be two different meanings for the same gesture.
//
// The zone is ``DropZone/insertPath`` and the reason is that it is the only cell that is live for every
// content kind (`DropActionResolverTests`: folder, file, URL and text all resolve there, all to
// `injectText`). It is also the most conservative: the path lands at the prompt, visible and editable,
// where the user finishes the sentence they meant to type. The alternatives all commit something on
// the user's behalf off a single tap — `newTab` spawns a tab, `openInPlace` fires a host verb, the two
// split cells rearrange the workspace — and a picker with no zone to aim at has not been told which.
//
// Everything below the zone is already shared with the drop path and is called, not re-derived:
// ``PaneDropProviderPolicy/fileEntry(for:)`` resolves folder-vs-file, ``DropPayloadClassifier`` reduces
// the entries, ``DropActionResolver`` picks the action and ``PaneDropActuator`` carries it out — the
// same four steps `performDrop` takes, so a picked file and a dropped one can never mean two things.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UniformTypeIdentifiers

@MainActor
package enum PaneFileImportPolicy {
    /// What the picker offers. `.item` is every file — the pane accepts a path, not a format, and the
    /// classifier downstream is the thing that decides what a path MEANS. Narrowing it here would only
    /// hide files the terminal on the other end can read perfectly well.
    package static let pickerTypes: [UTType] = [.item]

    /// The zone a picked file acts at. See the file header for why it is this one.
    package static let zone = DropZone.insertPath

    /// Actuate a picked selection against `paneID` — the same `(classify → resolve → actuate)` walk
    /// `performDrop` takes, entered at the same door.
    ///
    /// Nothing happens for an empty or unclassifiable selection (validate-then-drop, the drop path's
    /// contract): a picker that was cancelled, or that returned something with no usable path, is the
    /// normal case rather than a fault.
    ///
    /// - Parameters:
    ///   - urls: what the platform picker returned. Only `path` and folder-ness are read, so no
    ///     security-scoped access is started — nothing here opens the file, and the pane's other end
    ///     is a HOST anyway.
    ///   - store: the workspace store the terminal-rooted arms drive.
    ///   - terminalModel: the pane's live terminal model — `nil` for a chooser pane.
    ///   - overlay: the coordinator an advisory toast is pushed into; `nil` in tests.
    ///   - paneID: the pane the file was sent to, focused BEFORE anything is actuated.
    package static func actuate(
        picked urls: [URL],
        store: WorkspaceStore,
        terminalModel: TerminalViewModel?,
        overlay: OverlayCoordinator?,
        paneID: PaneID,
    ) {
        let files = urls.compactMap(PaneDropProviderPolicy.fileEntry(for:))
        guard let content = PaneDropProviderPolicy.content(files: files, urls: [], text: nil),
              let action = DropActionResolver.resolve(zone: zone, content: content)
        else { return }
        PaneDropActuator.actuate(
            action, store: store, terminalModel: terminalModel, overlay: overlay, paneID: paneID,
        )
    }
}
