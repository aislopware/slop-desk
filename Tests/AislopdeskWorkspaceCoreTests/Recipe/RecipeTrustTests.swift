import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-6 of E16: the pure ``RecipeTrustStore`` trust model behind the command-replay safety prompt.
///
/// Coverage (plan §WI-6): identical bytes → identical checksum; one edited byte → a different checksum → a
/// fresh `.prompt`; an Always-Trust record persists by hash and decodes back to `.trusted(mode)`; a
/// `schemaVersion` mismatch in the persisted blob decode-fails to the empty default (no-backcompat); a
/// self-saved recipe bypasses the prompt. The ``RecipeTrustStore/sha256Hex(_:)`` checksum is additionally
/// pinned against the published NIST SHA-256 test vectors so the self-contained implementation is proven
/// correct (revert-to-confirm-fail: any drift in the round arithmetic breaks these fixed digests). Fully
/// headless — no FileManager, no real pasteboard, no window.
final class RecipeTrustTests: XCTestCase {
    // MARK: - SHA-256 checksum: pinned NIST vectors

    func testSha256MatchesPublishedVectors() {
        // The canonical FIPS-180-4 / `shasum -a 256` digests — a fixed, independently-known oracle (NOT the
        // implementation's own derivation), so a regression in the compression function is caught here.
        XCTAssertEqual(
            RecipeTrustStore.sha256Hex(bytes(of: "")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "SHA-256 of the empty input",
        )
        XCTAssertEqual(
            RecipeTrustStore.sha256Hex(bytes(of: "abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256 of \"abc\" (single block)",
        )
        XCTAssertEqual(
            RecipeTrustStore.sha256Hex(bytes(of: "The quick brown fox jumps over the lazy dog")),
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
            "SHA-256 of a 43-byte message",
        )
        // A 56-byte message: padding spills into a SECOND 64-byte block — exercises the multi-block path.
        XCTAssertEqual(
            RecipeTrustStore.sha256Hex(bytes(of: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            "SHA-256 of a 56-byte message (forces a second block during padding)",
        )
    }

    func testSha256OutputShape() {
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "deploy-prod-debug"))
        XCTAssertEqual(hash.count, 64, "a SHA-256 digest is 64 lowercase-hex chars")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "lowercase hex only")
    }

    // MARK: - identical bytes → same hash; an edited byte → a fresh hash

    func testIdenticalBytesProduceIdenticalHash() {
        let recipe = bytes(of: "[recipe]\nname = 'x'\nversion = 1\n")
        XCTAssertEqual(
            RecipeTrustStore.sha256Hex(recipe),
            RecipeTrustStore.sha256Hex(recipe),
            "the checksum is a pure function of the bytes",
        )
        // A fresh array with the same content hashes identically (content-addressed, not identity-addressed).
        XCTAssertEqual(RecipeTrustStore.sha256Hex(recipe), RecipeTrustStore.sha256Hex(Array(recipe)))
    }

    func testEditedByteProducesDifferentHashAndFreshPrompt() {
        let original = bytes(of: "commands = ['make deploy']")
        // Edit ONE byte (the trailing char) — the otty rule: "editing the file changes its hash".
        var edited = original
        edited[edited.count - 1] = edited[edited.count - 1] ^ 0x01
        let originalHash = RecipeTrustStore.sha256Hex(original)
        let editedHash = RecipeTrustStore.sha256Hex(edited)
        XCTAssertNotEqual(originalHash, editedHash, "one changed byte flips the checksum")

        // Trust the ORIGINAL; the EDITED file is now unfamiliar → a fresh prompt.
        var store = RecipeTrustStore.empty
        store.trust(hash: originalHash, name: "deploy", origin: .alwaysTrust)
        XCTAssertEqual(store.decision(forHash: originalHash, settingsMode: .auto), .trusted(.auto))
        XCTAssertEqual(
            store.decision(forHash: editedHash, settingsMode: .auto), .prompt,
            "the edited file's new hash is not trusted → re-prompt",
        )
    }

    // MARK: - decision follows the replay-mode setting (not a hardcode)

    func testTrustedDecisionFollowsSettingsMode() {
        var store = RecipeTrustStore.empty
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "trusted"))
        store.trust(hash: hash, name: "r", origin: .alwaysTrust)
        // A trusted file "follows replay settings" — the decision carries whatever mode the caller resolved.
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .auto), .trusted(.auto))
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .askOnce), .trusted(.askOnce))
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .manually), .trusted(.manually))
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .skip), .trusted(.skip))
    }

    func testUnknownHashAlwaysPrompts() {
        let store = RecipeTrustStore.empty
        XCTAssertEqual(
            store.decision(forHash: RecipeTrustStore.sha256Hex(bytes(of: "never seen")), settingsMode: .skip),
            .prompt,
            "an empty store prompts for everything",
        )
    }

    // MARK: - self-saved bypasses the prompt

    func testSelfSavedRecipeBypassesPrompt() {
        var store = RecipeTrustStore.empty
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "[recipe]\nname = 'mine'\n"))
        // Before recording, even a self-authored file would prompt …
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .auto), .prompt)
        // … saving records it trusted up front, so the open path never shows the safety prompt.
        store.trust(hash: hash, name: "mine", origin: .selfSaved)
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .auto), .trusted(.auto))
        XCTAssertEqual(store.trusted[hash]?.origin, .selfSaved)
    }

    // MARK: - Always-Trust persists + decodes (round-trip through Codable)

    func testAlwaysTrustPersistsAndDecodes() throws {
        var store = RecipeTrustStore.empty
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "foreign.ottyrecipe"))
        store.trust(hash: hash, name: "deploy-prod-debug", origin: .alwaysTrust)

        let data = try XCTUnwrap(store.encoded(), "the trust store encodes to JSON")
        let decoded = RecipeTrustStore.decode(from: data)

        XCTAssertEqual(decoded.trusted[hash]?.name, "deploy-prod-debug")
        XCTAssertEqual(decoded.trusted[hash]?.origin, .alwaysTrust)
        XCTAssertEqual(
            decoded.decision(forHash: hash, settingsMode: .askOnce), .trusted(.askOnce),
            "a persisted Always-Trust record decodes back to a trusted decision",
        )
    }

    // MARK: - schemaVersion mismatch → empty default (no-backcompat)

    func testSchemaVersionMismatchDecodesToEmpty() throws {
        // A blob from a future/foreign schema carrying a trusted entry must NOT be honoured — the no-backcompat
        // directive: an unreadable version decode-fails to empty (re-prompt everything, never mis-trust).
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "future"))
        let future = RecipeTrustStore(
            schemaVersion: RecipeTrustStore.currentSchemaVersion + 1,
            trusted: [hash: RecipeTrustRecord(name: "x", origin: .alwaysTrust)],
        )
        let data = try XCTUnwrap(future.encoded())

        let decoded = RecipeTrustStore.decode(from: data)
        XCTAssertEqual(decoded.trusted, [:], "the mismatched-version trust set is dropped")
        XCTAssertEqual(
            decoded.decision(forHash: hash, settingsMode: .auto), .prompt,
            "the dropped entry re-prompts",
        )
    }

    func testCorruptJSONDecodesToEmpty() {
        XCTAssertEqual(RecipeTrustStore.decode(from: Data("not json {".utf8)).trusted, [:])
        XCTAssertEqual(RecipeTrustStore.decode(from: Data()).trusted, [:], "empty data → empty store")
    }

    // MARK: - forget revokes

    func testForgetRevokesTrust() {
        var store = RecipeTrustStore.empty
        let hash = RecipeTrustStore.sha256Hex(bytes(of: "x"))
        store.trust(hash: hash, name: "x", origin: .alwaysTrust)
        XCTAssertTrue(store.isTrusted(hash))
        store.forget(hash: hash)
        XCTAssertFalse(store.isTrusted(hash))
        XCTAssertEqual(store.decision(forHash: hash, settingsMode: .auto), .prompt)
        store.forget(hash: hash) // idempotent
        XCTAssertFalse(store.isTrusted(hash))
    }

    // MARK: - helpers

    private func bytes(of string: String) -> [UInt8] { Array(string.utf8) }
}
