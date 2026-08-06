#!/usr/bin/python3
"""End-to-end helper lifecycle tests for the structured chat entry points."""

from __future__ import annotations

import json
import os
import pathlib
import select
import shutil
import stat
import subprocess
import tempfile
import time
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "Server" / "terminal-relay-session"
CHAT = ROOT / "Server" / "terminal-relay-chat"
MARKER = "__TERMINAL_RELAY_CHAT_V1__"


def command_path(name: str) -> str:
    value = shutil.which(name)
    if not value:
        raise SystemExit(f"{name} is required for chat session tests")
    return os.path.realpath(value)


def read_json_line(process: subprocess.Popen, timeout: float = 5) -> dict:
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise AssertionError("timed out waiting for chat protocol output")
    raw = process.stdout.readline()
    if not raw:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise AssertionError(f"chat attachment ended early: {stderr}")
    return json.loads(raw.decode("utf-8"))


def protocol_command(
    kind: str,
    relay_id: str,
    thread_id: str,
    payload: dict,
    request_id: str | None = None,
) -> tuple[str, dict]:
    request_id = request_id or str(uuid.uuid4())
    return request_id, {
        "v": 1,
        "type": kind,
        "requestId": request_id,
        "relayId": relay_id,
        "provider": "codex",
        "providerThreadId": thread_id,
        "sentAt": 0,
        "payload": payload,
    }


def read_until(
    process: subprocess.Popen, kind: str, request_id: str | None = None
) -> dict:
    for _ in range(100):
        value = read_json_line(process)
        if value.get("type") != kind:
            continue
        if (
            request_id is not None
            and value.get("payload", {}).get("requestId") != request_id
        ):
            continue
        return value
    raise AssertionError(f"missing {kind}")


def run() -> None:
    tmux = command_path("tmux")
    python = command_path("python3")
    with tempfile.TemporaryDirectory(prefix="tr-chat-session.", dir="/tmp") as root:
        base = pathlib.Path(os.path.realpath(root))
        workspace = base / "workspace"
        runtime = base / "runtime"
        home = base / "home"
        repository = workspace / "example-repository"
        boot = base / "boot-id"
        flock = base / "flock"
        signal_adapter = base / "signal"
        repository.mkdir(parents=True)
        runtime.mkdir(mode=0o700)
        home.mkdir()
        boot.write_text(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n", encoding="ascii"
        )
        flock.write_text(
            f"""#!{python}
import fcntl
import sys
arguments = sys.argv[1:]
nonblocking = bool(arguments and arguments[0] == "--nonblock")
if nonblocking:
    arguments = arguments[1:]
if len(arguments) != 1 or not arguments[0].isdigit():
    raise SystemExit(64)
try:
    fcntl.flock(
        int(arguments[0]),
        fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0),
    )
except BlockingIOError:
    raise SystemExit(1)
""",
            encoding="utf-8",
        )
        flock.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        signal_adapter.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        signal_adapter.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        socket_label = f"tr-chat-test-{os.getpid()}"
        environment = {
            **os.environ,
            "HOME": str(home),
            "TERMINAL_RELAY_TEST_MODE": "1",
            "TERMINAL_RELAY_TEST_TMUX_PATH": tmux,
            "TERMINAL_RELAY_TEST_TMUX_SOCKET": socket_label,
            "TERMINAL_RELAY_TEST_WORKSPACE_ROOT": str(workspace),
            "TERMINAL_RELAY_TEST_RUNTIME_ROOT": str(runtime),
            "TERMINAL_RELAY_TEST_FLOCK_PATH": str(flock),
            "TERMINAL_RELAY_TEST_BOOT_ID_PATH": str(boot),
            "TERMINAL_RELAY_TEST_SIGNAL_PATH": str(signal_adapter),
            "TERMINAL_RELAY_TEST_CHAT_PATH": str(CHAT),
            "TERMINAL_RELAY_TEST_CHAT_FAKE": "1",
            "TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT": "0",
        }

        def helper(*arguments: str, check: bool = True):
            return subprocess.run(
                ["/bin/bash", str(HELPER), *arguments],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=15,
                check=check,
            )

        def helper_with_input(*arguments: str, data: bytes, check: bool = True):
            return subprocess.run(
                ["/bin/bash", str(HELPER), *arguments],
                env=environment,
                input=data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=15,
                check=check,
            )

        try:
            capability = helper(
                "chat-capabilities-v1", "codex", "example-repository"
            )
            lines = capability.stdout.splitlines()
            assert lines[0] == MARKER
            capability_value = json.loads(lines[1])
            assert capability_value["provider"] == "codex"
            assert capability_value["available"] is True
            assert capability_value["capabilities"]["protocolVersion"] == 1
            assert capability_value["capabilities"]["supportsAttachments"] is True
            assert (
                "file-attachments-v1"
                in capability_value["capabilities"]["features"]
            )

            start = helper(
                "chat-start-v1",
                "codex",
                "example-repository",
                "--model",
                "gpt-5.6-sol",
                "--effort",
                "max",
                "--full-access",
                check=False,
            )
            assert start.returncode == 0, start.stderr
            start_lines = start.stdout.splitlines()
            assert start_lines[0] == MARKER
            start_value = json.loads(start_lines[1])
            relay_id = start_value["relayId"]
            thread_id = start_value["providerThreadId"]
            uuid.UUID(relay_id)
            uuid.UUID(thread_id)
            assert start_value["provider"] == "codex"
            assert start_value["launchOptions"]["model"] == "gpt-5.6-sol"
            assert start_value["launchOptions"]["effort"] == "max"
            assert start_value["launchOptions"]["permissionMode"] == "bypassPermissions"
            assert start_value["launchOptions"]["fullAccess"] is True
            assert set(start_value["launchOptions"]) == {
                "model",
                "effort",
                "permissionMode",
                "fullAccess",
                "fastMode",
            }

            status = helper("status").stdout.splitlines()
            record = next(line for line in status if f"|{relay_id}|" in line)
            fields = record.split("|")
            assert len(fields) == 10
            assert fields[1:5] == [
                "codex",
                "example-repository",
                "0",
                relay_id,
            ]
            assert fields[8] == thread_id
            assert fields[9] == "chat"

            # Session supervision keeps an identifier-only intent and rebuilds
            # provider history after the broker is lost or the worker reboots.
            subprocess.run(
                [
                    tmux,
                    "-f",
                    "/dev/null",
                    "-L",
                    socket_label,
                    "kill-session",
                    "-t",
                    f"terminal-relay-chat-codex-{relay_id}",
                ],
                check=True,
            )
            state_path = runtime / f"chat-{relay_id}" / "broker.json"
            for _ in range(200):
                try:
                    broker_state = json.loads(state_path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    broker_state = {}
                if broker_state.get("status") == "stopped":
                    break
                time.sleep(0.01)
            else:
                raise AssertionError("interrupted broker did not finish cleanly")
            restored = helper("restore", check=False)
            assert restored.returncode == 0, (
                f"stdout={restored.stdout!r} stderr={restored.stderr!r}"
            )
            assert f"Restored codex structured chat {relay_id}" in restored.stdout
            restored_record = next(
                line
                for line in helper("status").stdout.splitlines()
                if f"|{relay_id}|" in line
            )
            assert restored_record.split("|")[8:] == [thread_id, "chat"]

            attachment_request_id = str(uuid.uuid4())
            attachment_id = str(uuid.uuid4())
            attachment_bytes = b"worker-local notes\n"
            upload_arguments = (
                "chat-attachment-upload-v1",
                "codex",
                "example-repository",
                relay_id,
                attachment_request_id,
                attachment_id,
                "txt",
                str(len(attachment_bytes)),
            )
            upload = helper_with_input(*upload_arguments, data=attachment_bytes)
            attachment_path = pathlib.Path(upload.stdout.decode("utf-8"))
            expected_attachment_path = (
                runtime
                / f"chat-{relay_id}"
                / "attachments"
                / attachment_request_id
                / f"{attachment_id}.txt"
            )
            assert attachment_path == expected_attachment_path
            assert attachment_path.read_bytes() == attachment_bytes
            assert stat.S_IMODE(os.lstat(attachment_path).st_mode) == 0o600
            duplicate = helper_with_input(*upload_arguments, data=attachment_bytes)
            assert pathlib.Path(duplicate.stdout.decode("utf-8")) == attachment_path
            conflict = helper_with_input(
                *upload_arguments,
                data=b"different contents\n",
                check=False,
            )
            assert conflict.returncode == 75
            assert attachment_path.read_bytes() == attachment_bytes

            partial_request_id = str(uuid.uuid4())
            partial_id = str(uuid.uuid4())
            partial = helper_with_input(
                "chat-attachment-upload-v1",
                "codex",
                "example-repository",
                relay_id,
                partial_request_id,
                partial_id,
                "bin",
                "10",
                data=b"short",
                check=False,
            )
            assert partial.returncode == 64
            assert not (
                runtime
                / f"chat-{relay_id}"
                / "attachments"
                / partial_request_id
            ).exists()

            process = subprocess.Popen(
                [
                    "/bin/bash",
                    str(HELPER),
                    "chat-attach-v1",
                    "codex",
                    "example-repository",
                    relay_id,
                ],
                env=environment,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
            )
            assert process.stdin is not None
            attach_id, attach = protocol_command(
                "session.attach", relay_id, thread_id, {"afterSeq": 0}
            )
            process.stdin.write(
                (json.dumps(attach, separators=(",", ":")) + "\n").encode("utf-8")
            )
            process.stdin.flush()
            assert read_json_line(process)["type"] == "session.hello"
            read_until(process, "ack", attach_id)

            ping_id, ping = protocol_command("ping", relay_id, thread_id, {})
            process.stdin.write(
                (json.dumps(ping, separators=(",", ":")) + "\n").encode("utf-8")
            )
            process.stdin.flush()
            assert read_until(process, "ack", ping_id)["payload"]["pong"] is True

            turn_request_id, turn = protocol_command(
                "turn.start",
                relay_id,
                thread_id,
                {
                    "text": "Read the attachment",
                    "attachments": [
                        {
                            "id": attachment_id,
                            "path": str(attachment_path),
                            "displayName": "Notes.txt",
                            "mediaType": "text/plain",
                            "kind": "file",
                            "byteCount": len(attachment_bytes),
                        }
                    ],
                },
                request_id=attachment_request_id,
            )
            process.stdin.write(
                (json.dumps(turn, separators=(",", ":")) + "\n").encode("utf-8")
            )
            process.stdin.flush()
            turn_ack = read_until(process, "ack", turn_request_id)
            provider_turn_id = turn_ack["payload"]["turnId"]
            assert attachment_path.exists()

            interrupt_id, interrupt = protocol_command(
                "turn.interrupt",
                relay_id,
                thread_id,
                {},
            )
            interrupt["turnId"] = provider_turn_id
            process.stdin.write(
                (json.dumps(interrupt, separators=(",", ":")) + "\n").encode(
                    "utf-8"
                )
            )
            process.stdin.flush()
            read_until(process, "ack", interrupt_id)
            assert not attachment_path.parent.exists()
            helper(
                "chat-attachment-delete-v1",
                "codex",
                "example-repository",
                relay_id,
                attachment_request_id,
            )

            detach_id, detach = protocol_command(
                "session.detach", relay_id, thread_id, {}
            )
            process.stdin.write(
                (json.dumps(detach, separators=(",", ":")) + "\n").encode("utf-8")
            )
            process.stdin.flush()
            read_until(process, "ack", detach_id)
            process.wait(timeout=5)
            assert process.returncode == 0

            # A stop that fails while the broker is still alive must propagate
            # the failure, not report success and orphan the live session.
            original_state = state_path.read_text(encoding="utf-8")
            state_path.write_text(
                original_state.replace('"status":"ready"', '"status":"stopped"'),
                encoding="utf-8",
            )
            failed_stop = helper(
                "chat-stop-v1",
                "codex",
                "example-repository",
                relay_id,
                check=False,
            )
            assert failed_stop.returncode == 75, failed_stop.stderr
            state_path.write_text(original_state, encoding="utf-8")

            helper(
                "chat-stop-v1",
                "codex",
                "example-repository",
                relay_id,
            )
            for _ in range(100):
                if all(f"|{relay_id}|" not in line for line in helper("status").stdout.splitlines()):
                    break
                time.sleep(0.02)
            else:
                raise AssertionError("stopped chat remained in status")

            # Stopping an already-stopped relay is idempotent and cleans up a
            # leaked restart intent and exact-relay uploads (e.g. from a
            # broker killed before its shutdown handler ran).
            leaked_intent = runtime / f"{relay_id}.chat-intent"
            leaked_intent.write_text("intent\n", encoding="utf-8")
            leaked_intent.chmod(0o600)
            leaked_request = str(uuid.uuid4())
            leaked_upload = (
                runtime
                / f"chat-{relay_id}"
                / "attachments"
                / leaked_request
                / f"{uuid.uuid4()}.txt"
            )
            leaked_upload.parent.mkdir(parents=True, mode=0o700)
            leaked_upload.parent.parent.chmod(0o700)
            leaked_upload.write_bytes(b"stale")
            leaked_upload.chmod(0o600)
            stale = helper(
                "chat-stop-v1",
                "codex",
                "example-repository",
                relay_id,
                check=False,
            )
            assert stale.returncode == 0, stale.stderr
            assert not leaked_intent.exists()
            assert not leaked_upload.parent.parent.exists()
        finally:
            subprocess.run(
                [tmux, "-f", "/dev/null", "-L", socket_label, "kill-server"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    print("Terminal Relay chat session lifecycle tests passed")


if __name__ == "__main__":
    run()
