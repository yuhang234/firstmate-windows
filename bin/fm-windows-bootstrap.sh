#!/usr/bin/env bash
# fm-windows-bootstrap.sh - make firstmate's missing Windows dependencies
# available to Git Bash (MSYS), reproducibly and idempotently.
#
# Verified on Git Bash (MINGW64_NT-10.0-26100, bash 5.x) next to a stock
# Windows 11 install: present are git, curl, awk, sed, grep, sha256sum,
# unzip, tar, node, python; ABSENT are jq and flock.
#
#   jq is a HARD requirement of the herdr backend: bin/backends/herdr.sh's
#   fm_backend_herdr_tool_check refuses backend=herdr without it, because
#   every workspace/tab/pane identity is parsed from herdr's JSON output.
#   This script installs the official pinned jq Windows build into
#   %LOCALAPPDATA%/firstmate/bin and puts that directory on this session's
#   PATH (the PowerShell wrapper bootstrap.ps1 persists it for future
#   sessions). A missing jq is never silent: --check reports it.
#
#   flock: verified 2026-10-19 by exhaustive search of bin/, skills/, and
#   tests/ - NO firstmate script invokes the flock binary. The three scripts
#   the upstream brief named deliberately avoid it: fm-claude-trust.sh uses
#   fingerprint-and-refuse ("flock is absent on macOS"), fm-supervise-daemon.sh
#   uses the portable fm_lock_* helpers from bin/fm-wake-lib.sh, and
#   fm-pipeline-spend.sh uses Python's in-process fcntl.flock, not the binary.
#   So no guard is skipped by its absence. For out-of-tree callers this script
#   still installs a small, tested shim implementing the file-based flock
#   forms; it REFUSES LOUDLY on the fd form (flock <fd>), which no separate
#   process can implement honestly. Use --skip-flock to decline the shim.
#
#   Herdr pane shell: firstmate's herdr spawn path delivers a bash launch
#   command into the new pane, so the pane must run Git Bash, not the Windows
#   default (pwsh). Unless --skip-herdr-shell is given, this script points
#   herdr's config.toml [terminal] default_shell at Git Bash (idempotent, one
#   timestamped backup on first edit). That takes effect for panes created
#   AFTER the herdr server next restarts; the script says so and never
#   restarts any server itself.
#
# Usage:
#   fm-windows-bootstrap.sh                 install what is missing
#   fm-windows-bootstrap.sh --check         report status only, change nothing
#   fm-windows-bootstrap.sh --skip-flock    do not install the flock shim
#   fm-windows-bootstrap.sh --skip-herdr-shell
#                                           do not touch herdr's config.toml
#
# POSIX hosts (Linux/macOS) are refused: there is nothing here for them, and a
# jq.exe on PATH would not even be executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The single owner of platform detection; sourced read-only (no state setup).
# shellcheck source=bin/fm-platform-lib.sh
. "$ROOT/bin/fm-platform-lib.sh"

die() {
  printf 'fm-windows-bootstrap: %s\n' "$*" >&2
  exit 1
}

# --- pinned jq release --------------------------------------------------------
# Official jqlang/jq release asset. The pin is the release asset's SHA-256;
# a mismatch aborts before anything is installed.
JQ_VERSION=1.7.1
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-windows-amd64.exe"
JQ_SHA256=7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab

# --- install directory ---------------------------------------------------------
# %LOCALAPPDATA%/firstmate/bin, resolved through the MSYS layer. Falls back to
# $HOME/AppData/Local/firstmate/bin when LOCALAPPDATA is unset.
fm_windows_bin_dir() {
  local base
  if [ -n "${LOCALAPPDATA:-}" ]; then
    base=$(fm_platform_win_to_posix "$LOCALAPPDATA")
  else
    base="${HOME:-}/AppData/Local"
  fi
  printf '%s/firstmate/bin\n' "${base%/}"
}

# fm_windows_git_bash_win: the Windows path of the Git Bash running this
# script. MSYS resolves both <root>/bin/bash.exe (the documented Git Bash
# launcher) and <root>/usr/bin/bash.exe (the MSYS runtime) to the same
# runtime, and a herdr pane started from either reports MINGW64 with a full
# PATH (verified on the Windows host), so the resolved path is used as-is.
fm_windows_git_bash_win() {
  local resolved
  resolved=$(command -v bash 2>/dev/null || true)
  [ -n "$resolved" ] || return 1
  fm_platform_posix_to_win "$resolved"
}

CHECK_ONLY=0
SKIP_FLOCK=0
SKIP_HERDR_SHELL=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --skip-flock) SKIP_FLOCK=1 ;;
    --skip-herdr-shell) SKIP_HERDR_SHELL=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d' ; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

if ! fm_platform_is_windows; then
  die "this bootstrap is for Windows Git Bash only; on $(fm_platform_uname) install jq with the platform package manager"
fi

BIN_DIR=$(fm_windows_bin_dir)
JQ_EXE="$BIN_DIR/jq.exe"

report() { printf '%s\n' "$*"; }

jq_state() {
  if command -v jq >/dev/null 2>&1; then
    printf 'jq: PRESENT (%s)\n' "$(command -v jq)"
  elif [ -x "$JQ_EXE" ]; then
    printf 'jq: INSTALLED BUT NOT ON PATH (%s)\n' "$JQ_EXE"
  else
    printf 'jq: MISSING\n'
  fi
}

flock_state() {
  if command -v flock >/dev/null 2>&1 && [ "$(command -v flock)" != "$BIN_DIR/flock" ]; then
    printf 'flock: PRESENT (%s)\n' "$(command -v flock)"
  elif [ -x "$BIN_DIR/flock" ]; then
    printf 'flock: SHIM INSTALLED (%s)\n' "$BIN_DIR/flock"
  else
    printf 'flock: ABSENT (no firstmate script requires the flock binary)\n'
  fi
}

herdr_shell_state() {
  local cfg default_shell
  cfg="$APPDATA/herdr/config.toml"
  [ -n "${APPDATA:-}" ] || cfg="$HOME/AppData/Roaming/herdr/config.toml"
  if [ ! -f "$cfg" ]; then
    printf 'herdr config: NOT FOUND (%s)\n' "$cfg"
    return 0
  fi
  default_shell=$(sed -n 's/^[[:space:]]*default_shell[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)
  if [ -n "$default_shell" ]; then
    printf 'herdr config: default_shell = %s\n' "$default_shell"
  else
    printf 'herdr config: default_shell UNSET (panes run the Windows default shell)\n'
  fi
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  report "== fm-windows-bootstrap --check =="
  jq_state
  flock_state
  herdr_shell_state
  report "install directory: $BIN_DIR"
  exit 0
fi

# --- install jq -----------------------------------------------------------------
install_jq() {
  if command -v jq >/dev/null 2>&1; then
    report "jq already on PATH: $(command -v jq)"
    return 0
  fi
  mkdir -p "$BIN_DIR"
  if [ -x "$JQ_EXE" ]; then
    report "jq already installed at $JQ_EXE (adding to PATH below)"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to download jq but was not found"
  local tmp attempt
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-jq.XXXXXX")
  # shellcheck disable=SC2064  # $tmp expands now, deliberately
  trap "rm -f '$tmp'" RETURN
  attempt=1
  while ! curl -fsSL "$JQ_URL" -o "$tmp"; do
    [ "$attempt" -lt 6 ] || die "jq download failed after 6 attempts ($JQ_URL)"
    report "jq download attempt $attempt failed; retrying"
    sleep $((1 << (attempt - 1)))
    attempt=$((attempt + 1))
  done
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
  else
    die "need sha256sum or shasum to verify the jq download"
  fi
  [ "$actual" = "$JQ_SHA256" ] || {
    rm -f "$tmp"
    die "jq checksum mismatch (expected $JQ_SHA256, got $actual); refusing to install"
  }
  mv -f "$tmp" "$JQ_EXE"
  chmod 0755 "$JQ_EXE"
  report "installed jq $JQ_VERSION -> $JQ_EXE"
}

# --- flock shim -----------------------------------------------------------------
# Implements the file-based forms a shell script can use portably:
#   flock [-x|-s] [-n] [-w <secs>] <file> -c <command...>
#   flock [-x|-s] [-n] [-w <secs>] <file> <command...>
# Mutual exclusion comes from mkdir's atomicity; the holder's pid is recorded
# so a dead holder's lock can be reaped. The fd form (flock <fd>, locking a
# descriptor the caller already holds open) is refused loudly: a separate
# process cannot hold a lock in the caller's descriptor.
install_flock() {
  if [ "$SKIP_FLOCK" -eq 1 ]; then
    report "flock shim skipped (--skip-flock)"
    return 0
  fi
  if command -v flock >/dev/null 2>&1 && [ "$(command -v flock)" != "$BIN_DIR/flock" ]; then
    report "flock already on PATH: $(command -v flock)"
    return 0
  fi
  mkdir -p "$BIN_DIR"
  cat >"$BIN_DIR/flock" <<'SHIM'
#!/usr/bin/env bash
# flock shim for Windows Git Bash (installed by bin/fm-windows-bootstrap.sh).
# File-based advisory locking through mkdir atomicity, with stale-lock
# reaping. Refuses the fd form loudly. Not a util-linux replacement.
set -u
wait=0
nonblock=0
while [ $# -gt 0 ]; do
  case "$1" in
    -x|--exclusive) ;;
    -s|--shared) ;;
    -n|--nonblock) nonblock=1 ;;
    -w|--wait)
      [ $# -ge 2 ] || { echo "flock shim: -w needs a value" >&2; exit 64; }
      wait=$2; shift ;;
    --timeout=*) wait=${1#--timeout=} ;;
    -o|--close) ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'
      exit 0 ;;
    --) shift; break ;;
    -*) echo "flock shim: unsupported option: $1" >&2; exit 64 ;;
    *) break ;;
  esac
  shift
done
[ $# -ge 1 ] || { echo "flock shim: usage: flock [-x|-s] [-n] [-w secs] <file> [-c] <command...>" >&2; exit 64; }
# The fd form names a descriptor, not a file; refuse it rather than pretend.
case "$1" in
  [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
    echo "flock shim: the descriptor form (flock $1) cannot be implemented by a separate process; open the file and use a file path instead" >&2
    exit 64 ;;
esac
lockfile=$1; shift
command_to_run=()
command_string=
if [ "${1:-}" = -c ]; then
  # Real flock passes the -c value to sh -c, so the value is one shell
  # command string, not an argv vector.
  shift
  [ $# -eq 1 ] || { echo "flock shim: -c takes exactly one command string" >&2; exit 64; }
  command_string=$1
elif [ $# -ge 1 ]; then
  command_to_run=("$@")
fi
lockdir="$lockfile.flock-shim"
holder_info="$lockdir/holder"
acquire() {
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" >"$holder_info" 2>/dev/null || true
    return 0
  fi
  # Reap a lock whose holder is gone (best effort: a pid file plus kill -0).
  local pid
  pid=$(cat "$holder_info" 2>/dev/null || true)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$lockdir" 2>/dev/null || true
    mkdir "$lockdir" 2>/dev/null || return 1
    printf '%s\n' "$$" >"$holder_info" 2>/dev/null || true
    return 0
  fi
  return 1
}
release() { rm -f "$holder_info" 2>/dev/null || true; rmdir "$lockdir" 2>/dev/null || true; }
deadline=0
if [ "$wait" != 0 ]; then
  deadline=$(( $(date +%s) + wait ))
fi
while ! acquire; do
  if [ "$nonblock" -eq 1 ] || { [ "$deadline" -ne 0 ] && [ "$(date +%s)" -ge "$deadline" ]; }; then
    echo "flock shim: could not acquire $lockfile" >&2
    exit 1
  fi
  sleep 0.2
done
# The release trap is armed only once THIS process holds the lock: a failed
# acquire must never remove the holder's lock on its way out.
trap 'release' EXIT INT TERM
if [ -z "$command_string" ] && [ "${#command_to_run[@]}" -eq 0 ]; then
  # No command: hold the lock until signalled, like flock <file> with no -c.
  exec sleep infinity
fi
if [ -n "$command_string" ]; then
  sh -c "$command_string"
else
  "${command_to_run[@]}"
fi
SHIM
  chmod 0755 "$BIN_DIR/flock"
  report "installed flock shim -> $BIN_DIR/flock"
}

# --- herdr pane shell -----------------------------------------------------------
# firstmate's herdr spawn path types a bash launch command into the new pane,
# so panes must run Git Bash. Idempotent edit of [terminal] default_shell with
# one timestamped backup of the original on the first edit. The value is
# written TOML-escaped (backslashes doubled) so a Windows path survives the
# parser; the edit itself runs through awk with the value passed by
# environment, because a sed replacement would eat the backslashes.
configure_herdr_shell() {
  if [ "$SKIP_HERDR_SHELL" -eq 1 ]; then
    report "herdr shell configuration skipped (--skip-herdr-shell)"
    return 0
  fi
  local cfg appdata bash_win bash_win_esc backup
  appdata="${APPDATA:-$HOME/AppData/Roaming}"
  cfg="$appdata/herdr/config.toml"
  if [ ! -f "$cfg" ]; then
    report "herdr config not found at $cfg; herdr may not be installed yet - skipping"
    return 0
  fi
  bash_win=$(fm_windows_git_bash_win) || {
    report "could not resolve Git Bash's Windows path; leaving herdr config untouched"
    return 0
  }
  # TOML basic strings escape backslashes, so the Windows path is doubled
  # before it is written and compared.
  bash_win_esc=${bash_win//\\/\\\\}
  if grep -qxF "default_shell = \"$bash_win_esc\"" "$cfg"; then
    report "herdr default_shell already set to $bash_win"
    return 0
  fi
  backup="$cfg.fm-backup-$(date +%Y%m%d%H%M%S)-$$"
  cp -p "$cfg" "$backup"
  report "backed up $cfg -> $backup"
  # One awk pass replaces an existing default_shell line wherever it sits, or
  # inserts the key inside an existing [terminal] section (before the next
  # section header), or appends a new [terminal] section at the end. The
  # value travels by ENVIRONMENT: a sed replacement would eat the backslashes.
  AWK_SHELL="$bash_win_esc" awk '
    BEGIN { shell = ENVIRON["AWK_SHELL"]; done = 0; inserted = 0; in_terminal = 0; terminal_seen = 0 }
    /^[[:space:]]*default_shell[[:space:]]*=/ && !done {
      print "default_shell = \"" shell "\""
      done = 1
      next
    }
    /^[[:space:]]*\[/ {
      if (in_terminal && !inserted) {
        print "default_shell = \"" shell "\""
        inserted = 1
      }
      in_terminal = ($0 ~ /^[[:space:]]*\[terminal\]/)
      if (in_terminal) terminal_seen = 1
      print
      next
    }
    { print }
    END {
      if (!done && !inserted) {
        if (!terminal_seen) print "[terminal]"
        print "default_shell = \"" shell "\""
      }
    }
  ' "$cfg" >"$cfg.fm-new" && mv -f "$cfg.fm-new" "$cfg"
  report "set herdr default_shell = $bash_win in $cfg"
  report "NOTE: panes created after the herdr server next restarts run Git Bash; this script restarts no server"
}

# --- run -------------------------------------------------------------------------
install_jq
install_flock
configure_herdr_shell

# Put the install directory on THIS session's PATH (idempotent). The
# PowerShell wrapper bootstrap.ps1 persists it for future sessions; without
# persistence a new Git Bash window would not see jq.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) PATH="$BIN_DIR:$PATH"; export PATH ;;
esac

report "== bootstrap complete =="
jq_state
flock_state
herdr_shell_state
command -v jq >/dev/null 2>&1 || die "jq is still not resolvable on PATH after install; add $BIN_DIR to PATH"
report "jq is on PATH for this session. Run bootstrap.ps1 from PowerShell once to persist PATH for future sessions."
