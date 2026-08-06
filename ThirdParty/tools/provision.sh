#!/usr/bin/env bash
# provision.sh — materialise the pinned host-side runtime dependencies from `tools.lock`.
#
# Downloads each pinned release, verifies its SHA-256, extracts it under `.prefix/<name>/<version>/`
# and links `.prefix/bin/<name>` at it. Idempotent: an entry whose binary is already in place and
# whose stamp matches the pinned digest is skipped, so re-running after a lock edit re-fetches only
# what changed.
#
# This is provisioning, NOT a runtime path. `hostd` never downloads anything — it only ever LOOKS in
# `.prefix/bin`, and reports the surface unavailable when a dependency is not there. That split is
# the point: a coding host must not reach the network because someone opened a panel.
#
#   bash ThirdParty/tools/provision.sh            # provision everything in tools.lock
#   bash ThirdParty/tools/provision.sh code-server  # just one entry
#   bash ThirdParty/tools/provision.sh --check    # verify what is installed; download nothing
#
# Exit non-zero on any digest mismatch — a bad download is deleted, never kept.
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${TOOLS_DIR}/tools.lock"
PREFIX="${TOOLS_DIR}/.prefix"
CACHE="${PREFIX}/.cache"
BIN="${PREFIX}/bin"
VENDOR="${TOOLS_DIR}/vendor"

CHECK_ONLY=0
WANTED=()
for arg in "$@"; do
  case "${arg}" in
    --check) CHECK_ONLY=1 ;;
    -*) echo "unknown flag: ${arg}" >&2 && exit 2 ;;
    *) WANTED+=("${arg}") ;;
  esac
done

log() { printf '  %s\n' "$*"; }
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "${LOCK}" ]] || fail "no tools.lock next to this script (${LOCK})"

# `shasum` over `sha256sum`: the latter is not on a stock macOS.
digest_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Skip when the binary is present AND the stamp records the digest currently pinned. The stamp is
# what makes a lock edit re-provision: the bytes on disk look fine, but they are the OLD bytes.
stamp_path() { printf '%s/.stamp/%s\n' "${PREFIX}" "$1"; }

is_current() {
  local name="$1" version="$2" sha="$3" binpath="$4"
  [[ -e "${binpath}" ]] || return 1
  local stamp
  stamp="$(stamp_path "${name}")"
  [[ -f "${stamp}" ]] || return 1
  [[ "$(cat "${stamp}")" = "${version} ${sha}" ]] || return 1
  return 0
}

# Downloads to a temp name and only moves it into the cache once the digest matches, so an
# interrupted transfer can never be mistaken for a verified one on the next run.
fetch_verified() {
  local url="$1" sha="$2" dest="$3"
  if [[ -f "${dest}" ]] && [[ "$(digest_of "${dest}")" = "${sha}" ]]; then
    log "cached  $(basename "${dest}")"
    return 0
  fi
  log "fetch   ${url}"
  local tmp="${dest}.partial"
  curl -fL --retry 3 --progress-bar -o "${tmp}" "${url}" || {
    rm -f "${tmp}"
    fail "download failed: ${url}"
  }
  local got
  got="$(digest_of "${tmp}")"
  if [[ "${got}" != "${sha}" ]]; then
    rm -f "${tmp}"
    fail "SHA-256 mismatch for ${url}
  expected ${sha}
  got      ${got}
A corrupt download, a re-cut upstream release, or a wrong pin — none of which are safe to run."
  fi
  mv "${tmp}" "${dest}"
}

# Every pinned archive has exactly ONE top-level directory whose name carries the version, which is
# redundant with the `<name>/<version>/` we extract into — so it is stripped. Verified per archive;
# a future upstream that flattens its tarball would land its files one level up and fail the
# post-extract binary check rather than silently half-install.
extract_into() {
  local kind="$1" archive="$2" target="$3"
  rm -rf "${target}"
  mkdir -p "${target}"
  case "${kind}" in
    tar.gz)
      tar -xzf "${archive}" -C "${target}" --strip-components=1
      ;;
    zip)
      # `unzip` has no --strip-components; unpack to a staging dir and lift the single root.
      local staging="${target}.staging"
      rm -rf "${staging}"
      mkdir -p "${staging}"
      unzip -q "${archive}" -d "${staging}"
      local roots=("${staging}"/*)
      [[ "${#roots[@]}" -eq 1 ]] || fail "expected one top-level directory in $(basename "${archive}"), got ${#roots[@]}"
      # `.`-globbing off by default, so move the dotfiles too rather than losing them silently.
      (shopt -s dotglob && mv "${roots[0]}"/* "${target}/")
      rm -rf "${staging}"
      ;;
    *) fail "unknown archive kind: ${kind}" ;;
  esac
  # curl does not set `com.apple.quarantine` (LaunchServices does), so this is belt-and-braces for
  # anyone who hand-drops a tarball into .cache from a browser. Gatekeeper refusing to exec a
  # panel's server surfaces as "not found", which is a miserable thing to debug.
  xattr -dr com.apple.quarantine "${target}" 2> /dev/null || true
}

mkdir -p "${BIN}" "${CACHE}" "${PREFIX}/.stamp"

installed=0
skipped=0
missing=0

while IFS='|' read -r name version kind binary url sha; do
  # Comments and blank lines.
  case "${name}" in
    '' | \#*) continue ;;
    *) ;;
  esac
  if [[ "${#WANTED[@]}" -gt 0 ]]; then
    found=0
    for want in "${WANTED[@]}"; do [[ "${want}" = "${name}" ]] && found=1; done
    [[ "${found}" -eq 1 ]] || continue
  fi

  echo "${name} ${version}"

  if [[ "${kind}" = "file" ]]; then
    # Committed in the repo — verified, never downloaded. A checkout whose bytes do not match
    # the pin is a corrupt checkout (or an LFS/filter mishap), and pushing a mangled jar to a
    # phone fails in a way that reads as a device problem.
    src="${VENDOR}/${binary}"
    [[ -f "${src}" ]] || fail "${name} is committed at vendor/${binary} but that file is missing"
    got="$(digest_of "${src}")"
    [[ "${got}" = "${sha}" ]] || fail "vendor/${binary} does not match its pin
  expected ${sha}
  got      ${got}"
    log "vendored (verified) vendor/${binary}"
    skipped=$((skipped + 1))
    continue
  fi

  target="${PREFIX}/${name}/${version}"
  binpath="${target}/${binary}"

  if is_current "${name}" "${version}" "${sha}" "${binpath}"; then
    log "current  ${binpath#"${TOOLS_DIR}"/}"
    skipped=$((skipped + 1))
  elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
    log "MISSING  (run without --check to provision)"
    missing=$((missing + 1))
    continue
  else
    archive="${CACHE}/${name}-${version}-$(basename "${url}")"
    fetch_verified "${url}" "${sha}" "${archive}"
    log "extract  .prefix/${name}/${version}"
    extract_into "${kind}" "${archive}" "${target}"
    [[ -x "${binpath}" ]] || fail "${name} ${version} extracted but ${binary} is not there or not executable — the upstream archive layout changed"
    printf '%s %s' "${version}" "${sha}" > "$(stamp_path "${name}")"
    # The cache is a TRANSFER cache, not a version store: drop the archive once its contents are
    # unpacked and checked. code-server's tarball alone is 206 MB, and this is a tree developers
    # keep several checkouts of — a re-provision can pay the download again.
    rm -f "${archive}"
    installed=$((installed + 1))
  fi

  # Relative link, so the whole repo stays movable — an absolute one breaks the moment the
  # checkout is renamed, and this is exactly the tree people keep several copies of.
  ln -sfn "../${name}/${version}/${binary}" "${BIN}/${name}"
done < "${LOCK}"

echo
if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "checked: ${skipped} present, ${missing} missing"
  [[ "${missing}" -eq 0 ]] || exit 1
else
  echo "provisioned: ${installed} installed, ${skipped} already current"
  echo "prefix: ${PREFIX#"$(cd "${TOOLS_DIR}/../.." && pwd)"/}"
fi
