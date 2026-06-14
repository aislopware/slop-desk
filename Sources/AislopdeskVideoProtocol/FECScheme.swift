import Foundation

/// Forward-error-correction over a frame's data fragments.
///
/// doc 17 §3.6 calls for ~20% parity per frame (Sunshine default). A full
/// Reed-Solomon codec is large; this protocol lets production swap one in later
/// (e.g. a GF(2^8) RS over the same fragment groups) while v1 ships a **correct,
/// fully-tested** XOR/parity scheme that recovers exactly one lost fragment per
/// group. The tests exercise REAL recovery — this is not a stub.
///
/// Contract: ``parity(forDataFragments:)`` produces parity fragments from the
/// frame's data fragments; ``recover(dataFragments:parityFragments:)`` fills any
/// `nil` (lost) data fragment it can, returning the repaired array (still possibly
/// holding `nil` for unrecoverable losses, which the caller escalates to
/// request-recovery).
public protocol FECScheme: Sendable {
    /// The DEFAULT group size: how many data fragments share one parity fragment when no explicit
    /// per-frame group size is supplied. With `groupSize = 5` the overhead is 1/5 = 20% parity,
    /// matching the doc-17 target. WF-4 adaptive FEC drives a per-frame group size through the
    /// `groupSize:`-parameterized methods; this value is the tier-0 / convenience default.
    var groupSize: Int { get }

    /// Computes parity fragments for `dataFragments`, in group order, grouping by `groupSize`.
    func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data]

    /// Attempts to recover lost (`nil`) data fragments using the parity fragments, grouping by
    /// `groupSize`. Entries that cannot be recovered remain `nil`.
    func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?]
}

public extension FECScheme {
    /// Convenience: parity using the scheme's configured default ``groupSize``. Keeps pre-WF-4
    /// callers (no explicit group size) compiling and behaving identically.
    func parity(forDataFragments dataFragments: [Data]) -> [Data] {
        parity(forDataFragments: dataFragments, groupSize: groupSize)
    }

    /// Convenience: recover using the scheme's configured default ``groupSize``.
    func recover(dataFragments: [Data?], parityFragments: [Data?]) -> [Data?] {
        recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: groupSize)
    }
}

/// XOR parity FEC: each group of ``groupSize`` data fragments produces one parity
/// fragment = the byte-wise XOR of the group. A single missing fragment **in a
/// group** is recovered as `parity XOR (all surviving members)`. Two or more
/// losses in one group are unrecoverable (the scheme reports them by leaving the
/// slots `nil`).
///
/// Fragments within a group may differ in length (the last fragment of a frame is
/// usually shorter); XOR is defined over the max length with shorter fragments
/// treated as zero-padded, and the recovered fragment is trimmed back to its
/// declared length carried out-of-band by the packet header (`payloadLength`).
/// To keep this scheme self-contained and exactly invertible, the parity fragment
/// stores a 2-byte big-endian length header per contributing member is NOT used;
/// instead each data fragment is length-prefixed before XOR so recovery yields the
/// exact original bytes. See ``parity(forDataFragments:)`` for the framing.
public struct XORParityFEC: FECScheme {
    public let groupSize: Int

    /// - Parameter groupSize: data fragments per parity fragment. Default 5 ⇒ 20%.
    public init(groupSize: Int = 5) {
        precondition(groupSize >= 1, "groupSize must be >= 1")
        self.groupSize = groupSize
    }

    /// Each data fragment is encoded as `[UInt32 BE length][bytes]` BEFORE the XOR
    /// so that XOR-recovery reproduces the *exact* original length even when group
    /// members differ in size. The parity fragment is the byte-wise XOR of these
    /// length-prefixed encodings, zero-padded to the longest member.
    public func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data] {
        let groupSize = max(1, groupSize) // defensive floor: a non-positive size must never trap/loop.
        var parities: [Data] = []
        var index = 0
        while index < dataFragments.count {
            let group = Array(dataFragments[index..<min(index + groupSize, dataFragments.count)])
            parities.append(Self.xorEncoded(group))
            index += groupSize
        }
        return parities
    }

    public func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?] {
        let groupSize = max(1, groupSize) // defensive floor (matches `parity`): host/client apply it identically.
        var result = dataFragments
        var groupIndex = 0
        var index = 0
        while index < dataFragments.count {
            let upper = min(index + groupSize, dataFragments.count)
            let range = index..<upper
            let missing = range.filter { result[$0] == nil }
            if missing.count == 1, groupIndex < parityFragments.count, let parity = parityFragments[groupIndex] {
                // Recover the single hole: XOR the parity with the encoded survivors,
                // then strip the length prefix to get the original fragment bytes.
                let survivors = range.compactMap { result[$0] }
                let recoveredEncoded = Self.xorRecover(parity: parity, survivors: survivors)
                if let bytes = Self.stripLengthPrefix(recoveredEncoded) {
                    result[missing[0]] = bytes
                }
            }
            index += groupSize
            groupIndex += 1
        }
        return result
    }

    // MARK: XOR primitives (length-prefixed for exact invertibility)

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        out.appendBE(UInt32(data.count))
        out.append(data)
        return out
    }

    private static func stripLengthPrefix(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let base = data.startIndex
        let length =
            (Int(data[base]) << 24) |
            (Int(data[base + 1]) << 16) |
            (Int(data[base + 2]) << 8) |
            Int(data[base + 3])
        guard length >= 0, 4 + length <= data.count else { return nil }
        let start = base + 4
        return Data(data[start..<start + length])
    }

    /// XOR of the length-prefixed encodings of a group, zero-padded to the longest.
    private static func xorEncoded(_ group: [Data]) -> Data {
        let encoded = group.map { lengthPrefixed($0) }
        let width = encoded.map(\.count).max() ?? 0
        var acc = [UInt8](repeating: 0, count: width)
        for member in encoded {
            let base = member.startIndex
            for i in 0..<member.count { acc[i] ^= member[base + i] }
        }
        return Data(acc)
    }

    /// `parity XOR (encoded survivors)` = the encoded form of the missing member,
    /// zero-padded. Trailing zeros beyond the embedded length are harmless because
    /// ``stripLengthPrefix(_:)`` cuts to the declared length.
    private static func xorRecover(parity: Data, survivors: [Data]) -> Data {
        let encodedSurvivors = survivors.map { lengthPrefixed($0) }
        let width = max(parity.count, encodedSurvivors.map(\.count).max() ?? 0)
        var acc = [UInt8](repeating: 0, count: width)
        let pBase = parity.startIndex
        for i in 0..<parity.count { acc[i] ^= parity[pBase + i] }
        for member in encodedSurvivors {
            let base = member.startIndex
            for i in 0..<member.count { acc[i] ^= member[base + i] }
        }
        return Data(acc)
    }
}
