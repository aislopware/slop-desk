// InspectorViewModel — the Swift side of one pane's read-only inspector, which is now a HANDLE and
// the feed's liveness, and nothing else.
//
// What used to be here: thirteen stored properties, three dictionary indices, an upsert-and-evict
// fold over them, and a second declaration of the whole event taxonomy for the `JSONDecoder` that
// filled them. The rules were already Rust's — a door per decision, each one lent the state it was
// deciding about. `docs/66` moved the state to meet the rules: the fold is
// `slopdesk_inspectord::store`, the event is declared once, and what crosses is what a surface
// actually reads.
//
// `feedState` stays because it is not the store's: whether a feed is live, ended or failed is about
// the `NWConnection`'s lifetime, and that seam is `docs/65` §5's parked one.

import CSlopDeskFFI
import Foundation

/// One pane's inspector, as the two peek overlays and the sidebar row read it.
///
/// A reference type owning one Rust store, and deliberately NOT `Sendable`: the handle is driven by
/// a single main-actor consumer, which is the same lifetime rule ``InspectorFrameDecoder`` keeps.
@preconcurrency
@MainActor
public final class InspectorViewModel {
    /// Liveness of the consumed feed. Surfaced as a banner so frozen tool cards do not look live
    /// forever — on macOS there is no in-session auto-resume, so a feed that `.ended` or `.failed`
    /// stays stale until the next iOS pause/resume cycle.
    public enum FeedState: Sendable, Equatable { case live, ended, failed }

    public private(set) var feedState: FeedState = .live

    /// The Rust-owned store. `nonisolated(unsafe)` because a `deinit` is nonisolated by definition and
    /// this is the pointer it must free; every OTHER touch is on the main actor, and by the time
    /// `deinit` runs there is no reference left that could race it.
    private nonisolated(unsafe) let store: OpaquePointer

    public init() {
        guard let store = slopdesk_inspector_store_new() else {
            preconditionFailure("the inspector store could not be built")
        }
        self.store = store
    }

    deinit { slopdesk_inspector_store_free(store) }

    /// The counter that moves whenever anything folded. A view diffs against it rather than against
    /// the collections, which no longer live on this side.
    public var revision: UInt64 { slopdesk_inspector_store_revision(store) }

    /// Whether anything user-visible has been folded in yet — the empty-state placeholder's gate.
    public var hasRenderableActivity: Bool { slopdesk_inspector_store_has_activity(store) }

    /// The "`i`/`n` · `activeForm`" todo-progress line, or `nil` when nothing is in flight.
    ///
    /// The caller's `.live`-feed gate is separate; this only answers "is there one, and what does it
    /// say". No argument, because the todo list is the store's.
    public var todoScent: String? {
        answer { out, cap in slopdesk_inspector_store_todo_scent(store, out, cap) }
            .flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// The newest tool call still waiting on its result, as the three strings a row renders.
    ///
    /// `nil` when nothing is in flight. Three strings rather than a card, because they are what both
    /// call sites draw and the card they came from has no other reader on this side.
    public var pendingLine: PendingToolLine? {
        guard let blob = answer({ out, cap in slopdesk_inspector_store_pending_line(store, out, cap) }),
              let fields = Self.splitFields(blob), fields.count == 3
        else { return nil }
        return PendingToolLine(name: fields[0], summary: fields[1], display: fields[2])
    }

    /// Folds one event's JSON body in. `false` means the body did not decode and nothing changed.
    ///
    /// Not an error the caller must act on: a future or corrupt event costs that event, never the
    /// session's feed. That is the same in-band recovery ``InspectorFrameDecoder`` gives a bad frame,
    /// applied one layer in — which is where the decode now happens.
    @discardableResult
    public func apply(_ body: Data) -> Bool {
        body.withUnsafeBytes { bytes in
            slopdesk_inspector_store_apply(
                store, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
            )
        }
    }

    /// Consumes a stream of event bodies until it finishes.
    public func consume(_ bodies: AsyncThrowingStream<Data, Error>) async {
        feedState = .live // reset-on-entry: an iOS resume opens a fresh feed → live again
        // An iOS pause/resume reuses this SAME model and re-subscribes `fromSeq: 0`, so the host
        // replays its ENTIRE history into us again. What that would double is the store's business,
        // and it is one call rather than a list of properties a new field can be forgotten from.
        slopdesk_inspector_store_reset(store)
        do {
            for try await body in bodies {
                apply(body)
            }
            feedState = .ended // the host closed the feed cleanly (no live resubscribe on macOS)
        } catch {
            feedState = .failed
            // Read-only viewer: a transport error (a true framing desync, `frameTooLarge`) just ends
            // the feed. There is no in-session live resubscribe today; it resumes on the next iOS
            // pause/resume cycle, when `LivePaneSession.resume` → `subscribeInspector` opens a fresh
            // connection and subscribes from 0 against the host replay log.
        }
    }

    // MARK: reading a door

    /// A door's answer, or `nil` when it has none: probe for the size, then fill.
    private func answer(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8]? {
        let needed = door(nil, 0)
        guard needed > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: needed)
        let written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        return written == needed ? out : nil
    }

    /// Cuts the door's length-prefixed fields: four big-endian bytes, then that many UTF-8 bytes.
    private static func splitFields(_ blob: [UInt8]) -> [String]? {
        var fields: [String] = []
        var cursor = 0
        while cursor + 4 <= blob.count {
            var length = 0
            for offset in 0..<4 { length = length << 8 | Int(blob[cursor + offset]) }
            cursor += 4
            guard cursor + length <= blob.count else { return nil }
            guard let text = String(bytes: blob[cursor..<cursor + length], encoding: .utf8) else { return nil }
            fields.append(text)
            cursor += length
        }
        return cursor == blob.count ? fields : nil
    }
}

/// A pending tool call, as the two peek overlays draw it: the tool NAME and the one-line input
/// SUMMARY for the collapsed row, and the full input DISPLAY for the expanded one.
///
/// Three fields rather than a card, kept apart so a view renders the name and the summary in two
/// foreground weights without re-splitting a combined string.
public struct PendingToolLine: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let display: String

    public init(name: String, summary: String, display: String) {
        self.name = name
        self.summary = summary
        self.display = display
    }
}
