import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

// MARK: - ConnectGate (the app-global link's rules, as `slopdesk-workspace::connect_gate` answers them)

/// The six decisions the connect gate makes, in one face.
///
/// They were six Swift statics across ``ConnectionViewModel`` and ``AppConnection``, two of them
/// spelled twice — the batch coalescer, the input packer, the recent-hosts push, the failure
/// reason (verbatim in both files), the form's parse/validate pair, and the reconnect fold. All six
/// are pure, none of them touches AppKit, and the two hottest run on every keystroke, which by the
/// repo's own rule means none of them belongs in Swift.
///
/// Nothing here holds state. Nothing here reads a clock. What crosses is described per door.
enum ConnectGate {
    // MARK: - The OUT batch plan (the keystroke path)

    /// The frames one drained OUT batch should actually be sent as: resizes coalesced latest-wins
    /// with input as a hard barrier, then adjacent input payloads merged and oversized ones split
    /// at `maxInputFrameBytes`.
    ///
    /// ### The bytes do not cross
    ///
    /// This runs on every drained batch, which during a window drag is ~100 events and during a
    /// paste is one very large one — so the boundary is built so the payloads stay HERE. The rule
    /// reads only lengths (merging is addition, splitting is division, the barrier is the kind), so
    /// what crosses is one fixed-width record per event and what comes back is `(offset, length)`
    /// frames naming slices of the blob this function concatenated. `docs/55` §4's "the answer that
    /// is an OFFSET, not a copy": a pasted megabyte crosses as the same handful of records a single
    /// keystroke does.
    ///
    /// ### What the two halves are for
    ///
    /// The coalesce is the resize-corruption fix. A fast drag makes the layout pass derive a distinct
    /// grid size on every frame, and forwarding every one spreads ~100 `TIOCSWINSZ` over the wire, so
    /// zsh's incremental prompt redraw recomputes its cursor-up count against a size that keeps
    /// moving and desyncs. A local terminal never sees this because the kernel coalesces `SIGWINCH`.
    /// The TRAILING-EDGE GUARANTEE — the last resize of every batch always survives — is what makes
    /// the final drag size reach the PTY by construction rather than by a timer that could be lost.
    ///
    /// The pack is the send-cost fix: a key-repeat run pays one send instead of one per byte, and a
    /// paste is cut into frames the windowed data sub-channel will accept. Concatenation
    /// byte-identity holds by construction — the frames partition the blob in order.
    ///
    /// The buffer lent is the ARITHMETIC bound (one frame per event, plus the blob cut at the
    /// ceiling), so the `docs/55` §4 retry is there for correctness and is not travelled.
    static func plan(
        _ batch: [ConnectionViewModel.OutEvent],
        maxInputFrameBytes: Int = MuxFlowControl.maxDataMessagePayloadBytes,
    ) -> [ConnectionViewModel.OutEvent] {
        guard !batch.isEmpty else { return [] }
        var blob = Data()
        var events = [SlopDeskWsOutEvent]()
        events.reserveCapacity(batch.count)
        for event in batch {
            switch event {
            case let .input(payload):
                blob.append(payload)
                events.append(SlopDeskWsOutEvent(length: payload.count, cols: 0, rows: 0, kind: 0))
            case let .resize(cols, rows):
                events.append(SlopDeskWsOutEvent(length: 0, cols: cols, rows: rows, kind: 1))
            }
        }
        let ceiling = max(1, maxInputFrameBytes)
        var frames = [SlopDeskWsOutFrame](
            repeating: SlopDeskWsOutFrame(),
            count: batch.count + (blob.count + ceiling - 1) / ceiling,
        )
        func ask() -> Int {
            events.withUnsafeBufferPointer { lent in
                frames.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_out_batch_plan(
                        lent.baseAddress, lent.count, maxInputFrameBytes, out.baseAddress, out.count,
                    )
                }
            }
        }
        var count = ask()
        if count > frames.count {
            frames = [SlopDeskWsOutFrame](repeating: SlopDeskWsOutFrame(), count: count)
            count = ask()
        }
        guard count <= frames.count else { return batch }
        return frames.prefix(count).compactMap { frame -> ConnectionViewModel.OutEvent? in
            guard frame.kind == 0 else { return .resize(cols: frame.cols, rows: frame.rows) }
            let end = frame.offset + frame.length
            guard frame.length > 0, end <= blob.count else { return nil }
            return .input(blob.subdata(in: frame.offset..<end))
        }
    }

    // MARK: - The recent-hosts menu

    /// The gate's MRU after one successful connect: dedupe by host:port, push to the front, cap at
    /// `limit`.
    ///
    /// The door answers positions into a VIRTUAL list where `0` is `target` and `i + 1` is
    /// `list[i]`, which is what lets one answer carry the dedupe, the push-front and the cap at
    /// once — and is why a re-connect that changed only the video ports comes back with the NEW
    /// ports: position `0` is this caller's own value, not the entry it matched. The hosts cross as
    /// spans into one blob, so no `ConnectionTarget` is ever rebuilt on the far side.
    static func pushingRecent(
        _ target: ConnectionTarget,
        into list: [ConnectionTarget],
        limit: Int,
    ) -> [ConnectionTarget] {
        var strings = WsStrings()
        let host = strings.span(target.host)
        let entries = list.map { entry in
            SlopDeskWsRecentTarget(host: strings.span(entry.host), port: entry.port)
        }
        let blob = strings.bytes
        var order = [UInt32](repeating: 0, count: max(1, limit))
        let count = entries.withUnsafeBufferPointer { lent in
            blob.withUnsafeBufferPointer { bytes in
                order.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_recent_targets_push(
                        host, target.port, lent.baseAddress, lent.count,
                        bytes.baseAddress, bytes.count, limit, out.baseAddress, out.count,
                    )
                }
            }
        }
        guard count <= order.count else { return list }
        return order.prefix(count).compactMap { position -> ConnectionTarget? in
            guard position > 0 else { return target }
            let index = Int(position) - 1
            return list.indices.contains(index) ? list[index] : nil
        }
    }

    // MARK: - The failure reason

    /// The user-facing `.failed` reason for a thrown error.
    ///
    /// An `Error` cannot cross a C ABI, so what crosses is what can be got out of one: a
    /// `LocalizedError`'s clean `errorDescription` ("Connection timed out — host unreachable?"), and
    /// `String(describing:)`, which preserves the readable Swift payload
    /// (`invalidState("resume before first connect")`) rather than the bridged "The operation
    /// couldn't be completed. (… error N.)" dump a bare `localizedDescription` prints for a plain
    /// error enum. The rule picks the first of the two that has WORDS — a description that is
    /// present but blank has told the user nothing.
    ///
    /// One face for what was spelled character-for-character in two files.
    static func failureReason(for error: Error) -> String {
        let described = Array(((error as? LocalizedError)?.errorDescription ?? "").utf8)
        let fallback = String(describing: error)
        let raw = Array(fallback.utf8)
        let answer = described.withUnsafeBufferPointer { localized in
            raw.withUnsafeBufferPointer { payload in
                wsAnswer { out, cap in
                    slopdesk_ws_failure_reason(
                        localized.baseAddress, localized.count,
                        payload.baseAddress, payload.count, out, cap,
                    )
                }
            }
        }
        return answer ?? fallback
    }

    // MARK: - The form

    /// The connect form's ONE verdict: a target, or the hint that says why there is none.
    ///
    /// One case, not two calls. `validationHint == nil` ⟺ the Connect button is live is STRUCTURAL
    /// here — the two Swift halves this replaces walked the same four fields in the same order with
    /// two different sets of `if`s, which is the shape where a new field gets added to one of them.
    enum Parsed: Equatable {
        /// The four fields parse.
        case target(ConnectionTarget)
        /// They do not, and this is what to say about it.
        case refused(String)
    }

    /// Parses and validates the gate's four text fields.
    ///
    /// The host comes back as a SPAN into the bytes lent, because trimming is the only thing the
    /// parse does to it — `docs/55` §4's offset answer again. Every field is trimmed by the rule,
    /// which now also cuts a pasted trailing newline: Rust's `trim` is Unicode `White_Space`, where
    /// Swift's `CharacterSet.whitespaces` was not, so a host pasted out of a terminal is accepted
    /// instead of refused.
    static func parse(host: String, port: String, mediaPort: String, cursorPort: String) -> Parsed {
        let hostBytes = Array(host.utf8)
        let portBytes = Array(port.utf8)
        let mediaBytes = Array(mediaPort.utf8)
        let cursorBytes = Array(cursorPort.utf8)
        let verdict = hostBytes.withUnsafeBufferPointer { h in
            portBytes.withUnsafeBufferPointer { p in
                mediaBytes.withUnsafeBufferPointer { m in
                    cursorBytes.withUnsafeBufferPointer { c in
                        slopdesk_ws_connect_gate_parse(
                            h.baseAddress, h.count, p.baseAddress, p.count,
                            m.baseAddress, m.count, c.baseAddress, c.count,
                        )
                    }
                }
            }
        }
        guard verdict.hint == 0 else {
            let words = wsAnswer { out, cap in slopdesk_ws_connect_gate_hint(verdict.hint, out, cap) }
            return .refused(words ?? "")
        }
        let end = verdict.host_offset + verdict.host_length
        guard verdict.host_length > 0, end <= hostBytes.count else { return .refused("") }
        // The span is a slice of bytes this function derived from a `String`, so it cannot be
        // invalid UTF-8; a failable decode here would add a branch meaning "the host has no text".
        // swiftlint:disable:next optional_data_string_conversion
        let trimmed = String(decoding: hostBytes[verdict.host_offset..<end], as: UTF8.self)
        return .target(ConnectionTarget(
            host: trimmed,
            port: verdict.port,
            mediaPort: verdict.media_port,
            cursorPort: verdict.cursor_port,
        ))
    }

    // MARK: - The reconnect fold

    /// What one reconnect-campaign callback does to the status it lands on.
    enum Reconnect {
        /// Nothing — the callback is stale, or the link moved on without it.
        case leave
        /// Adopt `.reconnecting`, carrying the caller's OWN attempt count and next-retry instant.
        case reconnecting
        /// Adopt `.unreachable`: the campaign is over.
        case unreachable
    }

    /// Decides what a reconnect callback does to `status`.
    ///
    /// Two races make this a rule rather than an assignment. A progress callback for the attempt
    /// that SUCCEEDED can land after the reconnected event already flipped the link back up, and
    /// adopting it would drag a live link into an orange "Reconnecting…" no supervisor would ever
    /// leave. And cancelling a supervisor does not cancel an already-fired callback's hop, while
    /// `.disconnected` is BOTH the transient-drop state and the deliberate-close terminal one — so
    /// without `deliberatelyClosed` a late callback whitewashes a closed link.
    ///
    /// The attempt count and the next-retry instant deliberately do not cross: they are the
    /// caller's payload for the status it adopts, and the rule reads neither. The mutation stays in
    /// Swift, where the `@Observable` property is.
    static func reconnectFold(
        status: ConnectionStatus,
        deliberatelyClosed: Bool,
        gaveUp: Bool,
    ) -> Reconnect {
        switch slopdesk_ws_reconnect_fold(status.terms.code, deliberatelyClosed, gaveUp) {
        case 1: .reconnecting
        case 2: .unreachable
        default: .leave
        }
    }
}
