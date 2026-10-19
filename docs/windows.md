# Firstmate on Windows (Git Bash + Herdr)

firstmate is bash-script based. On Windows it runs under **Git Bash**
(MSYS2, `MINGW64_NT-10.0-26100`), and its terminal backend is **Herdr for
Windows**. This document covers install, the dependency bootstrap, and the
known limitations.

## Verified environment

Verified against Git Bash next to a stock Windows 11 install and Herdr
0.9.3 for Windows:

- Present in Git Bash: `git`, `curl`, `awk`, `sed`, `grep`, `sha256sum`,
  `unzip`, `tar`, `node`, `python`.
- Absent: `jq`, `flock`, `tmux`, `shasum`, `python3`.
- `ln -s` silently degrades to a file copy on MSYS (upstream issue #3267),
  so no caller can detect a degraded link from its exit status.
- Herdr for Windows reports its API socket as a drive-letter path
  (`C:\Users\<you>\AppData\Roaming\herdr\herdr.sock`), which the
  POSIX-only socket canonicalizer refused outright (upstream issue #3283).

## Install

1. Install [Git for Windows](https://git-scm.com/download/win) (Git Bash).
2. Install [Herdr for Windows](https://herdr.dev) and start it once so the
   `default` session exists.
3. Clone the repository and run the bootstrap from **PowerShell**:

```powershell
git clone https://github.com/yuhang234/firstmate-windows.git
cd firstmate-windows
.\bootstrap.ps1
```

`bootstrap.ps1` locates Git Bash, runs `bin/fm-windows-bootstrap.sh`
through it, and persists the dependency directory on your user `PATH`. The
bootstrap:

- installs the **pinned jq 1.7.1** Windows build into
  `%LOCALAPPDATA%\firstmate\bin` (SHA-256 verified; jq is a hard
  requirement of the herdr backend - every workspace/tab/pane identity is
  parsed from herdr's JSON);
- installs a small **flock shim** (see "flock" below);
- points Herdr's `config.toml` `[terminal] default_shell` at Git Bash so
  spawned panes run bash instead of the Windows default shell (one
  timestamped backup is kept; panes created after the Herdr server next
  restarts pick it up - the bootstrap restarts no server).

Re-running is safe (idempotent). `--check` reports status without changing
anything:

```sh
bin/fm-windows-bootstrap.sh --check
```

## Starting firstmate

From PowerShell, in the repository root:

```powershell
.\firstmate.ps1                 # default harness (claude)
.\firstmate.ps1 -Agent codebuddy
.\firstmate.ps1 -Bootstrap -Agent agy
.\firstmate.ps1 -Backend herdr -Session fmtest   # pin backend and session
```

`firstmate.ps1` locates Git Bash, puts the bootstrap dependency directory
on `PATH`, sets the environment firstmate needs (`FM_HOME`, and
`FM_BACKEND`/`HERDR_SESSION` when given), and launches the selected harness
inside Git Bash with the repository as the working directory. `AGENTS.md`
takes over from there, exactly as on POSIX.

Backend selection follows the usual rules: running firstmate **inside a
Herdr pane** auto-detects the herdr backend (Herdr injects
`HERDR_SESSION`); from a plain shell, set `config/backend` to `herdr` or
pass `-Backend herdr`.

## What was adapted

- **`bin/fm-platform-lib.sh`** (new): the single owner of platform
  detection and portable primitives - OS/MSYS detection, Windows/POSIX path
  conversion, Windows socket-path canonicalization, and a
  symlink-or-marker-directory link primitive. The primitive either creates
  a real native symlink (`MSYS=winsymlinks:nativestrict`, which fails
  instead of copying, with a readback verification) or an atomic marker
  directory, and reports which one it made. It never silently copies.
- **`bin/fm-wake-lib.sh`**: the session lock routes its ownership proof
  through the primitive, so the lock is acquirable on Windows without any
  change to POSIX lock semantics.
- **`bin/backends/herdr.sh`**: `fm_backend_herdr_canonical_socket_path`
  canonicalizes and compares drive-letter and named-pipe socket paths, so a
  live Windows Herdr server resolves. POSIX behaviour is byte-identical.
- **`firstmate.ps1`** / **`bootstrap.ps1`** (new): the PowerShell entry
  points.

## Spawning a crewmate on Windows

The crewmate spawn path is the ordinary herdr backend path, unchanged:
`fm_backend_herdr_container_ensure` creates (or adopts) the home workspace,
`fm_backend_herdr_create_task` creates the task tab and its pane, and the
launch command is delivered into that pane. The observable result is a new
pane in the Herdr session running the selected agent in its worktree.

Herdr accepts MSYS-spelled `--cwd` paths directly, so no path conversion is
needed on the spawn path.

## Tests

```sh
bash tests/windows/run.sh
```

The suite runs on Windows (real MSYS) and on Linux/macOS (the Windows
branches run behind a fake `uname`). See `tests/windows/README.md`.

## Known limitations

- **Herdr pane shell.** Spawned panes run whatever Herdr's
  `default_shell` names. The bootstrap points it at Git Bash; until the
  Herdr server restarts, new panes still use the previous shell.
- **flock.** Verified by exhaustive search: **no firstmate script invokes
  the `flock` binary.** `bin/fm-claude-trust.sh` deliberately avoids it
  (fingerprint-and-refuse, "flock is absent on macOS"),
  `bin/fm-supervise-daemon.sh` uses the portable `fm_lock_*` helpers from
  `bin/fm-wake-lib.sh`, and `bin/fm-pipeline-spend.sh` uses Python's
  in-process `fcntl.flock`, not the binary. The bootstrap still installs a
  shim for out-of-tree callers; it refuses the descriptor form
  (`flock <fd>`) loudly, because a separate process cannot hold a lock in
  the caller's descriptor.
- **`fm-pipeline-spend.sh`** imports Python's `fcntl`, which does not exist
  on Windows Python. That script belongs to the no-mistakes pipeline, which
  this port does not use (direct-PR delivery); it is listed here rather
  than silently broken.
- **Native symlinks.** With Windows Developer Mode off (or no admin),
  `MSYS=winsymlinks:nativestrict` still fails, and the session lock falls
  back to marker-directory mode. Both modes are tested.
- **Herdr sessions.** All Herdr testing should happen in a named
  non-`default` session (`herdr --session <name>`); the `default` session is
  the operator's live desktop.
- **Not ported:** the tmux backend (no tmux on Windows), and the
  no-mistakes pipeline surface. Use `--backend herdr`.
