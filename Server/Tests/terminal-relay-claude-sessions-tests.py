#!/usr/bin/python3
"""Synthetic contract tests for the Claude session metadata adapter."""

from __future__ import annotations

import contextlib
import importlib.util
import importlib.machinery
import io
import json
import os
import pathlib
import subprocess
import tempfile
from types import SimpleNamespace


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
ADAPTER_PATH = REPOSITORY_ROOT / "Server" / "terminal-relay-claude-sessions"
SESSION_ONE = "11111111-1111-4111-8111-111111111111"
SESSION_TWO = "22222222-2222-4222-8222-222222222222"
SESSION_THREE = "33333333-3333-4333-8333-333333333333"
SESSION_FOUR = "44444444-4444-4444-8444-444444444444"
ACCOUNT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def load_adapter():
    loader = importlib.machinery.SourceFileLoader(
        "terminal_relay_claude_sessions",
        str(ADAPTER_PATH),
    )
    specification = importlib.util.spec_from_loader(loader.name, loader)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def capture_json(callable_value, *arguments):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        callable_value(*arguments)
    return json.loads(output.getvalue())


def session(session_id, title, modified, cwd):
    return SimpleNamespace(
        session_id=session_id,
        summary=title,
        custom_title=None,
        last_modified=modified,
        cwd=str(cwd),
    )


def run() -> None:
    adapter = load_adapter()
    with tempfile.TemporaryDirectory(prefix="terminal-relay-claude-adapter.") as root:
        root_path = pathlib.Path(os.path.realpath(root))
        project = root_path / "workspace" / "example-repository"
        worktree = root_path / "worktree"
        outside = root_path / "outside"
        archives = root_path / "runtime" / "archives"
        project.mkdir(parents=True)
        outside.mkdir()
        archives.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(project)], check=True)
        subprocess.run(
            ["git", "-C", str(project), "config", "user.email", "test@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(project), "config", "user.name", "Terminal Relay Test"],
            check=True,
        )
        (project / "README.md").write_text("synthetic\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(project), "add", "README.md"], check=True)
        subprocess.run(
            ["git", "-C", str(project), "commit", "-qm", "synthetic"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(project),
                "worktree",
                "add",
                "-qb",
                "synthetic-worktree",
                str(worktree),
            ],
            check=True,
        )

        records = [
            session(SESSION_ONE, "Inactive title", 4_000, project),
            session(SESSION_TWO, "Worktree title", 3_000, worktree),
            session(SESSION_THREE, "Out of scope", 2_000, outside),
            session(SESSION_FOUR, "Archived title", 1_000, project),
        ]

        def list_sessions(**_arguments):
            return records

        def get_session_info(session_id, **_arguments):
            return next(
                (record for record in records if record.session_id == session_id),
                None,
            )

        def rename_session(session_id, title, **_arguments):
            record = get_session_info(session_id)
            assert record is not None
            record.custom_title = title

        adapter.load_sdk = lambda: (
            get_session_info,
            list_sessions,
            rename_session,
        )
        adapter.provider_active_session_ids = (
            lambda _project, _test_mode: {SESSION_TWO}
        )
        (archives / SESSION_FOUR).write_text(
            adapter.ARCHIVE_MARKER_CONTENT,
            encoding="utf-8",
        )

        open_catalog = capture_json(
            adapter.list_command,
            [str(project), str(archives), "open"],
            True,
            ACCOUNT_ID,
        )
        assert [row["threadID"] for row in open_catalog["threads"]] == [
            SESSION_ONE,
            SESSION_TWO,
        ]
        assert open_catalog["threads"][0]["activityState"] == "inactive"
        assert open_catalog["threads"][0]["capabilities"]["resume"] is True
        assert all(
            row["accountID"] == ACCOUNT_ID for row in open_catalog["threads"]
        )
        assert open_catalog["threads"][1]["activityState"] == "external-active"
        assert open_catalog["threads"][1]["capabilities"]["resume"] is False
        assert all(
            row["title"] != "Out of scope" for row in open_catalog["threads"]
        )

        archived_catalog = capture_json(
            adapter.list_command,
            [str(project), str(archives), "archived"],
            True,
        )
        assert [row["threadID"] for row in archived_catalog["threads"]] == [
            SESSION_FOUR
        ]
        assert archived_catalog["threads"][0]["capabilities"]["unarchive"] is True

        renamed = capture_json(
            adapter.rename_command,
            [str(project), str(archives), SESSION_ONE, "Renamed title"],
            True,
        )
        assert renamed["threads"][0]["title"] == "Renamed title"
        assert renamed["threads"][0]["threadID"] == SESSION_ONE

        adapter.provider_active_session_ids = lambda _project, _test_mode: None
        unknown = capture_json(
            adapter.read_command,
            [str(project), str(archives), SESSION_ONE],
            True,
        )
        assert unknown["threads"][0]["activityState"] == "unknown"
        assert unknown["threads"][0]["capabilities"]["rename"] is False
        try:
            adapter.activity_command([str(project), SESSION_ONE], True)
        except adapter.AdapterError as error:
            assert error.exit_code == 70
        else:
            raise AssertionError("unknown activity was accepted")

        page_records = [
            session(
                f"00000000-0000-4000-8000-{index:012d}",
                f"Title {index}",
                100_000 - index,
                project,
            )
            for index in range(101)
        ]
        adapter.load_sdk = lambda: (
            get_session_info,
            lambda **_arguments: page_records,
            rename_session,
        )
        adapter.provider_active_session_ids = lambda _project, _test_mode: set()
        page = capture_json(
            adapter.list_command,
            [str(project), str(archives), "open"],
            True,
        )
        assert len(page["threads"]) == 100
        assert page["nextCursor"] == "100"
        final_bounded_page = capture_json(
            adapter.list_command,
            [str(project), str(archives), "open", "2000"],
            True,
        )
        assert len(final_bounded_page["threads"]) == 100
        assert final_bounded_page["nextCursor"] is None

        config_directory = root_path / "claude-account-data"
        config_directory.mkdir(mode=0o700)
        runtime_adapter = load_adapter()
        original_environment = {
            key: os.environ.get(key)
            for key in (
                "TERMINAL_RELAY_PROVIDER",
                "TERMINAL_RELAY_ACCOUNT_ID",
                "CLAUDE_CONFIG_DIR",
            )
        }
        original_run = runtime_adapter.subprocess.run
        captured_environment = None

        def fake_claude_run(*_arguments, **kwargs):
            nonlocal captured_environment
            captured_environment = kwargs["env"]
            return SimpleNamespace(returncode=0, stdout=b"[]")

        try:
            os.environ["TERMINAL_RELAY_PROVIDER"] = "claude"
            os.environ["TERMINAL_RELAY_ACCOUNT_ID"] = ACCOUNT_ID
            os.environ["CLAUDE_CONFIG_DIR"] = str(config_directory)
            assert runtime_adapter.runtime_account_identity() == ACCOUNT_ID
            runtime_adapter.subprocess.run = fake_claude_run
            assert runtime_adapter.provider_active_session_ids(str(project), True) == set()
            assert captured_environment is not None
            assert captured_environment["CLAUDE_CONFIG_DIR"] == str(config_directory)
        finally:
            runtime_adapter.subprocess.run = original_run
            for key, value in original_environment.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        bad_marker = archives / SESSION_ONE
        bad_marker.write_text("corrupt\n", encoding="utf-8")
        try:
            adapter.session_is_archived(str(archives), SESSION_ONE)
        except adapter.AdapterError:
            pass
        else:
            raise AssertionError("corrupt archive state was accepted")

    print("Claude session adapter tests passed")


if __name__ == "__main__":
    run()
