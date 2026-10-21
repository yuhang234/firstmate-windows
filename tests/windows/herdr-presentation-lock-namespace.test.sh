#!/usr/bin/env bash
# tests/windows/herdr-presentation-lock-namespace.test.sh -
# fm_backend_herdr_presentation_lock_namespace, ..._lock_namespace_valid, and
# ..._presentation_session_lock_path (bin/backends/herdr.sh) on both hosts.
#
# The Windows regression this file locks down: MSYS cannot apply POSIX mode
# bits, so `mkdir -m 700 <dir>` creates the directory and then fails with
# "cannot change permissions" (the mode stays 755) and `chmod` is a silent
# no-op. Requiring mode 700 therefore refused the lock namespace inside the
# machine-wide temp directory, ..._presentation_session_lock_path returned
# non-zero, and every spawn printed "herdr presentation focus lock unavailable;
# using the ordinary flat layout". The visible result was that no task ever got
# its own presentation space: every worker became a tab inside the captain's own
# workspace, at the top of the Herdr sidebar, next to the tabs the captain
# creates by hand.
#
# The fix keeps one account-scoped namespace for every home on the account, but
# on Windows places it under the account's own profile root, where Windows ACLs
# provide the privacy POSIX mode 700 provides, and replaces the mode proof with
# that location plus the unchanged ownership proof. POSIX behaviour stays
# byte-identical.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=bin/fm-platform-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/fm-platform-lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
TMP_ROOT=$(fm_test_tmproot fm-windows-herdr-lock)

# The real mkdir, captured before any fakebin is prepended to PATH.
REAL_MKDIR=$(command -v mkdir)

# --- fakebin: a fake `uname` and an MSYS-faithful `mkdir` --------------------
WINFAKE="$TMP_ROOT/winfake"
mkdir -p "$WINFAKE"
printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' >"$WINFAKE/uname"
chmod +x "$WINFAKE/uname"
# MSYS `mkdir -m 700 <dir>`: the directory IS created, then the mode is
# refused and mkdir exits 1. Reproducing that here means the Windows cases fail
# on the pre-fix code on a POSIX host too, not only on real Windows.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -u\n'
  printf 'out=()\nskip=0\nsaw_mode=0\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$skip" = 1 ]; then skip=0; continue; fi\n'
  printf '  case "$a" in\n'
  printf '    -m) saw_mode=1; skip=1; continue ;;\n'
  printf '    -m?*) saw_mode=1; continue ;;\n'
  printf '  esac\n'
  printf '  out+=("$a")\n'
  printf 'done\n'
  printf 'if [ "$saw_mode" = 1 ]; then\n'
  printf '  %s "${out[@]}" 2>/dev/null || true\n' "$REAL_MKDIR"
  printf '  echo "mkdir: cannot change permissions of a directory: Permission denied" >&2\n'
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$REAL_MKDIR"
} >"$WINFAKE/mkdir"
chmod +x "$WINFAKE/mkdir"

# --- fake herdr: always answers `session list --json` ------------------------
HERDRBIN="$TMP_ROOT/herdrbin"
mkdir -p "$HERDRBIN" "$TMP_ROOT/sockdir"
: >"$TMP_ROOT/sockdir/fmtest.sock"
cat >"$HERDRBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_HERDR_ARGLOG:-}" ] || printf '%s\n' "$*" >> "$FM_HERDR_ARGLOG"
cat "${FM_HERDR_SESSIONS:?}"
SH
chmod +x "$HERDRBIN/herdr"

# A Windows-shaped socket (the real shape on Git Bash/MSYS) and a POSIX one.
printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"C:\\\\Users\\\\fm-test\\\\AppData\\\\Roaming\\\\herdr\\\\herdr.sock\"}]}" \
  >"$TMP_ROOT/sessions-windows.json"
printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$TMP_ROOT/sockdir/fmtest.sock\"}]}" \
  >"$TMP_ROOT/sessions-posix.json"

# fm_lock_case <windows|posix> <localappdata> <function> [args...]
# Runs the real backend function in a fresh bash whose PATH carries the fake
# herdr, plus the fake `uname`/`mkdir` for the Windows cases.
fm_lock_case() {
  local kind=$1 la=$2
  shift 2
  cat >"$TMP_ROOT/case.sh" <<'CASE'
set -u
kind=$1; la=$2; root=$3; winfake=$4; herdrbin=$5; sessions_dir=$6
shift 6
if [ "$kind" = windows ]; then
  PATH="$winfake:$herdrbin:$PATH"
  FM_HERDR_SESSIONS="$sessions_dir/sessions-windows.json"
else
  PATH="$herdrbin:$PATH"
  FM_HERDR_SESSIONS="$sessions_dir/sessions-posix.json"
fi
export PATH FM_HERDR_SESSIONS
export LOCALAPPDATA="$la"
cd "$root" || exit 9
. ./bin/backends/herdr.sh
"$@"
CASE
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
    bash "$TMP_ROOT/case.sh" "$kind" "$la" "$ROOT" "$WINFAKE" "$HERDRBIN" "$TMP_ROOT" "$@"
}

fm_lock_rc() {
  local kind=$1 la=$2 status
  shift 2
  fm_lock_case "$kind" "$la" "$@" >/dev/null 2>&1
  status=$?
  printf '%s' "$status"
}

if fm_platform_is_windows; then
  echo "note: running on a real Windows host; the Windows cases run for real"
fi

UID_NOW=$(id -u)

# --- Windows branch (real on Windows, fake-uname on POSIX) -------------------
LA="$TMP_ROOT/profile"
mkdir -p "$LA"

ns=$(fm_lock_case windows "$LA" fm_backend_herdr_presentation_lock_namespace) \
  || fail "windows: lock namespace resolution failed"

# The root cause, and the state-independent part of the regression: a directory
# this account created with the ordinary default mode is exactly what MSYS
# produces for the namespace. Refusing it disabled presentation projection
# entirely, which is what put every worker in the captain's own workspace.
plain="$TMP_ROOT/plain-ns"
mkdir -p "$plain"
rc=$(fm_lock_rc windows "$LA" fm_backend_herdr_presentation_lock_namespace_valid "$plain")
expect_code 0 "$rc" "windows: a plain (mode 755) namespace directory must be accepted"
pass "herdr presentation lock: Windows accepts an MSYS-created namespace directory"

# Location and symlink proofs still hold on Windows.
linked="$TMP_ROOT/linked-ns"
ln -s "$plain" "$linked" 2>/dev/null || true
if [ -L "$linked" ]; then
  rc=$(fm_lock_rc windows "$LA" fm_backend_herdr_presentation_lock_namespace_valid "$linked")
  [ "$rc" != 0 ] || fail "windows: a symlinked namespace must be refused"
  pass "herdr presentation lock: Windows still refuses a symlinked namespace"
fi
rc=$(fm_lock_rc windows "$LA" fm_backend_herdr_presentation_lock_namespace_valid "$TMP_ROOT/absent-ns")
[ "$rc" != 0 ] || fail "windows: a missing namespace must be refused"
pass "herdr presentation lock: Windows refuses a missing namespace"

# The behaviour the captain sees: with the namespace accepted, the spawn's
# presentation path resolves instead of falling back to the flat layout.
path=$(fm_lock_case windows "$LA" fm_backend_herdr_presentation_session_lock_path fmtest) \
  || fail "windows: presentation session lock path must resolve (MSYS cannot set mode 700)"
case "$path" in
  "$ns"/order-*.lock) ;;
  *) fail "windows: lock path is outside the namespace: [$path]" ;;
esac
[ -d "$ns" ] || fail "windows: resolving the lock path must create the namespace directory"
pass "herdr presentation lock: Windows lock path resolves under MSYS mode-bit limits"

[ "$ns" = "$LA/firstmate/herdr-presentation-$UID_NOW" ] \
  || fail "windows: namespace must live under the account profile root: [$ns]"
case "$ns" in
  /tmp/firstmate-herdr-presentation-*)
    fail "windows: namespace must not use the machine-wide temp directory: [$ns]"
    ;;
esac
pass "herdr presentation lock: Windows namespace is account-private under the profile root"

# --- POSIX behaviour must stay byte-identical -------------------------------
if ! fm_platform_is_windows; then
  posix_la="$TMP_ROOT/profile-posix"
  mkdir -p "$posix_la"
  # LOCALAPPDATA is irrelevant on POSIX: the namespace stays in /tmp.
  ns_posix=$(fm_lock_case posix "$posix_la" fm_backend_herdr_presentation_lock_namespace) \
    || fail "POSIX: lock namespace resolution failed"
  [ "$ns_posix" = "/tmp/firstmate-herdr-presentation-$UID_NOW" ] \
    || fail "POSIX: namespace changed: [$ns_posix]"
  pass "herdr presentation lock: POSIX namespace is unchanged"

  path_posix=$(fm_lock_case posix "$posix_la" fm_backend_herdr_presentation_session_lock_path fmtest) \
    || fail "POSIX: presentation session lock path must resolve"
  case "$path_posix" in
    "/tmp/firstmate-herdr-presentation-$UID_NOW"/order-*.lock) ;;
    *) fail "POSIX: lock path changed: [$path_posix]" ;;
  esac
  pass "herdr presentation lock: POSIX lock path is unchanged"

  # The mode proof is a real requirement on POSIX and must not be relaxed.
  loose="$TMP_ROOT/loose-ns"
  mkdir -p "$loose"
  chmod 755 "$loose"
  rc=$(fm_lock_rc posix "$posix_la" fm_backend_herdr_presentation_lock_namespace_valid "$loose")
  [ "$rc" != 0 ] || fail "POSIX: a mode-755 namespace must still be refused"
  tight="$TMP_ROOT/tight-ns"
  mkdir -p "$tight"
  chmod 700 "$tight"
  rc=$(fm_lock_rc posix "$posix_la" fm_backend_herdr_presentation_lock_namespace_valid "$tight")
  expect_code 0 "$rc" "POSIX: a mode-700 namespace must be accepted"
  pass "herdr presentation lock: POSIX keeps the mode-700 ownership proof"
fi

echo "herdr presentation lock namespace tests: done"
