import Foundation

/// A rule's `region` spec — which slice of the snapshot the rule's gate evaluates against
/// (herdr `region()` + `validate_region_name`, ported 1:1 including the `\n`-only line/offset
/// math: line lengths are UTF-8 byte counts, each line contributes `len + 1`, and every offset
/// clamps to the content length — total on any input, never traps).
public enum ManifestRegion: Sendable, Equatable {
    case oscTitle
    case oscProgress
    case wholeRecent
    case afterLastPromptMarker
    case beforeCurrentPromptMarker
    case wholeRecentWithoutCurrentPromptMarker
    case currentPromptBlockMarker
    case afterCurrentPromptBlockMarker
    case promptBoxBody
    case abovePromptBox
    case lastNonEmptyAbovePromptBox
    case afterLastHorizontalRule
    case bottomLines(Int)
    case bottomNonEmptyLines(Int)
    case topNonEmptyLines(Int)

    /// Parses a (pre-trimmed) region spec. `nil` = invalid name (whole manifest rejected).
    public static func parse(_ spec: String) -> Self? {
        switch spec {
        case "osc_title": return .oscTitle
        case "osc_progress": return .oscProgress
        case "whole_recent": return .wholeRecent
        case "after_last_prompt_marker": return .afterLastPromptMarker
        case "before_current_prompt_marker": return .beforeCurrentPromptMarker
        case "whole_recent_without_current_prompt_marker": return .wholeRecentWithoutCurrentPromptMarker
        case "current_prompt_block_marker": return .currentPromptBlockMarker
        case "after_current_prompt_block_marker": return .afterCurrentPromptBlockMarker
        case "prompt_box_body": return .promptBoxBody
        case "above_prompt_box": return .abovePromptBox
        case "last_non_empty_above_prompt_box": return .lastNonEmptyAbovePromptBox
        case "after_last_horizontal_rule": return .afterLastHorizontalRule
        default:
            if let count = plainCount(spec, name: "bottom_lines") { return .bottomLines(count) }
            if let count = plainCount(spec, name: "bottom_non_empty_lines") { return .bottomNonEmptyLines(count) }
            if let count = topCount(spec) { return .topNonEmptyLines(count) }
            return nil
        }
    }

    /// herdr `region_count`: bare `usize` parse (accepts `+1`/`01`, like Rust's).
    private static func plainCount(_ spec: String, name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        let inner = String(spec.dropFirst(name.count + 1).dropLast())
        guard let count = Int(inner), count >= 0 else { return nil }
        return count
    }

    /// herdr `top_region_count`: canonical positive bounded count — digits only, no leading
    /// zero, ≤ 65535.
    private static func topCount(_ spec: String) -> Int? {
        guard spec.hasPrefix("top_non_empty_lines("), spec.hasSuffix(")") else { return nil }
        let inner = String(spec.dropFirst("top_non_empty_lines(".count).dropLast())
        guard !inner.isEmpty, !inner.hasPrefix("0"), inner.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int(inner), count <= Int(UInt16.max)
        else { return nil }
        return count
    }

    /// Resolves the region against a snapshot. OSC regions ignore the screen entirely.
    public func resolve(_ input: AgentDetectionInput) -> String {
        switch self {
        case .oscTitle: input.oscTitle
        case .oscProgress: input.oscProgress
        default: resolveScreen(input.screen)
        }
    }

    func resolveScreen(_ content: String) -> String {
        let text = RegionText(content)
        switch self {
        case .oscTitle,
             .oscProgress:
            return "" // handled in resolve()
        case .wholeRecent:
            return content
        case .afterLastPromptMarker:
            guard let index = text.lines.lastIndex(where: Self.codexPromptLine) else { return content }
            return text.suffix(fromLine: index + 1)
        case .beforeCurrentPromptMarker:
            guard let index = Self.currentCodexPromptIndex(text.lines) else { return content }
            return text.prefix(toLine: index)
        case .wholeRecentWithoutCurrentPromptMarker:
            return Self.currentCodexPromptIndex(text.lines) != nil ? "" : content
        case .currentPromptBlockMarker:
            guard let promptIndex = Self.currentCodexPromptIndex(text.lines) else { return "" }
            return text.lines[..<promptIndex].last(where: Self.codexBlockMarkerLine) ?? ""
        case .afterCurrentPromptBlockMarker:
            guard let promptIndex = Self.currentCodexPromptIndex(text.lines),
                  let blockIndex = text.lines[..<promptIndex].lastIndex(where: Self.codexBlockMarkerLine)
            else { return "" }
            return text.suffix(fromLine: blockIndex)
        case .promptBoxBody:
            guard let top = Self.promptBoxTopBorderIndex(text.lines) else { return "" }
            let start = text.byteOffset(ofLine: top + 1)
            let endIndex = text.lines[(top + 1)...].firstIndex(where: Self.isHorizontalRule)
                ?? text.lines.count
            let end = text.byteOffset(ofLine: endIndex)
            return text.slice(start..<end)
        case .abovePromptBox:
            guard let top = Self.promptBoxTopBorderIndex(text.lines) else { return content }
            return text.prefix(toLine: top)
        case .lastNonEmptyAbovePromptBox:
            let above = Self.abovePromptBox.resolveScreen(content)
            let aboveText = RegionText(above)
            return aboveText.lines.last { !$0.isBlankRustTrim } ?? ""
        case .afterLastHorizontalRule:
            var lastRuleEnd = 0
            var offset = 0
            for line in text.lines {
                let next = offset + line.utf8.count + 1
                if Self.isHorizontalRule(line) { lastRuleEnd = min(next, text.byteCount) }
                offset = next
            }
            return text.slice(lastRuleEnd..<text.byteCount)
        case let .bottomLines(count):
            let start = max(text.lines.count - count, 0)
            return text.suffix(fromLine: start)
        case let .bottomNonEmptyLines(count):
            guard count > 0 else { return "" }
            var startIndex: Int?
            var taken = 0
            for index in stride(from: text.lines.count - 1, through: 0, by: -1)
                where !text.lines[index].isBlankRustTrim
            {
                startIndex = index
                taken += 1
                if taken == count { break }
            }
            guard let start = startIndex else { return "" }
            return text.suffix(fromLine: start)
        case let .topNonEmptyLines(count):
            guard count > 0 else { return "" }
            var endIndex: Int?
            var taken = 0
            for (index, line) in text.lines.enumerated()
                where !line.isBlankRustTrim
            {
                endIndex = index
                taken += 1
                if taken == count { break }
            }
            guard let end = endIndex else { return "" }
            return text.prefix(toLine: end + 1)
        }
    }

    // MARK: - Line predicates (herdr, exact)

    static func codexPromptLine(_ line: String) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    static func codexBlockMarkerLine(_ line: String) -> Bool {
        line.hasPrefix("•") || line.hasPrefix("■") || line.hasPrefix("✗") || line.hasPrefix("✓")
    }

    /// The last prompt line — but only "current" if no block marker appears after it.
    static func currentCodexPromptIndex(_ lines: [String]) -> Int? {
        guard let promptIndex = lines.lastIndex(where: codexPromptLine) else { return nil }
        if lines[(promptIndex + 1)...].contains(where: codexBlockMarkerLine) { return nil }
        return promptIndex
    }

    /// The 2nd horizontal-rule line counted from the BOTTOM — the top border of the last box.
    static func promptBoxTopBorderIndex(_ lines: [String]) -> Int? {
        var borderCount = 0
        for index in stride(from: lines.count - 1, through: 0, by: -1) where isHorizontalRule(lines[index]) {
            borderCount += 1
            if borderCount == 2 { return index }
        }
        return nil
    }

    /// A leading run of `─` (U+2500); the line is a rule when the suffix is empty or the run
    /// is ≥ 3 (permits trailing annotations like `── (bypass permissions on) ─`).
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix(while: { $0 == "─" }).count
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.dropFirst(ruleChars).drop(while: \.isWhitespace)
        return suffix.isEmpty || ruleChars >= 3
    }
}

/// Rust-`str::lines()`-faithful line splitting + byte-offset math over one content string.
/// Lines split on `\n` only (one trailing empty segment dropped, one trailing `\r` stripped
/// per line); offsets are UTF-8 byte sums of `len + 1` per line, clamped to the content length.
struct RegionText {
    let content: String
    let lines: [String]
    let byteCount: Int
    private let bytes: [UInt8]

    init(_ content: String) {
        self.content = content
        bytes = Array(content.utf8)
        byteCount = bytes.count
        lines = Self.rustLines(content)
    }

    /// Rust `str::lines()` semantics, byte-exact. Split at the BYTE level: Swift's
    /// `Character`-based `split(separator: "\n")` treats `\r\n` as one grapheme and never
    /// splits CRLF text. And Rust strips a trailing `\r` only on segments that ended with
    /// `\n` — a final line without a newline keeps its `\r`.
    static func rustLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        let bytes = Array(content.utf8)
        var lines: [String] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            var end = index
            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
            lines.append(String(bytes: bytes[start..<end], encoding: .utf8) ?? "")
            start = index + 1
        }
        if start < bytes.count {
            lines.append(String(bytes: bytes[start...], encoding: .utf8) ?? "")
        }
        return lines
    }

    /// Byte offset of the start of `lines[index]` (index may equal `lines.count`), clamped.
    func byteOffset(ofLine index: Int) -> Int {
        var offset = 0
        for line in lines[..<min(index, lines.count)] {
            offset += line.utf8.count + 1
        }
        return min(offset, byteCount)
    }

    func suffix(fromLine index: Int) -> String {
        slice(byteOffset(ofLine: index)..<byteCount)
    }

    func prefix(toLine index: Int) -> String {
        slice(0..<byteOffset(ofLine: index))
    }

    /// Total byte-range slice. Every offset is a line boundary of valid-UTF-8 content (the
    /// grid builds its rows from Strings), so the failable decode only trips on the
    /// theoretical `\r`-drift case — where an empty region is the safe verdict (no rule
    /// matches), never a trap.
    func slice(_ range: Range<Int>) -> String {
        let lower = min(max(range.lowerBound, 0), byteCount)
        let upper = min(max(range.upperBound, lower), byteCount)
        return String(bytes: bytes[lower..<upper], encoding: .utf8) ?? ""
    }
}

extension String {
    /// Rust `line.trim().is_empty()`. Rust's `trim` strips Unicode White_Space, which
    /// INCLUDES `\r`/`\n` — Foundation's plain `.whitespaces` does not, and a final
    /// `\r`-only line must count as blank exactly like upstream.
    var isBlankRustTrim: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
