# Trouter Changelog

All notable changes to the trouter package are recorded here.
Format: `## [YYYY-MM-DD] - Component/Area`, with subsections for Added / Modified / Fixed / Security / Breaking Changes / Notes.

---

## [2026-03-11] - Terminal Spawner Export to Trouter

### Added
- `trouter/shell/terminal_spawner.sh` — Self-contained port of `CLI/lib/terminal_spawner.sh`.
  817 lines; 36 functions exported via `export -f`. Inlines the five logging helpers
  (`_ts_log_info`, `_ts_log_warn`, `_ts_log_error`, `_ts_log_success`, `_ts_log_debug`),
  `get_background_output_file()`, and `_escape_applescript()` so the script has no runtime
  dependency on `subagent_core.sh` and can be sourced or executed standalone.
- `trouter/terminal/__init__.py` + `trouter/terminal/spawner.py` — Python `TerminalSpawner`
  class that shells out to `terminal_spawner.sh` via `subprocess.run`. Public methods:
  - `detect_method()` — probe available terminal emulator (iTerm2 + tmux, iTerm2, tmux,
    screen, osascript, background/headless)
  - `spawn(command, *, title, working_dir, log_file)` — launch a new terminal session;
    raises `RuntimeError` on empty return or spawn failure
  - `list_sessions()` — return list of dicts with session metadata
  - `attach(session_name)` — attach to an existing named session; returns `bool`
  - `kill_session(session_name)` — terminate a named session; returns `bool`
  - `kill_all()` — terminate all managed sessions; returns count killed
  - `write_heartbeat(session_name, working_dir, command)` — write a `.heartbeat` file for
    the watchdog; raises `RuntimeError` if the file is not created
  - Constructor accepts `method` (validated against allowed set), `timeout` (default 30 s),
    and `health_dir` (default `~/.claude/terminal_health/heartbeats`)
- CLI subcommands added to `trouter/cli/main.py`:
  - `trouter spawn` — launch a new terminal session; `--method`, `--title`, `--log-file`
    flags; exits non-zero with a human-readable message on failure
  - `trouter sessions` — list active sessions in a Rich table
  - `trouter attach` — attach to a running session by name; warns when not found
  - `trouter kill-session` — terminate a named session; `--all` flag kills every session
- `tests/test_terminal_spawner.py` — 193 lines, 18 tests across four classes:
  - `TestShellLibrarySelfContained` (9 tests) — sources the script in a clean shell,
    validates `detect_terminal_app`, `generate_session_name`, `get_terminal_method`,
    `_escape_applescript` (plain, quoted, backslash), `get_background_output_file`, and
    presence of all five inline logging functions
  - `TestTerminalSpawner` (6 tests) — Python class init validation, method detection,
    session listing, kill of nonexistent session, heartbeat file creation and content,
    background spawn with log-file polling
  - `TestHeartbeatCompatibility` (2 tests) — roundtrip through `HeartbeatData.from_file`
    and special-character handling (`/tmp/dir with spaces`, quoted command strings)
  - `TestBackgroundSpawn` (1 test) — verifies log-file creation within a 5 s deadline

### Security
- Added `_escape_applescript()` in `terminal_spawner.sh` to sanitize user-supplied strings
  before interpolation into `osascript` heredocs. Double-quotes are backslash-escaped and
  backslashes are doubled; the function is applied to every caller-controlled field
  (session name, title, working directory, command) before heredoc insertion. The source
  `CLI/lib/terminal_spawner.sh` had no such escaping, leaving AppleScript injection
  possible via session names or commands.
- `write_initial_heartbeat()` now escapes all five injection-relevant characters
  (backslash, double-quote, newline `\n`, tab `\t`, carriage-return `\r`) in every
  caller-controlled field before interpolating into the JSON heartbeat payload. Previously
  only backslashes and double-quotes were handled.
- `write_initial_heartbeat()` sanitizes `session_name` through `basename --` before
  constructing the heartbeat file path, preventing path-traversal attacks via session
  names containing `../` sequences.
- `write_initial_heartbeat()` writes to a `.tmp` file and then renames it atomically
  (`mv "${hb_tmp}" "${hb_file}"`), preventing the watchdog from reading a partially
  written heartbeat.
- `grep -qF` (fixed-string matching) replaces `grep -q` throughout `terminal_spawner.sh`
  for session-name lookups, preventing regex injection when session names contain regex
  metacharacters.
- `printf '%q'` shell quoting is applied to working-directory and command arguments before
  they are embedded in shell strings passed to terminal emulators, preventing word-
  splitting and glob-expansion attacks.
- `shlex.quote()` is used throughout `TerminalSpawner._call()` and `spawn()` when
  constructing the shell expression string, preventing shell injection from caller-supplied
  Python arguments.
- `TerminalSpawner.__init__` raises `FileNotFoundError` immediately if `terminal_spawner.sh`
  is not found at the expected package path, rather than deferring the error to first use.
- All subprocess calls in `TerminalSpawner` use `timeout=self._timeout` (default 30 s);
  `subprocess.TimeoutExpired` is caught and surfaced as `RuntimeError` with the timed-out
  expression, preventing indefinite hangs from frozen terminal emulators.

### Fixed
- `_ts_log_debug()` exit-code leak: the function previously returned exit code 1 when
  `TROUTER_DEBUG` was unset, which propagated as a failure through callers that checked
  `$?`. Fixed so the function always returns 0.
- `write_heartbeat()` in `TerminalSpawner` now raises `RuntimeError` when the heartbeat
  file does not exist after `write_initial_heartbeat` completes, instead of silently
  returning a path to a file that was never written. Callers relying on the returned
  `Path` can now trust it exists and contains valid JSON.
- `TerminalSpawner.spawn()` raises `RuntimeError` when the shell command exits non-zero
  or returns an empty session identifier, rather than returning `None` or an empty string
  to the caller.

### Notes
- The shell script is intentionally self-contained so it can be sourced in environments
  where the broader `CLI/lib/` tree is not present (e.g., inside a spawned terminal
  session that has not yet activated the full repository).
- Heartbeat files written by `TerminalSpawner` (and by `write_initial_heartbeat` in the
  shell library) are compatible with the existing watchdog format consumed by
  `trouter dashboard`; `HeartbeatData.from_file` reads them without modification.
- The 36 exported functions cover five logical groups: logging (5 helpers + 5 aliases),
  terminal detection (3), session generation (1), emulator-specific spawn/list/attach/kill
  for osascript, iTerm2, tmux, screen, and tmux+iTerm (28), and heartbeat I/O (2).
- Review cycle: 3 cursor-agent passes, 3 Opus fix passes, 3 Opus review passes, 1 Sonnet
  fix pass, 3 Sonnet final review passes. All 129 trouter tests pass with zero regressions
  after the addition of the 18 new tests.
