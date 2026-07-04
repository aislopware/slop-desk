// HostDisplayName — resolves the human identity of the connected host for the chrome (the titlebar
// monogram + hostname label). The user often connects by IP; the chrome should still speak the host's
// NAME ("mac-studio"), so: a typed hostname is shortened to its first DNS label, and a typed IP literal
// is reverse-resolved once per connect (getnameinfo — on a LAN the peer's mDNS responder answers for
// `.local` names, no wire change and no host daemon involvement). Unresolvable stays `nil` and the
// chrome falls back to the raw target host.

import Foundation

public enum HostDisplayName {
    /// Whether `s` parses as a bare IPv4/IPv6 literal (no DNS labels — octets, not names).
    public static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return s.withCString { c in
            inet_pton(AF_INET, c, &v4) == 1 || inet_pton(AF_INET6, c, &v6) == 1
        }
    }

    /// The short display label for a HOSTNAME: the first DNS label ("mac-studio.local" → "mac-studio").
    /// An IP literal passes through unchanged (its dots separate octets, not labels), as does a
    /// label-less string.
    public static func shortLabel(_ name: String) -> String {
        guard !isIPLiteral(name) else { return name }
        return name.split(separator: ".").first.map(String.init) ?? name
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
        return String(cString: buffer)
    }
}
