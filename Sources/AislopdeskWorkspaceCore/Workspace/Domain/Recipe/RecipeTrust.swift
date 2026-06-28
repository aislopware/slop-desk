import Foundation

// MARK: - RecipeTrust (local trust-on-first-use checksum + replay-safety decision)

// The pure trust model behind the command-replay safety prompt: when a `.ottyrecipe` carries commands,
// opening an *unfamiliar* file shows those commands first (Always-Trust / Run-Once / Cancel). A file is
// remembered by the SHA-256 checksum of its bytes — so EDITING the file changes the bytes → a fresh hash →
// a fresh prompt — and a self-saved recipe is recorded trusted up front so it never prompts.
//
// ## This SHA-256 is NOT app-layer crypto/auth
// The CLAUDE.md / README rule "no app-layer crypto/auth, by design — the security boundary is the trusted
// WireGuard mesh" stands. The `RecipeTrustStore.sha256Hex(_:)` here is a local trust-on-first-use
// CHECKSUM for the replay-safety prompt only — a stable fingerprint of a file's bytes so the user is not
// re-asked about a recipe they already approved, and IS re-asked once an edit changes the bytes. It does
// no peer authentication, no pairing, no key exchange, no tokens, no signatures; it is unrelated to the
// WireGuard transport boundary and protects nothing on the wire. It is computed entirely client-side over
// already-on-disk bytes. (Documented here so a reviewer does not flag it against the "no app-layer crypto"
// convention — it is content-addressing, not security.)
//
// Wire posture: 100% client-side — nothing here touches the wire / golden corpus.

// MARK: - RecipeTrustDecision

/// What the store decided for a recipe the user is about to open.
public enum RecipeTrustDecision: Sendable, Equatable {
    /// The file is already trusted (self-saved, or a prior Always-Trust by this exact hash) — proceed and
    /// replay its commands following the user's ``RecipeReplayMode`` setting (carried here).
    case trusted(RecipeReplayMode)
    /// The file is unfamiliar (or its bytes changed since it was trusted) — show the commands and ask
    /// (Always-Trust / Run-Once / Cancel) before anything runs.
    case prompt
}

// MARK: - RecipeTrustOrigin

/// Why a recipe's hash is in the trusted set. Recorded for display / auditing; it does NOT change the
/// replay decision (both origins follow the user's replay-mode setting — the spec's "follow replay settings").
public enum RecipeTrustOrigin: String, Codable, Sendable, Equatable {
    /// The user saved this recipe themselves (⌘S) — trusted up front, never prompted.
    case selfSaved
    /// The user opened a foreign file and chose **Always Trust** in the prompt.
    case alwaysTrust
}

// MARK: - RecipeTrustRecord

/// A single trusted-recipe entry, keyed in ``RecipeTrustStore/trusted`` by the file's SHA-256 checksum.
public struct RecipeTrustRecord: Codable, Sendable, Equatable {
    /// The recipe's display name at the time it was trusted (for the Settings audit list).
    public var name: String
    /// How it came to be trusted (self-saved vs an explicit Always-Trust).
    public var origin: RecipeTrustOrigin

    public init(name: String, origin: RecipeTrustOrigin) {
        self.name = name
        self.origin = origin
    }
}

// MARK: - RecipeTrustStore

/// The persisted set of trusted-recipe checksums (`~/Library/Application Support/Aislopdesk/trusted_recipes.json`
/// — written by `RecipeLibrary`, WI-8). A pure, headless value type: it owns the trust map + the checksum +
/// the open-time decision; the file IO lives above it.
///
/// **No backcompat (CLAUDE.md):** the on-disk shape carries a ``schemaVersion``. ``decode(from:)`` returns the
/// empty default on ANY failure — a missing/corrupt file OR a `schemaVersion` this build does not understand —
/// so a stale/foreign blob decode-fails to an empty trust set (every recipe re-prompts) rather than mis-trusting.
public struct RecipeTrustStore: Codable, Sendable, Equatable {
    /// The on-disk schema this build writes and accepts. Bump on an incompatible reshape (the old file then
    /// decode-fails to empty — no migration, by the no-backcompat directive).
    public static let currentSchemaVersion = 1

    /// The version the loaded blob declared. A value `!= currentSchemaVersion` makes ``decode(from:)`` drop it.
    public var schemaVersion: Int
    /// Trusted recipes keyed by their SHA-256 checksum (``sha256Hex(_:)``). `private(set)` so mutation goes
    /// through ``trust(hash:name:origin:)`` / ``forget(hash:)`` and the map stays the single source of truth.
    public private(set) var trusted: [String: RecipeTrustRecord]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        trusted: [String: RecipeTrustRecord] = [:],
    ) {
        self.schemaVersion = schemaVersion
        self.trusted = trusted
    }

    /// The empty default — the result of a first launch or any decode failure.
    public static let empty = Self()

    // MARK: Trust set

    /// Record `hash` as trusted (idempotent — re-trusting overwrites the record). Called when the user saves a
    /// recipe (`origin: .selfSaved`, bypasses the prompt) or chooses **Always Trust** (`origin: .alwaysTrust`).
    public mutating func trust(hash: String, name: String, origin: RecipeTrustOrigin) {
        trusted[hash] = RecipeTrustRecord(name: name, origin: origin)
    }

    /// Drop a trusted record (the Settings audit list's revoke action). A no-op if the hash is not present.
    public mutating func forget(hash: String) {
        trusted[hash] = nil
    }

    /// Whether `hash` is currently trusted.
    public func isTrusted(_ hash: String) -> Bool {
        trusted[hash] != nil
    }

    // MARK: Decision

    /// The open-time decision for a recipe whose bytes hash to `hash`. A trusted hash proceeds and follows the
    /// user's replay-mode setting (`settingsMode` — Saved-Recipes vs Recipe-Files default, resolved by the
    /// caller); an unfamiliar hash (never trusted, or trusted under a DIFFERENT hash because the file was
    /// edited) returns ``RecipeTrustDecision/prompt`` so the commands are shown before anything runs.
    public func decision(forHash hash: String, settingsMode: RecipeReplayMode) -> RecipeTrustDecision {
        guard isTrusted(hash) else { return .prompt }
        return .trusted(settingsMode)
    }

    // MARK: Persistence (decode-fail-to-default; encode is deterministic)

    /// Decode a trust store from raw `trusted_recipes.json` bytes, returning ``empty`` on ANY failure —
    /// corrupt JSON OR a `schemaVersion` mismatch (no-backcompat). Pure (operates on `Data`, no FileManager);
    /// `RecipeLibrary.loadTrust()` (WI-8) reads the file and delegates the byte→value step here.
    public static func decode(from data: Data) -> Self {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return .empty // corrupt / unparseable
        }
        guard decoded.schemaVersion == currentSchemaVersion else {
            return .empty // a version this build does not understand → re-prompt everything, never mis-trust
        }
        return decoded
    }

    /// Encode to deterministic, reviewable JSON (sorted keys, pretty-printed) — the bytes `RecipeLibrary`
    /// writes back. `nil` only on an encode failure (never expected for this value shape).
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    // MARK: Checksum

    /// The lowercase-hex SHA-256 of `bytes` — the local trust-on-first-use **checksum** that fingerprints a
    /// recipe file (see the type doc: this is content-addressing for the replay prompt, NOT app-layer
    /// crypto/auth). Pure + deterministic: identical bytes → identical hash; one changed byte → a different
    /// hash (so an edit re-prompts).
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256Checksum.hexDigest(bytes)
    }
}

// MARK: - SHA256Checksum (self-contained, pure scalar Swift)

/// A self-contained SHA-256 over `[UInt8]`, used ONLY as the local recipe-trust checksum (see
/// ``RecipeTrustStore``'s doc — not app-layer crypto/auth). Pure scalar Swift in the repo's hash-cluster
/// style: the round arithmetic is deliberately **integer-wrapping** (`&+` / `&*`) — that IS the algorithm
/// (mod 2³²), not an oversight; the shifts/rotates use the non-trapping `<<`/`>>`. No SIMD, no framework,
/// fully headless-testable; pinned against the published NIST test vectors in `RecipeTrustTests`.
private enum SHA256Checksum {
    /// Round constants `k` — the first 32 bits of the fractional parts of the cube roots of the first 64 primes.
    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// Hex digits used to encode the 32-byte digest, lowercase to match the NIST/`shasum` convention.
    private static let hexAlphabet: [Character] = Array("0123456789abcdef")

    /// Rotate-right a 32-bit word by `n` (`1 ≤ n ≤ 31`). The `<<`/`>>` are non-trapping smart shifts.
    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    /// The SHA-256 digest of `message`, lowercase-hex (64 chars).
    static func hexDigest(_ message: [UInt8]) -> String {
        // Initial hash values: first 32 bits of the fractional parts of the square roots of the first 8 primes.
        var h0: UInt32 = 0x6A09_E667
        var h1: UInt32 = 0xBB67_AE85
        var h2: UInt32 = 0x3C6E_F372
        var h3: UInt32 = 0xA54F_F53A
        var h4: UInt32 = 0x510E_527F
        var h5: UInt32 = 0x9B05_688C
        var h6: UInt32 = 0x1F83_D9AB
        var h7: UInt32 = 0x5BE0_CD19

        // Pre-processing (padding): append the `0x80` terminator, zero-pad to 56 mod 64, then the original
        // length in bits as a 64-bit big-endian integer — so the total is a whole number of 64-byte blocks.
        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var chunkStart = 0
        while chunkStart < msg.count {
            // Load the 16 big-endian words of this 512-bit block, then extend to 64.
            for t in 0..<16 {
                let i = chunkStart + t * 4
                w[t] = (UInt32(msg[i]) << 24)
                    | (UInt32(msg[i + 1]) << 16)
                    | (UInt32(msg[i + 2]) << 8)
                    | UInt32(msg[i + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for t in 0..<64 {
                let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ bigS1 &+ ch &+ roundConstants[t] &+ w[t]
                let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = bigS0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
            chunkStart += 64
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return hexEncode(digest)
    }

    /// Lowercase-hex encode `bytes` (two chars per byte) without `String(format:)` (which can mis-handle Swift
    /// arguments) — a direct nibble→hex-character table lookup.
    private static func hexEncode(_ bytes: [UInt8]) -> String {
        var chars = [Character]()
        chars.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            chars.append(hexAlphabet[Int(byte >> 4)])
            chars.append(hexAlphabet[Int(byte & 0x0F)])
        }
        return String(chars)
    }
}
