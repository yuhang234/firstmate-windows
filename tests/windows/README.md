# Windows test suite (`tests/windows/`)

Covers the Windows (Git Bash / MSYS) adaptation layer on **both** hosts:

| File | What it proves |
| --- | --- |
| `fm-platform-lib.test.sh` | `bin/fm-platform-lib.sh`: OS/MSYS detection, Windows/POSIX path conversion, socket-path identity, and the symlink-or-marker link primitive (including marker mode when no native symlink exists - upstream issue #3267). |
| `herdr-socket-canonicalization.test.sh` | `bin/backends/herdr.sh`'s `fm_backend_herdr_canonical_socket_path`: drive-letter and named-pipe socket paths canonicalize (upstream issue #3283) while POSIX behaviour stays byte-identical. |
| `fm-windows-bootstrap.test.sh` | `bin/fm-windows-bootstrap.sh`: the POSIX refusal, the pinned jq release (version/URL/SHA-256 shape), install-directory resolution, the herdr `default_shell` config edit (insert/idempotent/replace/append/skip), and the flock shim semantics (hold, release, nonblocking refusal, fd-form refusal, stale-holder reaping). |

## Running

From the repository root:

```sh
bash tests/windows/run.sh
```

or one file at a time:

```sh
bash tests/windows/fm-platform-lib.test.sh
```

On Windows, run it from Git Bash (the suite is plain bash):

```sh
"C:\Program Files\Git\bin\bash.exe" -lc "cd /c/path/to/firstmate && bash tests/windows/run.sh"
```

## How one suite covers both hosts

On a real Windows host the MSYS branches execute for real. On
Linux/macOS the same cases run behind a fakebin `uname` that reports
`MINGW64_NT-10.0-26100`, so `fm_platform_is_windows` is true and the
Windows branches stay covered in CI without a Windows runner. Where a
branch needs a Windows-only failure mode (no native symlink), a fakebin
`ln` that always fails stands in for a Git Bash without symlink privilege.

The suite never touches a live herdr server, the real `HOME`, or the
network: the jq download path is exercised through its pin guards, and the
herdr config edit through a fake `APPDATA` inside the test temp root.

## Not covered here

The live spawn proof (a real agent process inside a real Herdr pane on a
Windows host) needs a running Herdr server and is recorded as evidence in
the task data directory, not as an automated test. See `docs/windows.md`.
