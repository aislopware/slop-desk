# 13 — Transport over the NetBird mesh (WireGuard)

> Both host and client are nodes in a **NetBird** (WireGuard mesh VPN). This doc records the network model + the **corrections** to docs 03/11/12 (many "pure LAN" assumptions no longer hold). Sources: NetBird docs + source (`client/iface/*`).

## TL;DR — 6 decisions

1. **Drop app-layer encryption (TLS/QUIC-crypto).** WireGuard already E2E-encrypts (ChaCha20-Poly1305) + authenticates nodes by public key. Adding another layer is **redundant** — exactly as you said. WireGuard's crypto is sub-microsecond/packet (not a latency source); what's worth avoiding is **a second encryption layer**.
2. **Do NOT pin `requiredInterfaceType = .wiredEthernet/.wifi`.** NetBird creates the interface **`utun100`** (userspace wireguard-go) → in Network.framework it is **`.other`**. Pinning to wiredEthernet/wifi would **exclude NetBird traffic → break the connection**. Leave it unpinned by default (the routing table steers `100.64/10` into utun100 on its own), or pin to a specific `NWInterface` by name.
3. **Bonjour/mDNS does NOT traverse the mesh.** WireGuard is L3 point-to-point, no multicast. Discovery over the mesh uses **NetBird DNS (`peer.netbird.cloud`)** or `100.64.0.0/10` IPs or the NetBird API. **Bonjour is only for the same physical LAN.**
4. **`serviceClass`/DSCP has no effect through the tunnel.** WireGuard zeroes the outer packet's DSCP (only ECN is propagated). → `serviceClass = .interactiveVideo` **does nothing** over NetBird. Replace with **app-layer adaptive rate control**.
5. **Authorization = NetBird ACL** (deny-by-default, per-port/protocol). WireGuard authenticates the *node*; NetBird policy restricts *which peer* reaches *which port*. This is the access-control layer that replaces app crypto.
6. **Assumption: NetBird direct P2P** (~5–20ms, near-native on the same LAN). **Do NOT engineer for relay** — if P2P fails and it drops to relay (>80ms), just **surface + warn** the user (accept degraded), don't build workarounds (no mosh/SSP, no adaptive/FEC). → the whole design is optimized for P2P.

---

## 1. Security — rely on the VPN, drop app crypto

| Layer | NetBird/WireGuard handles | App does NOT need |
|-----|----------------------|-------------------|
| Confidentiality | ChaCha20-Poly1305 AEAD | ❌ TLS/QUIC encryption |
| Integrity | Poly1305 MAC (16B) | ❌ |
| Node authentication | WireGuard public key + NetBird management | ❌ cert/key exchange |
| **Authorization (peer→port)** | **NetBird ACL** (deny-by-default, group/port/protocol) | ✅ just configure the policy |

- **"The NetBird mesh IS the security boundary"** (unlike a bare LAN): only peers that have joined + are allowed by ACL can reach the port. PTY=RCE is now **confined to authorized peers** (you control membership) — no longer "anyone on the LAN gets RCE".
- **Recommended ACL:** a policy opening only the app ports (e.g. TCP terminal + UDP video) from the client group → the host group. Per-port ranges supported since v0.48.
- **Limitation:** the ACL is *node*-level, not *user*-level. Multiple users on one machine → same rights. If per-user is needed → NetBird's OIDC/SSO, or a lightweight app-level device allowlist (not crypto).
- App-layer transport = **plain** (TCP for terminal, UDP for video) — no TLS, no QUIC-crypto.

> ⚠️ Self-hosted NetBird: the DNS domain differs from `netbird.cloud`; relay/signal are self-hosted. Adjust discovery accordingly.

## 2. Transport / Network.framework

```swift
// Do NOT pin .wiredEthernet/.wifi — it would exclude utun100 (NetBird). Let the routing table steer 100.64/10.
let params = NWParameters.udp          // plain UDP for video — WireGuard already encrypts
params.allowFastOpen = true
// params.requiredInterfaceType = .wiredEthernet   // ❌ WRONG for NetBird — remove
params.includePeerToPeer = false       // disable Apple's AWDL (unrelated to NetBird, still worth disabling)
// Do NOT set serviceClass expecting QoS — DSCP is zeroed by WireGuard through the tunnel. Use app-layer adaptive rate.
```

- **Terminal path:** plain TCP via `NWConnection` (framing: 1-byte type + 4-byte len). No TLS.
- **Video path:** plain UDP. **Drop QUIC** (the earlier reasons for QUIC were mainly TLS + congestion — TLS is redundant, congestion we handle ourselves adaptively).
- **MTU:** NetBird default is **1280** (`DefaultMTU` in `client/iface/iface.go`; NOT 1420). An app payload of ~1200 is **safe** (~52B headroom). Best: read the interface MTU at runtime, clamp payload = `mtu − 80` (WireGuard IPv6 outer overhead).

## 3. Discovery

| Case | How |
|-----------|------|
| **Same physical LAN** | Bonjour/mDNS still works (bypasses NetBird, uses local Ethernet/Wi-Fi) |
| **Over the mesh (remote)** | NetBird DNS `host-name.netbird.cloud` (resolver at the highest IP in the /16), or `100.64/10` IPs, or NetBird API `/api/peers` |

→ The app should: try Bonjour (same-LAN) **and** allow entering/selecting a NetBird hostname/IP. Don't rely on Bonjour for peers across the mesh.

## 4. Latency — design for direct P2P (relay = degraded fallback)

| Tier | Latency | Handling |
|------|---------|-------|
| **Direct P2P** (assumed) | ~5–20ms (near-native on the same LAN, dominated by the NIC) | Optimize for this tier |
| **Relayed** (fallback) | >80ms | **Only surface + warn**, do NOT engineer workarounds |

- Checking: `netbird status --detail` → `Connection type: P2P/Relayed`, `Direct: true/false`, `Latency`. The app shows a P2P/Relayed badge.
- ⚠️ **Same-LAN does NOT guarantee P2P 100%** — NAT hairpinning / different VLANs can force relay. **Ensure NetBird ≥ v0.69.0** (2026-04): it adds UPnP/NAT-PMP/PCP (PR #5219) + mitigates older same-LAN ([#1753](https://github.com/netbirdio/netbird/issues/1753)) / post-sleep ([#2507](https://github.com/netbirdio/netbird/issues/2507)) bugs. This is the reason to **keep the connection-type indicator**, not a reason to build mosh/SSP.

### Consequence: keep the design SIMPLE (no relay workarounds)
Since we assume P2P (loss~0, ~LAN), the WAN/relay techniques are **NOT needed**:
- **Terminal = TCP byte-stream + libghostty** (client renders; **not SwiftTerm** — best-only). **No mosh/SSP**, no predictive local-echo. (SSP's benefits only kick in when relayed — and we don't engineer for relay.)
- **Video = plain UDP, no adaptive bitrate, no FEC.** Direct P2P loss~0, like a LAN.
- If relay turns out to be frequent in practice → only then consider upgrading (a deferred decision, not v1).

### NetBird vs Tailscale/Headscale (verified — VPN choice)
- **Direct P2P: all three are equal** (Apple = userspace wireguard-go, same cipher/MTU). **None is faster on the wire.** → keep NetBird if you're getting direct (`netbird status` = P2P).
- The difference = the **probability of staying direct**. Tailscale still has 2 things NetBird lacks: **birthday-paradox** (avoiding relay behind symmetric NAT) + **more stable direct re-upgrade after sleep**. NetBird has had UPnP/NAT-PMP/PCP since **v0.69.0**.
- If *already* relayed: NetBird's relay = **QUIC/UDP** (potentially lower latency than Tailscale's DERP = **TCP/443**).
- ⚠️ **The strongest reason to consider Tailscale/Headscale: NetBird iOS bug [#5789](https://github.com/netbirdio/netbird/issues/5789)** (2026-04) — handshake OK but **0 data packets through utun** (`mkdir /var/run/wireguard: operation not permitted`), on both WiFi and cellular. **Verify the status of #5789 before deciding** — if the iOS client is a critical path, this matters more than any NAT theory.
- **Headscale** = Tailscale's data plane (full traversal: birthday-paradox + port-mapping) + self-hosted control. Caveats: control = SPOF, self-hosted DERP needs geographic placement, slow offline-node detection (~16 minutes).
- **Conclusion:** mostly same-LAN + expect-P2P → **switching VPNs isn't worth it for speed**. Only switch if (a) iOS bug #5789 blocks you, or (b) you're frequently remote behind difficult NAT.

## 5. Corrections to older docs (applied)

| Doc | Wrong/outdated | Fix |
|-----|--------|-----|
| [03](03-transport-protocol.md) | `requiredInterfaceType=.wiredEthernet` | Remove — utun is `.other`, pinning breaks NetBird |
| [03](03-transport-protocol.md) | `serviceClass=.interactiveVideo` "the most important lever" | No effect through the tunnel (DSCP zeroed) → app-layer adaptive rate |
| [03](03-transport-protocol.md) | Bonjour for all discovery | Bonjour same-LAN only; over the mesh use NetBird DNS/IP/API |
| [03](03-transport-protocol.md) | QUIC datagrams for Wi-Fi (TLS + CC) | Drop QUIC — TLS redundant; plain UDP |
| [12](12-coding-profile.md) §7 / Phase 5 | (old) "auth+encryption mandatory at the app layer" | Drop app crypto; rely on WireGuard + NetBird ACL *(already applied to doc 12)* |
| [12](12-coding-profile.md) | "LAN doesn't need local-echo" | Correct — assume P2P → **no local-echo, no SSP** (terminal = TCP byte-stream) |
| [11](11-absolute-latency.md) | serviceClass as a lever | Moot over NetBird |
| Scope | "LAN only" | NetBird mesh: direct (near-LAN) or relayed (WAN-like) |

## 5b. P2P doesn't eliminate all servers — a lightweight control plane is still needed (Happy/Happier lesson)

NetBird P2P handles the **byte path**, but it does **not** replace the entire control plane ([15](15-prior-art-happy-happier.md)):
- **Push notifications** ("Claude needs input" while the iOS app is backgrounded) — the host triggers **APNs/FCM directly** (not Expo Push — privacy). Device tokens have to be registered somewhere.
- **"Host offline → queue the prompt"** + device discovery + session metadata persistence — these need a lightweight control plane.
- The NetBird management server (already there) + APNs/FCM straight from the host may be enough; don't fantasize about "pure P2P, zero server". Only the relay is removed from the **byte path**.

## 6. Roadmap tasks
- [ ] Phase 0: log `NWPathMonitor.availableInterfaces` → confirm utun100 = `.other` on the target macOS + iOS.
- [ ] Phase 1: connect via NetBird IP/hostname (no Bonjour over the mesh); plain TCP.
- [ ] Show the connection type (P2P/relayed) in the UI + warn when relayed; clamp payload to the runtime MTU.
- [ ] Configure a NetBird ACL policy for the app ports (deny-by-default).
- [ ] Keep the design simple: terminal TCP byte-stream (no SSP), video plain UDP (no adaptive/FEC) — because we assume P2P.
