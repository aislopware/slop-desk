//! What the RIGHT panel's four surfaces SAY, and which of them a phase picks.
//!
//! The four surfaces had ONE renderer until the Mac drew them itself, so every word in them and
//! every phase→surface answer had a single speller BY ACCIDENT. There are two renderers now, so the
//! words and the folds live here and are single-spelled ON PURPOSE.
//!
//! ## What is NOT here
//!
//! **No ink, no metric, no font.** A surface names its own SILHOUETTE — an SF-Symbol name both
//! halves ask for — and each renderer spells the dim.
//!
//! **No poll, no task, no generation.** Those belong to whoever owns the clock, and how a renderer
//! keeps a loop alive across a mount is exactly the thing the two UI frameworks disagree about. The
//! DECISION — which key restarts which loop — IS here ([`phase_key`], [`ready_key`]), because
//! getting that wrong is a stalled panel on one platform only.

/// A centred empty state: a dim glyph, one line naming the situation, one line about it.
///
/// One record for all seven of them (three "not installed", three "host unreachable", one announced
/// Desktop) because the panel has ONE empty-state voice, and a renderer that took a title and a
/// detail as loose arguments is a renderer that can be given them in the other order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct EmptyState {
    /// The muted glyph, as an SF-Symbol name — each half maps the name onto its own image type.
    pub system_image: &'static str,
    /// One line: what the situation IS.
    pub title: &'static str,
    /// One line under it: what to do, or where the thing went.
    pub detail: &'static str,
    /// Set the detail in the instrument face — it is a shell command to copy, not a sentence.
    pub detail_is_command: bool,
}

impl EmptyState {
    /// The common case: a sentence, not a command.
    const fn sentence(system_image: &'static str, title: &'static str, detail: &'static str) -> Self {
        Self {
            system_image,
            title,
            detail,
            detail_is_command: false,
        }
    }
}

/// The provisioning line, spelled ONCE for the three surfaces that can be missing a tool.
///
/// The provision script, not a package manager: the panel is written against the `code-server`
/// version pinned in the tools lock, and the Homebrew formula froze below the Code floor this panel
/// needs before being deprecated outright. Sending someone to `brew` here hands them the broken
/// one.
pub const PROVISION_COMMAND: &str = "just provision";

/// The announced-but-empty fourth surface.
///
/// The TAB is real — selecting it parks the workbench and cancels the ensure poll — and only the
/// content is a placeholder.
pub const DESKTOP: EmptyState =
    EmptyState::sentence("display", "Desktop", "The host's window surface arrives here.");

/// The glyph the open gate stands under.
pub const GATE_SYSTEM_IMAGE: &str = "folder";

/// The open gate's button.
pub const GATE_OPEN_TITLE: &str = "Open Editor";

/// The Simulators surface's toast id.
///
/// Its own, not shared with Android: the two surfaces can both have something to say about
/// different devices, and one id would have one panel's report replace the other's.
pub const SIMULATOR_TOAST_ID: &str = "simulator";

/// The Android surface's toast id. See [`SIMULATOR_TOAST_ID`].
pub const ANDROID_TOAST_ID: &str = "android";

/// What a Simulators report is ABOUT when the selection has already been cleared.
///
/// A verdict of "no longer running" sets the text and clears the selection in one write, and the
/// card still has to say where it came from.
pub const SIMULATOR_FALLBACK_SUBJECT: &str = "Simulators";

/// What an Android report is about when the selection has been cleared. See
/// [`SIMULATOR_FALLBACK_SUBJECT`].
pub const ANDROID_FALLBACK_SUBJECT: &str = "Android";

/// The web workbench title bar's laid-out height at zoom 1 (30px on Code 1.131).
///
/// The workbench force-shows its title bar while the activity bar sits at "top" — the band must
/// host the relocated accounts and manage actions — and the grid positions every part with inline
/// absolute geometry, so a CSS `display: none` leaves a dead gap instead of reflowing. The clip is
/// the clean cut: the webview is laid out TALLER than its container by exactly this much and
/// shifted up, so the band renders above the clip line.
///
/// It is NOT a CSS constant to grep. The honest measurement is the laid-out box —
/// `document.querySelector('#workbench\\.parts\\.titlebar').getBoundingClientRect().height` against
/// a real workbench. It went 35 → 30 across Code 1.112 → 1.131; re-measure on every `code-server`
/// bump, because being wrong here clips the editor tab row instead. Here rather than at either
/// mount because both halves clip the same overhang, and a number measured once that two files
/// carry is a number that gets bumped in one of them.
pub const CLIPPED_TITLE_BAR_HEIGHT: f64 = 30.0;

/// How far a surface's host-side service has got.
///
/// The byte order is the two near-side enums' shared case order — offline, starting, unavailable,
/// ready — which `slopdesk-devicepanel`'s own `Phase` also carries. A byte no build wrote reads as
/// [`Offline`](Self::Offline), which keeps polling rather than reporting a tool as missing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    /// The ensure RPC got no answer — no connected pane channel, or a host too old to know the
    /// verb.
    Offline,
    /// The host is still bringing the service up.
    Starting,
    /// The tool the service needs is not installed on the host.
    Unavailable,
    /// The service is reachable.
    Ready,
}

impl Phase {
    /// The phase `byte` names.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Starting,
            2 => Self::Unavailable,
            3 => Self::Ready,
            _ => Self::Offline,
        }
    }
}

/// The workbench surface's four situations.
///
/// A renderer switches over this and nothing else — in particular it does NOT re-ask whether the
/// root is admitted, because the gate and the mount are the same decision seen twice, and answering
/// it in two places is how a project boots an editor it was gated out of.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Workbench {
    /// The project has never been opened — offer the gate, mount nothing.
    Gate,
    /// Mount the pooled workbench for the root the caller passed in.
    Mount,
    /// A spinner and this label. It resolves on its own.
    Waiting(&'static str),
    /// Nothing to show, and why.
    Empty(EmptyState),
}

/// What a DEVICE surface is showing.
///
/// `Devices` is the only state with no words: the list and the stage are the surface's own two
/// depths, and which of the two is on screen is the model's selection, not a phase.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DeviceSurface {
    /// The device list, or the stage over it.
    Devices,
    /// A spinner and this label.
    Waiting(&'static str),
    /// Nothing to show, and why.
    Empty(EmptyState),
}

/// What the workbench surface shows.
///
/// The ORDER of the questions is the whole rule and it is not interchangeable. The gate comes
/// first, because a project the user never opened must cost nothing at all — no ensure poll, no
/// proxy bind, no webview. Then the root, then the brief wait while the host's project-key push is
/// in flight, and only then the no-project placeholder: rendering that placeholder during the push
/// is a panel that says "no project" about a pane that has one.
///
/// - `has_root` — a project root resolved from the focused pane.
/// - `root_is_opened` — that root has been admitted through the gate before. Flattened by the
///   caller from its own set, because the set is the store's and only membership is a decision.
/// - `ready_is_this_root` — the phase is `Ready` AND the root it carries is the one in focus. ⚠️ A
///   ready phase carrying the PREVIOUS project is the render between a switch and its restarted
///   poll; mounting from it opened the old project's folder for the new root and stuck there. It
///   waits, exactly like a boot, because that is what it is.
/// - `awaiting_project_key` — the focused pane has a SECTION identity (the cwd fallback) but no
///   host-pushed key yet. Passed rather than derived, because the two identities are the store's
///   and only one of them may be ensured against.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four gates ARE the rule, and their ORDER is the rule too — see the doc above. Packing \
              them into one struct would move the ordering question somewhere the reader cannot see it \
              beside the answer"
)]
pub const fn workbench(
    phase: Phase,
    has_root: bool,
    root_is_opened: bool,
    ready_is_this_root: bool,
    awaiting_project_key: bool,
) -> Workbench {
    if !has_root {
        if awaiting_project_key {
            return Workbench::Waiting("Resolving project…");
        }
        return Workbench::Empty(EmptyState::sentence(
            "folder",
            "No project in focus",
            "Focus a terminal pane to open its project here.",
        ));
    }
    if !root_is_opened {
        return Workbench::Gate;
    }
    match phase {
        Phase::Ready if ready_is_this_root => Workbench::Mount,
        Phase::Ready | Phase::Starting => Workbench::Waiting("Starting code-server…"),
        Phase::Unavailable => {
            Workbench::Empty(EmptyState {
                system_image: "shippingbox",
                title: "code-server not found on host",
                detail: PROVISION_COMMAND,
                detail_is_command: true,
            })
        },
        Phase::Offline => {
            Workbench::Empty(EmptyState::sentence(
                "bolt.slash",
                "Host unreachable",
                "The editor opens once a pane is connected.",
            ))
        },
    }
}

/// What the Simulators surface shows.
///
/// Machine-scoped, so unlike the workbench it has no project to key on and no waiting-for-key
/// state: one ensure loop, one device list, one live stream.
#[must_use]
pub const fn simulators(phase: Phase) -> DeviceSurface {
    devices(
        phase,
        "Starting simulator server…",
        EmptyState {
            system_image: "iphone.slash",
            title: "baguette not found on host",
            detail: PROVISION_COMMAND,
            detail_is_command: true,
        },
        "Simulators appear once a pane is connected.",
    )
}

/// What the Android surface shows.
///
/// `adb` is the one piece without which there is nothing to list. A missing `scrcpy-server` still
/// lists and boots devices and reports itself when a mirror is asked for, which is where it can
/// name itself against the action that wanted it — and it is committed to the repo, so it is
/// present in any checkout. The emulator is deliberately not provisioned (system images are
/// gigabytes behind a licence accept), so a host that wants AVDs still needs its own SDK.
#[must_use]
pub const fn android(phase: Phase) -> DeviceSurface {
    devices(
        phase,
        "Opening the Android bridge…",
        EmptyState {
            system_image: "cable.connector.slash",
            title: "adb not found on host",
            detail: PROVISION_COMMAND,
            detail_is_command: true,
        },
        "Devices appear once a pane is connected.",
    )
}

/// The shape both device surfaces share. They differ in three strings and in nothing else, which is
/// why the fold is written once and the strings are the arguments.
const fn devices(
    phase: Phase,
    starting: &'static str,
    missing_tool: EmptyState,
    offline_detail: &'static str,
) -> DeviceSurface {
    match phase {
        Phase::Ready => DeviceSurface::Devices,
        Phase::Starting => DeviceSurface::Waiting(starting),
        Phase::Unavailable => DeviceSurface::Empty(missing_tool),
        Phase::Offline => {
            DeviceSurface::Empty(EmptyState::sentence(
                "bolt.slash",
                "Host unreachable",
                offline_detail,
            ))
        },
    }
}

/// WHICH of the four states is on screen, with the ready payload deliberately dropped.
///
/// A ready service that respawns on a new port is the same surface and must not blink; server boot
/// → devices is a real change of subject and cuts hard without an animation keyed on this.
#[must_use]
pub const fn phase_key(phase: Phase) -> &'static str {
    match phase {
        Phase::Ready => "ready",
        Phase::Starting => "starting",
        Phase::Unavailable => "unavailable",
        Phase::Offline => "offline",
    }
}

/// The service's ADDRESS, or empty when there is not one.
///
/// The device poll restarts on this rather than on the phase, so a respawn on a new port re-dials
/// and an identical re-render does not. It is a SECOND loop on purpose: folding it into the ensure
/// loop would tie the list's refresh rate to the server-boot retry rate, and those two want
/// opposite cadences.
#[must_use]
pub fn ready_key(phase: Phase, host: &str, port: u16) -> String {
    if phase == Phase::Ready {
        format!("{host}:{port}")
    } else {
        String::new()
    }
}

/// The open gate's heading — the project folder's own name.
///
/// The DETAIL beside it is the full root, which is the one place in the panel where the longer
/// string is the more useful one: the gate is precisely the moment of deciding whether this is the
/// project worth booting an editor for, and two same-named checkouts are told apart only by the
/// path above them.
///
/// A trailing separator is ignored rather than read as an empty name, and a root that is nothing
/// but separators answers with itself — there is no other name to give it.
#[must_use]
pub fn gate_title(project_root: &str) -> &str {
    let trimmed = project_root.trim_end_matches('/');
    if trimmed.is_empty() {
        return project_root;
    }
    match trimmed.rsplit_once('/') {
        Some((_, name)) if !name.is_empty() => name,
        _ => trimmed,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DESKTOP, DeviceSurface, EmptyState, PROVISION_COMMAND, Phase, Workbench, android, gate_title,
        phase_key, ready_key, simulators, workbench,
    };

    /// The empty state a device surface is in, or `None` when it is in another one.
    const fn empty_of_device(surface: DeviceSurface) -> Option<EmptyState> {
        match surface {
            DeviceSurface::Empty(state) => Some(state),
            DeviceSurface::Devices | DeviceSurface::Waiting(_) => None,
        }
    }

    /// The same read for the workbench surface.
    const fn empty_of_workbench(state: Workbench) -> Option<EmptyState> {
        match state {
            Workbench::Empty(state) => Some(state),
            Workbench::Gate | Workbench::Mount | Workbench::Waiting(_) => None,
        }
    }

    /// The gate comes FIRST — a project nobody opened costs nothing, whatever the poll is doing.
    #[test]
    fn an_unopened_root_offers_the_gate_from_every_phase() {
        for byte in 0..4_u8 {
            let phase = Phase::from_byte(byte);
            assert_eq!(
                workbench(phase, true, false, true, false),
                Workbench::Gate,
                "{phase:?}"
            );
        }
    }

    /// ⚠️ The bug this order exists for: a ready phase carrying the PREVIOUS project waits, exactly
    /// like a boot, rather than mounting the old folder for the new root.
    #[test]
    fn a_ready_phase_for_another_project_waits_instead_of_mounting() {
        assert_eq!(workbench(Phase::Ready, true, true, true, false), Workbench::Mount);
        assert_eq!(
            workbench(Phase::Ready, true, true, false, false),
            Workbench::Waiting("Starting code-server…"),
        );
    }

    /// The push is a WAIT, never a "no project" verdict about a pane that has one.
    #[test]
    fn a_pane_awaiting_its_key_waits_rather_than_reporting_no_project() {
        let waiting = workbench(Phase::Ready, false, false, false, true);
        assert_eq!(waiting, Workbench::Waiting("Resolving project…"));
        assert_eq!(
            workbench(Phase::Ready, false, false, false, false),
            Workbench::Empty(EmptyState::sentence(
                "folder",
                "No project in focus",
                "Focus a terminal pane to open its project here.",
            )),
        );
    }

    /// The provisioning line is a COMMAND on every surface that prints it, and it is one line.
    #[test]
    fn every_missing_tool_points_at_the_same_provision_script() {
        let missing: Vec<EmptyState> = [simulators(Phase::Unavailable), android(Phase::Unavailable)]
            .into_iter()
            .filter_map(empty_of_device)
            .chain(empty_of_workbench(workbench(
                Phase::Unavailable,
                true,
                true,
                false,
                false,
            )))
            .collect();
        assert_eq!(missing.len(), 3, "three surfaces can be missing a tool");
        for state in missing {
            assert_eq!(state.detail, PROVISION_COMMAND);
            assert!(state.detail_is_command, "a command is set in the instrument face");
        }
    }

    /// Offline is the same glyph and title everywhere, and only the detail names the surface.
    #[test]
    fn an_unreachable_host_reads_the_same_on_every_surface() {
        let mut details = Vec::new();
        for state in [simulators(Phase::Offline), android(Phase::Offline)]
            .into_iter()
            .filter_map(empty_of_device)
        {
            assert_eq!(state.system_image, "bolt.slash");
            assert_eq!(state.title, "Host unreachable");
            assert!(!state.detail_is_command);
            details.push(state.detail);
        }
        details.dedup();
        assert_eq!(details.len(), 2, "each surface names its own thing in the detail");
    }

    #[test]
    fn a_ready_service_shows_its_devices_and_a_booting_one_shows_its_own_line() {
        assert_eq!(simulators(Phase::Ready), DeviceSurface::Devices);
        assert_eq!(android(Phase::Ready), DeviceSurface::Devices);
        assert_eq!(
            simulators(Phase::Starting),
            DeviceSurface::Waiting("Starting simulator server…"),
        );
        assert_eq!(
            android(Phase::Starting),
            DeviceSurface::Waiting("Opening the Android bridge…"),
        );
    }

    /// The animation key drops the address; the poll key is the address.
    #[test]
    fn the_two_keys_answer_two_different_questions() {
        assert_eq!(phase_key(Phase::Ready), "ready");
        assert_eq!(ready_key(Phase::Ready, "127.0.0.1", 8080), "127.0.0.1:8080");
        assert_eq!(
            ready_key(Phase::Ready, "127.0.0.1", 8081),
            "127.0.0.1:8081",
            "a respawn on a new port re-dials",
        );
        for byte in 0..3_u8 {
            assert_eq!(ready_key(Phase::from_byte(byte), "h", 1), "");
        }
        let mut keys: Vec<&str> = (0..4_u8).map(|byte| phase_key(Phase::from_byte(byte))).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(
            keys.len(),
            4,
            "two phases sharing a key would suppress a real cut"
        );
    }

    /// A byte no build wrote keeps polling rather than reporting a tool as missing.
    #[test]
    fn an_unknown_phase_byte_is_the_offline_one() {
        assert_eq!(Phase::from_byte(9), Phase::Offline);
    }

    #[test]
    fn the_gate_heading_is_the_folders_own_name() {
        assert_eq!(gate_title("/Users/me/work/api"), "api");
        assert_eq!(gate_title("/Users/me/work/api/"), "api");
        assert_eq!(gate_title("api"), "api");
        assert_eq!(gate_title("/"), "/", "a root with no name answers with itself");
        assert_eq!(gate_title(""), "");
    }

    #[test]
    fn the_announced_surface_is_a_placeholder_with_a_real_tab() {
        assert_eq!(DESKTOP.title, "Desktop");
        const { assert!(!DESKTOP.detail_is_command) }
    }
}
