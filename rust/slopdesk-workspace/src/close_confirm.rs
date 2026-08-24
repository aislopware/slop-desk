//! What the pane/tab close confirmation SAYS.
//!
//! The confirmation itself is the platform's own modal on both platforms — an `NSAlert` sheet on
//! the Mac, a `SwiftUI` `.alert` on the phone — and there is nothing to port about either. What
//! there IS to keep in one place is the WORDING, because it is not a constant: it depends on which
//! of the two parks is armed, on whether a configured policy actually gated the park (a park raised
//! purely for the project-loss warning must not claim "a process is still running" over an idle
//! shell), and on whether the close takes a project's last pane with it. Both can apply at once.
//! Three branches and a join is exactly the amount of logic that drifts when two halves each carry
//! it.

/// Which unit a parked close is about.
///
/// A window closes like a tab as far as the wording goes — the sentence names the thing the reader
/// pressed × on, and nobody presses × on a window expecting to be told about a pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// One leaf.
    Pane,
    /// A tab, or the window that holds them.
    Tab,
}

impl Scope {
    /// Both scopes, in code order.
    pub const ALL: [Self; 2] = [Self::Pane, Self::Tab];

    /// The scope a code names; anything unrecognised reads as [`Scope::Tab`], the wider unit, so a
    /// stale code over-warns rather than under-warns.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        if code == 0 { Self::Pane } else { Self::Tab }
    }

    /// This scope's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Pane => 0,
            Self::Tab => 1,
        }
    }
}

/// Why a close was parked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    /// A process is still running under the unit.
    Process,
    /// The user asked to be confirmed every time.
    Always,
    /// The window holds several tabs.
    MultipleTabs,
}

impl Policy {
    /// Every policy, in code order.
    pub const ALL: [Self; 3] = [Self::Process, Self::Always, Self::MultipleTabs];

    /// The policy a code names. An unrecognised code reads as [`Policy::Process`], which is what
    /// the near side already substitutes for an absent one: it names a consequence rather than
    /// asking a bare question, and a park with no recorded reason is likelier to be a busy shell
    /// than a preference.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Always,
            2 => Self::MultipleTabs,
            _ => Self::Process,
        }
    }

    /// This policy's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Process => 0,
            Self::Always => 1,
            Self::MultipleTabs => 2,
        }
    }
}

/// Everything the confirmation needs to know about a parked close.
///
/// The two parks are mutually exclusive, so `pane_title` is what tells them apart: a pane close
/// names the leaf it would take, a tab close has no leaf to name.
#[derive(Clone, Copy, Debug)]
pub struct Request<'a> {
    /// Which unit the parked close is about.
    pub scope: Scope,
    /// The parked PANE's title, or [`None`] for a parked tab close. Empty is its own case — a pane
    /// with no title is named generically rather than with a pair of empty quotes.
    pub pane_title: Option<&'a str>,
    /// Whether a configured policy ACTUALLY gated this park. `false` when the park exists only for
    /// the project-loss warning.
    pub policy_gated: bool,
    /// The policy that gated it.
    pub policy: Policy,
    /// The By-Project section that dies with the close, when the close takes its last pane.
    pub project_name: Option<&'a str>,
}

/// The alert's headline: the pane's own title when a pane close is parked, else the tab copy.
#[must_use]
pub fn title(request: &Request<'_>) -> String {
    match request.pane_title {
        None => "Close this tab?".to_owned(),
        Some("") => "Close this pane?".to_owned(),
        Some(name) => format!("Close \u{201c}{name}\u{201d}?"),
    }
}

/// The alert's body: the policy line when a policy gated the park, the project-loss line when the
/// close takes a project's last pane, or both.
///
/// A park that matches NEITHER gate — both are resolved live, so either can decay while the dialog
/// is up — still prints the policy line rather than an empty body.
#[must_use]
pub fn message(request: &Request<'_>) -> String {
    let mut lines: Vec<String> = Vec::new();
    if request.policy_gated {
        lines.push(reason(request.policy, request.scope).to_owned());
    }
    if let Some(project) = request.project_name {
        lines.push(project_close_reason(project, request.scope));
    }
    if lines.is_empty() {
        lines.push(reason(request.policy, request.scope).to_owned());
    }
    lines.join("\n\n")
}

/// The subtitle for a resolved policy + close scope.
///
/// The wording stays soft: a running process names the consequence; `always` asks plainly (scoped
/// to "pane" vs "tab"); `multiple_tabs` warns that the window holds several tabs.
#[must_use]
pub const fn reason(policy: Policy, scope: Scope) -> &'static str {
    match policy {
        Policy::Process => "A process is still running. Closing it will stop the command.",
        Policy::Always => {
            match scope {
                Scope::Pane => "Are you sure you want to close this pane?",
                Scope::Tab => "Are you sure you want to close this tab?",
            }
        },
        Policy::MultipleTabs => "This window has multiple tabs.",
    }
}

/// The project-loss warning line: the parked close takes `project`'s LAST pane / tab with it, so
/// the whole By-Project section disappears.
#[must_use]
pub fn project_close_reason(project: &str, scope: Scope) -> String {
    let unit = match scope {
        Scope::Pane => "pane",
        Scope::Tab => "tab",
    };
    format!("This is the last {unit} of \u{201c}{project}\u{201d}. Closing it will close the project.")
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Policy, Request, Scope, message, project_close_reason, reason, title};

    fn park<'a>(
        scope: Scope,
        pane_title: Option<&'a str>,
        policy_gated: bool,
        project_name: Option<&'a str>,
    ) -> Request<'a> {
        Request {
            scope,
            pane_title,
            policy_gated,
            policy: Policy::Process,
            project_name,
        }
    }

    #[test]
    fn a_named_pane_is_quoted_and_a_nameless_one_is_not() {
        assert_eq!(
            title(&park(Scope::Pane, Some("make check"), true, None)),
            "Close \u{201c}make check\u{201d}?"
        );
        assert_eq!(
            title(&park(Scope::Pane, Some(""), true, None)),
            "Close this pane?"
        );
        assert_eq!(title(&park(Scope::Tab, None, true, None)), "Close this tab?");
    }

    /// The defect the module exists for: an ungated park must not claim a process is running.
    #[test]
    fn an_ungated_park_still_prints_a_body() {
        let body = message(&park(Scope::Pane, Some("zsh"), false, Some("slopdesk")));
        assert!(body.contains("last pane of"), "{body:?}");
        assert!(
            !body.contains("A process is still running"),
            "an ungated park must not blame a policy: {body:?}",
        );
    }

    #[test]
    fn both_gates_at_once_print_both_lines_in_order() {
        let body = message(&park(Scope::Pane, Some("zsh"), true, Some("slopdesk")));
        let (first, rest) = body.split_once("\n\n").expect("two lines");
        assert_eq!(first, reason(Policy::Process, Scope::Pane));
        assert_eq!(rest, project_close_reason("slopdesk", Scope::Pane));
    }

    /// Neither gate is the case both halves would have gotten wrong: the dialog is up, both facts
    /// decayed, and an empty body is worse than a stale one.
    #[test]
    fn a_park_that_matches_nothing_falls_back_to_the_policy_line() {
        let body = message(&park(Scope::Tab, None, false, None));
        assert_eq!(body, reason(Policy::Process, Scope::Tab));
    }

    #[test]
    fn only_the_plain_question_is_scoped_to_the_unit() {
        assert_ne!(
            reason(Policy::Always, Scope::Pane),
            reason(Policy::Always, Scope::Tab)
        );
        assert_eq!(
            reason(Policy::Process, Scope::Pane),
            reason(Policy::Process, Scope::Tab)
        );
        assert_eq!(
            reason(Policy::MultipleTabs, Scope::Pane),
            reason(Policy::MultipleTabs, Scope::Tab),
        );
    }

    #[test]
    fn every_policy_round_trips_and_an_unknown_code_reads_as_the_busy_one() {
        for policy in Policy::ALL {
            assert_eq!(Policy::from_code(policy.code()), policy);
        }
        assert_eq!(Policy::from_code(200), Policy::Process);
        for scope in Scope::ALL {
            assert_eq!(Scope::from_code(scope.code()), scope);
        }
        assert_eq!(Scope::from_code(200), Scope::Tab, "a stale code over-warns");
    }
}
