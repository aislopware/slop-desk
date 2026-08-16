/// One text answer through a lent buffer: ask for the length, then lend exactly that much.
///
/// Every text door in these settings is called twice, because the near side owns the memory and the
/// far side owns the length — the first call reports what is needed and writes nothing, the second
/// writes into the room it asked for. Written once here so the second call cannot drift from the
/// first: a measure that disagrees with its fill is a truncated answer, and the only honest reading
/// of a truncated answer is none at all.
///
/// `call` is handed `(nil, 0)` to measure and `(room, count)` to fill; it returns the byte count the
/// far side needs, or wrote.
func lentText(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
    let needed = call(nil, 0)
    guard needed > 0 else { return "" }
    var out = [UInt8](repeating: 0, count: needed)
    let written = out.withUnsafeMutableBufferPointer { room in
        call(room.baseAddress, room.count)
    }
    guard written == needed else { return "" }
    // The far side wrote its own UTF-8, so the decode cannot fail.
    return String(bytes: out, encoding: .utf8) ?? ""
}
