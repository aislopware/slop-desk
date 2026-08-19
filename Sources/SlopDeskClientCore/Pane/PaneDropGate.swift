// PaneDropGate — which external drags get in, which zone lights up, and what a loaded pasteboard
// MEANS. The three decisions that were inlined in a SwiftUI `DropDelegate`'s callbacks (docs/56).
//
// A drop delegate is framework-shaped three times over: SwiftUI hands it a `DropInfo`, AppKit an
// `NSDraggingInfo`, UIKit a `UIDropSession`. What none of those three change is the ANSWER — accept
// or decline, light this zone or none, this pasteboard is a folder / a file / a URL / a snippet — so
// each half is left holding its own event object and nothing else.
//
// The pasteboard half is the one worth being explicit about, because it looks like plumbing and is
// not. The PRECEDENCE is a decision, and it is two rules that a second implementation would get
// subtly wrong:
//
//   * A Finder file drag ALSO surfaces under `.url` (and under `.text`, as its path string). Files
//     win — you dropped a file, not a string — so a file URL arriving on the `.url` group is
//     DISCARDED there rather than double-counted as a web URL that would then classify as `.url`
//     and offer the wrong zones.
//   * The text group is only worth loading when neither of the other two produced anything.
//     `DropPayloadClassifier` would ignore it anyway (file → url → text), so loading it is a
//     provider round-trip whose result can never be read.
//
// `isDirectory` also lives here: folder-vs-file is resolved from the URL's resource values, and the
// pure classifier in `SlopDeskWorkspaceCore` never touches the disk on purpose. The stat is local to
// the DRAGGING client (the dropped item is on THIS Mac), so it is cheap and cannot block on a
// network mount the way a host path could.
//
// ⚠️ AND THE LOADING CAME DOWN TOO, one increment after the precedence did, which is a correction to
// what this header used to say. It said an `NSItemProvider` load "is actuation: it is async, it is
// the platform's, and it stays up there" — and the second clause is simply false. `NSItemProvider`
// is FOUNDATION. It is what a `DropInfo`, an `NSDraggingInfo` and a `UIDropSession` all hand you,
// which makes it the one part of a drop that is already common to the three frameworks rather than
// the part that is not. "Async" was doing the work in that sentence, and async is not a framework.
//
// What is genuinely per-framework is EXTRACTING the three provider groups from the event object —
// three lines, and the only thing ``PaneDropProviderBundle`` asks each renderer for. Left up there,
// the loop and its two continuation wrappers would have been written a second time for
// `NSDraggingInfo`, and the drift they invite is the silent kind: a `canLoadObject` guard dropped on
// one side turns a hostile drag from "declines" into a trap (docs/56 increment 56c).

import Foundation
import SlopDeskWorkspaceCore
import UniformTypeIdentifiers

/// The entry decisions of the external-drop path: what the pane advertises it takes, whether a given
/// drag is let in at all, and which zone a hover lights.
package enum PaneDropGate {
    /// The content types a pane accepts — a file/folder URL, a web URL, or plain text. Mirrors the
    /// ``DropPayloadClassifier`` precedence (file → url → text). ONE list: the registration
    /// (`.onDrop(of:)` / `registerForDraggedTypes`) and the validate query below must ask about the
    /// same set, or a drag is advertised as acceptable and then declined (an overlay that flickers
    /// once and never appears again).
    package static let acceptedTypes: [UTType] = [.fileURL, .url, .text]

    /// Whether a drag is accepted at all — validate-then-drop: an unsupported or hostile drag is the
    /// NORMAL case, so it is declined and no overlay ever appears, never a crash.
    ///
    /// - Parameters:
    ///   - enabled: `false` on a static-mirror (snapshot) pass, which declines everything so a
    ///     render pass can never engage the live overlay.
    ///   - carriesSupportedType: the platform's answer to "does this drag carry one of
    ///     ``acceptedTypes``" (`DropInfo.hasItemsConforming(to:)` and its siblings).
    ///   - isReadOnly: the dropped-on terminal pane's read-only flag, or `nil` for a chooser pane
    ///     (where read-only does not apply). READ-ONLY refuses every drop — parity with the paste
    ///     halt — so the affordance never appears and no inject / open-in-place can land.
    package static func acceptsDrag(enabled: Bool, carriesSupportedType: Bool, isReadOnly: Bool?) -> Bool {
        guard enabled, carriesSupportedType else { return false }
        return isReadOnly != true
    }

    /// The zone a hover at `hovered` should light, or `nil` for "none" — a gap between zones OR a
    /// zone the dragged content cannot act on (a file may not land on the green New-Tab half). A
    /// disabled cell never becomes active, so a release over one has nothing to commit.
    ///
    /// `nil` is also the FORBIDDEN drag proposal each framework returns from its own hover callback:
    /// the proposal type is SwiftUI's / AppKit's, the choice between the two answers is not.
    package static func hoverZone(_ hovered: DropZone?, allowedZones: Set<DropZone>) -> DropZone? {
        guard let hovered, allowedZones.contains(hovered) else { return nil }
        return hovered
    }
}

/// The pasteboard PRECEDENCE, separated from the provider loading that feeds it. Every member is a
/// pure function of what a load returned, so the async half above stays a loop with no rules in it.
package enum PaneDropProviderPolicy {
    /// The classifier entry for a URL loaded off the FILE group, or `nil` when it is not a file URL
    /// after all (the group is advertised, not guaranteed). Resolves folder-vs-file here, which is
    /// the one platform touch the pure classifier refuses to make.
    package static func fileEntry(for url: URL) -> DropPayloadClassifier.FileEntry? {
        guard url.isFileURL else { return nil }
        return .init(path: url.path, isDirectory: isDirectory(url))
    }

    /// The string for a URL loaded off the URL group, or `nil` when it is a FILE URL — which the file
    /// group has already handled. Keeping only true web URLs here is what stops one dragged Finder
    /// item from being counted twice and classifying as a `.url`.
    package static func webURLString(for url: URL) -> String? {
        guard !url.isFileURL else { return nil }
        return url.absoluteString
    }

    /// Whether the TEXT group is worth loading, given what the other two groups produced. It is not
    /// once either has an entry: `DropPayloadClassifier` reduces file → url → text, so a snippet
    /// loaded behind a file could never be read.
    package static func needsTextLoad(files: [DropPayloadClassifier.FileEntry], urls: [String]) -> Bool {
        files.isEmpty && urls.isEmpty
    }

    /// Reduce the loaded groups to one ``DroppedContent`` — the file → url → text precedence, which
    /// is ``DropPayloadClassifier``'s and stays there; this is the door onto it, so no drop path
    /// assembles a `Payload` by hand.
    package static func content(
        files: [DropPayloadClassifier.FileEntry],
        urls: [String],
        text: String?,
    ) -> DroppedContent? {
        DropPayloadClassifier.classify(.init(files: files, urls: urls, text: text))
    }

    /// Whether `url` points at a directory — resolved from the URL's resource values, falling back to
    /// its path shape (`hasDirectoryPath`) when the disk can't answer.
    package static func isDirectory(_ url: URL) -> Bool {
        if let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory {
            return isDir
        }
        return url.hasDirectoryPath
    }
}

// MARK: - The loaded pasteboard

/// The three provider groups a drop carries, and the loop that turns them into one
/// ``DroppedContent``. Every `guard` and `if` in ``classify()`` is a call into
/// ``PaneDropProviderPolicy`` — what is left is the `await`.
///
/// Each renderer supplies only the three GROUPS, off whatever event object its framework hands it:
/// `DropInfo.itemProviders(for:)` in SwiftUI, `NSPasteboard` → `NSItemProvider` under AppKit's
/// `NSDraggingInfo`, `UIDragItem.itemProvider` under UIKit's session. That extraction is three lines
/// and is the whole of what a drop path writes for itself.
///
/// `@MainActor`: `NSItemProvider` is not `Sendable`, and it is only ever touched on the main actor —
/// a `DropDelegate` callback is delivered there, an `NSDraggingDestination` one is too. `loadObject`
/// is CALLED on the main actor and only its `Sendable` continuation crosses to the background
/// completion, so the provider never crosses an actor boundary (Swift-6 strict-concurrency clean).
/// `await` suspends the task without blocking the main actor.
@MainActor
package struct PaneDropProviderBundle {
    package let fileProviders: [NSItemProvider]
    package let urlProviders: [NSItemProvider]
    package let textProviders: [NSItemProvider]

    package init(
        fileProviders: [NSItemProvider],
        urlProviders: [NSItemProvider],
        textProviders: [NSItemProvider],
    ) {
        self.fileProviders = fileProviders
        self.urlProviders = urlProviders
        self.textProviders = textProviders
    }

    /// Load the providers and reduce them to one ``DroppedContent``, or `nil` when nothing supported
    /// and non-empty resolves (validate-then-drop).
    ///
    /// The TEXT group is loaded last and only when the other two produced nothing — see
    /// ``PaneDropProviderPolicy/needsTextLoad(files:urls:)``. It is not an optimisation the caller
    /// may skip: a Finder drag surfaces its path under `.text` as well, so loading it eagerly and
    /// letting the classifier discard it would work by accident and stop working the day the
    /// precedence is re-ordered.
    package func classify() async -> DroppedContent? {
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

/// The two loads, and they are Foundation's — no drop path writes its own continuation. The
/// `canLoadObject` guard in each is the reason: without it a hostile or merely mistyped drag traps
/// rather than declining, and a second implementation is exactly where that guard goes missing.
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
