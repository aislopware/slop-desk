//! What the embedded code-server workbench is DRESSED with, and nothing else.
//!
//! The code panel runs a workbench this app does not own, inside a `WKWebView` it does. Six jobs
//! cannot be done by the host-side settings seed — the fonts a `WebContent` process cannot see, the
//! corners the workbench never rounded, the watermark that is the wrong logo, the recommendation
//! catalogue its server never forwards, the clipboard write `WebKit` drops, and the subframe canvas
//! that resolves to white. Each is a string injected into the page, and each of those strings is
//! built here.
//!
//! ## The shape
//! Every entry point is a plain function over constants. Nothing allocates a handle, nothing reads
//! a preference, nothing knows what a pane is; the four scripts that take no argument are built
//! once per process and handed out as `&'static str`. That is the whole crate — the `WebKit` seam
//! (installing a `WKUserScript`, answering the `slopdesk-font:` scheme, writing `NSPasteboard`)
//! stays in Swift because it IS the framework, and it is the only part that was ever untestable.
//!
//! ## What deliberately does not cross a door
//! [`dressing::MONO_FONT_FAMILY`] and [`dressing::NERD_FONT_FAMILY`] must agree with
//! `slopdesk-codeseed`'s pair, and they are compared by an invariant rather than shared: codeseed
//! is a HOST crate carrying the whole seed history, and linking it into the FFI artifact would drag
//! those tables into the iOS binary to fetch two strings.

pub mod dressing;
pub mod surface;
pub mod tips;
