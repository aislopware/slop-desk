// What a drop DOES, as the Swift face of `slopdesk_workspace::drop_action`, reached through
// `rust/slopdesk-ffi`'s `drop_action` door.
//
// ## What is not here any more
//
// The `(zone × content)` table: the text-pastes-everywhere catch-all, the disabled green-half cells,
// the retired web pane's two `nil`s, and the split zones' shared body. All Rust's. What stays is the
// vocabulary the actuator speaks and the marshalling into one door.

import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - Resolved drop action

/// The concrete action a `(zone, content)` pair resolves to — an instruction the actuator carries out
/// against the store / live terminal / metadata client. Carrying the action as a value (not actuating
/// here) keeps the drop path headless + table-testable.
///
/// The case set is terminal-only — there is intentionally NO video-pane creator: a streamed host
/// window is minted solely by the picker, never by a drop (see ``DropActionResolver``).
public enum DropAction: Equatable, Sendable {
    /// Paste this text/path VERBATIM into the focused terminal (`TerminalViewModel.sendInput`, never
    /// `SendKeysParser`).
    case injectText(String)
    /// Open a new terminal tab rooted at this folder (`newTab(kind:.terminal)` then
    /// `LinkActionPolicy.changeDirectoryCommandLine`, which cd's a file to its PARENT). Folders only.
    case newTabCd(String)
    /// Open this path Open-In-Place ON THE HOST (`MetadataClient.openPath`, verb 9). Files & folders.
    case hostOpen(String)
    /// Split the active terminal pane and target the new pane at this path (`leading` = left/top).
    case splitInjectPath(String, leading: Bool)
}

// MARK: - Resolver (the (zone × content) policy table, marshalled)

/// The policy mapping a hovered ``DropZone`` + classified ``DroppedContent`` to a ``DropAction``, or
/// `nil` for a disabled cell (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`). The spec's
/// table, with the local web pane removed — a dropped URL now only PASTES; it never opens a browser
/// pane:
///
/// | Dragged thing | Green half / terminal action            | Blue half / pane action          |
/// |---------------|------------------------------------------|----------------------------------|
/// | Folder        | New terminal tab with `cwd = <folder>`   | Folder viewer (host open) / split|
/// | File          | (disabled — no "open as terminal")       | File viewer (host open) / split  |
/// | URL           | (disabled — no "open as terminal")       | (disabled — no local web pane)   |
/// | Text snippet  | Pastes into the focused terminal         | Same                             |
///
/// **No drop-to-create a video pane.** A video pane is a real host window streamed over the PATH-2
/// UDP video path; it is minted ONLY by the picker / connect overlay
/// (`WorkspaceStore.newRemoteWindowTab(windowID:title:appName:)`), NEVER by a file / URL / text drop.
/// The crate's action enum carries terminal cases only — as does ``DropAction`` here, whose
/// EXHAUSTIVE switch in `DropActionResolverTests` stops that file compiling if a fifth case appears —
/// so no `(zone × content)` cell can spawn one. Conversely a foreign drop ONTO an already-mounted
/// video target self-guards: the actuator (`PaneDropReceiver`) holds a `nil` `terminalModel` for a
/// video pane and every terminal actuator is optional-chained, so the terminal-targeting actions
/// no-op without a crash, while the store-level split / reorder geometry stays kind-generic.
public enum DropActionResolver {
    public static func resolve(zone: DropZone, content: DroppedContent) -> DropAction? {
        let (verb, payload) = withOptionalText(content.value) { bytes, length, _ in
            dropAnswer { out, cap, needed in
                slopdesk_drop_action(zone.ffiCode, content.ffiKind, bytes, length, out, cap, needed)
            }
        }
        switch UInt32(verb) {
        case SLOPDESK_DROP_ACTION_INJECT_TEXT: return .injectText(payload)
        case SLOPDESK_DROP_ACTION_NEW_TAB_CD: return .newTabCd(payload)
        case SLOPDESK_DROP_ACTION_HOST_OPEN: return .hostOpen(payload)
        case SLOPDESK_DROP_ACTION_SPLIT_LEADING: return .splitInjectPath(payload, leading: true)
        case SLOPDESK_DROP_ACTION_SPLIT_TRAILING: return .splitInjectPath(payload, leading: false)
        default: return nil
        }
    }

    /// The set of zones that can ACT on `content` — i.e. the zones whose `(zone, content)` cell
    /// resolves to a non-`nil` ``DropAction``. The single source of truth the drop overlay uses to
    /// gate which blobs are targetable / highlightable: a disabled cell (a file or URL over New Tab —
    /// there is no "open as terminal") is NOT in the set, so the overlay renders it muted and the
    /// receiver never lets it become the active zone. Derived from ``resolve(zone:content:)``, so the
    /// overlay gating can never drift from the table it gates.
    public static func allowedZones(for content: DroppedContent) -> Set<DropZone> {
        Set(DropZone.allCases.filter { resolve(zone: $0, content: content) != nil })
    }

    /// Reads the door's two-part answer: the verb from the return, the payload from `(out, cap)` with
    /// `needed` carrying the retry number. `needed == 0` is not "no answer" — a dead cell answers the
    /// NOTHING verb with no payload — so the verb survives an empty read.
    private static func dropAnswer(
        _ call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> UInt8,
    ) -> (verb: UInt8, payload: String) {
        var out = [UInt8](repeating: 0, count: 256)
        var needed = 0
        var verb = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            verb = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        }
        guard needed > 0, needed <= out.count,
              let payload = String(bytes: out[0..<needed], encoding: .utf8) else { return (verb, "") }
        return (verb, payload)
    }
}

// MARK: - The codes the door reads

// Named rather than numbered, so no code is spelled twice and the two languages cannot drift over one.

// `DropZone.ffiCode` is beside the enum in `PaneDropZoneLayout.swift`: the hit test asks for a zone in the
// same numbers this asks what one does.

private extension DroppedContent {
    var ffiKind: UInt8 {
        switch self {
        case .folder: UInt8(SLOPDESK_DROP_CONTENT_FOLDER)
        case .file: UInt8(SLOPDESK_DROP_CONTENT_FILE)
        case .url: UInt8(SLOPDESK_DROP_CONTENT_URL)
        case .text: UInt8(SLOPDESK_DROP_CONTENT_TEXT)
        }
    }

    /// The one string every case carries — the path, the URL or the snippet.
    var value: String {
        switch self {
        case let .folder(value),
             let .file(value),
             let .url(value),
             let .text(value): value
        }
    }
}
