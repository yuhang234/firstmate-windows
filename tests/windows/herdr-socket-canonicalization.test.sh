#!/usr/bin/env bash
# tests/windows/herdr-socket-canonicalization.test.sh -
# fm_backend_herdr_canonical_socket_path (bin/backends/herdr.sh) on both
# hosts. Upstream issue #3283: the POSIX-only canonicalizer refused every
# Windows socket path outright, so a live Windows herdr server could never
# be resolved. The Windows branch must canonicalize drive-letter and
# named-pipe paths while POSIX behaviour stays byte-identical.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=bin/fm-platform-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/fm-platform-lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

TMP_ROOT=$(fm_test_tmproot fm-windows-herdr-socket)

# A fakebin whose `uname -s` reports MINGW64, so the Windows branch runs
# on a POSIX host.
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-win-uname.XXXXXX")
mkdir -p "$FAKE"
printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' >"$FAKE/uname"
chmod +x "$FAKE/uname"

# fm_canon_case <uname-dir|-> <socket-path>: run the real backend
# canonicalizer in a fresh bash with the chosen uname. Prints the
# canonical form on stdout; prints CANON_RC=<n> on stderr.
fm_canon_case() {
  local uname_dir=$1 socket=$2
  cat >"$TMP_ROOT/case.sh" <<'CASE'
set -u
if [ "$1" != "-" ]; then PATH="$1:$PATH"; export PATH; fi
cd "$3"
. ./bin/fm-backend.sh
fm_backend_source herdr >/dev/null 2>&1
out=$(fm_backend_herdr_canonical_socket_path "$2")
rc=$?
printf '%s\n' "$out"
printf 'CANON_RC=%s\n' "$rc" >&2
CASE
  bash "$TMP_ROOT/case.sh" "$uname_dir" "$socket" "$ROOT"
}

fm_canon_rc() {
  fm_canon_case "$1" "$2" 2>&1 >/dev/null | sed -n 's/^CANON_RC=//p'
}

if fm_platform_is_windows; then
  UNAME_DIR="-"
  echo "note: running on a real Windows host; the Windows branch runs for real"
else
  UNAME_DIR="$FAKE"
fi

# --- Windows branch (real on Windows, fake-uname on POSIX) ------------------
out=$(fm_canon_case "$UNAME_DIR" 'C:\Users\fuyou\AppData\Roaming\herdr\herdr.sock' 2>/dev/null)
rc=$(fm_canon_rc "$UNAME_DIR" 'C:\Users\fuyou\AppData\Roaming\herdr\herdr.sock')
expect_code 0 "$rc" "windows: drive-letter socket must canonicalize (#3283)"
[ "$out" = C:/Users/fuyou/AppData/Roaming/herdr/herdr.sock ] \
  || fail "windows: canonical form mismatch: [$out]"
pass "herdr socket: Windows drive-letter path canonicalizes (#3283)"

# A lowercase drive letter upper-cases, so two spellings compare equal.
lower=$(fm_canon_case "$UNAME_DIR" 'c:/users/fuyou/appdata/roaming/herdr/herdr.sock' 2>/dev/null)
[ "${lower%%:*}" = C ] || fail "windows: drive letter not upper-cased: [$lower]"
pass "herdr socket: lowercase drive letter upper-cases"

# A named pipe is separator-normalized, not treated as a filesystem path.
out=$(fm_canon_case "$UNAME_DIR" '\\.\pipe\herdr' 2>/dev/null)
rc=$(fm_canon_rc "$UNAME_DIR" '\\.\pipe\herdr')
expect_code 0 "$rc" "windows: named-pipe socket must canonicalize"
[ "$out" = //./pipe/herdr ] || fail "windows: named-pipe form mismatch: [$out]"
pass "herdr socket: Windows named-pipe path canonicalizes"

# Two spellings of one socket must compare equal (the identity contract).
a=$(fm_canon_case "$UNAME_DIR" 'C:\Users\fuyou\AppData\Roaming\herdr\herdr.sock' 2>/dev/null)
b=$(fm_canon_case "$UNAME_DIR" 'C:/Users/fuyou/AppData/Roaming/herdr/herdr.sock' 2>/dev/null)
[ "$a" = "$b" ] || fail "windows: spellings of one socket differ: [$a] vs [$b]"
pass "herdr socket: two spellings of one Windows socket compare equal"

# A relative path is still refused on Windows.
rc=$(fm_canon_rc "$UNAME_DIR" herdr.sock)
[ "$rc" != 0 ] || fail "windows: relative socket must be refused"
pass "herdr socket: relative path refused on Windows too"

# --- POSIX behaviour must stay byte-identical --------------------------------
if ! fm_platform_is_windows; then
  # On a POSIX host a Windows-shaped path is still refused, exactly as
  # before the Windows branch existed.
  rc=$(fm_canon_rc - 'C:\Users\fuyou\herdr.sock')
  [ "$rc" != 0 ] || fail "POSIX: a Windows-shaped socket must still be refused"
  pass "herdr socket: POSIX still refuses a Windows-shaped path"
fi

# An MSYS-spelled socket on Windows falls through to the POSIX branch.
out=$(fm_canon_case "$UNAME_DIR" /tmp/herdr.sock 2>/dev/null)
rc=$(fm_canon_rc "$UNAME_DIR" /tmp/herdr.sock)
expect_code 0 "$rc" "windows: an MSYS-spelled socket must still canonicalize"
[ "$out" = /tmp/herdr.sock ] || fail "windows: MSYS-spelled form changed: [$out]"
pass "herdr socket: MSYS-spelled socket keeps the POSIX canonical form"

echo "herdr socket canonicalization tests: done"
