import Foundation

/// The Swift half of `docs/55` §4c's arena convention: a `(offset, length)` pair read back as text.
///
/// Every door that hands Swift a list of records with strings in them passes the strings as offsets
/// into one buffer rather than as pointers, so no record makes the caller own a lifetime. The crate
/// side of that is `TextArena::intern` writing and `arena_text` reading; this is BOTH halves on the
/// Swift side — reading what a crate filled, and filling what a crate is about to read — and it is
/// here rather than in each codec because it was TWENTY-SIX copies before it was one, and they had
/// drifted in every way a bounds check can:
///
/// - Of the text readers, most bounds-checked the far end of the span; `VideoControlCodec` checked
///   only that the length was non-zero, so a pair naming bytes past the arena would have read
///   whatever followed it.
/// - Most repaired invalid UTF-8 (`String(decoding:as:)`); `WorkspaceChannelCodec`,
///   `FileTransferCodec`, `CLIArgs`, `JumpResolver`, `CLIConfig`, `CLICompletions` and
///   `HostWindowRecordRows` answered the empty string instead (`String(bytes:encoding:) ?? ""`),
///   which is a DIFFERENT answer for the same bytes and the opposite of what the crate's reader
///   does.
/// - Of the BYTE readers — a keybind's literal, a client effect's run, a retransmit ring's packet —
///   one guarded `start >= 0, end <= count, start <= end`, one guarded only `end <= count`, and the
///   ring guarded nothing at all: a pair naming bytes past the arena would have TRAPPED rather than
///   answered empty.
/// - The doors Swift builds an arena FOR each had their own `intern`, and they disagreed about
///   overflow too: most clamped the offset into `u32`, `WireMessageCodec` and `VideoControlCodec`
///   used a plain `UInt32(...)` conversion, which traps.
///
/// None of the twenty-six is known to have misread anything: every arena a face reads was filled by
/// a Rust `String` in the same call, so the checks are defence and the UTF-8 branch is unreachable
/// today. That is the argument FOR one copy rather than against it — §6's `process::basename` bug
/// was two implementations disagreeing for a month with nobody able to see it.
///
/// The module depends on nothing but Foundation — not even `CSlopDeskFFI`: an offset and a length
/// are not a boundary, they are arithmetic. A door whose pair is a named C struct keeps its own one-line
/// overload beside that struct and calls through to here, the way the crate's field-keyed readers do.
public enum ArenaText {
    /// The bytes at `offset..<offset + length`, or empty when the pair does not name bytes that are
    /// there.
    ///
    /// Total on purpose: this is the direction the FAR side filled, so a pair that does not fit is
    /// untrusted input on every door rather than something to trap on. Overflow is folded in by
    /// widening to `UInt64` before the add, so a hostile pair cannot make `offset + length` trap
    /// before the bounds check ever runs.
    public static func span(
        _ arena: UnsafeRawBufferPointer,
        _ offset: Int,
        _ length: Int,
    ) -> UnsafeRawBufferPointer {
        guard offset >= 0, length > 0 else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        let end = UInt64(offset) + UInt64(length)
        guard end <= UInt64(arena.count) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(rebasing: arena[offset..<offset + length])
    }

    /// One arena span as the string it holds — ``span(_:_:_:)`` read as UTF-8.
    ///
    /// The repairing initialiser rather than the failable one, matching the crate's `arena_text`:
    /// the bytes came back from a Rust `String`, so there is no reachable arm for a failure to take,
    /// and answering `""` for a byte sequence the far side considered a string would lose the whole
    /// field rather than one character of it.
    public static func text(_ arena: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: span(arena, offset, length), as: UTF8.self)
    }

    /// The same read for a pair the door spelled `UInt32`, which is most of them.
    public static func text(
        _ arena: UnsafeRawBufferPointer,
        _ offset: UInt32,
        _ length: UInt32,
    ) -> String {
        text(arena, Int(offset), Int(length))
    }

    /// ``text(_:_:_:)`` for the one door that can tell an ABSENT field from an empty one, where a
    /// pair that does not fit must not read as the empty string.
    ///
    /// `nil` means the pair names bytes that are not there — a marshalling bug, which that door
    /// reports rather than papers over. A length of zero inside the arena is still `""`, because a
    /// field the far side wrote as empty IS empty and is not the same fact.
    public static func optionalText(
        _ arena: UnsafeRawBufferPointer,
        _ offset: Int,
        _ length: Int,
    ) -> String? {
        guard offset >= 0, length >= 0, UInt64(offset) + UInt64(length) <= UInt64(arena.count) else {
            return nil
        }
        return text(arena, offset, length)
    }

    // MARK: - The arena Swift itself holds

    /// The same read for an arena Swift is holding as `Data` rather than as a borrowed buffer —
    /// which is every door Swift builds the arena FOR, on its way in.
    ///
    /// Same answers as ``text(_:_:_:)``, deliberately: a pair that does not fit reads `""`, and
    /// invalid UTF-8 is REPAIRED rather than dropped. The two copies this replaces used
    /// `String(bytes:encoding:) ?? ""`, which answers the empty string for a byte sequence the far
    /// side considered a field — losing the whole value instead of one character of it, and
    /// disagreeing with what the crate's own reader does with the same bytes.
    public static func text(_ arena: Data, offset: Int, length: Int) -> String {
        guard let range = range(in: arena, offset: offset, length: length) else { return "" }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: arena[range], as: UTF8.self)
    }

    /// The BYTES a pair names, for the arenas whose payload is not text — a keybind's literal, a
    /// retransmit ring's packet, a client effect's run.
    ///
    /// Same guard as the text reads, and the reason to share it is that the four copies this
    /// replaces did NOT share it: one checked `start >= 0, end <= count, start <= end`, one checked
    /// only `end <= count`, and one checked nothing at all and would have trapped on a pair naming
    /// bytes past the arena rather than answering empty.
    public static func bytes<Arena: Collection>(
        _ arena: Arena, offset: Int, length: Int,
    ) -> [UInt8] where Arena.Element == UInt8, Arena.Index == Int {
        guard let range = range(in: arena, offset: offset, length: length) else { return [] }
        return Array(arena[range])
    }

    /// ``bytes(_:offset:length:)`` answered as `Data`, for a caller handing the run straight back to
    /// something that wants one — no second copy on the way.
    public static func data(_ arena: Data, offset: Int, length: Int) -> Data {
        guard let range = range(in: arena, offset: offset, length: length) else { return Data() }
        return Data(arena[range])
    }

    /// The in-bounds range a `(offset, length)` pair names, or `nil` when it names bytes that are
    /// not there. The ONE guard behind every read above.
    ///
    /// Widened to `UInt64` before the add for the same reason ``span(_:_:_:)`` is: a hostile pair
    /// must not be able to overflow `offset + length` into a range that passes the check.
    private static func range<Arena: Collection>(
        in arena: Arena, offset: Int, length: Int,
    ) -> Range<Int>? where Arena.Index == Int {
        guard offset >= 0, length > 0,
              UInt64(offset) + UInt64(length) <= UInt64(arena.count) else { return nil }
        let start = arena.startIndex + offset
        return start..<start + length
    }

    /// Appends `bytes` to `arena` and answers the `(offset, length)` naming them — the write half of
    /// `docs/55` §4c, on the side that is filling the buffer.
    ///
    /// Generic over the arena because both spellings are in use and neither is wrong: a door that
    /// hands the crate an `UnsafeRawBufferPointer` builds `Data`, one that hands it an
    /// `UnsafeBufferPointer<UInt8>` builds `[UInt8]`. The law is the same either way, and it is the
    /// ORDER that matters — the offset is read before the append, and a copy that read it after
    /// would name the end of the span instead of its start.
    ///
    /// The saturation is the same one `TextArena::intern` performs on the crate side: a `u32` pair
    /// cannot name a span past 4 GiB, and an arena that large is a bug upstream of here, not a
    /// reason for this to trap. Clamping keeps the pair INSIDE the type at the cost of naming the
    /// wrong bytes; the reader's bounds check is what makes that a truncated field rather than a
    /// read past the end.
    @discardableResult
    public static func intern<Arena: RangeReplaceableCollection>(
        bytes: some Collection<UInt8>, into arena: inout Arena,
    ) -> (offset: UInt32, length: UInt32) where Arena.Element == UInt8 {
        let offset = UInt32(clamping: arena.count)
        arena.append(contentsOf: bytes)
        return (offset: offset, length: UInt32(clamping: bytes.count))
    }

    /// The `Data`-into-`Data` case, spelled concretely so it keeps `Data`'s bulk append.
    ///
    /// Not tidiness: the retransmit ring interns every outgoing packet of every frame, and the
    /// generic above would reach `Data.append(contentsOf:)` through a `Collection` witness on the
    /// video send path. Overload resolution prefers this one, and it is the same three lines.
    @discardableResult
    public static func intern(
        bytes: Data, into arena: inout Data,
    ) -> (offset: UInt32, length: UInt32) {
        let offset = UInt32(clamping: arena.count)
        arena.append(bytes)
        return (offset: offset, length: UInt32(clamping: bytes.count))
    }

    /// One string's UTF-8, interned.
    @discardableResult
    public static func intern<Arena: RangeReplaceableCollection>(
        _ value: String, into arena: inout Arena,
    ) -> (offset: UInt32, length: UInt32) where Arena.Element == UInt8 {
        intern(bytes: Array(value.utf8), into: &arena)
    }
}
