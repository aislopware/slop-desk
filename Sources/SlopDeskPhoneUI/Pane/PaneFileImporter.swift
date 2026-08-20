// PaneFileImporter — the way a file gets into a pane on a device with no drag SOURCE.
//
// ``PaneDropReceiver`` is the other way, and it works here: an iPad in Split View can drag a file out
// of Files and onto a pane, and the whole zone overlay lights up for it. An iPhone cannot. There is no
// second app on screen to drag out of, so the receiver sits mounted and unreachable and the pane has no
// door at all — which is a CAPABILITY gap, not a layout one, and docs/56 §3 says layout is the only
// thing the two halves are allowed to differ by.
//
// So this is the door the platform does offer: `.fileImporter`, which is SwiftUI's `UIDocumentPicker`.
// It is a drawing and nothing else. WHICH zone a picked file acts at, what a path classifies as, and
// what the resolved action DOES are all ``PaneFileImportPolicy``'s — the same four steps `performDrop`
// takes, entered at the same door, so a picked file and a dropped one can never come to mean two
// different things. The header of that type says why the zone is `insertPath` rather than one of the
// four cells that would commit something off a single tap.
//
// TWO SHAPES, because two callers want different halves of it. ``PaneFileImportButton`` is the whole
// affordance — plate, glyph and picker — for a surface that just wants to offer it; the
// ``SwiftUICore/View/paneFileImporter(isPresented:paneID:store:terminalModel:overlayCoordinator:)``
// modifier is the picker alone, for a surface that already has its own trigger (a menu row, a
// keybinding) and only needs somewhere to hang the sheet.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

/// The pane's "send a file" affordance: a plate button that opens the document picker and hands what
/// it returns to the drop path's actuator.
///
/// It owns its own presentation flag rather than taking a binding, because the flag is worth nothing
/// to anyone else — the picker is modal, it reports once, and nothing outside this view can be in a
/// position to raise or lower it meaningfully.
struct PaneFileImportButton: View {
    /// The pane the file is being sent to — focused by the actuator BEFORE anything lands, the same
    /// ordering a drop takes, so the path is injected into THIS pane and not whichever was focused.
    let paneID: PaneID
    let store: WorkspaceStore
    /// This pane's live terminal model — the verbatim PTY funnel the resolved action writes through.
    /// `nil` for a chooser pane, where the terminal arms are no-ops rather than a crash.
    let terminalModel: TerminalViewModel?
    /// The coordinator an advisory toast is pushed into; `nil` outside the scene root (tests).
    let overlayCoordinator: OverlayCoordinator?

    @State private var picking = false

    var body: some View {
        SlatePlateButton(
            symbol: .documentBadgePlus,
            help: "Send a File to This Pane",
            action: { picking = true },
        )
        .paneFileImporter(
            isPresented: $picking,
            paneID: paneID,
            store: store,
            terminalModel: terminalModel,
            overlayCoordinator: overlayCoordinator,
        )
    }
}

extension View {
    /// Hangs the pane's document picker on this view, raised by `isPresented`.
    ///
    /// The completion is the ONE line SwiftUI owns here: a `Result` in, a `[URL]` out. A cancel and a
    /// failure are the same non-event and are dropped — validate-then-drop, the drop path's contract,
    /// where a picker the user backed out of is the normal case rather than a fault.
    func paneFileImporter(
        isPresented: Binding<Bool>,
        paneID: PaneID,
        store: WorkspaceStore,
        terminalModel: TerminalViewModel?,
        overlayCoordinator: OverlayCoordinator?,
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: PaneFileImportPolicy.pickerTypes,
            allowsMultipleSelection: false,
        ) { result in
            guard case let .success(urls) = result else { return }
            PaneFileImportPolicy.actuate(
                picked: urls,
                store: store,
                terminalModel: terminalModel,
                overlay: overlayCoordinator,
                paneID: paneID,
            )
        }
    }
}
#endif
