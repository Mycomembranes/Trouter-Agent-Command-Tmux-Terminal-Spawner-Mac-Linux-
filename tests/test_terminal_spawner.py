"""Tests for the terminal spawner — shell library and Python wrapper."""

import json
import os
import subprocess
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from trouter.terminal.spawner import TerminalSpawner, _SPAWNER_SH

# ---------------------------------------------------------------------------
# Shell library tests
# ---------------------------------------------------------------------------


class TestShellLibrarySelfContained:
    """The shell library must source without errors (no external deps)."""

    def test_source_without_errors(self):
        """Source terminal_spawner.sh in a clean shell — must not fail."""
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}'"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Source failed: {result.stderr}"

    def test_detect_terminal_app_returns_valid(self):
        """detect_terminal_app must return a recognized value."""
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}' && detect_terminal_app"],
            capture_output=True, text=True,
        )
        valid = {"tmux-iterm", "tmux", "iterm", "osascript", "screen", "none"}
        assert result.stdout.strip() in valid

    def test_generate_session_name_format(self):
        """generate_session_name must produce {prefix}_{timestamp}_{random4}."""
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}' && generate_session_name test"],
            capture_output=True, text=True,
        )
        name = result.stdout.strip()
        assert name.startswith("test_")
        parts = name.split("_")
        # prefix_YYYYMMDD_HHMMSS_NNNN → at least 4 parts
        assert len(parts) >= 4, f"Unexpected format: {name}"
        # Last part is a 4-digit random suffix
        assert parts[-1].isdigit() and len(parts[-1]) == 4

    def test_get_terminal_method_returns_string(self):
        """get_terminal_method must return a non-empty string."""
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}' && get_terminal_method"],
            capture_output=True, text=True,
        )
        assert result.stdout.strip() != ""

    def test_escape_applescript_plain(self):
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}' && _escape_applescript 'hello world'"],
            capture_output=True, text=True,
        )
        assert result.stdout.strip() == "hello world"

    def test_escape_applescript_quotes(self):
        result = subprocess.run(
            ["bash", "-c", f"""source '{_SPAWNER_SH}' && _escape_applescript 'say "hi"'"""],
            capture_output=True, text=True,
        )
        assert result.stdout.strip() == 'say \\"hi\\"'

    def test_escape_applescript_backslash(self):
        result = subprocess.run(
            ["bash", "-c", f"""source '{_SPAWNER_SH}' && _escape_applescript 'C:\\Users\\foo'"""],
            capture_output=True, text=True,
        )
        assert result.stdout.strip() == "C:\\\\Users\\\\foo"

    def test_get_background_output_file(self):
        """get_background_output_file must return a path ending in .log."""
        result = subprocess.run(
            ["bash", "-c", f"source '{_SPAWNER_SH}' && get_background_output_file test"],
            capture_output=True, text=True,
        )
        path = result.stdout.strip()
        assert path.endswith(".log")
        assert "test_" in path

    def test_logging_functions_exist(self):
        """All inline logging functions must be callable."""
        for func in ("_ts_log_info", "_ts_log_warn", "_ts_log_error",
                      "_ts_log_success", "_ts_log_debug"):
            result = subprocess.run(
                ["bash", "-c", f"source '{_SPAWNER_SH}' && type -t {func}"],
                capture_output=True, text=True,
            )
            assert result.stdout.strip() == "function", f"{func} not found"


# ---------------------------------------------------------------------------
# Python wrapper tests
# ---------------------------------------------------------------------------


class TestTerminalSpawner:
    """Tests for the TerminalSpawner Python class."""

    def test_init_valid_method(self):
        spawner = TerminalSpawner(method="auto")
        assert spawner.method == "auto"

    def test_init_invalid_method(self):
        with pytest.raises(ValueError, match="Invalid method"):
            TerminalSpawner(method="invalid_method")

    def test_detect_method_returns_string(self):
        spawner = TerminalSpawner()
        method = spawner.detect_method()
        assert isinstance(method, str)
        assert method != ""

    def test_list_sessions_returns_list(self):
        spawner = TerminalSpawner()
        sessions = spawner.list_sessions()
        assert isinstance(sessions, list)

    def test_kill_session_nonexistent(self):
        spawner = TerminalSpawner()
        result = spawner.kill_session("nonexistent_session_xyz_12345")
        assert result is False

    def test_write_heartbeat_creates_file(self, tmp_path):
        spawner = TerminalSpawner(health_dir=tmp_path)
        hb_path = spawner.write_heartbeat(
            "test_session_001",
            working_dir="/tmp",
            command="echo hello",
        )
        assert hb_path.exists()
        data = json.loads(hb_path.read_text())
        assert data["session_id"] == "test_session_001"
        assert data["status"] == "starting"
        assert data["working_dir"] == "/tmp"

    def test_spawn_background(self, tmp_path):
        """Background spawns should create a log file."""
        spawner = TerminalSpawner(method="background", health_dir=tmp_path)
        log_file = str(tmp_path / "test.log")
        result = spawner.spawn(
            "echo 'hello from test'",
            title="test-bg",
            working_dir=str(tmp_path),
            log_file=log_file,
        )
        # Background mode returns the log file path
        assert result.endswith("test.log")
        # Poll for log file creation with timeout
        deadline = time.time() + 5.0
        while not Path(log_file).exists() and time.time() < deadline:
            time.sleep(0.1)
        assert Path(log_file).exists(), f"Log file not created within 5s: {log_file}"


# ---------------------------------------------------------------------------
# Heartbeat JSON compatibility
# ---------------------------------------------------------------------------


class TestHeartbeatCompatibility:
    """Heartbeats written by shell must be parseable by HeartbeatData.from_json."""

    def test_heartbeat_parseable_by_heartbeat_data(self, tmp_path):
        from trouter.health.heartbeat import HeartbeatData

        spawner = TerminalSpawner(health_dir=tmp_path)
        hb_path = spawner.write_heartbeat("compat_test", "/tmp", "echo hello")

        hb = HeartbeatData.from_file(hb_path)
        assert hb is not None
        assert hb.session_id == "compat_test"
        assert hb.status == "starting"
        assert hb.working_dir == "/tmp"

    def test_heartbeat_with_special_chars(self, tmp_path):
        spawner = TerminalSpawner(health_dir=tmp_path)
        hb_path = spawner.write_heartbeat(
            "special_test", "/tmp/dir with spaces", 'echo "hello world"'
        )
        data = json.loads(hb_path.read_text())
        assert data["session_id"] == "special_test"
