import CSlopDeskFFI
import Foundation

// MARK: - SecretRedactor

/// Scrubs likely SECRETS out of untrusted terminal-derived text (OSC 0/2 window titles and OSC 9/777
/// notification bodies) BEFORE it reaches a persistent UI surface — the sidebar title, the floating pill,
/// and especially the macOS Notification Center (which keeps a banner around long after the command ran).
///
/// A remote shell controls these strings; a prompt, a `set -x` trace, or a noisy program can splat an
/// access key / bearer token / `PASSWORD=…` into the title or a notification body, and the user would not
/// expect a remote-desktop window chrome to archive their credentials.
///
/// A face over `slopdesk-workspace`'s `secrets`, which states the ten shapes as a scanner rather than as
/// ten compiled `NSRegularExpression`s — the crate is linked into the iOS app, so it carries no regex
/// dependency, and every rule there is a prefix, a character class and a length floor.
public enum SecretRedactor {
    /// The fixed placeholder a masked secret collapses to. Contains no secret-shaped substring, so
    /// ``redact(_:)`` is idempotent (re-running never re-matches the mask).
    ///
    /// Asked for, not spelled: this is what the redaction tests assert against, and a transcribed
    /// copy would pass on a mask the crate stopped producing.
    public static let mask: String = {
        var out = [UInt8](repeating: 0, count: 64)
        let needed = out.withUnsafeMutableBufferPointer { room in
            slopdesk_ws_secret_mask(room.baseAddress, room.count)
        }
        guard needed > 0, needed <= out.count else { return "" }
        return String(bytes: out[0..<needed], encoding: .utf8) ?? ""
    }()

    /// Returns `text` with any recognized secret masked. The crate answers with a cheap pre-filter for the
    /// common case (a short title with no trigger character), so this is safe to call on every render.
    public static func redact(_ text: String) -> String {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { input -> String in
            var out = [UInt8](repeating: 0, count: max(256, input.count * 2 + 32))
            var needed = out.withUnsafeMutableBufferPointer { room in
                slopdesk_ws_redact_secrets(input.baseAddress, input.count, room.baseAddress, room.count)
            }
            if needed > out.count {
                out = [UInt8](repeating: 0, count: needed)
                needed = out.withUnsafeMutableBufferPointer { room in
                    slopdesk_ws_redact_secrets(input.baseAddress, input.count, room.baseAddress, room.count)
                }
            }
            guard needed > 0, needed <= out.count else { return text }
            return String(bytes: out[0..<needed], encoding: .utf8) ?? text
        }
    }
}
