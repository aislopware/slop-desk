//! The four posts — pointer, scroll, key, text — and the cursor warp two of them ride on.
//!
//! Each is a straight line: take the event source, build the `CGEvent`, set the fields the spec
//! names, post it. Where a comment explains WHY a field is set, the reason is hardware-measured
//! and moved here verbatim from the Swift this replaced; where a comment explains a `# Safety`, it
//! names the CoreGraphics contract, never a Rust one.

use std::cell::RefCell;

use objc2_core_foundation::{CFRetained, CGPoint};
use objc2_core_graphics::{
    CGAssociateMouseAndMouseCursorPosition, CGEvent, CGEventField, CGEventFlags, CGEventSource,
    CGEventSourceStateID, CGEventTapLocation, CGEventType, CGMouseButton, CGScrollEventUnit,
    CGWarpMouseCursorPosition,
};
use slopdesk_video::input_routing::{clamp_to_i32, scaled_scroll_delta};

/// Which pointer event a [`PointerPost`] is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerKind {
    /// A pure hover. Never carries a click state or modifier flags — the Swift it replaces set
    /// neither, and a move that carried a stale click state reads to a selection engine as a drag.
    Move,
    /// A button going down.
    Down,
    /// A button coming up.
    Up,
    /// A button-held move. A distinct event type, not an inferred one: macOS selection engines
    /// consume `*MouseDragged` between down and up and IGNORE a bare `MouseMoved` mid-gesture.
    Drag,
}

/// Which button a [`PointerPost`] names. `Other` is CoreGraphics' centre button.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    /// The primary button.
    Left,
    /// The secondary button.
    Right,
    /// Everything else, which CoreGraphics numbers as the centre button.
    Other,
}

/// One pointer event, fully specified. Every field is a value the caller already decided.
#[derive(Clone, Copy, Debug)]
pub struct PointerPost {
    /// Which of the four pointer events this is.
    pub kind: PointerKind,
    /// Which button `Down`, `Up` and `Drag` are about; ignored by `Move`.
    pub button: Button,
    /// The absolute CG point, top-left origin, already mapped out of the window's normalised space.
    pub x: f64,
    /// The absolute CG point's Y, same space as [`PointerPost::x`].
    pub y: f64,
    /// The originating click's count. Clamped to at least 1 on the way out: a fresh `CGEvent`
    /// carries 0, and a 0 click state makes some selection engines treat the event as "not a
    /// click" — which is the bug where a tap focused nothing and a drag selected nothing.
    pub click_count: u8,
    /// `slopdesk_video::input_event::InputModifiers` bits, translated by [`cg_flags`].
    pub modifiers: u8,
    /// The self-inject stamp written to `kCGEventSourceUserData`, which is how the cursor and
    /// geometry watchers recognise an event this process posted and refuse to feed it back.
    pub tag: u32,
    /// Warp the cursor to `(x, y)` before posting.
    pub warp: bool,
    /// Post a tablet-subtype absolute move instead of the warp-then-move pair. One `WindowServer`
    /// round trip rather than three, which is why a hover flood no longer stalls capture. Only
    /// meaningful for [`PointerKind::Move`].
    pub tablet: bool,
    /// Deliver straight to this pid instead of the HID tap. `None` is the production path; `Some`
    /// is the same-machine loopback seam, which must not hijack the real cursor.
    pub to_pid: Option<i32>,
}

/// One scroll event, fully specified.
#[derive(Clone, Copy, Debug)]
pub struct ScrollPost {
    /// Horizontal delta in points, pre-gain.
    pub dx: f64,
    /// Vertical delta in points, pre-gain.
    pub dy: f64,
    /// The gain to apply before narrowing. The caller passes 1.0 whenever it is replaying a real
    /// trackpad gesture — the OS derives the inertial coast velocity from the delta cadence, so
    /// rescaling a phased continuous stream desyncs the fling.
    pub gain: f64,
    /// The CoreGraphics scroll-phase code, forwarded verbatim. 0 means absent.
    pub scroll_phase: u8,
    /// The CoreGraphics momentum-phase code, forwarded verbatim. 0 means absent. Mutually
    /// exclusive with [`ScrollPost::scroll_phase`]; the client guarantees at most one is non-zero.
    pub momentum_phase: u8,
    /// Whether the source gesture was precise (a trackpad, including its momentum tail) rather
    /// than a wheel notch.
    pub continuous: bool,
    /// Whether to replay the two phase fields at all. False restores the phase-less behaviour that
    /// predates gesture forwarding, which exists only as an A/B.
    pub phased: bool,
    /// The self-inject stamp, as [`PointerPost::tag`].
    pub tag: u32,
    /// The loopback seam, as [`PointerPost::to_pid`].
    pub to_pid: Option<i32>,
}

thread_local! {
    /// The posting thread's handle onto `hidSystemState`.
    ///
    /// Thread-local rather than global because `CFRetained<CGEventSource>` is not `Sync` and
    /// should not be made so. Two handles are not two states — `hidSystemState` is the one the
    /// whole system shares — so the only cost is a CF allocation per posting thread, against a
    /// lock on the hottest path in the product.
    static SOURCE: RefCell<Option<CFRetained<CGEventSource>>> = const { RefCell::new(None) };
}

/// Runs `body` with this thread's event source, answering `false` if the source could not be made.
fn with_source<F: FnOnce(&CGEventSource) -> bool>(body: F) -> bool {
    SOURCE.with_borrow_mut(|slot| {
        if slot.is_none() {
            let made = CGEventSource::new(CGEventSourceStateID::HIDSystemState);
            if let Some(source) = made.as_deref() {
                // The default suppression interval is 0.25s, during which a synthetic event landing
                // after a post or a warp can simply be eaten — which is why a click immediately
                // after a warp-move sometimes did not take. Zero it so an injected event is never
                // suppressed. This is the modern spelling of the obsoleted
                // `CGEventSourceSetLocalEventsSuppressionInterval`.
                CGEventSource::set_local_events_suppression_interval(Some(source), 0.0);
            }
            *slot = made;
        }
        slot.as_deref().is_some_and(body)
    })
}

/// Translates the wire's modifier bits into CoreGraphics flags.
///
/// The bit values are `slopdesk_video::input_event::InputModifiers`', and the pairing is the
/// framework's own: this is the only place the two vocabularies meet, because `slopdesk-video` is
/// platform-free by construction and `CGEventFlags` is not a value it can name.
fn cg_flags(modifiers: u8) -> CGEventFlags {
    use slopdesk_video::input_event::InputModifiers;

    let bits = InputModifiers::from_bits(modifiers);
    let mut flags = CGEventFlags::empty();
    if bits.contains(InputModifiers::SHIFT) {
        flags |= CGEventFlags::MaskShift;
    }
    if bits.contains(InputModifiers::CONTROL) {
        flags |= CGEventFlags::MaskControl;
    }
    if bits.contains(InputModifiers::OPTION) {
        flags |= CGEventFlags::MaskAlternate;
    }
    if bits.contains(InputModifiers::COMMAND) {
        flags |= CGEventFlags::MaskCommand;
    }
    if bits.contains(InputModifiers::CAPS_LOCK) {
        flags |= CGEventFlags::MaskAlphaShift;
    }
    if bits.contains(InputModifiers::FUNCTION) {
        flags |= CGEventFlags::MaskSecondaryFn;
    }
    flags
}

/// Warps the cursor to an absolute point and immediately re-associates mouse and cursor.
///
/// The re-associate is not optional. A warp transiently DISASSOCIATES the two, and an event posted
/// inside that window can be swallowed; together with the zeroed suppression interval, this is what
/// makes warp-then-post safe.
fn warp(point: CGPoint) {
    let _ = CGWarpMouseCursorPosition(point);
    let _ = CGAssociateMouseAndMouseCursorPosition(true);
}

/// Stamps the self-inject tag and posts, at the HID tap or straight to a pid.
///
/// POINTER AND SCROLL ONLY. Keyboard events go through [`post_keyboard`], which deliberately does
/// not stamp — see its note.
fn stamp_and_post(event: &CGEvent, tag: u32, to_pid: Option<i32>) {
    CGEvent::set_integer_value_field(Some(event), CGEventField::EventSourceUserData, i64::from(tag));
    match to_pid {
        Some(pid) => CGEvent::post_to_pid(pid, Some(event)),
        None => CGEvent::post(CGEventTapLocation::HIDEventTap, Some(event)),
    }
}

/// Posts a KEYBOARD event, deliberately WITHOUT the self-inject stamp — the one place that
/// diverges from [`stamp_and_post`].
///
/// A host Vietnamese IME (xkey) installs two taps, a HID tap and a session tap, and dedupes across
/// them via `kCGEventSourceUserData`: the HID tap marks an event handled so the session tap skips
/// it. A keystroke posted with our non-zero tag defeats that dedup, the session tap re-processes
/// it, and Telex composes twice — "ddaa" arrives as "daa" instead of "đâ". Posting with the field
/// left at zero restores the dedup.
///
/// Leaving keys untagged is safe because the self-inject filter serves only the cursor and geometry
/// watchers, and a keystroke moves neither the cursor nor the window.
fn post_keyboard(event: &CGEvent) {
    CGEvent::post(CGEventTapLocation::HIDEventTap, Some(event));
}

/// Builds and posts one pointer event. Answers `false` if CoreGraphics refused to make it.
#[must_use]
pub fn post_pointer(spec: &PointerPost) -> bool {
    let point = CGPoint::new(spec.x, spec.y);

    if spec.kind == PointerKind::Move && spec.tablet {
        return post_tablet_move(spec, point);
    }
    if spec.warp {
        warp(point);
    }
    let (event_type, button) = match (spec.kind, spec.button) {
        (PointerKind::Move, _) => (CGEventType::MouseMoved, CGMouseButton::Left),
        (PointerKind::Down, Button::Left) => (CGEventType::LeftMouseDown, CGMouseButton::Left),
        (PointerKind::Down, Button::Right) => (CGEventType::RightMouseDown, CGMouseButton::Right),
        (PointerKind::Down, Button::Other) => (CGEventType::OtherMouseDown, CGMouseButton::Center),
        (PointerKind::Up, Button::Left) => (CGEventType::LeftMouseUp, CGMouseButton::Left),
        (PointerKind::Up, Button::Right) => (CGEventType::RightMouseUp, CGMouseButton::Right),
        (PointerKind::Up, Button::Other) => (CGEventType::OtherMouseUp, CGMouseButton::Center),
        (PointerKind::Drag, Button::Left) => (CGEventType::LeftMouseDragged, CGMouseButton::Left),
        (PointerKind::Drag, Button::Right) => (CGEventType::RightMouseDragged, CGMouseButton::Right),
        (PointerKind::Drag, Button::Other) => (CGEventType::OtherMouseDragged, CGMouseButton::Center),
    };
    with_source(|source| {
        let Some(event) = CGEvent::new_mouse_event(Some(source), event_type, point, button) else {
            return false;
        };
        if spec.kind != PointerKind::Move {
            // The SAME value on the down, every drag and the up. A drag inherits its originating
            // click's state (1 = drag-select, 2 = word-by-word), and a mismatch between the three
            // is what makes a selection collapse mid-gesture.
            CGEvent::set_integer_value_field(
                Some(&event),
                CGEventField::MouseEventClickState,
                i64::from(spec.click_count.max(1)),
            );
            CGEvent::set_flags(Some(&event), cg_flags(spec.modifiers));
        }
        stamp_and_post(&event, spec.tag, spec.to_pid);
        true
    })
}

/// The tablet-subtype absolute move: ONE event, no warp, no associate.
///
/// A remote pointer stream is roughly 99% hover moves, and the warp path spends three synchronous
/// `WindowServer` round trips on each of them, which under a flood saturates `WindowServer` and
/// stalls the capture stream — the desktop hitches exactly while the pointer moves. A tablet-point
/// `MouseMoved` carrying absolute coordinates positions the cursor on its own, verified end to end
/// on macOS 26. Hover only: a drag keeps the warp path so selection engines see byte-identical
/// input.
fn post_tablet_move(spec: &PointerPost, point: CGPoint) -> bool {
    with_source(|source| {
        let Some(event) =
            CGEvent::new_mouse_event(Some(source), CGEventType::MouseMoved, point, CGMouseButton::Left)
        else {
            return false;
        };
        // 1 == `kCGEventMouseSubtypeTabletPoint`, which the bindings do not name.
        CGEvent::set_integer_value_field(Some(&event), CGEventField::MouseEventSubtype, 1);
        // The clamp is the same never-traps backstop the scroll deltas take. A hostile datagram can
        // carry a finite but enormous coordinate — the decode rejects only NaN and infinity, and
        // the window mapping does not bound its output — so a bare narrowing would trap on a value
        // no display could ever hold. The event's own cursor position does the real positioning;
        // these two fields only give delta-reading apps an absolute point.
        CGEvent::set_integer_value_field(
            Some(&event),
            CGEventField::TabletEventPointX,
            i64::from(clamp_to_i32(spec.x)),
        );
        CGEvent::set_integer_value_field(
            Some(&event),
            CGEventField::TabletEventPointY,
            i64::from(clamp_to_i32(spec.y)),
        );
        stamp_and_post(&event, spec.tag, spec.to_pid);
        true
    })
}

/// Builds and posts one scroll event in pixel units. Answers `false` if CoreGraphics refused.
#[must_use]
pub fn post_scroll(spec: &ScrollPost) -> bool {
    with_source(|source| {
        let Some(event) = CGEvent::new_scroll_wheel_event2(
            Some(source),
            CGScrollEventUnit::Pixel,
            2,
            scaled_scroll_delta(spec.dy, spec.gain),
            scaled_scroll_delta(spec.dx, spec.gain),
            0,
        ) else {
            return false;
        };
        if spec.phased {
            // Replay the forwarded gesture verbatim so Chromium and AppKit run their native 1:1
            // continuous scrolling and rubber-band, rather than the per-notch easing a phase-less
            // event gets. `IsContinuous` follows the precise flag, not the phase.
            CGEvent::set_integer_value_field(
                Some(&event),
                CGEventField::ScrollWheelEventIsContinuous,
                i64::from(spec.continuous),
            );
            if spec.scroll_phase != 0 {
                CGEvent::set_integer_value_field(
                    Some(&event),
                    CGEventField::ScrollWheelEventScrollPhase,
                    i64::from(spec.scroll_phase),
                );
            }
            if spec.momentum_phase != 0 {
                CGEvent::set_integer_value_field(
                    Some(&event),
                    CGEventField::ScrollWheelEventMomentumPhase,
                    i64::from(spec.momentum_phase),
                );
            }
        } else {
            CGEvent::set_integer_value_field(Some(&event), CGEventField::ScrollWheelEventIsContinuous, 1);
        }
        stamp_and_post(&event, spec.tag, spec.to_pid);
        true
    })
}

/// Builds and posts one key edge. Answers `false` if CoreGraphics refused to make the event.
///
/// A posted `CGEvent` key reaches even a `SecurityAgent` secure field: Secure Event Input blocks
/// event-tap INTERCEPTION, not trusted HID-tap injection, which is why no virtual-HID driver is
/// needed to type a password into a host dialog.
#[must_use]
pub fn post_key(key_code: u16, down: bool, modifiers: u8) -> bool {
    with_source(|source| {
        let Some(event) = CGEvent::new_keyboard_event(Some(source), key_code, down) else {
            return false;
        };
        CGEvent::set_flags(Some(&event), cg_flags(modifiers));
        post_keyboard(&event);
        true
    })
}

/// Types `text` as a Unicode string — layout-independent, and the robust path for arbitrary text.
///
/// The string attaches to the key-DOWN edge only. Attaching it to both edges inserts the text
/// twice; the up is posted bare so the app still sees the balanced pair `CGEvent` requires.
///
/// Both edges are posted with EMPTY flags. A plain-text insertion must never inherit a latched
/// modifier from the shared `hidSystemState` source — a command key still held from an earlier
/// chord would otherwise turn the insertion into a command-modified keystroke.
#[must_use]
pub fn post_text(text: &str) -> bool {
    let units: Vec<u16> = text.encode_utf16().collect();
    // The binding's length is a `u64`; on every target this crate builds for, a `usize` is one.
    let Ok(length) = u64::try_from(units.len()) else {
        return false;
    };
    with_source(|source| {
        let Some(down) = CGEvent::new_keyboard_event(Some(source), 0, true) else {
            return false;
        };
        // SAFETY: `keyboard_set_unicode_string` copies `length` UTF-16 units out of the pointer
        // into the event and retains nothing, so the buffer need only be live for this call —
        // `units` is a local that outlives it. The length is `units.len()`, so the count and the
        // allocation cannot disagree.
        #[expect(
            unsafe_code,
            reason = "the one raw-pointer function on the injection path; objc2-core-graphics cannot \
                      generate it safe"
        )]
        unsafe {
            CGEvent::keyboard_set_unicode_string(Some(&down), length, units.as_ptr());
        }
        CGEvent::set_flags(Some(&down), CGEventFlags::empty());
        post_keyboard(&down);
        if let Some(up) = CGEvent::new_keyboard_event(Some(source), 0, false) {
            CGEvent::set_flags(Some(&up), CGEventFlags::empty());
            post_keyboard(&up);
        }
        true
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report"
)]
mod tests {
    use objc2_core_foundation::CGPoint;
    use objc2_core_graphics::{
        CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID, CGEventType, CGMouseButton,
    };

    use super::{cg_flags, with_source};

    /// The modifier translation, which is the only table in the crate.
    #[test]
    fn every_wire_modifier_bit_has_its_framework_flag() {
        assert_eq!(cg_flags(0), CGEventFlags::empty());
        assert_eq!(cg_flags(1 << 0), CGEventFlags::MaskShift);
        assert_eq!(cg_flags(1 << 1), CGEventFlags::MaskControl);
        assert_eq!(cg_flags(1 << 2), CGEventFlags::MaskAlternate);
        assert_eq!(cg_flags(1 << 3), CGEventFlags::MaskCommand);
        assert_eq!(cg_flags(1 << 4), CGEventFlags::MaskAlphaShift);
        assert_eq!(cg_flags(1 << 5), CGEventFlags::MaskSecondaryFn);
        assert_eq!(
            cg_flags(0b0000_1001),
            CGEventFlags::MaskShift | CGEventFlags::MaskCommand
        );
        // Bits 6 and 7 are not modifiers the wire defines, and must not become flags.
        assert_eq!(cg_flags(0b1100_0000), CGEventFlags::empty());
    }

    /// The thread-local source is made once and reused, which is the whole reason it is a
    /// thread-local rather than a per-call allocation.
    #[test]
    fn the_source_is_made_once_per_thread() {
        let mut seen = Vec::new();
        for _ in 0_u8..4 {
            assert!(with_source(|source| {
                seen.push(std::ptr::from_ref(source).cast::<()>());
                true
            }));
        }
        assert_eq!(seen.len(), 4);
        assert!(
            seen.windows(2).all(|pair| pair[0] == pair[1]),
            "four calls on one thread must see one source"
        );
    }

    /// The LEAK test `docs/57` §3 asks of every crate in this family, read off the objects' own
    /// retain counts rather than the process footprint — on macOS the resident size is the malloc
    /// zone's high-water mark and does not fall when a CF object is released, so a footprint
    /// assertion would pass whether or not anything leaked.
    ///
    /// What it actually proves: the constructors this crate calls follow the CREATE rule (one
    /// reference, owned by the caller) and `CFRetained`'s drop discharges it. Both halves matter —
    /// a get-rule function wrapped as a create-rule one over-releases, and the reverse leaks.
    #[test]
    fn every_event_this_crate_makes_is_owned_once_and_released_on_drop() {
        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .expect("the HID source is always available");
        assert_eq!(source.retain_count(), 1, "create rule: one reference");

        let event = CGEvent::new_mouse_event(
            Some(&source),
            CGEventType::MouseMoved,
            CGPoint::new(0.0, 0.0),
            CGMouseButton::Left,
        )
        .expect("a mouse event needs no permission to CREATE");
        assert_eq!(event.retain_count(), 1);
        {
            let second = event.clone();
            assert_eq!(event.retain_count(), 2, "a clone retains");
            drop(second);
        }
        assert_eq!(event.retain_count(), 1, "and its drop releases");

        // The bulk half: ten thousand events created and dropped must leave the SOURCE's count
        // where it started. A constructor that retained its source without balancing would show
        // up here as a count in the thousands, and nowhere else.
        let before = source.retain_count();
        for _ in 0_u16..10_000 {
            drop(CGEvent::new_mouse_event(
                Some(&source),
                CGEventType::MouseMoved,
                CGPoint::new(0.0, 0.0),
                CGMouseButton::Left,
            ));
            drop(CGEvent::new_keyboard_event(Some(&source), 0, true));
        }
        assert_eq!(source.retain_count(), before);
    }
}
