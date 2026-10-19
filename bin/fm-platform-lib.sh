#!/usr/bin/env bash
# fm-platform-lib.sh - the single owner of platform detection and portable
# primitives for firstmate on Windows (Git Bash / MSYS) alongside POSIX
# (Linux, macOS). No source-time side effects beyond the uname cache, so
# read-only callers can load it without any library's state setup.
#
# Everything here has a POSIX path that is byte-identical to the historical
# inline command it replaces, and a Windows path used only when
# fm_platform_is_windows reports an MSYS runtime:
#
#   - fm_platform_is_windows / fm_platform_is_msys: OS/MSYS detection.
#   - fm_platform_win_to_posix / fm_platform_posix_to_win: path conversion.
#   - fm_platform_socket_identity: Windows socket-path canonicalization, so
#     two spellings of one drive-letter or named-pipe socket compare equal.
#   - fm_platform_link_or_marker / fm_platform_link_target /
#     fm_platform_link_is_link / fm_platform_remove_link: the
#     symlink-or-marker-directory primitive behind fm-wake-lib.sh's session
#     lock. MSYS `ln -s` degrades silently (a file copy that exits 0, or an
#     outright failure when symlink privilege is absent - upstream issue
#     #3267), so a caller can never detect a degraded link from the exit
#     status alone. This primitive either creates a REAL native symlink
#     (MSYS=winsymlinks:nativestrict, which fails instead of copying) or an
#     atomic marker DIRECTORY, and reports which one it made in
#     FM_PLATFORM_LINK_MODE. It never silently copies.

FM_PLATFORM_UNAME=
FM_PLATFORM_LINK_MODE=

# fm_platform_uname: cached `uname -s` (Linux, Darwin, MINGW64_NT-*, MSYS_NT-*,
# CYGWIN_NT-*). Resolved once per process because fm_platform_is_windows sits
# on lock-acquire and socket-identity hot paths.
fm_platform_uname() {
  if [ -z "$FM_PLATFORM_UNAME" ]; then
    FM_PLATFORM_UNAME=$(uname -s 2>/dev/null || printf 'unknown')
  fi
  printf '%s' "$FM_PLATFORM_UNAME"
}

# fm_platform_is_msys: true inside a Windows MSYS/Cygwin runtime (Git Bash).
# This is the runtime a bash script actually observes on Windows; a native
# Windows process is never this shell.
fm_platform_is_msys() {
  case "$(fm_platform_uname)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_platform_is_windows: true when this bash is running on Windows. The MSYS
# runtime check is the whole test; there is no separate native-Windows bash.
fm_platform_is_windows() {
  fm_platform_is_msys
}

# fm_platform_win_to_posix <path>: convert a Windows path to its MSYS POSIX
# spelling (C:\a\b -> /c/a/b, \\server\share -> //server/share). A path that is
# already POSIX-shaped passes through unchanged. cygpath is preferred when
# present; the fork-free fold is the documented fallback so a caller without
# cygpath still gets one deterministic answer.
fm_platform_win_to_posix() {
  local path=$1 drive rest
  case "$path" in
    /*) printf '%s' "$path"; return 0 ;;
    [A-Za-z]:[/\\]*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u -- "$path" 2>/dev/null && return 0
      fi
      drive=$(printf '%s' "${path:0:1}" | tr '[:upper:]' '[:lower:]')
      rest=${path#?:}
      rest=${rest//\\//}
      printf '/%s%s\n' "$drive" "$rest"
      return 0
      ;;
    \\\\*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u -- "$path" 2>/dev/null && return 0
      fi
      printf '%s\n' "${path//\\//}"
      return 0
      ;;
    *) printf '%s' "$path"; return 0 ;;
  esac
}

# fm_platform_posix_to_win <path>: convert an MSYS POSIX path to its Windows
# spelling (/c/a/b -> C:\a\b). A path that is already Windows-shaped passes
# through unchanged. cygpath is preferred when present.
fm_platform_posix_to_win() {
  local path=$1 rest
  case "$path" in
    /*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -w -- "$path" 2>/dev/null && return 0
      fi
      case "$path" in
        /[A-Za-z]/*)
          rest=${path#/?}
          rest=${rest//\//\\}
          printf '%s:%s\n' "$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')" "$rest"
          return 0
          ;;
        *)
          printf '%s\n' "${path//\//\\}"
          return 0
          ;;
      esac
      ;;
    *) printf '%s' "$path"; return 0 ;;
  esac
}

# fm_platform_socket_identity <socket-path>: normalize one Windows
# drive-letter or named-pipe socket path so two spellings of the same socket
# compare equal. Drive letters are upper-cased, separators normalize to '/',
# and an existing parent directory is resolved through the MSYS layer (short
# names, junctions, case) and mapped back to drive form. A named pipe is not
# a filesystem path, so it is separator-normalized only. Refuses a relative
# or empty path; an unresolvable parent directory is left as-is rather than
# treated as a failure. Returns 1 for a POSIX-shaped path, whose canonical
# form is owned by the POSIX branch of the caller (bin/backends/herdr.sh).
fm_platform_socket_identity() {
  local socket=$1 sock_dir sock_base resolved drive rest
  [ -n "$socket" ] || return 1
  case "$socket" in
    [A-Za-z]:[/\\]*)
      drive=$(printf '%s' "${socket:0:1}" | tr '[:lower:]' '[:upper:]')
      rest=${socket#?:}
      rest=${rest//\\//}
      socket="$drive:$rest"
      ;;
    \\\\*)
      printf '%s\n' "${socket//\\//}"
      return 0
      ;;
    *) return 1 ;;
  esac
  sock_dir=$(dirname "$socket")
  sock_base=$(basename "$socket")
  [ -n "$sock_dir" ] && [ -n "$sock_base" ] || return 1
  if [ -d "$sock_dir" ]; then
    resolved=$(cd "$sock_dir" 2>/dev/null && pwd -P) || return 1
    resolved=$(fm_platform_posix_to_win "$resolved")
    resolved=${resolved//\\//}
    [ -n "$resolved" ] || return 1
    socket="$resolved/$sock_base"
  fi
  printf '%s' "$socket"
}

# fm_platform_link_marker_file: the marker filename a marker-directory link
# carries inside it, holding the link target as its single line. One owner so
# creation, read, and removal can never disagree about the name.
fm_platform_link_marker_file() {
  printf '%s' '.fm-platform-owner'
}

# fm_platform_link_or_marker <link> <target>: create <link> as an atomic
# ownership pointer to <target>, reporting the mode in FM_PLATFORM_LINK_MODE
# (symlink or marker). On POSIX this is exactly `ln -s target link`, the
# historical call. On Windows it first tries a REAL native symlink under
# MSYS=winsymlinks:nativestrict (which fails rather than silently copying),
# verifying the readback, and otherwise creates an atomic marker DIRECTORY:
# mkdir is the atomic claim, the owner pid is mirrored in first so a live
# holder is visible to every stale-owner proof, and the marker file records
# the target last. A marker whose write failed is removed by this same call
# and reported as a failure, so a half-created marker is never mistaken for a
# held link. Returns 0 only when <link> now resolves to <target>.
# shellcheck disable=SC2034 # Link mode read by callers after this function returns.
fm_platform_link_or_marker() {
  local link=$1 target=$2 marker
  FM_PLATFORM_LINK_MODE=
  if ! fm_platform_is_windows; then
    if ln -s "$target" "$link" 2>/dev/null; then
      FM_PLATFORM_LINK_MODE=symlink
      return 0
    fi
    return 1
  fi
  if MSYS=winsymlinks:nativestrict ln -s "$target" "$link" 2>/dev/null \
    && [ "$(fm_platform_link_target "$link" 2>/dev/null || true)" = "$target" ]; then
    FM_PLATFORM_LINK_MODE=symlink
    return 0
  fi
  # No native symlink is available. mkdir is the atomic claim; a degraded
  # `ln -s` artifact (a copied file or directory) is never created here, so
  # there is nothing to mistake for a link.
  mkdir "$link" 2>/dev/null || return 1
  if [ -f "$target/pid" ]; then
    cp -- "$target/pid" "$link/pid" 2>/dev/null || true
  fi
  marker="$link/$(fm_platform_link_marker_file)"
  if printf '%s\n' "$target" >"$marker" 2>/dev/null \
    && [ "$(fm_platform_link_target "$link" 2>/dev/null || true)" = "$target" ]; then
    FM_PLATFORM_LINK_MODE=marker
    return 0
  fi
  rm -f -- "$link/pid" "$marker" 2>/dev/null || true
  rmdir "$link" 2>/dev/null || true
  return 1
}

# fm_platform_link_target <link>: print what <link> points to, exactly as
# POSIX readlink would, or return 1. A marker directory reports its recorded
# target, so marker-mode callers resolve the same answer a symlink would have
# given. On POSIX this is exactly `readlink link`.
fm_platform_link_target() {
  local link=$1 marker line extra
  if [ -L "$link" ]; then
    readlink "$link" 2>/dev/null
    return $?
  fi
  fm_platform_is_windows || return 1
  [ -d "$link" ] && [ ! -L "$link" ] || return 1
  marker="$link/$(fm_platform_link_marker_file)"
  [ -f "$marker" ] || return 1
  # Exactly one newline-terminated line: the recorded target and nothing else.
  line=
  extra=
  { IFS= read -r line || true; IFS= read -r extra || true; } <"$marker" || return 1
  [ -n "$line" ] || return 1
  [ -z "$extra" ] || return 1
  printf '%s\n' "$line"
}

# fm_platform_link_is_link <link>: true when <link> exists as a symlink or as
# a complete marker directory. On POSIX this is exactly `[ -L link ]`.
fm_platform_link_is_link() {
  local link=$1
  [ -L "$link" ] && return 0
  fm_platform_is_windows || return 1
  [ -d "$link" ] && [ ! -L "$link" ] && [ -f "$link/$(fm_platform_link_marker_file)" ]
}

# fm_platform_remove_link <link>: remove a symlink or a marker directory. On
# POSIX this is exactly `rm -f link`, which unlinks the symlink and never
# touches its target.
fm_platform_remove_link() {
  local link=$1
  if [ -L "$link" ]; then
    rm -f "$link" 2>/dev/null
    return $?
  fi
  if fm_platform_is_windows && [ -d "$link" ] && [ ! -L "$link" ] \
    && [ -f "$link/$(fm_platform_link_marker_file)" ]; then
    rm -f -- "$link/pid" "$link/$(fm_platform_link_marker_file)" 2>/dev/null || true
    rmdir "$link" 2>/dev/null
    return $?
  fi
  return 1
}
