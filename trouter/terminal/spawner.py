"""Python interface for terminal_spawner.sh — spawn and manage agent terminal sessions.

Thin subprocess wrapper around the self-contained shell library.  The shell
script remains the source of truth for all terminal/tmux/iTerm/screen logic;
this class simply invokes its functions via ``bash -c 'source …; func …'``.
"""

import json
import logging
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# Resolve the shell script bundled in the trouter package
_SPAWNER_SH = Path(__file__).resolve().parent.parent / "shell" / "terminal_spawner.sh"

VALID_METHODS = ("auto", "tmux-iterm", "tmux", "iterm", "osascript", "screen", "background")

# Default subprocess timeout (seconds) — prevents indefinite hangs
_DEFAULT_TIMEOUT = 30


class TerminalSpawner:
    """Create and manage agent terminal sessions.

    Example::

        spawner = TerminalSpawner()
        session = spawner.spawn("claude --resume", title="agent-1")
        print(spawner.list_sessions())
        spawner.kill_session(session)
    """

    def __init__(
        self,
        method: str = "auto",
        session_prefix: str = "agent",
        health_dir: Optional[Path] = None,
        timeout: int = _DEFAULT_TIMEOUT,
    ) -> None:
        if method not in VALID_METHODS:
            raise ValueError(
                f"Invalid method {method!r}; choose from: {', '.join(VALID_METHODS)}"
            )

        self.method = method
        self.session_prefix = session_prefix
        self.health_dir = health_dir or Path.home() / ".claude" / "terminal_health"
        self._timeout = timeout

        if not _SPAWNER_SH.exists():
            raise FileNotFoundError(f"Shell library not found: {_SPAWNER_SH}")

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _env(self) -> Dict[str, str]:
        """Build environment for shell subprocess."""
        env = os.environ.copy()
        env["AGENT_TERMINAL_METHOD"] = self.method
        env["AGENT_SESSION_PREFIX"] = self.session_prefix
        env["WATCHDOG_HEALTH_DIR"] = str(self.health_dir)
        return env

    def _call(self, shell_expr: str, *, capture: bool = True) -> subprocess.CompletedProcess:
        """Source the shell library then evaluate *shell_expr*.

        Log functions are redirected to stderr so that stdout only contains
        the real return value (session name, log path, etc.).
        """
        # Override log wrappers to send all log output to stderr,
        # keeping stdout clean for machine-parseable return values.
        log_redirect = (
            "_ts_log_info()  { echo \"[INFO]  $(date +%H:%M:%S) $*\" >&2; }; "
            "_ts_log_success() { echo \"[OK]    $(date +%H:%M:%S) $*\" >&2; }; "
        )
        cmd = (
            f"source {shlex.quote(str(_SPAWNER_SH))} && "
            f"{log_redirect}{shell_expr}"
        )
        try:
            return subprocess.run(
                ["bash", "-c", cmd],
                capture_output=capture,
                text=True,
                env=self._env(),
                timeout=self._timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"Shell command timed out after {self._timeout}s: {shell_expr[:80]}"
            ) from exc

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def detect_method(self) -> str:
        """Auto-detect the best terminal method for this environment."""
        result = self._call("detect_terminal_app")
        if result.returncode != 0:
            return "none"
        return result.stdout.strip()

    def spawn(
        self,
        command: str,
        title: Optional[str] = None,
        working_dir: Optional[str] = None,
        log_file: Optional[str] = None,
    ) -> str:
        """Spawn an agent in a new terminal session.

        Returns the session name (or log file path for background mode).
        Raises RuntimeError if the spawn fails or returns no session identifier.
        """
        title = title or f"Agent-{int(time.time()) % 100000}"
        working_dir = working_dir or os.getcwd()

        parts = [
            f"spawn_agent_terminal {shlex.quote(command)}",
            shlex.quote(title),
            shlex.quote(working_dir),
        ]
        if log_file:
            parts.append(shlex.quote(log_file))

        result = self._call(" ".join(parts))
        if result.returncode != 0:
            stderr = result.stderr.strip()
            raise RuntimeError(f"spawn failed: {stderr}")

        # The last non-empty stdout line is the session name / log path
        lines = [line for line in result.stdout.strip().splitlines() if line.strip()]
        if not lines:
            raise RuntimeError(
                f"spawn returned no session identifier; stderr: {result.stderr.strip()}"
            )
        return lines[-1].strip()

    def list_sessions(self) -> List[Dict]:
        """List all agent sessions with health status.

        Returns a list of dicts with keys: session_id, age_seconds, status, health.
        """
        heartbeats_dir = self.health_dir / "heartbeats"
        sessions: List[Dict] = []

        # Collect tmux sessions matching the prefix.
        # tmux list-sessions returns 0 on success and 1 when no server is running.
        try:
            tmux_result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}"],
                capture_output=True, text=True,
                timeout=self._timeout,
            )
            tmux_names = [
                n for n in tmux_result.stdout.strip().splitlines()
                if n.startswith(self.session_prefix)
            ] if tmux_result.returncode in (0, 1) else []
        except (FileNotFoundError, subprocess.TimeoutExpired):
            logger.debug("tmux not available or timed out, skipping tmux session discovery")
            tmux_names = []

        for name in tmux_names:
            entry: Dict = {"session_id": name, "type": "tmux"}
            hb_file = heartbeats_dir / f"{name}.heartbeat"
            if hb_file.exists():
                try:
                    data = json.loads(hb_file.read_text())
                    age = time.time() - data.get("unix_time", 0)
                    entry["age_seconds"] = round(age, 1)
                    entry["status"] = data.get("status", "unknown")
                    entry["health"] = (
                        "healthy" if age < 30
                        else "warning" if age < 60
                        else "frozen"
                    )
                    entry["last_tool"] = data.get("last_tool")
                    entry["pid"] = data.get("pid")
                except (json.JSONDecodeError, KeyError):
                    entry.update(age_seconds=None, status="unknown", health="unknown")
            else:
                entry.update(age_seconds=None, status="no heartbeat", health="unknown")
            sessions.append(entry)

        # Collect screen sessions matching the prefix.
        # screen -ls returns 0 when sessions exist; non-zero otherwise.
        try:
            screen_result = subprocess.run(
                ["screen", "-ls"],
                capture_output=True, text=True,
                timeout=self._timeout,
            )
            if screen_result.returncode in (0, 1):
                for line in screen_result.stdout.splitlines():
                    if f".{self.session_prefix}" in line:
                        parts = line.strip().split()
                        if parts:
                            sessions.append({
                                "session_id": parts[0],
                                "type": "screen",
                                "age_seconds": None,
                                "status": "active",
                                "health": "unknown",
                            })
        except (FileNotFoundError, subprocess.TimeoutExpired):
            logger.debug("screen not available or timed out, skipping screen session discovery")

        return sessions

    def attach(self, session_name: Optional[str] = None) -> bool:
        """Attach to a session (most recent if *session_name* not given)."""
        if session_name:
            expr = f"attach_agent_session {shlex.quote(session_name)}"
        else:
            expr = "attach_agent_session"
        result = self._call(expr, capture=False)
        return result.returncode == 0

    def kill_session(self, session_name: str) -> bool:
        """Kill a specific terminal session."""
        result = self._call(f"kill_agent_session {shlex.quote(session_name)}")
        return result.returncode == 0

    def kill_all(self) -> int:
        """Kill all agent sessions. Returns count of sessions that existed."""
        sessions = self.list_sessions()
        count = 0
        for s in sessions:
            if self.kill_session(s["session_id"]):
                count += 1
        return count

    def write_heartbeat(self, session_name: str, working_dir: str, command: str) -> Path:
        """Write an initial heartbeat file for watchdog tracking.

        Raises RuntimeError if the shell function fails.
        """
        result = self._call(
            f"write_initial_heartbeat {shlex.quote(session_name)} "
            f"{shlex.quote(working_dir)} {shlex.quote(command)}"
        )
        hb_path = self.health_dir / "heartbeats" / f"{session_name}.heartbeat"
        if result.returncode != 0 or not hb_path.exists():
            raise RuntimeError(
                f"Failed to write heartbeat for {session_name}: {result.stderr.strip()}"
            )
        return hb_path
