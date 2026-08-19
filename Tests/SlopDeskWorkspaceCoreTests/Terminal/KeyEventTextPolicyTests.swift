import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind the encoder-text filter. The door answers only WHETHER the characters may be
/// forwarded, so what is pinned here is the near side of that: an absent `characters` never reaches the
/// door, a permitted one comes back VERBATIM rather than round-tripped through the boundary, and a refused
/// one comes back as `nil`. Which payloads are refused — the function-key PUA placeholders and the
/// control-led text, and the two Claude Code bugs behind each — is
/// `slopdesk_terminal::surface::forwards_encoder_text`'s, and is tested there.
final class KeyEventTextPolicyTests: XCTestCase {
    /// No characters at all is not a payload to ask about.
    func testAnAbsentPayloadIsNil() {
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: nil))
    }

    /// Permitted text is returned as it came in, byte for byte — including multi-scalar IME output and
    /// grapheme clusters, which a lossy trip through UTF-8 and back would be the place to damage.
    func testPermittedTextIsReturnedVerbatim() {
        for typed in ["a", "!", "đ", "việt", "🇻🇳", "\u{7F}", ""] {
            XCTAssertEqual(KeyEventTextPolicy.encoderText(for: typed), typed)
        }
    }

    /// The two refused classes come back as `nil`, not as the empty string — an empty `text` would still be
    /// text to the encoder.
    func testARefusedPayloadIsNilRatherThanEmpty() {
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\u{F700}"), "the up arrow placeholder")
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\t"))
    }
}
