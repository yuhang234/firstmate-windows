#!/usr/bin/env bash
# tests/windows/fm-platform-lib.test.sh - the platform primitives
# (bin/fm-platform-lib.sh) on both hosts. On POSIX the real runtime is
# exercised; the Windows branches are driven behind a fake `uname` so the
# same file covers Git Bash without a Windows runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
LIB="$ROOT/bin/fm-platform-lib.sh"

# fm_fake_uname_dir <dir>: a fakebin whose `uname -s` reports MINGW64, so
# fm_platform_is_windows is true on a POSIX host.
fm_fake_uname_dir() {
  local dir=$1
  mkdir -p "$dir"
  printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' >"$dir/uname"
  chmod +x "$dir/uname"
}

# fm_fake_failing_ln_dir <dir>: a fakebin whose `ln` always fails, standing
# in for a Git Bash without symlink privilege (upstream issue #3267).
fm_fake_failing_ln_dir() {
  local dir=$1
  mkdir -p "$dir"
  printf '#!/bin/sh\nexit 1\n' >"$dir/ln"
  chmod +x "$dir/ln"
}

TMP_ROOT=$(fm_test_tmproot fm-windows-platform)

# --- POSIX behaviour (byte-identical to the historical inline commands) ----
. "$LIB"
if fm_platform_is_windows; then
  # A real Windows host: the POSIX assertions below do not apply; the
  # Windows cases further down cover it for real.
  echo "note: running on a real Windows host"
else
  fm_platform_is_windows && fail "is_windows must be false on POSIX"
  pass "platform: POSIX detection"
  [ "$(fm_platform_uname)" = "$(uname -s)" ] || fail "uname cache disagrees with uname"
  pass "platform: uname cache"
  # win_to_posix passes a POSIX path through unchanged.
  [ "$(fm_platform_win_to_posix /already/posix)" = /already/posix ] \
    || fail "win_to_posix must pass a POSIX path through"
  pass "platform: win_to_posix POSIX passthrough"
  # link_or_marker on POSIX is exactly `ln -s`.
  owner="$TMP_ROOT/posix-owner"
  link="$TMP_ROOT/posix-link"
  mkdir -p "$owner"
  fm_platform_link_or_marker "$link" "$owner" || fail "link_or_marker failed on POSIX"
  [ "$FM_PLATFORM_LINK_MODE" = symlink ] \
    || fail "POSIX link mode must be symlink, got $FM_PLATFORM_LINK_MODE"
  [ -L "$link" ] || fail "POSIX link must be a real symlink"
  [ "$(fm_platform_link_target "$link")" = "$owner" ] \
    || fail "POSIX link target mismatch"
  fm_platform_link_is_link "$link" || fail "POSIX link_is_link false negative"
  fm_platform_remove_link "$link" || fail "POSIX remove_link failed"
  [ ! -e "$link" ] || fail "POSIX remove_link left the link behind"
  [ -d "$owner" ] || fail "POSIX remove_link must not touch the target"
  pass "platform: POSIX link_or_marker is exactly ln -s"
  # A relative or empty socket path is refused on POSIX too.
  fm_platform_socket_identity relative.sock && fail "relative socket must be refused"
  fm_platform_socket_identity "" && fail "empty socket must be refused"
  pass "platform: socket identity refuses relative/empty on POSIX"
fi

# --- Windows branches, driven behind a fake uname on POSIX hosts ------------
WIN_CASES=$(mktemp -d "${TMPDIR:-/tmp}/fm-win-cases.XXXXXX")
fm_fake_uname_dir "$WIN_CASES/fakebin"
cat >"$WIN_CASES/drive.sh" <<'DRIVE'
set -u
. "$1"
fm_platform_is_windows || exit 10
# Drive-letter path conversion.
[ "$(fm_platform_win_to_posix 'C:\Users\fuyou')" = /c/Users/fuyou ] || exit 11
[ "$(fm_platform_win_to_posix 'c:/users/fuyou')" = /c/users/fuyou ] || exit 12
[ "$(fm_platform_win_to_posix 'D:\a\b c')" = /d/a/b\ c ] || exit 13
[ "$(fm_platform_posix_to_win /c/Users/fuyou)" = 'C:\Users\fuyou' ] || exit 14
# Socket identity: drive letters upper-cased, separators normalized,
# named pipes separator-normalized only, POSIX-shaped refused.
[ "$(fm_platform_socket_identity 'C:\Users\fuyou\herdr.sock')" = C:/Users/fuyou/herdr.sock ] || exit 15
[ "$(fm_platform_socket_identity 'c:/users/fuyou/herdr.sock')" = C:/users/fuyou/herdr.sock ] || exit 16
[ "$(fm_platform_socket_identity '\\.\pipe\herdr')" = //./pipe/herdr ] || exit 17
fm_platform_socket_identity /tmp/herdr.sock && exit 18
fm_platform_socket_identity relative.sock && exit 19
exit 0
DRIVE
PATH="$WIN_CASES/fakebin:$PATH" bash "$WIN_CASES/drive.sh" "$LIB"
expect_code 0 $? "windows: drive-letter conversion and socket identity"
pass "platform: Windows drive-letter paths and socket identity"

# Marker mode: no native symlink available, so link_or_marker must create
# an atomic marker DIRECTORY and report it honestly.
cat >"$WIN_CASES/marker.sh" <<'MARKER'
set -u
. "$1"
fm_platform_is_windows || exit 10
owner="$2/owner"
link="$2/link"
mkdir -p "$owner"
printf '%s\n' "$$" >"$owner/pid"
fm_platform_link_or_marker "$link" "$owner" || exit 20
[ "$FM_PLATFORM_LINK_MODE" = marker ] || exit 21
[ -d "$link" ] && [ ! -L "$link" ] || exit 22
[ "$(fm_platform_link_target "$link")" = "$owner" ] || exit 23
fm_platform_link_is_link "$link" || exit 24
# The owner pid is mirrored into the marker for stale-owner proofs.
[ "$(cat "$link/pid" 2>/dev/null)" = "$$" ] || exit 25
# A half-created marker is never mistaken for a held link: a marker
# directory without its marker file is not a link.
fm_platform_remove_link "$link" || exit 26
[ ! -e "$link" ] || exit 27
[ -d "$owner" ] || exit 28
# Removal of a marker that lost its marker file must fail, not delete data.
mkdir -p "$link"
fm_platform_remove_link "$link" && exit 29
rmdir "$link"
exit 0
MARKER
fm_fake_failing_ln_dir "$WIN_CASES/nolinkbin"
PATH="$WIN_CASES/nolinkbin:$WIN_CASES/fakebin:$PATH" \
  bash "$WIN_CASES/marker.sh" "$LIB" "$WIN_CASES"
expect_code 0 $? "windows: marker-directory link mode"
pass "platform: Windows marker-directory link mode (no silent ln copy)"

echo "fm-platform-lib windows tests: done"
