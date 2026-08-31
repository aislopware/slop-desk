# Product

## Platform

ios

Apple-native only, and macOS-first in practice: a macOS host daemon plus native Swift/SwiftUI clients for macOS, iOS, and iPadOS. There is no web surface. Build floor is macOS 26 / iOS 26 on Apple Silicon.

## Users

Today: a single developer (the author) doing daily coding by running shells and AI coding agents (Claude Code) on a remote Mac and driving them from another Mac, iPad, or iPhone over a private mesh. Typical scene: several projects with several agents in flight at once; the user supervises, answers agent permission prompts, and drops into any pane to type.

Confirmed direction (user-directed 2026-08-07): personal-first, OSS-later — optimize for the author's own setup, but avoid decisions that would block publishing for other developers running agent fleets.

The iOS/iPadOS client is first-class, equal in ambition to macOS — not a companion/glance app (user-directed 2026-08-07).

## Product Purpose

SlopDesk is a low-latency remote-coding workspace: the client is a Session → Tab → n-ary-split canvas where each pane is either a full-fidelity terminal (host PTY → TCP → libghostty-vt → this repo's own block renderer) or a streamed GUI window (ScreenCaptureKit → HEVC → UDP), with a read-only agent inspector alongside. Right-sidebar panels embed VS Code (code-server), iOS simulators, and Android emulators; a Desktop window-OS surface is in progress.

Success means feels-local: terminal latency ≈ network RTT, GUI path measured at p50 ~27 ms compositor-to-compositor, and never losing agent or workspace state across reconnects and relaunches. It is explicitly a coding tool, not game streaming — smoothness targets are set for text and scrolling, not fps maximalism.

## Positioning

- Against remote-desktop/game-streaming (Parsec-class): purpose-built for coding — pixel-perfect terminal text via a real terminal renderer, per-pane transport choice, agent-aware chrome.
- Against phone-clients-for-Claude-Code (Happy-class): full terminal fidelity plus GUI-window streaming plus a read-only inspector, in one workspace.
- Deliberate non-goal: SlopDesk is a client to agents, not an orchestration product (settled decision; see docs/DECISIONS.md).
- Security posture nothing similar copies: the trusted WireGuard mesh IS the security boundary; the app ships zero app-layer crypto/auth/pairing by design.

## Operating Context

- Two-machine reality: mac-studio (host) and macbook-pro (client) on a WireGuard/NetBird mesh; different subnets; reverse-DNS dead on this network.
- Host is non-sandboxed (spawns shells, injects input), distributed Developer-ID/notarized outside MAS; client can be MAS.
- Multi-client is unconditional: workspace document and PTY fan-out sync across all attached clients with no toggle.
- Panel runtimes (code-server, baguette, adb/scrcpy) are pinned and vendored via ThirdParty/tools; hostd never downloads.
- The agent workflow leans on Claude Code specifics: JSONL transcript tailing + hooks feed the inspector; agent status (working/awaiting/done) drives chrome, sounds, and notifications.

## Capabilities and Constraints

- Three transports that never merge: terminal TCP, video UDP, inspector TCP — separate sockets, message sets, versions, no negotiation.
- Wire format is golden-pinned (manual big-endian binary, golden_vectors.json); untrusted UDP is validate-then-drop.
- Bit-exact float discipline and FEC invariants (m == 1 ≡ old XOR) constrain any code touching the media path.
- No backward compatibility or migration support: host and client ship together (standing directive).
- Important features ship ON, without flags — a flag is only for genuinely optional modes (standing directive; nine flags were deleted under this rule).
- Headless `swift build`/`swift test` must never touch Metal/VideoToolbox/ScreenCaptureKit; unit tests must never create capture/codec/Metal sessions.
- Client-UI dimensions go through Slate design tokens; raw font-size/cornerRadius/frame-height literals fail lint.

## Brand Commitments

None are immutable (user-directed 2026-08-07). The name "SlopDesk", the slopcat logo (screen-faced cat, `❯ ▁` eyes), and the Monokai Pro theme family all exist today, but the user explicitly declared that any of them may be replaced by a future design round with good reason. Treat them as incumbent evidence, not binding constraints.

## Evidence on Hand

- Measured performance: G2G p50 27 ms (4 runs, 320 flash pairs, scripts/measure-g2g.sh); decode 1.1 ms; risk-resolution measurements in docs/18.
- ~5,200 passing tests, golden wire vectors, differential NEON≡scalar pins.
- Full architecture/decision record in docs/ (00-overview, DECISIONS.md, numbered design docs).
- No external users, testimonials, benchmarks against competitors, or adoption numbers exist — future marketing/OSS surfaces must not fabricate any.

## Product Principles

1. Latency is the product: feels-local beats feature count; every media-path change is measured before it ships.
2. Commit to one good choice per problem — one renderer, one inspector, no fallback matrices.
3. Security lives in the mesh; the app stays trustful and simple inside it.
4. Be a client to agents, not an orchestrator of them.
5. Personal-first, OSS-ready: build for the author's daily use, avoid one-user dead ends.
