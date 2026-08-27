//! The three embedded-workbench verbs: ensure the child, open a path in it, sync the editor font.
//!
//! The port of `HostCodeServerPerformer.swift`. The manager it drives is
//! [`crate::code::CodeServerManager`], which was ported at stage E; what was left was this — the
//! validator in front of it, and the ONE decision that is neither the manager's nor the wire's:
//! which of two ways a path gets opened, and how the client is told which happened.
//!
//! ## Verb 19 routes, and the reply says where it went
//! A FILE on a host that has code-server goes to the workbench, and the reply is `workbench`. A
//! DIRECTORY goes to the host's default app — a folder is not a thing the editor opens — and so
//! does a file on a host with no code-server at all. Both answer `hostDefault`, so the client can
//! render what actually happened instead of assuming.
//!
//! The workbench arm is **accepted, not completed**: `open_in_workbench` hands back a thread and
//! this performer does not wait on it. It is on a pane's serial executor answering an RPC with a
//! five-second deadline, and the open retries for eighteen seconds across a cold Node boot. Waiting
//! would park the executor that the pane's project-key walk also runs on.
//!
//! ## The path rule is [`crate::pathaction::absolute_host_path`], and that is the point
//! The Swift validated verb 19's target inline with `expandingTildeInPath.standardizingPath` while
//! verb 9 used its own resolver, and the two had already drifted: one expanded `~user` through
//! `getpwnam`, the other did not. One function now, for both.
//!
//! ## Validate-then-drop, and the host always replies
//! A non-UTF-8, empty or relative payload is `error`; a path the host cannot see is `notFound`; a
//! font spec that fails to decode is `error`. Never a trap — these bytes are a peer's choice.

use std::sync::Arc;

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_terminal::link_action::line_col_suffix;
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    CodeOpenDisposition, decode_code_font_spec, encode_code_open_disposition,
};

use crate::code::CodeServerManager;
use crate::pathaction::{OpensPaths, absolute_host_path};

/// The performer for verbs 18, 19 and 20.
#[derive(Debug)]
pub struct CodeActions<D> {
    manager: Arc<CodeServerManager>,
    /// The verb-19 fallback: a directory, or a host without code-server, opens in the default app.
    /// The SAME door verb 9 actuates, so "open this in the Finder's chosen app" has one meaning on
    /// this host regardless of which verb asked.
    fallback: D,
    home: String,
}

impl<D: OpensPaths> CodeActions<D> {
    /// A performer over `manager`, falling back to `fallback`, expanding `~` against `home`.
    #[must_use]
    pub const fn new(manager: Arc<CodeServerManager>, fallback: D, home: String) -> Self {
        Self {
            manager,
            fallback,
            home,
        }
    }

    /// A performer taking `$HOME` from the environment. See
    /// [`crate::pathaction::absolute_host_path`] for what an absent one refuses.
    #[must_use]
    pub fn from_environment(manager: Arc<CodeServerManager>, fallback: D) -> Self {
        Self::new(manager, fallback, std::env::var("HOME").unwrap_or_default())
    }

    /// Verb 18 — ensure the shared workbench for `root`, and answer where it stands.
    ///
    /// `notFound` when the manager refuses the root: never hand out an endpoint for a path the host
    /// cannot see. An `unavailable` STATE is not that — "there is no code-server here" is a real
    /// answer to a real root, and it rides back as `ok`.
    fn ensure(&self, payload: &[u8]) -> MetadataAnswer {
        let Ok(root) = core::str::from_utf8(payload) else {
            return MetadataAnswer::failed();
        };
        if !root.starts_with('/') {
            return MetadataAnswer::failed();
        }
        let Some(endpoint) = self.manager.ensure(root) else {
            return MetadataAnswer {
                status: MetadataStatus::NotFound.as_byte(),
                payload: Vec::new(),
            };
        };
        MetadataAnswer::ok(crate::ensure::endpoint_payload(endpoint))
    }

    /// Verb 19 — open a `path[:line[:col]]` target, in the workbench or in the host's default app.
    fn open(&self, payload: &[u8]) -> MetadataAnswer {
        let Ok(raw) = core::str::from_utf8(payload) else {
            return MetadataAnswer::failed();
        };
        // The suffix is `slopdesk-terminal`'s, which is the rule the CLIENT's link detector split
        // with — so what is put back is exactly what was taken off. The path is what is left, and a
        // substring of a string this side already holds is not a fact two languages could disagree
        // about.
        let suffix = line_col_suffix(raw);
        let Some(path) = raw
            .get(..raw.len().saturating_sub(suffix.len()))
            .and_then(|bare| absolute_host_path(bare, &self.home))
        else {
            return MetadataAnswer::failed();
        };
        let Ok(metadata) = std::fs::metadata(&path) else {
            return MetadataAnswer {
                status: MetadataStatus::NotFound.as_byte(),
                payload: Vec::new(),
            };
        };
        if metadata.is_dir() {
            return self.host_default(&path);
        }
        // The project root is the file's own directory. One code-server serves every folder, so
        // this only decides which root the ensure validates — not which child is asked.
        let project_root = path.rsplit_once('/').map_or("/", |(parent, _leaf)| parent);
        let project_root = if project_root.is_empty() {
            "/"
        } else {
            project_root
        };
        let target = format!("{path}{suffix}");
        if self
            .manager
            .open_in_workbench(&target, project_root, None)
            .is_none()
        {
            // No code-server on this host — the file still opens, just not in the editor.
            return self.host_default(&path);
        }
        MetadataAnswer::ok(encode_code_open_disposition(CodeOpenDisposition::Workbench))
    }

    /// The verb-19 fallback arm: Launch Services, and the disposition byte that says so.
    fn host_default(&self, path: &str) -> MetadataAnswer {
        let status = if self.fallback.open(path) {
            MetadataStatus::Ok
        } else {
            MetadataStatus::Error
        };
        MetadataAnswer {
            status: status.as_byte(),
            payload: encode_code_open_disposition(CodeOpenDisposition::HostDefault),
        }
    }

    /// Verb 20 — fold a client's terminal font into the shared workbench settings.
    ///
    /// The decoder is the validator: these numbers land in a file the workbench trusts, and it
    /// range-checks them. A spec that decodes always answers `ok` whether or not the file needed a
    /// write — already-in-sync is success, not failure.
    fn sync_font(&self, payload: &[u8]) -> MetadataAnswer {
        let Ok(spec) = decode_code_font_spec(payload) else {
            return MetadataAnswer::failed();
        };
        let _changed = self.manager.sync_editor_font(&spec);
        MetadataAnswer::ok(Vec::new())
    }
}

impl<D: OpensPaths> MetadataPerformer for CodeActions<D> {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        match MetadataVerb::from_byte(request.verb) {
            Some(MetadataVerb::EnsureCodeServer) => self.ensure(request.payload),
            Some(MetadataVerb::OpenInCodeServer) => self.open(request.payload),
            Some(MetadataVerb::SyncCodeFont) => self.sync_font(request.payload),
            // Unreachable: the routing table sends only these three here. `unsupportedVerb` rather
            // than a second opinion about who owns a byte.
            _ => {
                MetadataAnswer {
                    status: MetadataStatus::UnsupportedVerb.as_byte(),
                    payload: Vec::new(),
                }
            },
        }
    }
}
