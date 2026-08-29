import CSlopDeskFFI

/// A pointer into `rust/slopdesk-clientnet`, and the ONE place the claim that it may cross an
/// isolation boundary is written down.
///
/// `OpaquePointer` is not `Sendable` and should not be — the compiler cannot know what is behind
/// one, so every handle would otherwise need its own escape hatch at every site that moves it
/// between a task, a `DispatchQueue` and an actor. Behind every pointer this type wraps is a Rust
/// object whose every door takes `&self` through its own `Mutex`, which makes both of the things
/// Swift wants to hear true at once: transferring one across threads is a move Rust does not care
/// about, and calling two doors from two threads is the case it is built for rather than a race.
///
/// One type, one `@unchecked`, one reason attached to it — rather than the same sentence repeated
/// at each use site, where the next reader has to re-derive whether it still holds.
struct RustHandle: @unchecked Sendable {
    let raw: OpaquePointer?

    init(_ raw: OpaquePointer?) {
        self.raw = raw
    }
}
