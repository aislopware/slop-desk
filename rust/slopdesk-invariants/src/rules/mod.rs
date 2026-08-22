//! One module per section of the gate this crate replaces, and the registry that names them all.
//!
//! A rule lands here by being added to [`registry`] — there is no macro, no inventory crate and no
//! link-time registration, because the one property this list must have is that a reader can see
//! the whole enforced set in one screen. A rule that is written but not registered is a rule that
//! runs never, and the way to notice that is for the list to be short enough to read.

pub mod supervisor_envelope;

use crate::Rule;

/// Every rule, in the order the shell ran them.
#[must_use]
pub fn registry() -> Vec<Rule> {
    vec![
        Rule {
            name: "rendezvous-address",
            origin: "docs/51 §1",
            check: supervisor_envelope::rendezvous_address,
        },
        Rule {
            name: "control-socket-export",
            origin: "docs/51 §1",
            check: supervisor_envelope::control_socket_export,
        },
        Rule {
            name: "shell-integration-env-keys",
            origin: "docs/51 §6.4",
            check: supervisor_envelope::shell_integration_env_keys,
        },
        Rule {
            name: "superd-private-paths",
            origin: "docs/51 §1",
            check: supervisor_envelope::superd_private_paths,
        },
        Rule {
            name: "protocol-version",
            origin: "docs/51 §2, docs/49",
            check: supervisor_envelope::protocol_version,
        },
        Rule {
            name: "verbs",
            origin: "docs/51 §3",
            check: supervisor_envelope::verbs,
        },
        Rule {
            name: "listener-kinds",
            origin: "docs/51 §3b",
            check: supervisor_envelope::listener_kinds,
        },
        Rule {
            name: "frame-envelope",
            origin: "docs/20 §4",
            check: supervisor_envelope::frame_envelope,
        },
    ]
}

#[cfg(test)]
mod tests {
    /// A registry with two rules of the same name would make `--only` ambiguous and a differential
    /// diff unattributable.
    #[test]
    fn every_rule_name_is_unique() {
        let names: std::collections::BTreeSet<_> = super::registry().iter().map(|rule| rule.name).collect();
        assert_eq!(names.len(), super::registry().len());
    }

    /// Every rule must pass on the real tree. This is the gate itself, run as a test — which is
    /// what lets `cargo test` in this crate stand in for the whole shell script during development.
    #[test]
    fn the_live_tree_satisfies_every_rule() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(std::path::Path::parent)
            .expect("repository root is two levels above this crate")
            .to_path_buf();
        let tree = crate::Tree::load(&root).expect("load the repository");
        let violations = crate::run(&tree, None);
        assert!(violations.is_empty(), "{}", violations.join("\n"));
    }
}
