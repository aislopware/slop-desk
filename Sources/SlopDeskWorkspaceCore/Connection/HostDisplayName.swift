// HostDisplayName — resolves the human identity of the connected host for the chrome (the titlebar
// monogram + hostname label), as a face over `slopdesk_workspace::host_name` plus the one lookup that
// cannot be a pure rule.
//
// The user often connects by IP; the chrome should still speak the host's NAME ("mac-studio"), so: a
// typed hostname is shortened to its first DNS label, and a typed IP literal is reverse-resolved once
// per connect (getnameinfo — on a LAN the peer's mDNS responder answers for `.local` names, no wire
// change and no host daemon involvement). Unresolvable stays `nil` and the chrome falls back to the
// raw target host.
//
// The two DECISIONS — is this an address, and where does its name end — crossed to Rust, where they
// are spelled out against the answers `inet_pton` was MEASURED giving rather than against
// `std::net`'s stricter grammar. The LOOKUP stayed here: `getaddrinfo`/`getnameinfo` is the socket
// owner's, and a resolver is not a rule.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

public enum HostDisplayName {
    /// Whether `s` parses as a bare IPv4/IPv6 literal (no DNS labels — octets, not names).
    public static func isIPLiteral(_ s: String) -> Bool {
        var bytes = Array(s.utf8)
        return bytes.withUnsafeMutableBufferPointer {
            slopdesk_ws_host_is_ip_literal($0.baseAddress, $0.count)
        }
    }

    /// The short display label for a HOSTNAME: the first DNS label ("mac-studio.local" → "mac-studio").
    /// An IP literal passes through unchanged (its dots separate octets, not labels), as does a
    /// label-less string.
    public static func shortLabel(_ name: String) -> String {
        var bytes = Array(name.utf8)
        let answer = bytes.withUnsafeMutableBufferPointer { lent in
            wsAnswer { out, cap in
                Int(slopdesk_ws_host_short_label(lent.baseAddress, lent.count, out, cap))
            }
        }
        // The door spells an empty label `0`, which is the same nothing an empty input asks for.
        return answer ?? ""
    }

    /// Reverse-resolves an IP literal to its hostname, already shortened via ``shortLabel(_:)``.
    /// `nil` when `ip` is not a literal (nothing to do — shorten it directly) or nothing answers the
    /// PTR/mDNS query. The blocking `getnameinfo` runs off-main on a detached utility task.
    public static func reverseResolve(_ ip: String) async -> String? {
        guard isIPLiteral(ip) else { return nil }
        let value = ip
        guard let name = await Task.detached(priority: .utility, operation: {
            blockingReverseResolve(value)
        }).value else { return nil }
        return shortLabel(name)
    }

    /// The synchronous lookup: numeric-host `getaddrinfo` builds the sockaddr (v4 or v6), then
    /// `getnameinfo(NI_NAMEREQD)` demands a real name (never echoes the IP back as a "name").
    private static func blockingReverseResolve(_ ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(
            first.pointee.ai_addr, first.pointee.ai_addrlen,
            &buffer, socklen_t(buffer.count),
            nil, 0, NI_NAMEREQD,
        )
        guard rc == 0 else { return nil }
        return String(bytes: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), encoding: .utf8)
    }
}
