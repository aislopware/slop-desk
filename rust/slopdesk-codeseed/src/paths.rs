//! Where the code-server child reads what this program writes.
//!
//! Every path here is resolved the way the CHILD resolves it, not the way this process would.
//! That distinction has already cost a bug once: a gate-sandboxed hostd seeded the real user's
//! settings file while its children read the sandbox's, because the seeder asked the directory
//! service for "home" instead of asking the environment.
//!
//! Which is why every function takes the environment as an ARGUMENT rather than reading it. A
//! resolver that reaches for the ambient process state is one nobody can test against a home
//! directory they do not have, and the bug above is exactly the one such a test would have caught.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// The environment these resolvers read, passed rather than sampled.
pub type Environment = BTreeMap<String, String>;

/// This process's environment — hostd's, and therefore the one the child inherits.
#[must_use]
pub fn process_environment() -> Environment {
    std::env::vars().collect()
}

/// The code-server data dir the child resolves.
///
/// `--user-data-dir` is not passed, so code-server resolves `$XDG_DATA_HOME/code-server` (absolute
/// values only), else `~/.local/share/code-server`. "Home" must be what Node's `os.homedir()`
/// answers IN THE CHILD — `$HOME` first — never a directory-service lookup, which is blind to a
/// `HOME` override. Settings live under `User/`, seeded extensions under `extensions/`.
#[must_use]
pub fn data_dir_in(environment: &Environment) -> PathBuf {
    let absolute = |key: &str| {
        environment
            .get(key)
            .filter(|value| value.starts_with('/'))
            .map(PathBuf::from)
    };
    let data_home = absolute("XDG_DATA_HOME")
        .or_else(|| absolute("HOME").map(|home| home.join(".local/share")))
        // No usable `HOME` at all. A relative path here would seed into whatever directory hostd
        // happened to launch from, so the answer is the literal default instead: wrong in the same
        // way for everyone, and visible in the reported path.
        .unwrap_or_else(|| PathBuf::from("/.local/share"));
    data_home.join("code-server")
}

/// Where the child reads user settings.
#[must_use]
pub fn user_settings_in(environment: &Environment) -> PathBuf {
    data_dir_in(environment).join("User/settings.json")
}

/// The profile's extensions directory — the seeded theme and bridge extensions live here, beside
/// the `extensions.json` registry that decides which of them the workbench can see.
#[must_use]
pub fn extensions_dir_in(environment: &Environment) -> PathBuf {
    data_dir_in(environment).join("extensions")
}

/// Where `CodeBridgeServer` listens: the user's temp dir, at a **pid-free** name.
///
/// It used to carry the pid, copying what the agent hook and control sockets did — and it inherited
/// their bug with it (`docs/51` §1). code-server now survives a hostd restart, and its extension
/// host is holding the environment it was `execve`d with: a pid in this name means the bridge
/// extension spends the rest of that workbench's life reconnecting to a socket nobody will ever
/// bind again. Open-file and run-in-terminal simply stop working, silently.
///
/// What a stable name gives up is the claim that two hosts on one machine never share a socket
/// file. They now do, and the last one to bind wins — which is the honest state of things either
/// way: the code panel is a per-USER singleton, not a per-hostd one.
#[must_use]
pub fn bridge_socket_in(environment: &Environment) -> PathBuf {
    let temp = environment
        .get("TMPDIR")
        .filter(|dir| dir.starts_with('/'))
        .cloned();
    PathBuf::from(temp.unwrap_or_else(|| "/tmp".to_owned())).join("slopdesk-code-bridge.sock")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(pairs: &[(&str, &str)]) -> Environment {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn home_gives_the_documented_default() {
        assert_eq!(
            data_dir_in(&environment(&[("HOME", "/Users/ada")])),
            PathBuf::from("/Users/ada/.local/share/code-server"),
        );
    }

    #[test]
    fn xdg_data_home_wins_over_home() {
        let resolved = data_dir_in(&environment(&[
            ("HOME", "/Users/ada"),
            ("XDG_DATA_HOME", "/data"),
        ]));
        assert_eq!(resolved, PathBuf::from("/data/code-server"));
    }

    #[test]
    fn a_relative_xdg_data_home_is_ignored_the_way_code_server_ignores_it() {
        let resolved = data_dir_in(&environment(&[("HOME", "/Users/ada"), ("XDG_DATA_HOME", "data")]));
        assert_eq!(resolved, PathBuf::from("/Users/ada/.local/share/code-server"));
    }

    #[test]
    fn no_home_at_all_answers_the_literal_default_rather_than_a_relative_path() {
        assert_eq!(
            data_dir_in(&environment(&[])),
            PathBuf::from("/.local/share/code-server")
        );
        assert_eq!(
            data_dir_in(&environment(&[("HOME", "relative")])),
            PathBuf::from("/.local/share/code-server"),
        );
    }

    #[test]
    fn settings_and_extensions_hang_off_the_data_dir() {
        let env = environment(&[("HOME", "/Users/ada")]);
        assert_eq!(
            user_settings_in(&env),
            PathBuf::from("/Users/ada/.local/share/code-server/User/settings.json"),
        );
        assert_eq!(
            extensions_dir_in(&env),
            PathBuf::from("/Users/ada/.local/share/code-server/extensions"),
        );
    }

    #[test]
    fn the_bridge_socket_carries_no_pid() {
        let named = bridge_socket_in(&environment(&[("TMPDIR", "/private/var/t")]));
        assert_eq!(named, PathBuf::from("/private/var/t/slopdesk-code-bridge.sock"));
        assert_eq!(
            bridge_socket_in(&environment(&[])),
            PathBuf::from("/tmp/slopdesk-code-bridge.sock"),
        );
        assert!(!named.to_string_lossy().contains(&std::process::id().to_string()));
    }
}
