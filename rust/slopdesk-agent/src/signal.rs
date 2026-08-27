//! What the state machine consumes: semantic hook events, and the signal envelope around them.

use crate::screen::AgentScreenDetection;
use crate::status::ClaudeStatus;

/// The semantic class of a `Notification` hook (the matcher field, docs/41 §2.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NotificationKind {
    /// `permission_prompt` — explicit approval needed to proceed. → blocked.
    Permission,
    /// Idle-waiting on the human to type the next thing. → blocked.
    WaitingForInput,
    /// `auth_success` / `elicitation_complete` / anything else — informational only.
    Other,
}

/// The wire byte for a notification class, as the class it names.
///
/// Total, and `Other` is the fall-through: a class this build has no case for is informational
/// rather than blocking, which is the reading that cannot invent a block nobody is waiting on.
#[must_use]
pub const fn notification_of(byte: u8) -> NotificationKind {
    match byte {
        0 => NotificationKind::Permission,
        1 => NotificationKind::WaitingForInput,
        _ => NotificationKind::Other,
    }
}

/// The flat hook discriminants, as the event they name.
///
/// Total over `hook`, defaulting to the session-start case, which changes no status a later signal
/// cannot correct. ONE spelling on purpose: the same mapping serves the FFI detector's hook door
/// and hostd's own hook listener, and two copies of it would be two answers to "is discriminant 7
/// an interrupt".
///
/// It lives HERE rather than beside either caller because this crate owns the vocabulary it maps
/// INTO, and is the only crate both callers already depend on. It takes the flat fields rather than
/// a `slopdesk_hookevent::HookEvent` deliberately — that would make the reader a dependency of the
/// state machine, and the machine is meant to be drivable by anything that can name an edge.
#[must_use]
pub fn hook_event_of(
    hook: u8,
    notification: u8,
    session_id: Option<String>,
    tool: Option<String>,
    tool_use_id: Option<String>,
    label: Option<String>,
) -> ClaudeHookEvent {
    match hook {
        1 => ClaudeHookEvent::UserPromptSubmit { session_id },
        2 => {
            ClaudeHookEvent::PreToolUse {
                session_id,
                tool,
                tool_use_id,
            }
        },
        3 => {
            ClaudeHookEvent::PostToolUse {
                session_id,
                tool,
                tool_use_id,
            }
        },
        4 => {
            ClaudeHookEvent::Notification {
                kind: notification_of(notification),
                label,
                tool_use_id,
                session_id,
            }
        },
        5 => ClaudeHookEvent::Stop { session_id, label },
        6 => ClaudeHookEvent::SubagentStop { agent_id: session_id },
        7 => ClaudeHookEvent::Interrupted { session_id },
        8 => ClaudeHookEvent::SessionEnd { session_id },
        9 => ClaudeHookEvent::PreCompact { session_id },
        _ => ClaudeHookEvent::SessionStart { session_id },
    }
}

/// A semantic Claude Code hook event, decoupled from any transport.
///
/// Each variant carries ONLY the fields the state machine needs — not the full hook JSON. The
/// adapter that maps a raw hook body to this vocabulary lives in the host; this crate stays
/// standalone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeHookEvent {
    /// Session opened (`startup` / `resume` / `clear` / `compact`) → present and at rest.
    SessionStart {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
    /// A user prompt was submitted → a turn began.
    UserPromptSubmit {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
    /// A tool is about to run → working, and a just-resolved permission block comes down.
    ///
    /// `tool_use_id` is the call's identity, which is what lets the BLOCK LEDGER resolve exactly
    /// the call that was blocking rather than "whatever was outstanding".
    PreToolUse {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
        /// The tool name (e.g. `Bash`), carried for diagnostics and labels.
        tool: Option<String>,
        /// The call's identity.
        tool_use_id: Option<String>,
    },
    /// A tool finished → still working until the turn's `Stop`, because a tool result is mid-turn.
    ///
    /// `tool_use_id` identifies WHICH call finished: a parallel tool's result must not resolve the
    /// `AskUserQuestion` the human is still staring at.
    PostToolUse {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
        /// The tool name.
        tool: Option<String>,
        /// The call's identity.
        tool_use_id: Option<String>,
    },
    /// An async notification — `permission_prompt` or waiting-for-input → BLOCKED.
    ///
    /// `tool_use_id` is present when the block belongs to a specific call (a `PermissionRequest`,
    /// or an `AskUserQuestion`'s `PreToolUse` routed here) and absent for the free-standing
    /// notifications that name no call. The ledger treats the two differently.
    Notification {
        /// The notification's semantic class.
        kind: NotificationKind,
        /// Chip text — the prompt's own wording.
        label: Option<String>,
        /// The blocking call's identity, when it has one.
        tool_use_id: Option<String>,
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
    /// The turn ended → done, then idle after the timeout.
    Stop {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
        /// The last assistant message, as chip text.
        label: Option<String>,
    },
    /// A subagent stopped — does not change the parent pane's coarse status.
    SubagentStop {
        /// The subagent's own id, when it named one.
        agent_id: Option<String>,
    },
    /// The turn was INTERRUPTED by the human. Claude Code emits no `Stop` for this, so it is the
    /// only announcement the turn is over — and it is QUIET, exactly like an Esc-cancelled dialog:
    /// the person who ended it was looking at it.
    Interrupted {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
    /// The session ended → the agent is gone.
    SessionEnd {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
    /// A transcript COMPACTION is starting (`/compact`, or the automatic mid-turn one).
    ///
    /// Carries no status of its own — it ARMS a one-shot marker saying "the next turn end may be
    /// the compaction's, not a task's".
    PreCompact {
        /// The session this event belongs to, when the envelope named one.
        session_id: Option<String>,
    },
}

impl ClaudeHookEvent {
    /// The session id this event names, or `None` when it names none.
    ///
    /// Tool calls and notifications carry no session in the adapter, and no ctl `report` ever does.
    #[must_use]
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Self::SessionStart { session_id }
            | Self::UserPromptSubmit { session_id }
            | Self::SessionEnd { session_id }
            | Self::Interrupted { session_id }
            | Self::PreCompact { session_id }
            | Self::PreToolUse { session_id, .. }
            | Self::PostToolUse { session_id, .. }
            | Self::Stop { session_id, .. }
            | Self::Notification { session_id, .. } => session_id.as_deref(),
            Self::SubagentStop { .. } => None,
        }
    }

    /// This event with `id` filled into every session slot it left empty.
    ///
    /// The payload shapes that model a CALL carry no session — Claude Code stamps `session_id` on
    /// the envelope, not on the tool. The host reads it off the raw body and stamps it here, so
    /// every authoritative event arrives attributed and the machine can tell its own pane agent
    /// from a nested `claude -p`. Only empty slots are filled: an id the payload itself named
    /// always wins.
    ///
    /// A subagent belongs to whichever session owns it and changes no status — nothing to
    /// attribute, and attributing it would let a nested run's subagent claim a free pane.
    #[must_use]
    pub fn attributed(self, id: Option<&str>) -> Self {
        let Some(id) = id.filter(|id| !id.is_empty()) else {
            return self;
        };
        let fill = |slot: Option<String>| Some(slot.unwrap_or_else(|| id.to_owned()));
        match self {
            Self::SessionStart { session_id } => {
                Self::SessionStart {
                    session_id: fill(session_id),
                }
            },
            Self::UserPromptSubmit { session_id } => {
                Self::UserPromptSubmit {
                    session_id: fill(session_id),
                }
            },
            Self::SessionEnd { session_id } => {
                Self::SessionEnd {
                    session_id: fill(session_id),
                }
            },
            Self::Interrupted { session_id } => {
                Self::Interrupted {
                    session_id: fill(session_id),
                }
            },
            Self::PreCompact { session_id } => {
                Self::PreCompact {
                    session_id: fill(session_id),
                }
            },
            Self::PreToolUse {
                session_id,
                tool,
                tool_use_id,
            } => {
                Self::PreToolUse {
                    session_id: fill(session_id),
                    tool,
                    tool_use_id,
                }
            },
            Self::PostToolUse {
                session_id,
                tool,
                tool_use_id,
            } => {
                Self::PostToolUse {
                    session_id: fill(session_id),
                    tool,
                    tool_use_id,
                }
            },
            Self::Stop { session_id, label } => {
                Self::Stop {
                    session_id: fill(session_id),
                    label,
                }
            },
            Self::Notification {
                kind,
                label,
                tool_use_id,
                session_id,
            } => {
                Self::Notification {
                    kind,
                    label,
                    tool_use_id,
                    session_id: fill(session_id),
                }
            },
            Self::SubagentStop { .. } => self,
        }
    }
}

/// The INPUT signals the machine consumes. Transport-agnostic by construction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeSignal {
    /// A semantic hook event — the richest signal, and the authoritative one.
    Hook(ClaudeHookEvent),
    /// The host's foreground-process watch: is the agent the PTY's foreground process?
    ///
    /// Presence is the FLOOR; absence forces [`ClaudeStatus::None`].
    ProcessPresent(bool),
    /// The no-hooks fallback's coarse verdict.
    ///
    /// A conservative [`ClaudeStatus::None`] is IGNORED — it never downgrades a present process —
    /// and the rest promote only while a more-authoritative hook block is not in effect.
    ManifestVerdict(ClaudeStatus),
    /// An OSC 2 title. Weak corroboration; promotes at most to idle, except for the agent's own
    /// spinner and at-rest telltales.
    OscTitle(String),
    /// A clock tick — drives the done→idle decay and the dissent watchdog off the injected `now`.
    Tick,
    /// A SCREEN-RULE verdict from the manifest engine: the live grid evaluated against the agent's
    /// rule ladder. Continuous ground truth, richer than [`ManifestVerdict`](Self::ManifestVerdict)
    /// because it carries the `visible_*` chrome flags.
    Screen(AgentScreenDetection),
    /// A CANCEL key routed into the pane's PTY — the caller classifies with
    /// [`contains_cancel_keystroke`](crate::input::contains_cancel_keystroke).
    ///
    /// Narrowly scoped: it demotes ONLY a standing block, because an Esc-cancel fires no `Stop`
    /// hook and the at-rest title shows while the dialog is still up, making it the one unblock
    /// edge the host can see. Every OTHER way out of a dialog re-promotes itself through a hook, so
    /// widening this to any keystroke only manufactured false blocked→idle→blocked flaps.
    UserInput,
}

#[cfg(test)]
mod tests {
    use super::{ClaudeHookEvent, NotificationKind, hook_event_of, notification_of};

    /// The nine named discriminants, each landing on the variant it names.
    ///
    /// One assertion per row rather than a loop, because the FAILURE this guards against is a
    /// neighbour — "is 7 an interrupt" — and a loop that compared two tables would be wrong in the
    /// same way at both ends.
    #[test]
    fn every_discriminant_names_the_event_it_is_documented_as() {
        let id = || Some("s1".to_owned());
        assert!(matches!(
            hook_event_of(1, 0, id(), None, None, None),
            ClaudeHookEvent::UserPromptSubmit { .. }
        ));
        assert!(matches!(
            hook_event_of(2, 0, id(), None, None, None),
            ClaudeHookEvent::PreToolUse { .. }
        ));
        assert!(matches!(
            hook_event_of(3, 0, id(), None, None, None),
            ClaudeHookEvent::PostToolUse { .. }
        ));
        assert!(matches!(
            hook_event_of(4, 0, id(), None, None, None),
            ClaudeHookEvent::Notification { .. }
        ));
        assert!(matches!(
            hook_event_of(5, 0, id(), None, None, None),
            ClaudeHookEvent::Stop { .. }
        ));
        assert!(matches!(
            hook_event_of(6, 0, id(), None, None, None),
            ClaudeHookEvent::SubagentStop { .. }
        ));
        assert!(matches!(
            hook_event_of(7, 0, id(), None, None, None),
            ClaudeHookEvent::Interrupted { .. }
        ));
        assert!(matches!(
            hook_event_of(8, 0, id(), None, None, None),
            ClaudeHookEvent::SessionEnd { .. }
        ));
        assert!(matches!(
            hook_event_of(9, 0, id(), None, None, None),
            ClaudeHookEvent::PreCompact { .. }
        ));
    }

    /// An unknown discriminant is a session start, which changes no status a later signal cannot
    /// correct. `0` is the documented one; everything past the table lands there too.
    #[test]
    fn an_unknown_discriminant_is_the_harmless_one() {
        for byte in [0_u8, 10, 200, 255] {
            assert!(
                matches!(
                    hook_event_of(byte, 0, None, None, None, None),
                    ClaudeHookEvent::SessionStart { .. }
                ),
                "discriminant {byte} did not fall through"
            );
        }
    }

    /// A `SubagentStop` takes the envelope's id as the SUBAGENT's, and reports no session.
    ///
    /// The one row where the mapping is not a rename: a subagent's stop must not resolve the parent
    /// pane's turn, and `session_id() == None` is what keeps the ledger from doing so.
    #[test]
    fn a_subagent_stop_carries_an_agent_id_and_no_session() {
        let event = hook_event_of(6, 0, Some("sub-1".to_owned()), None, None, None);
        assert_eq!(event.session_id(), None);
        assert!(
            matches!(event, ClaudeHookEvent::SubagentStop { agent_id } if agent_id.as_deref() == Some("sub-1"))
        );
    }

    /// The notification class, with `Other` as the fall-through.
    ///
    /// Informational rather than blocking, because a class this build has no case for must not
    /// invent a block nobody is waiting on.
    #[test]
    fn an_unknown_notification_class_is_informational() {
        assert_eq!(notification_of(0), NotificationKind::Permission);
        assert_eq!(notification_of(1), NotificationKind::WaitingForInput);
        for byte in [2_u8, 3, 99] {
            assert_eq!(notification_of(byte), NotificationKind::Other);
        }
    }

    #[test]
    fn attribution_fills_only_the_empty_slots() {
        let stamped = ClaudeHookEvent::Stop {
            session_id: None,
            label: Some("done".to_owned()),
        }
        .attributed(Some("s1"));
        assert_eq!(stamped.session_id(), Some("s1"));

        let already = ClaudeHookEvent::Stop {
            session_id: Some("own".to_owned()),
            label: None,
        }
        .attributed(Some("s1"));
        assert_eq!(already.session_id(), Some("own"));
    }

    #[test]
    fn an_empty_or_absent_id_attributes_nothing() {
        let event = ClaudeHookEvent::SessionStart { session_id: None };
        assert_eq!(event.clone().attributed(None).session_id(), None);
        assert_eq!(event.attributed(Some("")).session_id(), None);
    }

    #[test]
    fn a_subagent_stop_never_takes_an_attribution() {
        let event = ClaudeHookEvent::SubagentStop {
            agent_id: Some("a".to_owned()),
        };
        assert_eq!(event.clone().attributed(Some("s1")), event);
        assert_eq!(event.session_id(), None);
    }

    #[test]
    fn every_call_carrying_shape_is_attributable() {
        for event in [
            ClaudeHookEvent::PreToolUse {
                session_id: None,
                tool: None,
                tool_use_id: None,
            },
            ClaudeHookEvent::PostToolUse {
                session_id: None,
                tool: None,
                tool_use_id: None,
            },
            ClaudeHookEvent::Notification {
                kind: NotificationKind::Permission,
                label: None,
                tool_use_id: None,
                session_id: None,
            },
            ClaudeHookEvent::UserPromptSubmit { session_id: None },
            ClaudeHookEvent::SessionEnd { session_id: None },
            ClaudeHookEvent::Interrupted { session_id: None },
            ClaudeHookEvent::PreCompact { session_id: None },
        ] {
            assert_eq!(
                event.clone().attributed(Some("s1")).session_id(),
                Some("s1"),
                "{event:?}"
            );
        }
    }
}
