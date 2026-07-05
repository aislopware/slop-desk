# 13 — Network model & transport assumptions

> Apps use **plain TCP** (terminal) + **plain UDP** (video), **no app-layer encryption or auth**. Deployment assumes a **trusted private network** — typically a userspace-WireGuard mesh (NetBird, Tailscale) supplying E2E encryption, node auth, and per-port ACLs. The security boundary is the network, not the app. The mesh is an example, never a dependency.

## Decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | No app crypto (no TLS/QUIC-crypto) | The WireGuard mesh already E2E-encrypts + authenticates nodes by key; a second layer is redundant. |
| 2 | Do **not** pin `requiredInterfaceType` | A userspace-WG interface (`utun100`, wireguard-go) shows up as `.other`; pinning `.wifi/.wiredEthernet` excludes it. Leave unpinned (routing table steers mesh CIDRs) or pin a named `NWInterface`. |
| 3 | App-layer adaptive rate, not DSCP | WireGuard zeroes the outer DSCP (only ECN propagates), so `serviceClass` QoS does nothing through the tunnel. Video carries its own congestion control + ABR. |
| 4 | mDNS/Bonjour is same-LAN only | The mesh is L3 point-to-point with no multicast. Across the mesh, connect by IP/hostname (mesh DNS or assigned CIDR). Bonjour still works on the same physical LAN. |
| 5 | Access control = mesh ACL | Per-port/protocol, deny-by-default, client group → host group. Replaces app-level authz. ACLs are node-level, not user-level. |
| 6 | Clamp UDP payload to runtime MTU | A WG tunnel lowers effective MTU (commonly ~1280). Read interface MTU at runtime, clamp payload ≈ `mtu − 80` (WG/IPv6 outer overhead). |

## Transport summary

- **Terminal:** plain TCP via `NWConnection`, `TCP_NODELAY` mandatory (framing = 1-byte type + 4-byte len). No TLS.
- **Video:** plain UDP with FEC (`FECScheme` / `AdaptiveFECPolicy`), adaptive bitrate, and congestion control (`LiveCongestionController` / `LiveBitratePolicy`) — always on, since even a direct mesh hop can drop/reorder packets.
- **Discovery:** try Bonjour for same LAN; otherwise enter/select a mesh hostname or IP.

## Control plane (a mesh handles the byte path, not everything)

The mesh moves bytes; a lightweight control plane still covers ([15](15-prior-art-happy-happier.md)):

- **Push notifications** ("Claude needs input" while the iOS app is backgrounded) — host triggers APNs/FCM directly (not Expo Push, for privacy); device tokens register somewhere.
- **Host-offline prompt queueing, device discovery, session metadata.**

> Mesh comparison (reference only): over a direct WireGuard hop, NetBird, Tailscale/Headscale, and bare WireGuard are equivalent on the wire (same cipher/MTU). They differ in NAT traversal and direct-path stability; self-hosted variants change the DNS domain + relay placement — none of which the app depends on.

## Corrections to older docs (applied)

| Doc | Outdated | Fix |
|-----|----------|-----|
| [03](03-transport-protocol.md) | `requiredInterfaceType=.wiredEthernet` | Remove — a userspace-WG interface is `.other`; pinning breaks it. |
| [03](03-transport-protocol.md) | `serviceClass=.interactiveVideo` "most important lever" | No effect through the tunnel (DSCP zeroed) → app-layer adaptive rate. |
| [03](03-transport-protocol.md) | Bonjour for all discovery | Same-LAN only; across the mesh connect by IP/hostname. |
| [03](03-transport-protocol.md) | QUIC datagrams (TLS + CC) | Plain UDP; TLS redundant on the mesh, CC handled in-app. |
| [12](12-coding-profile.md) | App-layer auth+encryption mandatory | Drop app crypto; rely on the mesh + its ACL. |
| [11](11-absolute-latency.md) | `serviceClass` as a lever | Moot through a WG tunnel. |
| Scope | "LAN only" | Trusted private network: same-LAN or across the mesh. |
