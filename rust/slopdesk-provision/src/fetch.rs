//! The download, and the digest computed on the way past.
//!
//! The shell wrote the file and then read it back to hash it. For code-server's 206 MB tarball that
//! is a second full pass over the bytes for no information the first pass did not already have.
//! Here the hasher sits between the socket and the file, so a verified download costs exactly one
//! pass — and an unverified one costs the same, because the answer is known the instant the last
//! byte lands.

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The chunk the transfer moves in.
///
/// 256 KiB rather than the 8 KiB `io::copy` would choose: these are hundred-megabyte assets over a
/// TLS socket, and the syscall count is the only thing the buffer size decides.
const CHUNK: usize = 256 * 1024;

/// What went wrong, in the vocabulary of the pin rather than of the program that failed.
#[derive(Debug)]
pub enum FetchError {
    /// The transfer itself did not complete.
    Transport {
        /// The pinned asset that was being fetched.
        url: String,
        /// What the transport said, flattened to a line.
        cause: String,
    },
    /// The bytes arrived and are not the pinned ones.
    Digest {
        /// The pinned asset the bytes came from.
        url: String,
        /// The digest `tools.lock` pins.
        expected: String,
        /// The digest the bytes actually hash to.
        got: String,
    },
    /// The filesystem refused.
    Io {
        /// The file the refusal was about.
        path: PathBuf,
        /// What the filesystem said.
        cause: io::Error,
    },
}

impl core::fmt::Display for FetchError {
    fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Transport { url, cause } => write!(out, "download failed: {url}\n  {cause}"),
            Self::Digest { url, expected, got } => {
                write!(
                    out,
                    "SHA-256 mismatch for {url}\n  expected {expected}\n  got      {got}\nA corrupt \
                     download, a re-cut upstream release, or a wrong pin — none of which are safe to run."
                )
            },
            Self::Io { path, cause } => write!(out, "{}: {cause}", path.display()),
        }
    }
}

impl std::error::Error for FetchError {}

/// The SHA-256 of a file already on disk, lowercase hex.
///
/// # Errors
/// Any read failure, naming the file.
pub fn digest_of(path: &Path) -> Result<String, FetchError> {
    let mut file = File::open(path).map_err(|cause| {
        FetchError::Io {
            path: path.to_path_buf(),
            cause,
        }
    })?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK];
    loop {
        let read = file.read(&mut buffer).map_err(|cause| {
            FetchError::Io {
                path: path.to_path_buf(),
                cause,
            }
        })?;
        if read == 0 {
            break;
        }
        // The read count is the live prefix of the buffer; `get` rather than a slice index so the
        // crate's `indexing_slicing` bar holds without an `unwrap` standing in for the proof.
        if let Some(filled) = buffer.get(..read) {
            hasher.update(filled);
        }
    }
    Ok(hex(&hasher.finalize()))
}

/// Downloads `url` to `dest`, verifying it is `sha256`.
///
/// A cached file that already matches is left alone and reported as such — this is what makes a
/// re-run after an interrupted extraction cheap.
///
/// The transfer lands on `dest.partial` and is only renamed once the digest matches, so an
/// interrupted transfer can never be mistaken for a verified one on the next run. A mismatch
/// deletes the partial rather than keeping it: bytes that are not the pinned bytes have no second
/// use.
///
/// # Errors
/// [`FetchError`], which names the pin's URL rather than the transport's own message.
pub fn fetch_verified(url: &str, sha256: &str, dest: &Path) -> Result<Cached, FetchError> {
    if dest.is_file() && digest_of(dest)?.eq_ignore_ascii_case(sha256) {
        return Ok(Cached::Already);
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).map_err(|cause| {
            FetchError::Io {
                path: parent.to_path_buf(),
                cause,
            }
        })?;
    }
    let partial = dest.with_extension("partial");
    let got = stream_to(url, &partial)?;
    if !got.eq_ignore_ascii_case(sha256) {
        // Best-effort: the mismatch is the error worth reporting, not a failure to tidy after it.
        drop(fs::remove_file(&partial));
        return Err(FetchError::Digest {
            url: url.to_owned(),
            expected: sha256.to_owned(),
            got,
        });
    }
    fs::rename(&partial, dest).map_err(|cause| {
        FetchError::Io {
            path: dest.to_path_buf(),
            cause,
        }
    })?;
    Ok(Cached::Downloaded)
}

/// Whether a verified archive was already on disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cached {
    /// It was in the transfer cache and its digest matched.
    Already,
    /// It came over the wire.
    Downloaded,
}

/// Streams `url` into `path`, returning the digest of what was written.
fn stream_to(url: &str, path: &Path) -> Result<String, FetchError> {
    let transport = |cause: String| {
        FetchError::Transport {
            url: url.to_owned(),
            cause,
        }
    };
    let mut body = ureq::get(url)
        .call()
        .map_err(|error| transport(error.to_string()))?
        .into_body()
        .into_reader();

    let file = File::create(path).map_err(|cause| {
        FetchError::Io {
            path: path.to_path_buf(),
            cause,
        }
    })?;
    let mut writer = io::BufWriter::with_capacity(CHUNK, file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK];
    loop {
        let read = body
            .read(&mut buffer)
            .map_err(|error| transport(error.to_string()))?;
        if read == 0 {
            break;
        }
        let Some(filled) = buffer.get(..read) else {
            break;
        };
        hasher.update(filled);
        writer.write_all(filled).map_err(|cause| {
            FetchError::Io {
                path: path.to_path_buf(),
                cause,
            }
        })?;
    }
    writer.flush().map_err(|cause| {
        FetchError::Io {
            path: path.to_path_buf(),
            cause,
        }
    })?;
    Ok(hex(&hasher.finalize()))
}

/// Lowercase hex, which is what every published `SHA256SUMS` is written in.
fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        // `write!` into a `String` cannot fail, and the crate bars both `unwrap` and `panic` — so
        // push the two nibbles directly rather than borrowing an infallibility nobody can see.
        out.push(nibble(byte >> 4));
        out.push(nibble(byte & 0x0F));
    }
    out
}

/// One hex digit from the low four bits.
const fn nibble(value: u8) -> char {
    match value & 0x0F {
        0..=9 => (b'0' + value) as char,
        other => (b'a' + other - 10) as char,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::fs;

    use super::{digest_of, hex};

    /// The published vector for the empty input, which pins the hex encoder and the streaming
    /// reader at once.
    const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    #[test]
    fn hex_is_lower_case_and_two_digits_a_byte() {
        assert_eq!(hex(&[0x00, 0x0F, 0xA5, 0xFF]), "000fa5ff");
        assert_eq!(hex(&[]), "");
    }

    #[test]
    fn an_empty_file_hashes_to_the_published_vector() {
        let dir = std::env::temp_dir().join("slopdesk-provision-empty-digest");
        drop(fs::remove_dir_all(&dir));
        fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("empty");
        fs::write(&path, b"").expect("write");
        assert_eq!(digest_of(&path).expect("digest"), EMPTY_SHA256);
        drop(fs::remove_dir_all(&dir));
    }

    /// Larger than one CHUNK, so the loop runs more than once and the incremental update is what is
    /// actually being pinned.
    #[test]
    fn a_multi_chunk_file_hashes_as_one_stream() {
        let dir = std::env::temp_dir().join("slopdesk-provision-chunked-digest");
        drop(fs::remove_dir_all(&dir));
        fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("big");
        let bytes = vec![0x5A_u8; super::CHUNK * 2 + 7];
        fs::write(&path, &bytes).expect("write");

        let streamed = digest_of(&path).expect("digest");
        let at_once = {
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(&bytes);
            hex(&hasher.finalize())
        };
        assert_eq!(streamed, at_once, "chunking must not change the answer");
        drop(fs::remove_dir_all(&dir));
    }

    #[test]
    fn a_missing_file_names_itself_rather_than_panicking() {
        let error = digest_of(std::path::Path::new("/nonexistent/slopdesk/provision"))
            .expect_err("a missing file fails");
        assert!(error.to_string().contains("/nonexistent/slopdesk/provision"));
    }
}
