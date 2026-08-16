import CSlopDeskFFI

/// Arrangement for a `windowList` reply built from the FULL window enumeration (not on-screen-only)
/// — the Swift face of `rust/slopdesk-video`'s `arrange_streamable_windows`.
///
/// The reply is the client's authority for BOTH the in-pane picker and `WindowRebind`'s
/// open-time / reconnect revalidation. Minimized and other-Space windows are streamable (the mint
/// path rescues them via ``OffScreenWindowMintRescue``), so they must appear here — an on-screen-only
/// reply made the client's revalidation resolve a freshly picked minimized window to `.unresolved`
/// and close the pane while the host was mid-rescue on the very hello it was about to accept.
public enum StreamableWindowListOrder {
    /// On-screen windows first (original relative order preserved on both sides) so the reply's
    /// record cap can only ever crowd out the off-screen tail; UNTITLED off-screen entries are
    /// dropped — phantom enumeration junk carries no title, while a real minimized window keeps
    /// its. Untitled ON-screen windows stay (real apps do show untitled windows).
    ///
    /// The windows themselves never cross the door: the rule reads two facts about each, so those
    /// two flags go over and the answer comes back as indices into the caller's own array.
    public static func arrange<Window>(
        _ windows: [Window],
        isOnScreen: (Window) -> Bool,
        title: (Window) -> String,
    ) -> [Window] {
        let onScreen = windows.map(isOnScreen)
        let titled = windows.map { !title($0).isEmpty }
        let order: [UInt32] = onScreen.withUnsafeBufferPointer { seen in
            titled.withUnsafeBufferPointer { named in
                let needed = slopdesk_arrange_streamable_windows(
                    seen.baseAddress, named.baseAddress, windows.count, nil, 0,
                )
                guard needed > 0 else { return [] }
                var indices = [UInt32](repeating: 0, count: needed)
                let written = indices.withUnsafeMutableBufferPointer { out in
                    slopdesk_arrange_streamable_windows(
                        seen.baseAddress, named.baseAddress, windows.count, out.baseAddress, out.count,
                    )
                }
                return written == needed ? indices : []
            }
        }
        return order.compactMap { index in
            windows.indices.contains(Int(index)) ? windows[Int(index)] : nil
        }
    }
}
