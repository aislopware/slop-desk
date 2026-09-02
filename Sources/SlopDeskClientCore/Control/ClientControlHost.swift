// The client control socket's FACE — the running GUI, as one callback the Rust listener drives.
//
// What stood here was a second implementation of a socket: an `AF_UNIX` bind, an accept loop, a
// per-connection `read(2)` loop, a newline splitter, a size cap, a UTF-8 guard, an NDJSON parser, a
// fourteen-case `switch` over method STRINGS, a `[String: Any]` params reader per verb and a
// `[String: Any]` result builder per verb. Every one of those is `slopdesk-clientctl` now, and the
// CLI links the same crate — so the two ends of this socket agree by CONSTRUCTION rather than by a
// lint comparing two spellings that ship on different clocks (a `.app` and a `brew upgrade`).
//
// What is left is the only part that was ever this language's: reaching into `@MainActor` client
// stores. A request arrives already decoded and already validated — the verb is an index, the
// params are typed, and a hostile line never reaches here at all — and this file answers it by
// calling a ``ClientControlBackend`` and pushing typed rows back.
//
// ## Hang-safety (compiled-only, never unit-tested)
// The listener's accept loop and its per-connection reads run on threads Rust owns, never on the
// Swift cooperative pool, so a blocked socket read cannot park a concurrency thread. The callback
// lands on one of those threads and hops to the main actor on a semaphore — the connection thread
// parks, the main actor never waits on the connection thread, so there is no cycle to deadlock.
// This face is compiled and code-reviewed only, never instantiated in a test; the decode, the
// validation and the encode it sits between are tested in Rust, with no socket and no GUI.
//
// ## No app-layer auth
// The trust boundary is the same-uid `AF_UNIX` socket at mode 0600, bound by the listener. There
// are no tokens and no pairing (CLAUDE.md).

import CSlopDeskFFI
import Darwin
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import Synchronization

/// Binds the client control socket and answers it out of the live GUI stores.
///
/// `@unchecked Sendable`, and the two reasons are NOT the listener handle — that lives in a `Mutex`
/// and needs no help. It is `onLog`, a `var` the app sets before ``start()``, and the backend, which
/// is only ever touched
/// inside a main-actor hop (see `BackendBox`, file-scope below).
public final class ClientControlHost: @unchecked Sendable {
    /// The resolved socket path this host binds — the `SLOPDESK_CLIENT_SOCKET` override, else the
    /// file beside `workspace.json` in Application Support. Resolved by the crate, so the CLI and
    /// the app cannot disagree about where to meet.
    public let socketPath: String

    /// Optional diagnostics sink (stderr / os_log), set by the app before ``start()``.
    public var onLog: (@Sendable (String) -> Void)?

    private let backendBox: BackendBox
    /// The bound listener, `nil` until ``start()`` and again after ``stop()``. The `Mutex` is what
    /// makes both idempotent: the test and the assignment are one hold, so two callers cannot both
    /// see `nil` and bind the same path twice.
    private let server = Mutex<OpaquePointer?>(nil)

    /// - Parameters:
    ///   - backend: the live-store adapter every verb is answered out of.
    ///   - socketPath: where to bind. Defaults to the crate's own resolution.
    @preconcurrency
    @MainActor
    public init(
        backend: any ClientControlBackend,
        socketPath: String = ClientControlHost.resolvedSocketPath(),
    ) {
        backendBox = BackendBox(backend)
        self.socketPath = socketPath
    }

    deinit { stop() }

    // MARK: - Where the socket lives

    /// The `SLOPDESK_CLIENT_SOCKET` override, else `cli-control.sock` inside the Application Support
    /// container — as `slopdesk_client_ctl_socket_path` resolves it.
    ///
    /// The CONTAINER is this side's because Application Support is a platform lookup; every rule
    /// about the path is the crate's, which is why the CLI reaches the same answer without sharing a
    /// line of this file.
    public static func resolvedSocketPath(using fileManager: FileManager = .default) -> String {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        let container = base.appendingPathComponent("SlopDesk", isDirectory: true).path
        return ffiText { out, cap in
            container.withCString { raw in
                raw.withMemoryRebound(to: UInt8.self, capacity: container.utf8.count) { bytes in
                    slopdesk_client_ctl_socket_path(bytes, container.utf8.count, out, cap)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Binds the socket, publishes its path into the process environment, and begins accepting.
    ///
    /// Idempotent: a second call while bound does nothing, which is what a scene task that re-fires
    /// needs. Throws when the listener could not bind — a path past `sun_path`, or a container this
    /// user cannot write.
    public func start() throws {
        try server.withLock { server in
            guard server == nil else { return }

            // The retain is PERMANENT on the success path, and the door says why: freeing the
            // handle cannot join a connection thread parked inside the callback, so there is no
            // moment at which this side can prove nobody is still reading the pointer. One object,
            // once, for a socket whose lifetime is the app's — the alternative is a release racing
            // a live callback.
            let retained = Unmanaged.passRetained(backendBox)
            let bytes = Array(socketPath.utf8)
            let opened = bytes.withUnsafeBufferPointer { buffer in
                slopdesk_client_ctl_serve(buffer.baseAddress, buffer.count, retained.toOpaque(), runRequest)
            }
            guard let opened else {
                // Nothing was started and no callback can ever run, so this one IS balanced.
                retained.release()
                throw ClientControlSocketError.bindFailed(socketPath)
            }
            server = opened

            // Publish the resolved path so a child the app spawns inherits it. Best-effort: a
            // separately launched CLI resolves the same default through the same door.
            setenv("SLOPDESK_CLIENT_SOCKET", socketPath, 1)
            onLog?("client-control socket listening at \(socketPath)")
        }
    }

    /// Stops the listener and unlinks the socket file. Idempotent, and NON-BLOCKING by design.
    ///
    /// It does not wait for a connection thread that is mid-request: that thread may be parked on
    /// the main-actor hop, and this is routinely called FROM the main actor (`deinit` at quit), so
    /// waiting would be the one deadlock the hop is shaped to avoid. The box the callback reaches
    /// through is therefore never released — see ``start()``.
    public func stop() {
        let opened = server.withLock { server -> OpaquePointer? in
            defer { server = nil }
            return server
        }
        guard let opened else { return }
        slopdesk_client_ctl_free(opened)
    }
}

// MARK: - Answering one request

/// Carries the `@MainActor` backend to the listener's threads. `@unchecked Sendable`: the reference
/// is only DEREFERENCED inside the main-actor hop in ``answer(box:request:reply:)``, so no
/// main-actor state is ever touched off-main.
private final class BackendBox: @unchecked Sendable {
    let backend: any ClientControlBackend
    init(_ backend: any ClientControlBackend) { self.backend = backend }
}

/// Runs one decoded request against the backend and fills the reply.
///
/// Called on a listener thread. The hop is synchronous on a semaphore: the connection thread parks
/// (it is not on the cooperative pool) and the main actor never waits on it, so the two cannot
/// deadlock. Both handles are valid for exactly this call, which is why every push happens inside
/// the hop rather than being deferred.
private func answer(box: BackendBox, request: OpaquePointer?, reply: OpaquePointer?) {
    let handles = Handles(request: request, reply: reply)
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        serve(request: handles.request, reply: handles.reply, backend: box.backend)
        semaphore.signal()
    }
    semaphore.wait()
}

/// The two handles, carried across the hop. `@unchecked Sendable` is the truthful annotation, not a
/// waiver: the listener owns both for exactly the callback, and the connection thread is parked on
/// the semaphore for the whole of the hop — so one thread reads them at a time, and neither outlives
/// the call that lent them.
private struct Handles: @unchecked Sendable {
    let request: OpaquePointer?
    let reply: OpaquePointer?
}

/// The verb table: one case per method, each reading its already-validated params and pushing a
/// typed outcome. There is no `default` that could swallow a new verb — an unhandled index falls
/// through to the crate's "unknown method", which names it.
@MainActor
private func serve(
    request: OpaquePointer?,
    reply: OpaquePointer?,
    backend: any ClientControlBackend,
) {
    switch slopdesk_client_ctl_verb(request) {
    case SLOPDESK_CTL_VERB_WINDOWS:
        slopdesk_client_ctl_answer_list(reply, Kind.windows)
        for window in backend.listWindows() {
            lending([window.id, window.title]) { text in
                slopdesk_client_ctl_push_window(reply, SlopDeskCtlWindow(
                    id: text[0],
                    title: text[1],
                    tab_count: Int64(window.tabCount),
                    focused: window.isFocused,
                ))
            }
        }

    case SLOPDESK_CTL_VERB_TABS:
        slopdesk_client_ctl_answer_list(reply, Kind.tabs)
        for tab in backend.listTabs(windowId: text(request, Field.windowID)) {
            lending([tab.id, tab.windowId, tab.title]) { text in
                slopdesk_client_ctl_push_tab(reply, SlopDeskCtlTab(
                    id: text[0],
                    window_id: text[1],
                    title: text[2],
                    pane_count: Int64(tab.paneCount),
                    focused: tab.isFocused,
                    // Negative is "wearing nothing", which prints a bare tab rather than a
                    // neighbour's mark.
                    badge: tab.badge.map { Int32($0.ffiByte) } ?? -1,
                ))
            }
        }

    case SLOPDESK_CTL_VERB_PANES:
        slopdesk_client_ctl_answer_list(reply, Kind.panes)
        for pane in backend.listPanes(tabId: text(request, Field.tabID)) {
            lending([pane.id, pane.tabId, pane.title, pane.kind, pane.cwd ?? ""]) { text in
                slopdesk_client_ctl_push_pane(reply, SlopDeskCtlPane(
                    id: text[0],
                    tab_id: text[1],
                    title: text[2],
                    kind: text[3],
                    focused: pane.isFocused,
                    cwd: text[4],
                    // An EMPTY cwd and an unknown one are different answers: the first prints a
                    // blank, the second omits the key.
                    has_cwd: pane.cwd != nil,
                ))
            }
        }

    case SLOPDESK_CTL_VERB_TAB_BADGE:
        // The token was parsed on the far side; what crosses is the ladder position, which is
        // the same byte `TabBadgeKind` already speaks to every other door.
        let raw = slopdesk_client_ctl_number(request, Number.badge)
        guard let kind = TabBadgeKind(ffiByte: Int8(clamping: raw)) else { return }
        guard backend.setTabBadge(tabId: text(request, Field.tabID), kind: kind) else {
            refuse(reply, Refusal.tabNotFound)
            return
        }
        slopdesk_client_ctl_answer_badge(reply, Int32(kind.ffiByte))

    case SLOPDESK_CTL_VERB_JUMP:
        let changeDirectory = slopdesk_client_ctl_flag(request, Flag.changeDirectory)
        guard let outcome = backend.jump(
            query: text(request, Field.query),
            changeDirectory: changeDirectory,
        ) else {
            refuse(reply, Refusal.noJumpTarget)
            return
        }
        lending([outcome.path]) { text in
            slopdesk_client_ctl_answer_jump(reply, text[0], outcome.didChangeDirectory)
        }

    case SLOPDESK_CTL_VERB_LEARN:
        guard let recorded = backend.learn(path: text(request, Field.path)) else {
            refuse(reply, Refusal.nothingToLearn)
            return
        }
        lending([recorded]) { text in slopdesk_client_ctl_answer_path(reply, text[0]) }

    case SLOPDESK_CTL_VERB_IGNORE:
        let path = text(request, Field.path) ?? ""
        guard backend.ignore(path: path) else {
            refuse(reply, Refusal.couldNotIgnore)
            return
        }
        lending([path]) { text in slopdesk_client_ctl_answer_path(reply, text[0]) }

    case SLOPDESK_CTL_VERB_VIEW,
         SLOPDESK_CTL_VERB_EDIT:
        // Two verbs, one shape: they differ only in whether the shim is editable, so the flag is
        // the branch rather than a second case body that would drift from this one.
        let editable = slopdesk_client_ctl_flag(request, Flag.editable)
        let slot = slopdesk_client_ctl_number(request, Number.placement)
        let placement = ClientControlPlacement(rawValue: UInt8(clamping: slot)) ?? .newTab
        guard backend.open(
            target: text(request, Field.target) ?? "",
            mode: editable ? .edit : .view,
            placement: placement,
        ) else {
            refuse(reply, Refusal.couldNotOpen)
            return
        }
        slopdesk_client_ctl_answer_done(reply)

    case SLOPDESK_CTL_VERB_FONT_LIST:
        slopdesk_client_ctl_answer_list(reply, Kind.fonts)
        let slot = slopdesk_client_ctl_number(request, Number.scope)
        // Absent means BOTH scopes, which is a filter of `nil` rather than a scope of zero.
        let scope = slot < 0 ? nil : ClientControlFontScope(rawValue: UInt8(clamping: slot))
        let fonts = backend.listFonts(
            monospaceOnly: slopdesk_client_ctl_flag(request, Flag.monospace),
            family: text(request, Field.family),
            scope: scope,
        )
        for font in fonts {
            lending([font.family]) { text in
                slopdesk_client_ctl_push_font(reply, SlopDeskCtlFont(
                    family: text[0],
                    monospace: font.isMonospace,
                    system: font.isSystem,
                ))
            }
        }

    case SLOPDESK_CTL_VERB_KEYBIND_LIST:
        slopdesk_client_ctl_answer_list(reply, Kind.keybinds)
        for bind in backend.listKeybinds(actionFilter: text(request, Field.action)) {
            lending([bind.action, bind.keys]) { text in
                slopdesk_client_ctl_push_keybind(reply, SlopDeskCtlKeybind(
                    action: text[0],
                    keys: text[1],
                ))
            }
        }

    case SLOPDESK_CTL_VERB_PANE_CAPTURE:
        // The count arrives positive and already clamped — the ceiling is the crate's, so a
        // hostile number cost a comparison rather than an unbounded read.
        let lines = Int(slopdesk_client_ctl_number(request, Number.lines))
        guard let captured = backend.capturePane(
            paneId: text(request, Field.paneID),
            lines: lines,
        ) else {
            refuse(reply, Refusal.paneNotFound)
            return
        }
        slopdesk_client_ctl_answer_list(reply, Kind.lines)
        for line in captured {
            lending([line]) { text in slopdesk_client_ctl_push_line(reply, text[0]) }
        }

    case SLOPDESK_CTL_VERB_PANE_SEND_KEYS:
        let named = (0..<slopdesk_client_ctl_key_count(request)).map { index in
            ffiText { out, cap in slopdesk_client_ctl_key(request, index, out, cap) }
        }
        switch backend.sendKeys(
            paneId: text(request, Field.paneID),
            text: text(request, Field.text) ?? "",
            keys: named,
        ) {
        case .sent:
            slopdesk_client_ctl_answer_done(reply)
        case .paneNotFound:
            refuse(reply, Refusal.paneNotFound)
        case let .unknownKey(name):
            // An unknown key name is its OWN refusal, not a missing pane: reporting it as one
            // gives the right failure the wrong reason, and `--key f5` looked delivered.
            refuse(reply, Refusal.unknownKey, detail: name)
        }

    case SLOPDESK_CTL_VERB_AGENT_STATUS:
        switch backend.agentStatus(id: text(request, Field.id) ?? "") {
        case .unresolved:
            slopdesk_client_ctl_answer_agent(reply, false, false, 0)
        case .resolvedNoStatus:
            // The pane exists and has not reported — the agent-startup window. `watch:claude`
            // keeps polling rather than exiting 4 on the first poll.
            slopdesk_client_ctl_answer_agent(reply, true, false, 0)
        case let .status(status):
            slopdesk_client_ctl_answer_agent(reply, true, true, UInt8(clamping: status.urgency))
        }

    default:
        // A verb this build does not serve. Answering nothing is what says so: the crate refuses
        // it by NAME, which is the honest report for a well-formed request with nowhere to go.
        break
    }
}

/// Refuses the request in the socket's own words. `detail` is the token the caller mistyped.
private func refuse(_ reply: OpaquePointer?, _ refusal: UInt8, detail: String = "") {
    lending([detail]) { text in slopdesk_client_ctl_refuse(reply, refusal, text[0]) }
}

// MARK: - Reading one request's fields

/// One text field, or `nil` when the request does not carry it.
///
/// Absent and empty are different answers — a `learn` with no `path` takes the focused pane's
/// cwd — which is why the door reports presence separately from length.
private func text(_ request: OpaquePointer?, _ field: UInt8) -> String? {
    var present = false
    let needed = slopdesk_client_ctl_text(request, field, nil, 0, &present)
    guard present else { return nil }
    guard needed > 0 else { return "" }
    var out = [UInt8](repeating: 0, count: needed)
    let written = out.withUnsafeMutableBufferPointer { buffer in
        slopdesk_client_ctl_text(request, field, buffer.baseAddress, buffer.count, nil)
    }
    guard written == needed else { return "" }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - The vocabularies, as this build's doors name them

/// The field codes, converted once from the header's untyped constants.
private enum Field {
    static let windowID = UInt8(SLOPDESK_CTL_FIELD_WINDOW_ID)
    static let tabID = UInt8(SLOPDESK_CTL_FIELD_TAB_ID)
    static let paneID = UInt8(SLOPDESK_CTL_FIELD_PANE_ID)
    static let query = UInt8(SLOPDESK_CTL_FIELD_QUERY)
    static let path = UInt8(SLOPDESK_CTL_FIELD_PATH)
    static let target = UInt8(SLOPDESK_CTL_FIELD_TARGET)
    static let family = UInt8(SLOPDESK_CTL_FIELD_FAMILY)
    static let action = UInt8(SLOPDESK_CTL_FIELD_ACTION)
    static let text = UInt8(SLOPDESK_CTL_FIELD_TEXT)
    static let id = UInt8(SLOPDESK_CTL_FIELD_ID)
}

private enum Flag {
    static let changeDirectory = UInt8(SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY)
    static let monospace = UInt8(SLOPDESK_CTL_FLAG_MONOSPACE)
    static let editable = UInt8(SLOPDESK_CTL_FLAG_EDITABLE)
}

private enum Number {
    static let lines = UInt8(SLOPDESK_CTL_NUMBER_LINES)
    static let badge = UInt8(SLOPDESK_CTL_NUMBER_BADGE)
    static let placement = UInt8(SLOPDESK_CTL_NUMBER_PLACEMENT)
    static let scope = UInt8(SLOPDESK_CTL_NUMBER_SCOPE)
}

private enum Kind {
    static let windows = UInt8(SLOPDESK_CTL_LIST_WINDOWS)
    static let tabs = UInt8(SLOPDESK_CTL_LIST_TABS)
    static let panes = UInt8(SLOPDESK_CTL_LIST_PANES)
    static let fonts = UInt8(SLOPDESK_CTL_LIST_FONTS)
    static let keybinds = UInt8(SLOPDESK_CTL_LIST_KEYBINDS)
    static let lines = UInt8(SLOPDESK_CTL_LIST_LINES)
}

/// The seven refusals a FACE can answer. The other thirteen are the decoder's, refused before
/// this file is ever reached.
private enum Refusal {
    static let tabNotFound = UInt8(SLOPDESK_CTL_REFUSAL_TAB_NOT_FOUND)
    static let noJumpTarget = UInt8(SLOPDESK_CTL_REFUSAL_NO_JUMP_TARGET)
    static let nothingToLearn = UInt8(SLOPDESK_CTL_REFUSAL_NOTHING_TO_LEARN)
    static let couldNotIgnore = UInt8(SLOPDESK_CTL_REFUSAL_COULD_NOT_IGNORE)
    static let couldNotOpen = UInt8(SLOPDESK_CTL_REFUSAL_COULD_NOT_OPEN)
    static let paneNotFound = UInt8(SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND)
    static let unknownKey = UInt8(SLOPDESK_CTL_REFUSAL_UNKNOWN_KEY)
}

/// The one bind-time failure left. The listener reports the reason to its own log; what this side
/// needs is the path that could not be taken.
public enum ClientControlSocketError: Error {
    case bindFailed(String)
}

// MARK: - The callback

/// The listener's one entry point back into this language.
///
/// A file-scope function rather than a method, because `@convention(c)` cannot capture: the backend
/// is reached through the context pointer the bind registered, which stays retained for the life of
/// the process.
private let runRequest: @convention(c) (
    UnsafeMutableRawPointer?,
    OpaquePointer?,
    OpaquePointer?,
) -> Void = { context, request, reply in
    guard let context else { return }
    let box = Unmanaged<BackendBox>.fromOpaque(context).takeUnretainedValue()
    answer(box: box, request: request, reply: reply)
}

// MARK: - Lending

/// Lends several strings' UTF-8 to a door for the length of one call, and nothing longer.
///
/// One buffer for the whole row rather than a nested `withUnsafeBufferPointer` per field: a pane row
/// carries five strings, and five levels of nesting would say nothing the offsets do not. An empty
/// string lends a null pointer with a zero length, which is the pair every door documents as empty.
private func lending<R>(_ strings: [String], _ body: ([SlopDeskCtlText]) -> R) -> R {
    var bytes: [UInt8] = []
    var spans: [Range<Int>] = []
    for string in strings {
        let utf8 = Array(string.utf8)
        spans.append(bytes.count..<(bytes.count + utf8.count))
        bytes.append(contentsOf: utf8)
    }
    return bytes.withUnsafeBufferPointer { buffer in
        let texts = spans.map { span in
            guard let base = buffer.baseAddress, !span.isEmpty else {
                return SlopDeskCtlText(bytes: nil, len: 0)
            }
            return SlopDeskCtlText(bytes: base + span.lowerBound, len: span.count)
        }
        return body(texts)
    }
}

/// Reads one size-then-take door into a `String`.
///
/// The first call sizes with a null buffer, the second fills exactly that many bytes — the §4 shape
/// every text door in this tree answers to.
private func ffiText(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
    let needed = door(nil, 0)
    guard needed > 0 else { return "" }
    var out = [UInt8](repeating: 0, count: needed)
    let written = out.withUnsafeMutableBufferPointer { buffer in
        door(buffer.baseAddress, buffer.count)
    }
    guard written == needed else { return "" }
    return String(decoding: out, as: UTF8.self)
}
