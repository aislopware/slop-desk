//! Finding the three host binaries the Android panel stands on, and running the one of them that
//! answers questions.
//!
//! **Why locating is harder here than for a pinned single binary.** The Android SDK is not one
//! binary: it is a directory tree that Android Studio, `sdkmanager`, `mise`, `asdf` and Nix each
//! put somewhere different, and whose `platform-tools` end up on `PATH` only if the user edited a
//! shell profile — which a daemon, launched outside a login shell, never reads anyway. So the
//! search walks the SDK roots as well, in order of how authoritative each is.
//!
//! **Only `adb` is vendored, on purpose.** It is a standalone versioned download from Google. The
//! `emulator` is not: it comes from `sdkmanager` and is useless without a system image, and those
//! run to gigabytes per API level behind an interactive licence accept. So `adb` pins and the
//! emulator stays a host install.
//!
//! **`scrcpy-server` is a jar, not an executable**, so it cannot go through a binary locator at
//! all. It is the one dependency committed to this repo outright (`ThirdParty/tools/vendor/`), with
//! Homebrew's `share/scrcpy` kept as the fallback for a daemon running outside a checkout.
//!
//! ## The search ORDER lives here for the whole project, not only for this panel
//!
//! `docs/46`'s "Vendored runtime deps" table states one order — override, vendored prefix, `PATH`,
//! then a tail — and it used to be written twice: [`locate_sdk_tool`] here, and
//! `HostServiceProcess.locate` in Swift for `code-server` and `baguette`. That is the pair shape
//! `docs/55` §8 catalogues, and the two had already stopped agreeing on the one question neither
//! doc mentions — *what makes a candidate executable*. Swift asked `FileManager.isExecutableFile`,
//! which is `access(X_OK)`: true for a DIRECTORY named `code-server` sitting on `PATH`, and false
//! for a root-owned `0700` binary this crate would have handed back. Two answers, opposite
//! directions, both silent — one hands a directory to `posix_spawn`, the other hands back a path
//! this daemon cannot exec.
//!
//! So [`locate_tool`] is the order, once, and the two callers differ only in their TAIL: the SDK
//! roots for a panel tool, [`host_service_fallback_dirs`] for a hostd service. Nothing about that
//! tail is Android's, which is why it is exported rather than hidden.

use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Where the host's Android tooling lives.
///
/// A `None` member means the panel reports that piece missing — an install hint that says "adb"
/// when adb is what is missing beats one generic "Android unavailable".
#[derive(Debug, Clone)]
pub struct Toolchain {
    /// `platform-tools/adb` — the device channel. Without this there is no Android panel at all.
    pub adb: PathBuf,
    /// `emulator/emulator` — only needed to LIST and BOOT AVDs. A host with a physical device
    /// plugged in and no emulator installed is a perfectly good Android host.
    pub emulator: Option<PathBuf>,
    /// `share/scrcpy/scrcpy-server` — the jar pushed to the device. Without it devices still list
    /// and boot, but nothing mirrors.
    pub scrcpy_server_jar: Option<PathBuf>,
}

impl Toolchain {
    /// Resolves the toolchain, or `None` when `adb` itself is missing.
    #[must_use]
    pub fn locate(
        environment: &HashMap<String, String>,
        vendored_bin: Option<&Path>,
        vendored_jar: Option<&Path>,
    ) -> Option<Self> {
        let adb = locate_sdk_tool(
            "adb",
            "platform-tools",
            "SLOPDESK_ADB_BIN",
            environment,
            vendored_bin,
        )?;
        Some(Self {
            adb,
            emulator: locate_sdk_tool(
                "emulator",
                "emulator",
                "SLOPDESK_ANDROID_EMULATOR_BIN",
                environment,
                // Deliberately NOT vendored — see the module comment.
                None,
            ),
            scrcpy_server_jar: locate_scrcpy_server_jar(environment, vendored_jar),
        })
    }

    /// Runs `adb -s <serial> <arguments…>`, or host-scoped `adb <arguments…>` with no serial.
    #[must_use]
    pub fn adb(&self, serial: Option<&str>, arguments: &[&str], timeout: Duration) -> Option<String> {
        let mut argv: Vec<&str> = Vec::with_capacity(arguments.len() + 2);
        if let Some(serial) = serial {
            argv.push("-s");
            argv.push(serial);
        }
        argv.extend_from_slice(arguments);
        run(&self.adb, &argv, timeout)
    }
}

/// The vendored prefix first when the tool is pinned there, then `PATH`, then every SDK root this
/// host might have, each probed at `<root>/<subdirectory>/<name>`.
#[must_use]
#[expect(
    clippy::implicit_hasher,
    reason = "the environment bag is built by this crate or its tests, never handed in with another hasher"
)]
pub fn locate_sdk_tool(
    name: &str,
    subdirectory: &str,
    override_variable: &str,
    environment: &HashMap<String, String>,
    vendored_bin: Option<&Path>,
) -> Option<PathBuf> {
    let tail: Vec<PathBuf> = sdk_roots(environment)
        .into_iter()
        .map(|root| root.join(subdirectory))
        .collect();
    locate_tool(
        name,
        environment.get(override_variable).map(String::as_str),
        environment.get("PATH").map(String::as_str).unwrap_or_default(),
        vendored_bin,
        &tail,
    )
}

/// The project's binary search order, once: the override, the vendored prefix, `PATH`, then `tail`.
///
/// `override_value` is the variable's VALUE, not its name — the environment read stays with the
/// caller, whose tests pass dictionaries in (`docs/55` §8, "the environment lookup stays on the
/// near side"). What crosses is this: the precedence, the emptiness filter that makes an exported
/// blank the same as an absent one, and the executability test.
///
/// **The vendored prefix outranks `PATH`**, which inverts the usual instinct on purpose: the copy
/// in `ThirdParty/tools/tools.lock` is the one the panels were written and measured against, and a
/// stale Homebrew install silently winning is the failure that layer exists to end. The override
/// stays above it, because an operator bisecting a candidate build meant that build.
///
/// A named-but-broken override answers `None` rather than falling through. Going looking for a
/// different binary would make a bisect report the wrong verdict about the wrong program.
#[must_use]
pub fn locate_tool(
    name: &str,
    override_value: Option<&str>,
    path_value: &str,
    vendored_bin: Option<&Path>,
    tail: &[PathBuf],
) -> Option<PathBuf> {
    if let Some(override_path) = override_value.filter(|value| !value.is_empty()) {
        let path = PathBuf::from(override_path);
        return is_executable(&path).then_some(path);
    }
    if let Some(vendored) = vendored_bin {
        let candidate = vendored.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    for directory in path_value.split(':') {
        if directory.is_empty() {
            continue;
        }
        let candidate = Path::new(directory).join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    for directory in tail {
        let candidate = directory.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

/// The tail hostd's lazily-spawned HTTP services search after `PATH` — `code-server` (verb 18) and
/// `baguette` (verb 21).
///
/// `~/.local/bin` FIRST and Homebrew after: a service installed there is the hand-managed copy, so
/// where both exist that is the one the operator meant. The Apple-silicon prefix leads the Homebrew
/// pair. The tail exists at all because hostd is launched by `nohup`/launchd rather than a login
/// shell, so its inherited `PATH` routinely misses every one of them.
///
/// An absent or blank `HOME` drops the first entry rather than inventing `/.local/bin`, which is
/// a directory no host has and a candidate no walk should stat.
#[must_use]
pub fn host_service_fallback_dirs(home: Option<&str>) -> Vec<PathBuf> {
    let mut directories = Vec::with_capacity(3);
    if let Some(home) = home.filter(|value| !value.is_empty()) {
        directories.push(Path::new(home).join(".local/bin"));
    }
    directories.push(PathBuf::from("/opt/homebrew/bin"));
    directories.push(PathBuf::from("/usr/local/bin"));
    directories
}

/// Candidate SDK roots, most authoritative first: the two environment variables Google documents,
/// then Android Studio's default, then the version-manager trees.
///
/// `mise`/`asdf` install one directory per version, so those are ENUMERATED rather than guessed — a
/// hard-coded version number would rot on the user's next upgrade.
#[must_use]
#[expect(
    clippy::implicit_hasher,
    reason = "the environment bag is built by this crate or its tests, never handed in with another hasher"
)]
pub fn sdk_roots(environment: &HashMap<String, String>) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Some(value) = environment.get(variable).filter(|value| !value.is_empty()) {
            roots.push(PathBuf::from(value));
        }
    }
    let Some(home) = environment.get("HOME").filter(|value| !value.is_empty()) else {
        return roots;
    };
    let home = Path::new(home);
    roots.push(home.join("Library/Android/sdk"));
    for managed in [
        ".local/share/mise/installs/android-sdk",
        ".asdf/installs/android-sdk",
    ] {
        let parent = home.join(managed);
        let Ok(entries) = std::fs::read_dir(&parent) else {
            continue;
        };
        let mut versions: Vec<PathBuf> = entries.filter_map(|entry| entry.ok().map(|e| e.path())).collect();
        // Newest-looking first, so a host with several SDKs installed does not answer with the
        // oldest one purely because its name sorts first.
        versions.sort_by(|left, right| right.cmp(left));
        roots.extend(versions);
    }
    roots
}

/// The `scrcpy-server` jar. Not an executable and not on `PATH`, so it never went through the
/// binary locator at all.
///
/// `SLOPDESK_ANDROID_SERVER_JAR` overrides everything, for anyone running scrcpy from a build tree;
/// Homebrew's `share/scrcpy` stays below the vendored copy so a `brew install scrcpy` host keeps
/// mirroring when the daemon runs outside a checkout.
#[must_use]
#[expect(
    clippy::implicit_hasher,
    reason = "the environment bag is built by this crate or its tests, never handed in with another hasher"
)]
pub fn locate_scrcpy_server_jar(
    environment: &HashMap<String, String>,
    vendored_jar: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(override_path) = environment
        .get("SLOPDESK_ANDROID_SERVER_JAR")
        .filter(|value| !value.is_empty())
    {
        let path = PathBuf::from(override_path);
        return path.is_file().then_some(path);
    }
    if let Some(jar) = vendored_jar
        && jar.is_file()
    {
        return Some(jar.to_path_buf());
    }
    for prefix in ["/opt/homebrew", "/usr/local"] {
        let candidate = Path::new(prefix).join("share/scrcpy/scrcpy-server");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Whether `path` is a file this process could exec.
#[must_use]
fn is_executable(path: &Path) -> bool {
    // `metadata` follows symlinks, which is what a locator wants: `/opt/homebrew/bin/adb` is one.
    std::fs::metadata(path).is_ok_and(|metadata| {
        metadata.is_file() && std::os::unix::fs::MetadataExt::mode(&metadata) & 0o111 != 0
    })
}

/// Runs a tool and returns its merged stdout/stderr as text, or `None` when the exec failed or the
/// deadline passed.
///
/// **The timeout is not optional.** `adb` blocks indefinitely on a device that has wedged (a
/// half-booted emulator answers the transport and never the shell). A timed-out probe reports
/// "cannot say" and the panel keeps its last-known list.
///
/// Lossy UTF-8 on purpose: `adb` and `emulator` print whatever a device handed them, and a command
/// whose output has one bad byte still has to report the rest.
#[must_use]
pub fn run(binary: &Path, arguments: &[&str], timeout: Duration) -> Option<String> {
    capture(binary, arguments, timeout, true).map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// The same run, as BYTES.
///
/// Separate from [`run`] for one operation — `screencap`, whose output is a PNG. Decoding that as
/// UTF-8 and re-encoding it would not round-trip: every byte that is not valid UTF-8 becomes a
/// replacement character, which is most of a compressed image. `merge_stderr` is false there for
/// the same reason: folded into a PNG, a tool's complaint is a corrupt file with a warning spliced
/// through it.
#[must_use]
pub fn capture(binary: &Path, arguments: &[&str], timeout: Duration, merge_stderr: bool) -> Option<Vec<u8>> {
    let mut command = Command::new(binary);
    command
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(if merge_stderr { Stdio::piped() } else { Stdio::null() })
        // stdin must not be the caller's terminal: `adb` inherits it and a stray tool that reads a
        // line would take the daemon's own input.
        .stdin(Stdio::null());
    let mut child = command.spawn().ok()?;

    // Drain on threads rather than after `wait`: a tool that fills the 64 KiB pipe buffer blocks in
    // `write` forever if nobody is reading, and a real device's property dump clears that easily.
    let (sender, receiver) = mpsc::channel();
    if let Some(mut stdout) = child.stdout.take() {
        let sender = sender.clone();
        drop(std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ignored = stdout.read_to_end(&mut bytes);
            let _ignored = sender.send((0_u8, bytes));
        }));
    }
    if let Some(mut stderr) = child.stderr.take() {
        let sender = sender.clone();
        drop(std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ignored = stderr.read_to_end(&mut bytes);
            let _ignored = sender.send((1_u8, bytes));
        }));
    }
    drop(sender);

    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {},
            Err(_error) => return None,
        }
        if Instant::now() >= deadline {
            let _ignored = child.kill();
            let _ignored = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    // The drain threads end when the child's last writer closes, which the exit above guarantees.
    // A bounded receive keeps a wedged descriptor from stranding the caller anyway.
    let mut stdout_bytes = Vec::new();
    let mut stderr_bytes = Vec::new();
    while let Ok((which, bytes)) = receiver.recv_timeout(Duration::from_secs(2)) {
        if which == 0 {
            stdout_bytes = bytes;
        } else {
            stderr_bytes = bytes;
        }
    }
    stdout_bytes.extend_from_slice(&stderr_bytes);
    Some(stdout_bytes)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use super::{
        capture, host_service_fallback_dirs, locate_scrcpy_server_jar, locate_sdk_tool, locate_tool, run,
        sdk_roots,
    };

    fn environment(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    /// A private directory tree per case, removed on drop.
    ///
    /// Every locator case builds its own and injects it. Nothing here reads the developer's real
    /// machine — a locator test that consults the real `PATH` passes or fails according to what the
    /// person running it happens to have installed, which is the opposite of a test.
    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        /// The name is the CASE's, not a random one: `Math::random` is unavailable in this tree's
        /// test discipline anyway, and a fixed name per case is also a directory you can go and
        /// look at when one fails.
        fn new(case: &str) -> Self {
            let root = std::env::temp_dir().join(format!("androidd-toolchain-{case}"));
            let _ignored = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).expect("creates the tree root");
            Self { root }
        }

        fn path(&self, relative: &str) -> PathBuf {
            self.root.join(relative)
        }

        /// Writes a file at `relative` and returns its path.
        fn file(&self, relative: &str) -> PathBuf {
            let path = self.path(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("creates the parent");
            }
            std::fs::write(&path, "#!/bin/sh\n").expect("writes the file");
            path
        }

        /// The same, `chmod +x` — what a locator will actually accept.
        fn executable(&self, relative: &str) -> PathBuf {
            let path = self.file(relative);
            std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
                .expect("marks it executable");
            path
        }

        fn string(&self, relative: &str) -> String {
            self.path(relative).to_string_lossy().into_owned()
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ignored = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn adb_prefers_the_vendored_prefix_over_an_sdk_root() {
        // The pinned copy is the one `make provision` put there and the one the gates measure
        // against; a host that also has an SDK install must not silently run that one instead.
        let tree = Tree::new("adb-prefers-vendored");
        let vendored = tree.executable("prefix/bin/adb");
        tree.executable("sdk/platform-tools/adb");

        let env = environment(&[("PATH", ""), ("ANDROID_HOME", &tree.string("sdk"))]);
        assert_eq!(
            locate_sdk_tool(
                "adb",
                "platform-tools",
                "SLOPDESK_ADB_BIN",
                &env,
                Some(&tree.path("prefix/bin"))
            ),
            Some(vendored)
        );
    }

    #[test]
    fn the_emulator_still_resolves_from_the_hosts_sdk() {
        // The emulator is deliberately NOT provisioned, so its lookup is handed no prefix and must
        // reach the host's SDK. A prefix that accidentally shadowed it would break AVD booting on
        // every machine while looking like it worked.
        let tree = Tree::new("emulator-from-sdk");
        let sdk_emulator = tree.executable("sdk/emulator/emulator");

        let env = environment(&[("PATH", ""), ("ANDROID_HOME", &tree.string("sdk"))]);
        assert_eq!(
            locate_sdk_tool(
                "emulator",
                "emulator",
                "SLOPDESK_ANDROID_EMULATOR_BIN",
                &env,
                None
            ),
            Some(sdk_emulator)
        );
    }

    #[test]
    fn the_committed_scrcpy_jar_wins() {
        let tree = Tree::new("scrcpy-committed");
        let vendored = tree.file("vendor/scrcpy-server");
        assert_eq!(
            locate_scrcpy_server_jar(&environment(&[]), Some(&vendored)),
            Some(vendored)
        );
    }

    #[test]
    fn an_absent_committed_jar_does_not_short_circuit_the_rest_of_the_search() {
        // Outside a checkout the committed jar is unreachable; a `brew install scrcpy` host must
        // keep mirroring rather than regress to "no scrcpy-server".
        let tree = Tree::new("scrcpy-absent");
        let missing = tree.path("nothing-here");
        // Whatever this machine has (a Homebrew jar or nothing) — the claim is only that an absent
        // vendored jar does not short-circuit the rest of the search.
        assert_ne!(
            locate_scrcpy_server_jar(&environment(&[]), Some(&missing)),
            Some(missing)
        );
    }

    #[test]
    fn a_named_but_broken_override_is_an_error_not_a_fallback() {
        // An operator who pointed at a path meant that path; quietly using a different `adb` is how
        // a bisect reports the wrong verdict.
        let env = environment(&[
            ("SLOPDESK_ADB_BIN", "/definitely/not/here/adb"),
            ("PATH", "/bin:/usr/bin"),
        ]);
        assert_eq!(
            locate_sdk_tool("adb", "platform-tools", "SLOPDESK_ADB_BIN", &env, None),
            None
        );
    }

    #[test]
    fn a_working_override_wins_over_every_other_candidate() {
        let env = environment(&[("SLOPDESK_ADB_BIN", "/bin/sh"), ("PATH", "/bin:/usr/bin")]);
        assert_eq!(
            locate_sdk_tool("sh", "platform-tools", "SLOPDESK_ADB_BIN", &env, None),
            Some(PathBuf::from("/bin/sh"))
        );
    }

    #[test]
    fn path_is_searched_in_order_and_a_non_executable_is_skipped() {
        let env = environment(&[("PATH", "/definitely/not/here:/bin")]);
        assert_eq!(
            locate_sdk_tool("sh", "platform-tools", "SLOPDESK_ADB_BIN", &env, None),
            Some(PathBuf::from("/bin/sh"))
        );
    }

    #[test]
    fn the_documented_sdk_variables_outrank_the_studio_default() {
        let env = environment(&[
            ("ANDROID_HOME", "/opt/sdk-a"),
            ("ANDROID_SDK_ROOT", "/opt/sdk-b"),
            ("HOME", "/Users/nobody"),
        ]);
        let roots = sdk_roots(&env);
        assert_eq!(roots.first().map(PathBuf::as_path), Some(Path::new("/opt/sdk-a")));
        assert_eq!(roots.get(1).map(PathBuf::as_path), Some(Path::new("/opt/sdk-b")));
        assert_eq!(
            roots.get(2).map(PathBuf::as_path),
            Some(Path::new("/Users/nobody/Library/Android/sdk"))
        );
    }

    #[test]
    fn a_missing_home_does_not_invent_a_root() {
        assert_eq!(sdk_roots(&environment(&[])), Vec::<PathBuf>::new());
    }

    #[test]
    fn a_jar_override_that_does_not_exist_refuses_rather_than_falling_back() {
        let env = environment(&[("SLOPDESK_ANDROID_SERVER_JAR", "/nowhere/scrcpy-server")]);
        assert_eq!(locate_scrcpy_server_jar(&env, None), None);
    }

    #[test]
    fn a_tool_that_prints_is_captured_whole() {
        let output = run(
            Path::new("/bin/echo"),
            &["hello", "world"],
            Duration::from_secs(5),
        );
        assert_eq!(output.as_deref(), Some("hello world\n"));
    }

    #[test]
    fn stderr_is_folded_in_for_text_and_dropped_for_bytes() {
        let script = "printf out; printf err >&2";
        let merged = capture(
            Path::new("/bin/sh"),
            &["-c", script],
            Duration::from_secs(5),
            true,
        )
        .expect("the shell runs");
        assert_eq!(String::from_utf8_lossy(&merged), "outerr");
        let clean = capture(
            Path::new("/bin/sh"),
            &["-c", script],
            Duration::from_secs(5),
            false,
        )
        .expect("the shell runs");
        assert_eq!(String::from_utf8_lossy(&clean), "out");
    }

    #[test]
    fn a_wedged_tool_is_killed_at_the_deadline_rather_than_parking_the_caller() {
        // The whole reason the timeout is not optional: `adb` blocks forever on a half-booted
        // emulator, and every caller here is answering something.
        let started = std::time::Instant::now();
        let output = run(Path::new("/bin/sleep"), &["30"], Duration::from_millis(300));
        assert_eq!(output, None);
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the deadline was enforced"
        );
    }

    /// The order hostd's services take, end to end. Same function the SDK tools take, so the two
    /// cannot come to disagree about which rung wins.
    #[test]
    fn a_host_service_takes_the_vendored_prefix_over_path_and_the_tail() {
        let tree = Tree::new("host-service-order");
        let vendored = tree.executable("prefix/bin/code-server");
        tree.executable("homebrew/bin/code-server");
        tree.executable("home/.local/bin/code-server");

        let tail = host_service_fallback_dirs(Some(&tree.string("home")));
        assert_eq!(
            locate_tool(
                "code-server",
                None,
                &tree.string("homebrew/bin"),
                Some(&tree.path("prefix/bin")),
                &tail
            ),
            Some(vendored)
        );
    }

    /// An unprovisioned checkout must not become an unusable one: `PATH` still answers, and the
    /// tail after it.
    #[test]
    fn an_unprovisioned_host_falls_through_to_path_and_then_the_tail() {
        let tree = Tree::new("host-service-fallthrough");
        let on_path = tree.executable("homebrew/bin/baguette");
        let in_tail = tree.executable("home/.local/bin/other-tool");

        let tail = host_service_fallback_dirs(Some(&tree.string("home")));
        assert_eq!(
            locate_tool(
                "baguette",
                None,
                &tree.string("homebrew/bin"),
                Some(&tree.path("prefix/bin")),
                &tail
            ),
            Some(on_path)
        );
        // Nothing on `PATH` this time — the tail is what answers.
        assert_eq!(locate_tool("other-tool", None, "", None, &tail), Some(in_tail));
    }

    /// The divergence this port removed, in the direction Swift got wrong. `access(X_OK)` — which
    /// is what `FileManager.isExecutableFile` answers — is TRUE for a directory, so a directory
    /// named like the tool on `PATH` used to be handed to `posix_spawn`.
    #[test]
    fn a_directory_wearing_the_tools_name_is_not_a_candidate() {
        let tree = Tree::new("directory-not-a-binary");
        std::fs::create_dir_all(tree.path("bin/code-server")).expect("creates the decoy directory");
        let real = tree.executable("later/code-server");

        let path = format!("{}:{}", tree.string("bin"), tree.string("later"));
        assert_eq!(locate_tool("code-server", None, &path, None, &[]), Some(real));
    }

    /// A file with no execute bit at all is skipped and the search continues past it, rather than
    /// the first name-match ending the walk. `is_executable` is a MODE test on purpose: it is one
    /// stated rule both callers now share, and a candidate that passes it and still cannot be
    /// `exec`d (a mode this user's ids do not reach) fails at spawn, where both callers already
    /// report the service unavailable.
    #[test]
    fn a_name_match_with_no_execute_bit_does_not_stop_the_search() {
        let tree = Tree::new("unexecutable-candidate");
        let unreadable = tree.file("first/baguette");
        std::fs::set_permissions(&unreadable, std::os::unix::fs::PermissionsExt::from_mode(0o644))
            .expect("marks it non-executable");
        let real = tree.executable("second/baguette");

        let path = format!("{}:{}", tree.string("first"), tree.string("second"));
        assert_eq!(locate_tool("baguette", None, &path, None, &[]), Some(real));
    }

    /// An exported-but-blank override is a shell accident, not a request to find nothing.
    #[test]
    fn a_blank_override_is_the_same_as_an_absent_one() {
        let tree = Tree::new("blank-override");
        let real = tree.executable("bin/code-server");
        assert_eq!(
            locate_tool("code-server", Some(""), &tree.string("bin"), None, &[]),
            Some(real)
        );
    }

    /// Empty `PATH` entries — a leading, trailing or doubled colon — are skipped rather than read
    /// as the current directory, which would make the answer depend on where hostd was launched.
    #[test]
    fn empty_path_entries_are_not_the_working_directory() {
        let tree = Tree::new("empty-path-entries");
        let real = tree.executable("bin/adb");
        let path = format!("::{}::", tree.string("bin"));
        assert_eq!(locate_tool("adb", None, &path, None, &[]), Some(real));
    }

    /// A host with no `HOME` gets Homebrew and nothing invented above it.
    #[test]
    fn a_homeless_host_does_not_invent_a_local_bin() {
        assert_eq!(host_service_fallback_dirs(None), vec![
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
        ]);
        assert_eq!(
            host_service_fallback_dirs(Some("")),
            host_service_fallback_dirs(None)
        );
        assert_eq!(
            host_service_fallback_dirs(Some("/Users/nobody")).first().cloned(),
            Some(PathBuf::from("/Users/nobody/.local/bin"))
        );
    }

    #[test]
    fn a_binary_that_does_not_exist_is_none_rather_than_a_panic() {
        assert_eq!(
            run(Path::new("/nowhere/at/all"), &[], Duration::from_secs(1)),
            None
        );
    }
}
