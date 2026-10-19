#!/usr/bin/env bash
# tests/windows/fm-windows-bootstrap.test.sh - bin/fm-windows-bootstrap.sh
# on both hosts. The Windows paths are driven behind a fake `uname`; the
# POSIX refusal and the offline-verifiable pieces run for real everywhere.
# No network access and no real %LOCALAPPDATA% writes: the download path is
# exercised through its guards (pin shape, checksum verification inputs),
# and the config edit through a fake APPDATA.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=bin/fm-platform-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/fm-platform-lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
BOOTSTRAP="$ROOT/bin/fm-windows-bootstrap.sh"

TMP_ROOT=$(fm_test_tmproot fm-windows-bootstrap)

# A fakebin whose `uname -s` reports MINGW64.
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-win-uname.XXXXXX")
mkdir -p "$FAKE"
printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' >"$FAKE/uname"
chmod +x "$FAKE/uname"

# Extract the bootstrap's functions without running its main body, so the
# config-edit and path-resolution logic can be driven with fixtures.
extract_bootstrap_functions() {
  sed -n '/^fm_windows_bin_dir()/,/^}/p; /^fm_windows_git_bash_win()/,/^}/p; /^configure_herdr_shell()/,/^}/p; /^jq_state()/,/^}/p; /^flock_state()/,/^}/p; /^herdr_shell_state()/,/^}/p' "$BOOTSTRAP"
}

# --- POSIX refusal -----------------------------------------------------------
if ! fm_platform_is_windows; then
  out=$(bash "$BOOTSTRAP" --check 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "POSIX: the bootstrap must refuse to run"
  printf '%s\n' "$out" | grep -q "Windows Git Bash only" \
    || fail "POSIX: refusal message missing: [$out]"
  pass "bootstrap: refuses a POSIX host"
fi

# --- the pinned jq release is well-formed -------------------------------------
# The pin is what makes the bootstrap reproducible; a malformed pin must
# fail here rather than on a user machine.
grep -q '^JQ_VERSION=1\.7\.1$' "$BOOTSTRAP" || fail "bootstrap: JQ_VERSION pin missing"
grep -q '^JQ_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-windows-amd64.exe"$' "$BOOTSTRAP" \
  || fail "bootstrap: JQ_URL pin missing or wrong"
sha=$(sed -n 's/^JQ_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$BOOTSTRAP")
[ -n "$sha" ] || fail "bootstrap: JQ_SHA256 is not a 64-hex pin"
pass "bootstrap: jq version/URL/SHA-256 pins are well-formed"

# --- install directory resolution ---------------------------------------------
cat >"$TMP_ROOT/bindir.sh" <<'BINDIR'
set -u
. "$1"
if [ "$2" != "-" ]; then PATH="$2:$PATH"; export PATH; fi
fm_platform_is_windows || exit 10
eval "$(sed -n '/^fm_windows_bin_dir()/,/^}/p' "$3/bin/fm-windows-bootstrap.sh")"
export LOCALAPPDATA='C:\Users\fuyou\AppData\Local'
[ "$(fm_windows_bin_dir)" = /c/Users/fuyou/AppData/Local/firstmate/bin ] || exit 11
unset LOCALAPPDATA
export HOME=/home/fixture
[ "$(fm_windows_bin_dir)" = /home/fixture/AppData/Local/firstmate/bin ] || exit 12
exit 0
BINDIR
bash "$TMP_ROOT/bindir.sh" "$ROOT/bin/fm-platform-lib.sh" "$FAKE" "$ROOT"
expect_code 0 $? "bootstrap: install directory resolution"
pass "bootstrap: install directory resolves through the MSYS layer"

# --- herdr config edit (fake APPDATA, no real config touched) -----------------
cat >"$TMP_ROOT/herdrcfg.sh" <<'HERDRCFG'
set -u
. "$1/bin/fm-platform-lib.sh"
if [ "$2" != "-" ]; then PATH="$2:$PATH"; export PATH; fi
fm_platform_is_windows || exit 10
eval "$(sed -n '/^configure_herdr_shell()/,/^}/p; /^fm_windows_git_bash_win()/,/^}/p; /^report()/,/^}/p' "$1/bin/fm-windows-bootstrap.sh")"
report() { printf '%s\n' "$*"; }
CFGDIR="$3/appdata/herdr"
mkdir -p "$CFGDIR"
export APPDATA="$3/appdata"
SKIP_FLOCK=1
SKIP_HERDR_SHELL=0
# 1: insert into an existing [terminal] section.
printf 'onboarding = false\n\n[theme]\nname = "terminal"\n\n[terminal]\nnew_cwd = "D:/x"\n' >"$CFGDIR/config.toml"
configure_herdr_shell >/dev/null
grep -q '^default_shell = "' "$CFGDIR/config.toml" || exit 20
grep -q '^new_cwd = "D:/x"$' "$CFGDIR/config.toml" || exit 21
# 2: idempotent - a second run changes nothing.
cp "$CFGDIR/config.toml" "$3/before"
configure_herdr_shell >/dev/null
cmp -s "$3/before" "$CFGDIR/config.toml" || exit 22
# 3: a pre-existing different value is replaced in place.
printf '[terminal]\ndefault_shell = "C:\\other\\shell.exe"\n' >"$CFGDIR/config.toml"
configure_herdr_shell >/dev/null
grep -q 'C:\\other\\shell.exe' "$CFGDIR/config.toml" && exit 23
grep -q '^default_shell = "' "$CFGDIR/config.toml" || exit 24
# 4: no [terminal] section at all appends one.
printf 'onboarding = false\n' >"$CFGDIR/config.toml"
configure_herdr_shell >/dev/null
grep -q '^\[terminal\]$' "$CFGDIR/config.toml" || exit 25
grep -q '^default_shell = "' "$CFGDIR/config.toml" || exit 26
# 5: a missing config is skipped, not created.
mv "$CFGDIR/config.toml" "$3/moved"
configure_herdr_shell >/dev/null || exit 27
[ ! -e "$CFGDIR/config.toml" ] || exit 28
exit 0
HERDRCFG
bash "$TMP_ROOT/herdrcfg.sh" "$ROOT" "$FAKE" "$TMP_ROOT"
expect_code 0 $? "bootstrap: herdr config edit"
pass "bootstrap: herdr default_shell edit (insert, idempotent, replace, append, skip)"

# --- the flock shim (offline, real semantics) ---------------------------------
# The shim body is extracted straight out of the bootstrap (it is written by
# a quoted heredoc there) and exercised directly, so the test never depends
# on the host's own flock being absent and never writes outside the temp
# root.
cat >"$TMP_ROOT/flockshim.sh" <<'FLOCKSHIM'
set -u
. "$2/bin/fm-platform-lib.sh"
if [ "$1" != "-" ]; then PATH="$1:$PATH"; export PATH; fi
fm_platform_is_windows || exit 10
SHIM="$3/flock"
awk '/^[[:space:]]*cat >"\$BIN_DIR\/flock" <</ { inh=1; next } inh && /^SHIM$/ { exit } inh { print }' "$2/bin/fm-windows-bootstrap.sh" >"$SHIM"
[ -s "$SHIM" ] || exit 30
chmod +x "$SHIM"
LOCK="$3/demo.lock"
# The -c form runs the command under the lock and releases it.
"$SHIM" -x "$LOCK" -c 'printf held' >"$3/out1" || exit 31
[ "$(cat "$3/out1")" = held ] || exit 32
# After release, the lock is acquirable again.
"$SHIM" -x "$LOCK" -c 'printf again' >"$3/out2" || exit 33
# A held lock blocks a second nonblocking attempt.
mkdir -p "$LOCK.flock-shim"
printf '%s\n' "$$" >"$LOCK.flock-shim/holder"
"$SHIM" -n -x "$LOCK" -c true 2>/dev/null && exit 34
# The fd form is refused loudly, never silently skipped.
"$SHIM" 9 2>/dev/null && exit 35
# A stale holder (dead pid) is reaped.
printf '%s\n' "999999999" >"$LOCK.flock-shim/holder"
"$SHIM" -x "$LOCK" -c 'printf reaped' >"$3/out3" || exit 36
[ "$(cat "$3/out3")" = reaped ] || exit 37
exit 0
FLOCKSHIM
bash "$TMP_ROOT/flockshim.sh" "$FAKE" "$ROOT" "$TMP_ROOT"
expect_code 0 $? "bootstrap: flock shim semantics"
pass "bootstrap: flock shim (hold/release, nonblock, fd refusal, stale reap)"

echo "fm-windows-bootstrap tests: done"
