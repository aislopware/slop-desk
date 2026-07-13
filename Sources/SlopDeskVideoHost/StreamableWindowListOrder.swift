/// Arrangement for a `windowList` reply built from the FULL window enumeration (not on-screen-only).
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
    public static func arrange<Window>(
        _ windows: [Window],
        isOnScreen: (Window) -> Bool,
        title: (Window) -> String,
    ) -> [Window] {
        windows.filter(isOnScreen) + windows.filter { !isOnScreen($0) && !title($0).isEmpty }
    }
}
