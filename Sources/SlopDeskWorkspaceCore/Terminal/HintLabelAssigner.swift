import CSlopDeskFFI
import Foundation
import SlopDeskArena

// MARK: - Pure Hint Mode target detection + Vimium-style 2-letter label assignment

/// Which hint action the user armed — the "Hint to …" family (`docs/ui-shell/spec/terminal-features__hint-mode.md`).
///
/// - ``open``: ⌘⇧J — opens the matched target (a file path on the HOST, a URL on the CLIENT, …).
/// - ``copy``: ⌘⇧Y — copies the matched text to the CLIENT clipboard.
/// - ``reveal``: (chord-less — ⌘⇧R is slopdesk's Toggle Details) — reveals the matched PATH in
///   Finder on the HOST.
public enum HintIntent: Equatable, Sendable {
    case open
    case copy
    case reveal

    /// The word the overlay's badge prints, and the word its accessibility label reads.
    ///
    /// On the enum rather than at the badge because the badge is drawn twice — `HintModeOverlayView` in UIKit
    /// on the phone, `MacHintModeOverlay` in AppKit on the Mac (docs/56 §2) — and a verb spelled at each
    /// drawing is a verb that can drift. Upper-case is the SHAPE of the badge, not a shout: it is one word in a
    /// 14pt plate over a terminal, and mixed case at that size reads as body text.
    public var badgeLabel: String {
        switch self {
        case .open: "OPEN"
        case .copy: "COPY"
        case .reveal: "REVEAL"
        }
    }
}

/// A user-defined hint pattern (`hint-pattern` + `hint-pattern-action`): a regex string plus an
/// optional shell-command action template whose `{0}` placeholder is replaced with the matched text.
public struct HintPattern: Equatable, Sendable {
    /// The regex that defines a custom hintable span.
    ///
    /// The dialect is the `regex` crate's: the full character-class / repetition / alternation
    /// grammar, minus the two constructs a finite automaton has no room for — lookaround and
    /// backreferences. That is not a limitation the engine apologises for, it is the reason it was
    /// chosen: a pattern here is matched in time linear in the row, so no `hint-pattern` a user
    /// pastes in can hang the overlay on a long line. A pattern the engine cannot compile is
    /// dropped, and the others keep working.
    public var regex: String
    /// The action template run when the label resolves — `{0}` is replaced with the matched text. `nil` when
    /// the pattern carries no paired action (the target then falls back to copy-on-resolve).
    public var action: String?

    public init(regex: String, action: String? = nil) {
        self.regex = regex
        self.action = action
    }
}

/// One hintable target in the visible viewport: its cell span (same display-cell convention as
/// ``DetectedLink`` — fullwidth/East-Asian glyphs count as two cells), the matched text, and the kind that
/// decides how a resolved label actuates.
public struct HintTarget: Equatable, Sendable {
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
    public var raw: String
    public var kind: Kind

    /// What the target is — drives the resolved action (open/copy/reveal) at the actuation site.
    ///
    /// - ``link``: a path / URL / `file://` / `mailto:` span the shared ``TerminalLinkDetector`` already
    ///   classified — carries the full ``DetectedLink`` so the actuator routes through the SAME pure
    ///   ``LinkActionPolicy`` the ⌘click / Jump-To paths use (no parallel mapping to drift).
    /// - ``gitHash``: a `[0-9a-f]{7,40}` commit-hash-shaped token.
    /// - ``ipAddress``: a dotted-quad IPv4 address.
    /// - ``custom``: a user `hint-pattern` match, carrying its optional `{0}` action template.
    public enum Kind: Equatable, Sendable {
        case link(DetectedLink)
        case gitHash
        case ipAddress
        case custom(actionTemplate: String?)
    }

    public init(row: Int, colStart: Int, colEnd: Int, raw: String, kind: Kind) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.raw = raw
        self.kind = kind
    }
}

/// The heart of Hint Mode: every hintable target in the visible viewport, then collision-free
/// 2-letter Vimium labels over them, filtered as the user types.
///
/// ## The SCAN is a call; the LABELS are not
/// ``targets(rows:cwd:schemes:patterns:maxScanColumns:)`` is `slopdesk_hint::targets`, reached
/// through `slopdesk_hint_scan` (docs/55). What used to be here was a second regex pass — ten
/// `NSRegularExpression` runs bridged through `NSString`, with a third cell walk asking the link
/// detector for each glyph's width. Two problems, and the boundary fixed both: the columns now come
/// from the SAME clustering the link overlay draws its underline in, and the user's `hint-pattern`
/// now runs on a finite automaton, so a pattern pasted off the internet can no longer make a long
/// row hang the overlay the way a backtracking engine could.
///
/// ``labels(count:alphabet:)`` and ``filter(typed:labels:)`` stay here. They are list arithmetic
/// over 26 letters — no text, no bounds, no untrusted input — and they run on every keystroke next
/// to the overlay that already holds their result.
///
/// ## Validate-then-drop & bounds (applied to untrusted terminal bytes)
/// Terminal output is attacker-influenced. Each row is scanned for at most `maxScanColumns` **cells**, at
/// most ``TerminalLinkDetector/maxMatchesPerRow`` targets are kept per row, an invalid user regex is dropped
/// (never a trap), and an extra (git-hash/IP/custom) match that OVERLAPS an already-accepted span is dropped
/// so a hex run inside a URL — or an IP inside a path — never double-lights. All of that is the
/// crate's now; `HintLabelAssignerTests` pins it from this side unchanged.
public enum HintLabelAssigner {
    /// The label alphabet — home row first, then the top row, then the bottom row (Vimium "ordered by
    /// distance from the home row"). 26 letters ⇒ up to 26² = 676 two-letter labels (far more than a
    /// viewport ever holds). All lowercase; matching is case-insensitive.
    public static let defaultAlphabet: [Character] = Array("asdfghjklqwertyuiopzxcvbnm")

    // MARK: - Label assignment

    /// Assign `count` UNIQUE, exactly-2-letter labels over `alphabet`.
    ///
    /// The first letter cycles FASTEST (`alphabet[i % k]`) and the second slowest (`alphabet[i / k]`), so
    /// consecutive on-screen targets get DIFFERENT first letters — typing one key spreads the survivors
    /// across the screen instead of clustering them (the Vimium ergonomic). Each `i` in `0 ..< k²` maps to a
    /// unique `(i % k, i / k)` pair, so the labels are collision-free. Bounded at `k²`: a (pathological)
    /// request for more targets than the alphabet can label 2-deep is clamped (the caller then shows only the
    /// labelled prefix — never an ambiguous or 3-letter label).
    public static func labels(count: Int, alphabet: [Character] = defaultAlphabet) -> [String] {
        guard !alphabet.isEmpty else { return [] }
        let k = alphabet.count
        let n = min(max(count, 0), k * k)
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(String([alphabet[i % k], alphabet[i / k]]))
        }
        return out
    }

    /// The result of filtering the labels against the keys typed so far.
    public struct FilterResult: Equatable, Sendable {
        /// Labels that still start with the typed prefix (kept bright).
        public var matched: [String]
        /// Labels that no longer match (dimmed / hidden to narrow focus).
        public var dimmed: [String]
        /// The label the user has fully typed (2 chars, exact) — the action runs immediately, no Enter.
        public var confirmed: String?

        public init(matched: [String], dimmed: [String], confirmed: String?) {
            self.matched = matched
            self.dimmed = dimmed
            self.confirmed = confirmed
        }
    }

    /// Filter `labels` against `typed` (the keys entered so far). Empty `typed` ⇒ all matched, none dimmed.
    /// One letter ⇒ matched are the labels with that first letter (the rest dim). Two letters ⇒ `confirmed`
    /// is the exact label (if any) — the second key confirms with no Enter required.
    public static func filter(typed: String, labels: [String]) -> FilterResult {
        let key = typed.lowercased()
        guard !key.isEmpty else {
            return FilterResult(matched: labels, dimmed: [], confirmed: nil)
        }
        var matched: [String] = []
        var dimmed: [String] = []
        for label in labels {
            if label.hasPrefix(key) { matched.append(label) } else { dimmed.append(label) }
        }
        // A label is exactly 2 chars; once the prefix is 2 long it either equals a label (confirm) or matches
        // none (an invalid second key — the caller ignores it, keeping the first letter).
        let confirmed = key.count >= 2 ? labels.first { $0 == key } : nil
        return FilterResult(matched: matched, dimmed: dimmed, confirmed: confirmed)
    }

    // MARK: - Target detection

    /// Detect every hintable target in `rows` (the VISIBLE viewport), row-major / left-to-right.
    ///
    /// - Parameters:
    ///   - rows: the visible viewport rows top→bottom (``TerminalViewportSnapshotting/viewportTextRows()``).
    ///   - cwd: the pane's last-known working directory (OSC 7) — resolves relative detected paths.
    ///   - schemes: which `scheme://…` URLs are detected (`http(s)`/`file`/`mailto` always on).
    ///   - patterns: user `hint-pattern` regexes (+ their `{0}` action templates).
    ///   - maxScanColumns: per-row cell-scan ceiling (the anti-hang bound). The default is
    ///     ``TerminalLinkDetector/maxScanColumnsDefault``, which is the one spelling of
    ///     `link::MAX_SCAN_COLUMNS` on this side and the one `slopdesk-invariants` ratchets. A bare
    ///     `4096` sat here instead until 2026-08-20 — a third copy of the bound, outside the gate's
    ///     scope, free to stay behind a tuning of the other two.
    public static func targets(
        rows: [String],
        cwd: String?,
        schemes: LinkSchemePolicy,
        patterns: [HintPattern] = [],
        maxScanColumns: Int = TerminalLinkDetector.maxScanColumnsDefault,
    ) -> [HintTarget] {
        guard maxScanColumns > 0 else { return [] }

        let (rowBlob, rowLengths) = TerminalLinkDetector.flatten(rows)
        let schemeList: [String]
        let schemeMode: UInt32
        switch schemes {
        case .all:
            schemeList = []
            schemeMode = UInt32(SLOPDESK_LINK_SCHEMES_ALL)
        case let .custom(allowed):
            schemeList = allowed
            schemeMode = UInt32(SLOPDESK_LINK_SCHEMES_CUSTOM)
        }
        let (schemeBlob, schemeLengths) = TerminalLinkDetector.flatten(schemeList)
        let (patternBlob, patternLengths) = TerminalLinkDetector.flatten(patterns.map(\.regex))
        // An empty template IS "no action" on the far side, so a pattern without one contributes a
        // zero-length entry rather than a hole the two lists would then disagree about.
        let (actionBlob, actionLengths) = TerminalLinkDetector.flatten(patterns.map { $0.action ?? "" })
        let cwdBytes = Array((cwd ?? "").utf8)

        guard let scan = slopdesk_hint_scan(
            rowBlob, rowBlob.count,
            rowLengths, rowLengths.count,
            cwdBytes, cwdBytes.count,
            schemeMode,
            schemeBlob, schemeBlob.count,
            schemeLengths, schemeLengths.count,
            patternBlob, patternBlob.count,
            patternLengths,
            actionBlob, actionBlob.count,
            actionLengths,
            patternLengths.count,
            maxScanColumns,
        ) else { return [] }
        defer { slopdesk_hint_scan_free(scan) }

        let counts = slopdesk_hint_scan_counts(scan)
        var arena = [UInt8](repeating: 0, count: counts.arena_length)
        let written = arena.withUnsafeMutableBufferPointer {
            slopdesk_hint_scan_take_arena(scan, $0.baseAddress, $0.count)
        }
        precondition(written == counts.arena_length, "the arena answered a size it would not fill")

        // One borrow for every string in the scan: the arena is read at most three times per
        // target, and each read is a rebase inside a buffer that is already there.
        return arena.withUnsafeBytes { raw -> [HintTarget] in
            var out: [HintTarget] = []
            out.reserveCapacity(counts.target_count)
            for index in 0..<counts.target_count {
                let record = slopdesk_hint_scan_target(scan, index)
                let text = TerminalLinkDetector.text(raw, record.raw_offset, record.raw_length)
                guard let kind = kind(of: record, raw: raw, text: text) else { continue }
                out.append(HintTarget(
                    row: record.row, colStart: record.col_start, colEnd: record.col_end,
                    raw: text, kind: kind,
                ))
            }
            return out
        }
    }

    /// The kind one record names, reading the arena for whichever strings that kind carries.
    ///
    /// `nil` for `SLOPDESK_HINT_KIND_NONE` — the door's answer to an index past the end, which the
    /// reader loop never asks for — and for a LINK whose link kind does not decode, which is the
    /// same validate-then-drop the link reader applies.
    private static func kind(
        of record: SlopDeskHintTarget,
        raw: UnsafeRawBufferPointer,
        text: String,
    ) -> HintTarget.Kind? {
        switch record.kind {
        case UInt32(SLOPDESK_HINT_KIND_LINK):
            guard let linkKind = TerminalLinkDetector.kind(of: record.link_kind) else { return nil }
            return .link(DetectedLink(
                row: record.row, colStart: record.col_start, colEnd: record.col_end,
                kind: linkKind, raw: text,
                resolvedAbsolute: record.has_resolved
                    ? TerminalLinkDetector.text(raw, record.resolved_offset, record.resolved_length)
                    : nil,
            ))
        case UInt32(SLOPDESK_HINT_KIND_GIT_HASH):
            return .gitHash
        case UInt32(SLOPDESK_HINT_KIND_IP_ADDRESS):
            return .ipAddress
        case UInt32(SLOPDESK_HINT_KIND_CUSTOM):
            return .custom(actionTemplate: record.has_action
                ? TerminalLinkDetector.text(raw, record.action_offset, record.action_length)
                : nil)
        default:
            return nil
        }
    }
}
