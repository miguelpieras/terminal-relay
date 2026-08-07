#!/usr/bin/python3
"""Deterministic protocol and broker tests for terminal-relay-chat."""

from __future__ import annotations

import asyncio
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import queue
import socket
import stat
import sys
import tempfile
import threading
from types import SimpleNamespace
import uuid


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
BROKER_PATH = REPOSITORY_ROOT / "Server" / "terminal-relay-chat"
THREAD_ID = "11111111-1111-4111-8111-111111111111"
RELAY_ID = "22222222-2222-4222-8222-222222222222"


def load_broker():
    loader = importlib.machinery.SourceFileLoader("terminal_relay_chat", str(BROKER_PATH))
    specification = importlib.util.spec_from_loader(loader.name, loader)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[loader.name] = module
    specification.loader.exec_module(module)
    return module


class ProtocolClient:
    def __init__(self, module, reader, writer, relay_id=RELAY_ID):
        self.module = module
        self.reader = reader
        self.writer = writer
        self.relay_id = relay_id
        self.records: list[dict] = []

    def command(self, kind: str, payload: dict, **identities) -> tuple[str, dict]:
        request_id = str(uuid.uuid4())
        value = {
            "v": 1,
            "type": kind,
            "requestId": request_id,
            "relayId": self.relay_id,
            "provider": "codex",
            "providerThreadId": THREAD_ID,
            "sentAt": 0,
            "payload": payload,
            **identities,
        }
        return request_id, value

    async def send(self, value: dict) -> None:
        self.writer.write(self.module.encode_record(value))
        await self.writer.drain()

    async def read(self, timeout: float = 2) -> dict:
        raw = await asyncio.wait_for(self.reader.readline(), timeout)
        assert raw, "broker closed before expected record"
        value = self.module.load_record(raw.rstrip(b"\r\n"))
        self.records.append(value)
        return value

    async def read_type(self, event_type: str, request_id: str | None = None) -> dict:
        for _ in range(100):
            value = await self.read()
            if value.get("type") != event_type:
                continue
            if (
                request_id is not None
                and value.get("payload", {}).get("requestId") != request_id
            ):
                continue
            return value
        raise AssertionError(f"missing {event_type}")

    async def attach(self, after_seq: int = 0, generation: str | None = None):
        payload = {"afterSeq": after_seq}
        if generation is not None:
            payload["snapshotGeneration"] = generation
        request_id, command = self.command("session.attach", payload)
        await self.send(command)
        hello = await self.read()
        assert hello["type"] == "session.hello"
        assert hello["seq"] == 0
        terminal = await self.read_type("ack", request_id)
        return hello, terminal

    async def close(self) -> None:
        self.writer.close()
        await self.writer.wait_closed()


async def connect(module, broker, after_seq=0, generation=None) -> ProtocolClient:
    reader, writer = await asyncio.open_unix_connection(broker.socket_path)
    client = ProtocolClient(module, reader, writer, broker.relay_id)
    await client.attach(after_seq, generation)
    return client


async def wait_ready(broker) -> None:
    # The attach surface opens before the provider connects; wait for the
    # provider-ready state so tests observe the fully resumed broker.
    for _ in range(200):
        if (
            pathlib.Path(broker.socket_path).exists()
            and broker.connection_state == "streaming"
        ):
            return
        await asyncio.sleep(0.01)
    raise AssertionError("broker did not become ready")


async def wait_attach_surface(broker) -> None:
    for _ in range(200):
        if pathlib.Path(broker.socket_path).exists():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("broker did not open its attach surface")


def exercise_attachment_upload(module, root: pathlib.Path) -> None:
    runtime = root / "upload-runtime"
    runtime.mkdir(mode=0o700)
    os.chmod(runtime, 0o700)
    relay_id = "91919191-9191-4919-8919-919191919191"
    module.prepare_session_directory(str(runtime), relay_id)
    request_id = "92929292-9292-4929-8929-929292929292"
    attachment_id = "93939393-9393-4939-8939-939393939393"

    def upload(data: bytes, declared_size: int, *, item_id: str = attachment_id):
        original_stdin = module.sys.stdin
        module.sys.stdin = SimpleNamespace(buffer=io.BytesIO(data))
        try:
            return module.upload_attachment(
                str(runtime),
                relay_id,
                request_id,
                item_id,
                "txt",
                declared_size,
            )
        finally:
            module.sys.stdin = original_stdin

    uploaded = pathlib.Path(upload(b"hello", 5))
    expected = (
        runtime
        / f"chat-{relay_id}"
        / "attachments"
        / request_id
        / f"{attachment_id}.txt"
    )
    assert uploaded == expected
    assert uploaded.read_bytes() == b"hello"
    assert stat.S_IMODE(os.lstat(uploaded).st_mode) == 0o600
    assert stat.S_IMODE(os.lstat(uploaded.parent).st_mode) == 0o700

    assert pathlib.Path(upload(b"hello", 5)) == uploaded
    try:
        upload(b"other", 5)
    except module.ChatError as error:
        assert error.code == "uploadConflict"
    else:
        raise AssertionError("accepted conflicting attachment bytes")
    assert uploaded.read_bytes() == b"hello"

    partial_id = "94949494-9494-4949-8949-949494949494"
    try:
        upload(b"no", 4, item_id=partial_id)
    except module.ChatError as error:
        assert error.code == "invalidAttachments"
    else:
        raise AssertionError("accepted a partial attachment upload")
    assert not (uploaded.parent / f"{partial_id}.txt").exists()
    assert not any(entry.name.endswith(".tmp") for entry in uploaded.parent.iterdir())

    try:
        upload(b"extra", 4, item_id=partial_id)
    except module.ChatError as error:
        assert error.code == "invalidAttachments"
    else:
        raise AssertionError("accepted excess attachment bytes")
    assert not (uploaded.parent / f"{partial_id}.txt").exists()

    module.discard_attachment_request(str(runtime), relay_id, request_id)
    module.discard_attachment_request(str(runtime), relay_id, request_id)
    assert not uploaded.parent.exists()

    outside = root / "upload-symlink-target"
    outside.mkdir(mode=0o700)
    request_directory = uploaded.parent
    request_directory.symlink_to(outside, target_is_directory=True)
    try:
        upload(b"hello", 5)
    except module.ChatError as error:
        assert error.code == "unsafeState"
    else:
        raise AssertionError("accepted a symbolic upload directory")
    assert list(outside.iterdir()) == []
    request_directory.unlink()


async def exercise_attachment_lifecycle(module, root: pathlib.Path) -> None:
    runtime = root / "lifecycle-runtime"
    project = root / "lifecycle-project"
    runtime.mkdir(mode=0o700)
    project.mkdir()
    os.chmod(runtime, 0o700)
    relay_id = "a1919191-9191-4919-8919-919191919191"
    provider = module.FakeProvider(str(project), THREAD_ID, {})
    broker = module.ChatBroker(
        "codex", "example-repository", str(project), str(runtime), relay_id, provider, {}
    )
    module.prepare_session_directory(str(runtime), relay_id)
    attachment_root = pathlib.Path(broker.attachment_root)
    attachment_root.mkdir(mode=0o700)
    os.chmod(attachment_root, 0o700)

    terminal_events = ("turn.completed", "turn.failed", "turn.interrupted")
    for index, event_type in enumerate(terminal_events, start=1):
        request_id = f"{index:08x}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        turn_id = f"{index + 10:08x}-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        request_directory = attachment_root / request_id
        request_directory.mkdir(mode=0o700)
        os.chmod(request_directory, 0o700)
        attachment_path = request_directory / (
            f"{index + 20:08x}-cccc-4ccc-8ccc-cccccccccccc.txt"
        )
        attachment_path.write_bytes(b"temporary")
        os.chmod(attachment_path, 0o600)
        broker.turn_attachment_requests[turn_id] = {request_id}
        await broker._publish(event_type, {"status": "done"}, turn_id=turn_id)
        assert not request_directory.exists()

    aggregate_request = "e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1"
    aggregate_directory = attachment_root / aggregate_request
    aggregate_directory.mkdir(mode=0o700)
    os.chmod(aggregate_directory, 0o700)
    aggregate_attachments = []
    for index in range(5):
        attachment_id = f"{index + 30:08x}-eeee-4eee-8eee-eeeeeeeeeeee"
        path = aggregate_directory / f"{attachment_id}.bin"
        path.touch(mode=0o600)
        os.chmod(path, 0o600)
        os.truncate(path, module.MAX_ATTACHMENT_FILE_BYTES)
        aggregate_attachments.append(
            {
                "id": attachment_id,
                "path": str(path),
                "displayName": f"file-{index}.bin",
                "mediaType": "application/octet-stream",
                "kind": "file",
                "byteCount": module.MAX_ATTACHMENT_FILE_BYTES,
            }
        )
    aggregate_payload = {"text": "Inspect", "attachments": aggregate_attachments}
    aggregate_command = {
        "type": "turn.start",
        "requestId": aggregate_request,
        "relayId": relay_id,
        "provider": "codex",
        "providerThreadId": THREAD_ID,
        "payload": aggregate_payload,
    }
    try:
        await broker._execute_command(
            "turn.start", aggregate_request, aggregate_payload, aggregate_command
        )
    except module.ChatError as error:
        assert error.code == "invalidAttachments"
    else:
        raise AssertionError("accepted attachments over the per-turn limit")
    assert not aggregate_directory.exists()

    unsupported_request = "e2e2e2e2-e2e2-4e2e-8e2e-e2e2e2e2e2e2"
    unsupported_directory = attachment_root / unsupported_request
    unsupported_directory.mkdir(mode=0o700)
    os.chmod(unsupported_directory, 0o700)
    unsupported_id = "e3e3e3e3-e3e3-4e3e-8e3e-e3e3e3e3e3e3"
    unsupported_path = unsupported_directory / f"{unsupported_id}.txt"
    unsupported_path.write_bytes(b"opaque")
    os.chmod(unsupported_path, 0o600)
    broker.provider_name = "claude"
    try:
        broker.resolve_turn_attachment(
            {
                "id": unsupported_id,
                "path": str(unsupported_path),
                "displayName": "opaque.txt",
                "mediaType": "text/plain",
                "kind": "file",
                "byteCount": 6,
            },
            unsupported_request,
        )
    except module.ChatError as error:
        assert error.code == "unsupportedAttachments"
    else:
        raise AssertionError("accepted a generic file for Claude")
    finally:
        broker.provider_name = "codex"
    module.discard_attachment_request(str(runtime), relay_id, unsupported_request)

    image_request = "e4e4e4e4-e4e4-4e4e-8e4e-e4e4e4e4e4e4"
    image_directory = attachment_root / image_request
    image_directory.mkdir(mode=0o700)
    os.chmod(image_directory, 0o700)
    image_id = "e5e5e5e5-e5e5-4e5e-8e5e-e5e5e5e5e5e5"
    mismatched_extension_path = image_directory / f"{image_id}.txt"
    mismatched_extension_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    os.chmod(mismatched_extension_path, 0o600)
    try:
        broker.resolve_turn_attachment(
            {
                "id": image_id,
                "path": str(mismatched_extension_path),
                "displayName": "opaque.txt",
                "mediaType": "text/plain",
                "kind": "file",
            },
            image_request,
        )
    except module.ChatError as error:
        assert error.code == "invalidAttachments"
    else:
        raise AssertionError("accepted incomplete managed attachment metadata")
    for path, media_type in (
        (mismatched_extension_path, "image/png"),
        (image_directory / f"{image_id}.png", "image/jpeg"),
    ):
        if not path.exists():
            path.write_bytes(b"\x89PNG\r\n\x1a\n")
            os.chmod(path, 0o600)
        try:
            broker.resolve_turn_attachment(
                {
                    "id": image_id,
                    "path": str(path),
                    "displayName": "image.png",
                    "mediaType": media_type,
                    "kind": "image",
                    "byteCount": 8,
                },
                image_request,
            )
        except module.ChatError as error:
            assert error.code == "invalidAttachments"
        else:
            raise AssertionError("accepted mismatched PNG attachment metadata")
    module.discard_attachment_request(str(runtime), relay_id, image_request)

    claimed_request = "d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1"
    orphan_request = "d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2"
    for request_id in (claimed_request, orphan_request):
        request_directory = attachment_root / request_id
        request_directory.mkdir(mode=0o700)
        os.chmod(request_directory, 0o700)
        os.utime(
            request_directory,
            (0, 0),
            follow_symlinks=False,
        )
    broker.turn_attachment_requests[
        "d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3"
    ] = {claimed_request}
    broker.last_attachment_sweep = -module.ATTACHMENT_SWEEP_SECONDS
    broker._sweep_attachment_orphans()
    assert (attachment_root / claimed_request).exists()
    assert not (attachment_root / orphan_request).exists()

    other_relay_id = "d4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4"
    other_attachment_root = (
        runtime / f"chat-{other_relay_id}" / "attachments"
    )
    other_attachment_root.mkdir(parents=True, mode=0o700)
    os.chmod(other_attachment_root.parent, 0o700)
    os.chmod(other_attachment_root, 0o700)
    other_attachment = other_attachment_root / "neighbor.txt"
    other_attachment.write_bytes(b"other relay")
    os.chmod(other_attachment, 0o600)
    broker._clear_all_attachments()
    assert not attachment_root.exists()
    assert other_attachment.read_bytes() == b"other relay"


async def exercise_protocol(module, root: pathlib.Path) -> None:
    runtime = root / "runtime"
    project = root / "workspace" / "example-repository"
    runtime.mkdir(parents=True, mode=0o700)
    os.chmod(runtime, 0o700)
    project.mkdir(parents=True)
    (project / "README.md").write_text("hello π\n", encoding="utf-8")
    outside = root / "outside.txt"
    outside.write_text("private\n", encoding="utf-8")

    history = [
        {
            "type": "message.completed",
            "turnId": THREAD_ID,
            "itemId": "33333333-3333-4333-8333-333333333333",
            "payload": {"role": "user", "text": "older", "status": "completed"},
        }
    ]
    provider = module.FakeProvider(str(project), THREAD_ID, {}, scripted_history=history)
    broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        RELAY_ID,
        provider,
        {},
    )
    legacy_attachment_root = root / "attachments" / RELAY_ID
    broker.legacy_attachment_root = str(legacy_attachment_root.resolve())
    legacy_attachment_name = "abababab-abab-4bab-8bab-abababababab.png"
    legacy_attachment_path = legacy_attachment_root / legacy_attachment_name
    symlink_name = "acacacac-acac-4cac-8cac-acacacacacac.png"
    symlink_path = legacy_attachment_root / symlink_name
    cross_relay_root = root / "attachments" / "99999999-9999-4999-8999-999999999999"
    cross_relay_root.mkdir(parents=True, mode=0o700)
    os.chmod(cross_relay_root, 0o700)
    cross_relay_path = cross_relay_root / "adadadad-adad-4dad-8dad-adadadadadad.png"
    cross_relay_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    os.chmod(cross_relay_path, 0o600)
    outside_attachment_root = root / "outside-attachments"
    outside_attachment_root.mkdir(mode=0o700)
    outside_attachment_path = (
        outside_attachment_root / "aeaeaeae-aeae-4eae-8eae-aeaeaeaeaeae.png"
    )
    outside_attachment_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    os.chmod(outside_attachment_path, 0o600)
    broker_task = asyncio.create_task(broker.run())
    await wait_ready(broker)

    legacy_attachment_root.mkdir(parents=True, mode=0o700)
    os.chmod(legacy_attachment_root, 0o700)
    legacy_attachment_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    os.chmod(legacy_attachment_path, 0o600)
    symlink_path.symlink_to(legacy_attachment_path)

    socket_info = os.lstat(broker.socket_path)
    state_info = os.lstat(broker.state_path)
    assert stat.S_ISSOCK(socket_info.st_mode)
    assert stat.S_IMODE(socket_info.st_mode) == 0o600
    assert stat.S_IMODE(state_info.st_mode) == 0o600
    assert "older" not in pathlib.Path(broker.state_path).read_text(encoding="utf-8")

    first = await connect(module, broker)
    assert any(record["type"] == "conversation.snapshot" for record in first.records)
    snapshot = next(
        record for record in first.records if record["type"] == "conversation.snapshot"
    )
    assert snapshot["payload"]["items"][0]["payload"]["text"] == "older"
    assert snapshot["payload"]["baseSeq"] == snapshot["seq"]

    # A matching cursor attaches through replay and multiple clients see the
    # same provider event sequence.
    cursor = broker.sequence
    generation = broker.snapshot_generation
    second = await connect(module, broker, cursor, generation)
    assert second.records[-1]["payload"]["replayed"] is True
    second_attach_ack = second.records[-1]
    mirrored_attach_ack = await first.read_type(
        "ack", second_attach_ack["payload"]["requestId"]
    )
    assert mirrored_attach_ack["seq"] == second_attach_ack["seq"]
    event = await broker.emit(
        "message.delta",
        {"role": "assistant", "text": "stream"},
        turn_id=THREAD_ID,
        item_id="44444444-4444-4444-8444-444444444444",
    )
    assert event["seq"] == second_attach_ack["seq"] + 1
    assert (await first.read_type("message.delta"))["seq"] == event["seq"]
    assert (await second.read_type("message.delta"))["seq"] == event["seq"]
    assert broker.snapshot_payload()["items"][-1]["occurredAt"] == event["occurredAt"]

    # Every command receives an acknowledgement and turn.start is idempotent.
    ping_id, ping = first.command("ping", {})
    await first.send(ping)
    assert (await first.read_type("ack", ping_id))["payload"]["pong"] is True

    for invalid_path, expected_code in (
        (str(cross_relay_path), "pathOutOfScope"),
        (str(symlink_path), "invalidAttachments"),
        (str(outside_attachment_path), "pathOutOfScope"),
    ):
        invalid_id, invalid_turn = first.command(
            "turn.start",
            {
                "text": "Inspect",
                "attachments": [{"path": invalid_path}],
            },
        )
        await first.send(invalid_turn)
        assert (
            await first.read_type("error", invalid_id)
        )["payload"]["code"] == expected_code
    assert provider.start_attempts == 0

    isolated_request_id, isolated_turn = first.command(
        "turn.start", {"text": "Inspect", "attachments": []}
    )
    foreign_request_id = "afafafaf-afaf-4faf-8faf-afafafafafaf"
    foreign_directory = pathlib.Path(broker.attachment_root) / foreign_request_id
    foreign_directory.mkdir(parents=True, mode=0o700)
    os.chmod(pathlib.Path(broker.attachment_root), 0o700)
    os.chmod(foreign_directory, 0o700)
    foreign_path = foreign_directory / "bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc.txt"
    foreign_path.write_bytes(b"private")
    os.chmod(foreign_path, 0o600)
    isolated_turn["payload"]["attachments"] = [
        {
            "id": "bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc",
            "path": str(foreign_path),
            "displayName": "notes.txt",
            "mediaType": "text/plain",
            "kind": "file",
            "byteCount": 7,
        }
    ]
    await first.send(isolated_turn)
    isolated_error = await first.read_type("error", isolated_request_id)
    assert isolated_error["payload"]["code"] == "pathOutOfScope"
    assert foreign_path.exists()

    rejected_request_id, rejected_turn = first.command(
        "turn.start",
        {
            "text": "Inspect",
            "attachments": [],
            "model": "invalid model",
        },
    )
    rejected_attachment_id = "bebebebe-bebe-4ebe-8ebe-bebebebebebe"
    rejected_directory = pathlib.Path(broker.attachment_root) / rejected_request_id
    rejected_directory.mkdir(mode=0o700)
    os.chmod(rejected_directory, 0o700)
    rejected_path = rejected_directory / f"{rejected_attachment_id}.txt"
    rejected_path.write_bytes(b"reject me")
    os.chmod(rejected_path, 0o600)
    rejected_turn["payload"]["attachments"] = [
        {
            "id": rejected_attachment_id,
            "path": str(rejected_path),
            "displayName": "Rejected.txt",
            "mediaType": "text/plain",
            "kind": "file",
            "byteCount": 9,
        }
    ]
    await first.send(rejected_turn)
    rejected_error = await first.read_type("error", rejected_request_id)
    assert rejected_error["payload"]["code"] == "invalidOptions"
    assert not rejected_directory.exists()

    turn_request_id, turn = first.command(
        "turn.start",
        {
            "text": "Build it",
            "attachments": [],
            "model": "example-model",
            "reasoningEffort": "high",
            "sandbox": "workspace-write",
            "approvalPolicy": "on-request",
            "fastMode": True,
        },
    )
    attachment_id = "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"
    attachment_directory = pathlib.Path(broker.attachment_root) / turn_request_id
    attachment_directory.mkdir(parents=True, mode=0o700)
    os.chmod(pathlib.Path(broker.attachment_root), 0o700)
    os.chmod(attachment_directory, 0o700)
    attachment_path = attachment_directory / f"{attachment_id}.txt"
    attachment_path.write_bytes(b"build notes")
    os.chmod(attachment_path, 0o600)
    turn["payload"]["attachments"] = [
        {
            "id": attachment_id,
            "path": str(attachment_path),
            "displayName": "Build Notes.txt",
            "mediaType": "text/plain",
            "kind": "file",
            "byteCount": 11,
        }
    ]
    await asyncio.gather(first.send(turn), second.send(turn))
    turn_ack = await first.read_type("ack", turn_request_id)
    second_turn_ack = await second.read_type("ack", turn_request_id)
    turn_id = turn_ack["payload"]["turnId"]
    assert second_turn_ack["payload"]["turnId"] == turn_id
    assert provider.start_attempts == 1
    assert provider.turn_commands == [turn_request_id]
    assert provider.turn_payloads[0]["attachments"] == [
        {
            "id": attachment_id,
            "path": str(attachment_path),
            "displayName": "Build Notes.txt",
            "mediaType": "text/plain",
            "kind": "file",
            "byteCount": 11,
        }
    ]
    assert attachment_path.exists()
    await first.send(turn)
    await first.read_type("ack", turn_request_id)
    assert provider.turn_commands == [turn_request_id]

    active_rejection_id, active_rejection = first.command(
        "turn.start", {"text": "Queue this", "attachments": []}
    )
    active_attachment_id = "cececece-cece-4ece-8ece-cececececece"
    active_rejection_directory = (
        pathlib.Path(broker.attachment_root) / active_rejection_id
    )
    active_rejection_directory.mkdir(mode=0o700)
    os.chmod(active_rejection_directory, 0o700)
    active_rejection_path = (
        active_rejection_directory / f"{active_attachment_id}.txt"
    )
    active_rejection_path.write_bytes(b"later")
    os.chmod(active_rejection_path, 0o600)
    active_rejection["payload"]["attachments"] = [
        {
            "id": active_attachment_id,
            "path": str(active_rejection_path),
            "displayName": "Later.txt",
            "mediaType": "text/plain",
            "kind": "file",
            "byteCount": 5,
        }
    ]
    await first.send(active_rejection)
    active_error = await first.read_type("error", active_rejection_id)
    assert active_error["payload"]["code"] == "turnActive"
    assert not active_rejection_directory.exists()

    interrupt_id, interrupt = first.command(
        "turn.interrupt", {}, turnId=turn_id
    )
    await first.send(interrupt)
    assert (
        await first.read_type("ack", interrupt_id)
    )["payload"]["interruptRequested"] is True
    assert not attachment_directory.exists()
    stale_id, stale_interrupt = first.command(
        "turn.interrupt", {}, turnId=turn_id
    )
    await first.send(stale_interrupt)
    assert (await first.read_type("error", stale_id))["payload"]["code"] == "staleTurn"

    history_id, history_command = first.command(
        "history.load",
        {
            "beforeItemId": "33333333-3333-4333-8333-333333333333",
            "limit": 50,
        },
    )
    await first.send(history_command)
    await first.read_type("history.page")
    assert (await first.read_type("ack", history_id))["payload"]["loaded"] == 0

    preview_id, preview = first.command(
        "file.preview", {"path": "README.md", "line": 1, "column": 1}
    )
    await first.send(preview)
    preview_event = await first.read_type("file.preview")
    assert preview_event["payload"]["content"] == "hello π\n"
    assert preview_event["payload"]["originalByteCount"] == len(
        "hello π\n".encode("utf-8")
    )
    assert (await first.read_type("ack", preview_id))["payload"]["previewed"] is True

    escape_id, escape = first.command(
        "file.preview", {"path": str(outside)}
    )
    await first.send(escape)
    assert (await first.read_type("error", escape_id))["payload"]["code"] == "pathOutOfScope"

    display_id = "55555555-5555-4555-8555-555555555555"
    await broker.emit(
        "approval.requested",
        {
            "displayId": display_id,
            "id": display_id,
            "providerConnectionGeneration": provider.connection_generation,
            "providerRequestId": "approval-1",
            "providerRequestID": "approval-1",
            "title": "Run command?",
            "decisions": module.approval_decisions(),
            "status": "pending",
        },
        item_id=display_id,
    )
    await first.read_type("approval.requested")
    pending_snapshot = broker.snapshot_payload()["approvals"][0]
    assert pending_snapshot["providerConnectionGeneration"] == provider.connection_generation
    assert pending_snapshot["providerRequestID"] == "approval-1"
    assert pending_snapshot["decisions"][0]["id"] == "allow"
    approval_id, approval = first.command(
        "approval.respond",
        {
            "providerConnectionGeneration": provider.connection_generation,
            "providerRequestId": "approval-1",
            "decision": "allow",
            "permissionChanges": None,
        },
    )
    await asyncio.gather(first.send(approval), second.send(approval))
    await first.read_type("approval.resolved")
    await first.read_type("ack", approval_id)
    await second.read_type("ack", approval_id)
    assert provider.approval_responses[-1]["decision"] == "allow"
    assert len(provider.approval_responses) == 1

    question_id_value = "66666666-6666-4666-8666-666666666666"
    await broker.emit(
        "question.requested",
        {
            "displayId": question_id_value,
            "id": question_id_value,
            "providerConnectionGeneration": provider.connection_generation,
            "providerRequestId": "question-1",
            "providerRequestID": "question-1",
            "prompt": "Input requested",
            "question": "Choose",
            "kind": "singleChoice",
            "options": [{"id": "yes", "label": "Yes", "detail": None}],
            "questions": [
                {
                    "id": "choice",
                    "prompt": "Choose",
                    "kind": "singleChoice",
                    "options": [{"id": "yes", "label": "Yes", "detail": None}],
                    "allowsOther": False,
                }
            ],
            "allowsOther": False,
            "status": "pending",
        },
        item_id=question_id_value,
    )
    await first.read_type("question.requested")
    pending_question = broker.snapshot_payload()["questions"][0]
    assert pending_question["questions"][0]["id"] == "choice"
    assert pending_question["providerRequestID"] == "question-1"
    answer_id, answer = first.command(
        "question.respond",
        {
            "providerConnectionGeneration": provider.connection_generation,
            "providerRequestId": "question-1",
            "answers": [
                {
                    "questionID": "choice",
                    "selectedOptionIDs": ["yes"],
                    "text": None,
                }
            ],
        },
    )
    await first.send(answer)
    await first.read_type("question.resolved")
    await first.read_type("ack", answer_id)
    assert provider.question_responses[-1]["answers"][0]["questionID"] == "choice"
    await first.send(answer)
    await first.read_type("ack", answer_id)
    assert len(provider.question_responses) == 1

    # A replay gap causes an authoritative snapshot instead of substring
    # reconstruction.
    broker.replay.clear()
    broker.replay_bytes = 0
    gap_reader, gap_writer = await asyncio.open_unix_connection(broker.socket_path)
    gap = ProtocolClient(module, gap_reader, gap_writer, broker.relay_id)
    await gap.attach(1, broker.snapshot_generation)
    assert any(record["type"] == "conversation.snapshot" for record in gap.records)

    # Reusing a command ID with a different payload is a fatal protocol error.
    await first.send(turn | {"payload": {"text": "Different", "attachments": []}})
    reused = await first.read_type("error", turn_request_id)
    assert reused["payload"]["code"] == "requestIdReused"
    assert await first.reader.read() == b""

    # Slow readers are bounded independently.
    dummy = module.ClientConnection(None, None)  # type: ignore[arg-type]
    dummy.queued_bytes = module.MAX_CLIENT_BYTES
    assert dummy.enqueue(b"x\n") is False

    await second.close()
    await gap.close()
    stopper = await connect(module, broker)
    stop_id, stop = stopper.command("session.stop", {})
    await stopper.send(stop)
    await stopper.read_type("ack", stop_id)
    await asyncio.wait_for(broker_task, 5)
    assert not pathlib.Path(broker.socket_path).exists()
    assert not pathlib.Path(broker.attachment_root).exists()
    assert not pathlib.Path(broker.legacy_attachment_root).exists()

    # Provider locks cover the whole broker lifetime and are released at stop.
    second_relay = "77777777-7777-4777-8777-777777777777"
    replacement_provider = module.FakeProvider(str(project), THREAD_ID, {})
    replacement = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        second_relay,
        replacement_provider,
        {},
    )
    replacement_task = asyncio.create_task(replacement.run())
    await wait_ready(replacement)
    replacement.stop_event.set()
    await asyncio.wait_for(replacement_task, 5)

    # A new provider thread has no materialized history until its first user
    # message. Starting the broker must not issue an impossible history read.
    class NewThreadProvider(module.FakeProvider):
        async def history(self, before_item_id, limit):
            del before_item_id, limit
            raise AssertionError("new provider history must not be read")

    third_relay = "88888888-8888-4888-8888-888888888888"
    new_provider = NewThreadProvider(str(project), None, {})
    new_broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        third_relay,
        new_provider,
        {},
    )
    new_broker_task = asyncio.create_task(new_broker.run())
    await wait_ready(new_broker)
    assert new_broker.provider_thread_id is not None
    new_broker.stop_event.set()
    await asyncio.wait_for(new_broker_task, 5)


class FakeCodexWebSocket:
    def __init__(
        self,
        *,
        thread_turns=None,
        disconnect_turn_start=False,
        drop_unsubscribe=False,
    ):
        self.incoming: queue.Queue = queue.Queue()
        self.sent: list[dict] = []
        self.initialize_answered = False
        self.closed = False
        self.thread_turns = thread_turns
        self.disconnect_turn_start = disconnect_turn_start
        self.drop_unsubscribe = drop_unsubscribe

    def connect(self) -> None:
        return None

    def send_json(self, value: dict) -> None:
        self.sent.append(value)
        method = value.get("method")
        request_id = value.get("id")
        if method == "initialize":
            assert set(value["params"]) == {"clientInfo", "capabilities"}
            assert value["params"]["capabilities"] == {
                "experimentalApi": True,
                "requestAttestation": False,
            }
            self.initialize_answered = True
            self.incoming.put({"id": request_id, "result": {"serverInfo": {}}})
        elif method == "initialized":
            assert self.initialize_answered
        elif method == "thread/resume":
            self.incoming.put(
                {
                    "id": request_id,
                    "result": {"thread": {"id": THREAD_ID}},
                }
            )
        elif method == "thread/read":
            turns = self.thread_turns
            if turns is None:
                turns = [
                    {
                        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        "status": "completed",
                        "items": [
                            {
                                "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                                "type": "userMessage",
                                "text": "hello",
                                "clientUserMessageId": "client-fixture",
                            },
                            {
                                "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                                "type": "agentMessage",
                                "text": "world",
                            },
                            {
                                "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                                "type": "commandExecution",
                                "command": "pwd",
                                "aggregatedOutput": "/workspace/repo",
                                "exitCode": 0,
                            },
                        ],
                        "startedAt": 1_800_000_000.25,
                    }
                ]
            self.incoming.put(
                {
                    "id": request_id,
                    "result": {
                        "thread": {
                            "id": THREAD_ID,
                            "turns": turns,
                        }
                    },
                }
            )
        elif method == "turn/start":
            assert value["params"]["clientUserMessageId"]
            if self.disconnect_turn_start:
                self.incoming.put(None)
            else:
                self.incoming.put(
                    {
                        "id": request_id,
                        "result": {
                            "turn": {
                                "id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
                            }
                        },
                    }
                )
        elif method == "turn/interrupt" or (
            method == "thread/unsubscribe" and not self.drop_unsubscribe
        ):
            self.incoming.put({"id": request_id, "result": {}})

    def receive_json(self) -> dict:
        value = self.incoming.get(timeout=5)
        if value is None:
            raise EOFError
        return value

    def close(self) -> None:
        self.closed = True
        self.incoming.put(None)


def exercise_unix_websocket_close(module) -> None:
    class RecordingSocket:
        def __init__(self):
            self.shutdown_mode = None
            self.closed = False

        def sendall(self, _value: bytes) -> None:
            return None

        def shutdown(self, mode: int) -> None:
            self.shutdown_mode = mode

        def close(self) -> None:
            self.closed = True

    transport = RecordingSocket()
    websocket = module.UnixWebSocket("/tmp/example-codex.sock")
    websocket.socket = transport
    websocket.close()
    assert transport.shutdown_mode == socket.SHUT_RDWR
    assert transport.closed is True
    assert websocket.socket is None


async def exercise_codex_adapter(module, root: pathlib.Path) -> None:
    project = root / "codex-project"
    project.mkdir()
    transport = FakeCodexWebSocket()
    adapter = module.CodexAdapter(
        str(project),
        THREAD_ID,
        {
            "model": "example-model",
            "effort": "high",
            "sandbox": "workspace-write",
            "fastMode": True,
            "fullAccess": False,
        },
        str(root / "codex.sock"),
    )
    adapter.websocket = transport
    events: list[dict] = []

    async def emit(event_type, payload, *, turn_id=None, item_id=None):
        event = {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }
        events.append(event)
        return event

    assert await adapter.start(emit) == THREAD_ID
    assert [value.get("method") for value in transport.sent[:3]] == [
        "initialize",
        "initialized",
        "thread/resume",
    ]
    history, older = await adapter.history(None, 100)
    assert older is False
    assert [item["type"] for item in history] == [
        "message.completed",
        "message.completed",
        "tool.completed",
    ]
    assert history[0]["payload"]["clientUserMessageId"] == "client-fixture"
    assert history[0]["occurredAt"] == 1_800_000_000_250
    assert history[-1]["occurredAt"] == 1_800_000_000_250
    assert history[-1]["payload"]["exitCode"] == 0
    older_page, has_more = await adapter.history(
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc", 100
    )
    assert has_more is False
    assert [item["itemId"] for item in older_page] == [
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    ]
    assert module.CodexAdapter.map_item(
        {
            "id": "tool",
            "type": "commandExecution",
            "command": "pwd",
            "status": "inProgress",
            "aggregatedOutput": "/workspace\n",
        },
        completed=False,
    )["payload"]["kind"] == "shell"
    mapped_diff = module.CodexAdapter.map_item(
        {
            "id": "diff",
            "type": "fileChange",
            "status": "completed",
            "changes": [
                {"path": "README.md", "kind": "update", "diff": "@@ -1 +1 @@"}
            ],
        },
        completed=True,
    )
    assert mapped_diff["eventType"] == "diff.updated"
    assert mapped_diff["payload"]["path"] == "README.md"
    assert mapped_diff["payload"]["diff"] == "@@ -1 +1 @@"
    mapped_plan = module.CodexAdapter.map_item(
        {"id": "plan", "type": "plan", "text": "Ship it"},
        completed=True,
    )
    assert mapped_plan["payload"]["steps"][0]["title"] == "Ship it"

    request_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    image_path = project / "attachment.png"
    document_path = project / "attachment.txt"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    document_path.write_text("worker-local", encoding="utf-8")
    result = await adapter.start_turn(
        {
            "requestId": request_id,
            "payload": {
                "text": "go",
                "attachments": [
                    {
                        "id": "01010101-0101-4101-8101-010101010101",
                        "path": str(image_path),
                        "displayName": "diagram.png",
                        "mediaType": "image/png",
                        "kind": "image",
                        "byteCount": 8,
                    },
                    {
                        "id": "02020202-0202-4202-8202-020202020202",
                        "path": str(document_path),
                        "displayName": "Notes.txt",
                        "mediaType": "text/plain",
                        "kind": "file",
                        "byteCount": 12,
                    },
                ],
                "options": {},
            },
        }
    )
    assert result["turnId"] == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    turn_request = next(
        value for value in transport.sent if value.get("method") == "turn/start"
    )
    assert turn_request["params"]["model"] == "example-model"
    assert turn_request["params"]["effort"] == "high"
    assert turn_request["params"]["sandboxPolicy"]["type"] == "workspaceWrite"
    assert turn_request["params"]["serviceTier"] == "fast"
    assert turn_request["params"]["input"] == [
        {"type": "text", "text": "go"},
        {"type": "localImage", "path": str(image_path)},
    ]
    attachment_context = turn_request["params"]["additionalContext"][
        "terminal_relay_attachments"
    ]
    assert attachment_context["kind"] == "untrusted"
    context_value = attachment_context["value"]
    context_attachments = json.loads(context_value[context_value.index("[") :])
    assert context_attachments == [
        {
            "displayName": "Notes.txt",
            "mediaType": "text/plain",
            "byteCount": 12,
            "path": str(document_path),
        }
    ]

    transport.incoming.put(
        {
            "method": "turn/started",
            "params": {"turn": {"id": result["turnId"]}},
        }
    )
    item_id = "12121212-1212-4212-8212-121212121212"
    transport.incoming.put(
        {
            "method": "item/started",
            "params": {
                "turnId": result["turnId"],
                "item": {"id": item_id, "type": "agentMessage", "text": ""},
            },
        }
    )
    transport.incoming.put(
        {
            "method": "item/agentMessage/delta",
            "params": {
                "turnId": result["turnId"],
                "itemId": item_id,
                "delta": "streamed",
            },
        }
    )
    transport.incoming.put(
        {
            "method": "item/completed",
            "params": {
                "turnId": result["turnId"],
                "item": {
                    "id": item_id,
                    "type": "agentMessage",
                    "text": "streamed",
                },
            },
        }
    )
    transport.incoming.put(
        {
            "method": "turn/completed",
            "params": {
                "turn": {"id": result["turnId"], "status": "completed"}
            },
        }
    )
    for _ in range(100):
        if any(event["type"] == "turn.completed" for event in events):
            break
        await asyncio.sleep(0.01)
    assert [event["type"] for event in events if event["itemId"] == item_id] == [
        "message.started",
        "message.delta",
        "message.completed",
    ]

    output_item_id = "23232323-2323-4232-8232-232323232323"
    transport.incoming.put(
        {
            "method": "item/commandExecution/outputDelta",
            "params": {
                "turnId": result["turnId"],
                "itemId": output_item_id,
                "delta": "first ",
            },
        }
    )
    transport.incoming.put(
        {
            "method": "item/commandExecution/outputDelta",
            "params": {
                "turnId": result["turnId"],
                "itemId": output_item_id,
                "delta": "second",
            },
        }
    )
    transport.incoming.put(
        {
            "method": "thread/tokenUsage/updated",
            "params": {
                "turnId": result["turnId"],
                "tokenUsage": {
                    "inputTokens": 10,
                    "outputTokens": 4,
                    "totalTokens": 14,
                },
            },
        }
    )
    for _ in range(100):
        output_events = [
            event
            for event in events
            if event["type"] == "tool.updated"
            and event["itemId"] == output_item_id
        ]
        if len(output_events) == 2 and any(
            event["type"] == "usage.updated" for event in events
        ):
            break
        await asyncio.sleep(0.01)
    assert [event["payload"]["outputDelta"] for event in output_events] == [
        "first ",
        "second",
    ]
    assert all("output" not in event["payload"] for event in output_events)
    usage = next(event for event in events if event["type"] == "usage.updated")
    assert usage["payload"] == {
        "inputTokens": 10,
        "outputTokens": 4,
        "contextTokens": 14,
    }

    transport.incoming.put(
        {
            "id": 91,
            "method": "item/commandExecution/requestApproval",
            "params": {
                "turnId": result["turnId"],
                "command": "git status",
                "availableDecisions": ["accept", "acceptForSession", "decline"],
            },
        }
    )
    for _ in range(100):
        requested = next(
            (event for event in events if event["type"] == "approval.requested"),
            None,
        )
        if requested:
            break
        await asyncio.sleep(0.01)
    assert requested is not None
    approval_payload = requested["payload"]
    assert approval_payload["providerRequestId"] == 91
    assert approval_payload["providerConnectionGeneration"]
    assert [decision["id"] for decision in approval_payload["decisions"]] == [
        "allow",
        "allowForSession",
        "deny",
    ]
    await adapter.respond_approval(
        approval_payload | {"decision": "allow", "permissionChanges": None}
    )
    assert transport.sent[-1]["id"] == 91
    assert transport.sent[-1]["result"]["decision"] == "accept"

    transport.incoming.put(
        {
            "id": 92,
            "method": "item/permissions/requestApproval",
            "params": {
                "turnId": result["turnId"],
                "permissions": {"network": {"enabled": True}},
                "reason": "Fetch package metadata",
            },
        }
    )
    for _ in range(100):
        permission = next(
            (
                event
                for event in events
                if event["type"] == "approval.requested"
                and event["payload"]["providerRequestId"] == 92
            ),
            None,
        )
        if permission:
            break
        await asyncio.sleep(0.01)
    assert permission is not None
    await adapter.respond_approval(
        permission["payload"]
        | {
            "decision": "allowForSession",
            "permissionChanges": {"network": {"enabled": True}},
        }
    )
    assert transport.sent[-1]["result"] == {
        "permissions": {"network": {"enabled": True}},
        "scope": "session",
    }

    transport.incoming.put(
        {
            "id": "question-request",
            "method": "item/tool/requestUserInput",
            "params": {
                "questions": [
                    {
                        "id": "choice",
                        "header": "Choice",
                        "question": "Choose one",
                        "options": [
                            {"label": "A", "description": "First"},
                            {"label": "B", "description": "Second"},
                        ],
                    },
                    {
                        "id": "note",
                        "header": "Note",
                        "question": "Why?",
                        "options": None,
                    },
                ]
            },
        }
    )
    for _ in range(100):
        question = next(
            (event for event in events if event["type"] == "question.requested"),
            None,
        )
        if question:
            break
        await asyncio.sleep(0.01)
    assert question is not None
    await adapter.respond_question(
        question["payload"]
        | {
            "answers": [
                {
                    "questionID": "choice",
                    "selectedOptionIDs": ["A"],
                    "text": None,
                },
                {
                    "questionID": "note",
                    "selectedOptionIDs": [],
                    "text": "Because",
                },
            ]
        }
    )
    assert transport.sent[-1]["id"] == "question-request"
    assert transport.sent[-1]["result"]["answers"] == {
        "choice": {"answers": ["A"]},
        "note": {"answers": ["Because"]},
    }

    # Codex can deliver item and usage notifications for a turn after its
    # completion notification. Those late records must not reactivate the
    # finished turn or block the next message.
    assert adapter.active_turn is None
    next_request_id = "45454545-4545-4545-8545-454545454545"
    next_result = await adapter.start_turn(
        {
            "requestId": next_request_id,
            "payload": {
                "text": "send after late events",
                "attachments": [],
                "options": {},
            },
        }
    )
    assert next_result["clientUserMessageId"] == next_request_id
    await adapter.close()
    assert transport.closed is True


async def exercise_codex_reconnect(module, root: pathlib.Path) -> None:
    project = root / "codex-reconnect-project"
    project.mkdir()
    command_id = "34343434-3434-4434-8434-343434343434"
    turn_id = "35353535-3535-4535-8535-353535353535"
    user_item_id = "36363636-3636-4636-8636-363636363636"
    assistant_item_id = "37373737-3737-4737-8737-373737373737"
    first = FakeCodexWebSocket(disconnect_turn_start=True)
    second = FakeCodexWebSocket(
        thread_turns=[
            {
                "id": turn_id,
                "status": "inProgress",
                "items": [
                    {
                        "id": user_item_id,
                        "type": "userMessage",
                        "text": "recover this",
                        "clientUserMessageId": command_id,
                    },
                    {
                        "id": assistant_item_id,
                        "type": "agentMessage",
                        "text": "partial answer",
                    },
                ],
            }
        ]
    )
    adapter = module.CodexAdapter(
        str(project), THREAD_ID, {}, str(root / "codex-reconnect.sock")
    )
    adapter.websocket = first
    adapter.websocket_factory = lambda: second
    events: list[dict] = []

    async def emit(event_type, payload, *, turn_id=None, item_id=None):
        event = {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }
        events.append(event)
        return event

    await adapter.start(emit)
    first_generation = adapter.connection_generation
    result = await asyncio.wait_for(
        adapter.start_turn(
            {
                "requestId": command_id,
                "payload": {
                    "text": "recover this",
                    "attachments": [],
                    "options": {},
                },
            }
        ),
        5,
    )
    assert result == {
        "turnId": turn_id,
        "clientUserMessageId": command_id,
    }
    assert adapter.active_turn == turn_id
    assert adapter.connection_generation != first_generation
    assert [value.get("method") for value in second.sent[:4]] == [
        "initialize",
        "initialized",
        "thread/resume",
        "thread/read",
    ]
    states = [
        event["payload"]["reason"]
        for event in events
        if event["type"] == "session.state"
    ]
    assert states == ["providerDisconnected", "providerReconnected"]
    reconciled_user = next(
        event for event in events if event["itemId"] == user_item_id
    )
    assert reconciled_user["payload"]["clientUserMessageId"] == command_id
    assert any(
        event["type"] == "turn.started"
        and event["turnId"] == turn_id
        and event["payload"]["reconciled"] is True
        for event in events
    )
    second.incoming.put(
        {
            "method": "turn/completed",
            "params": {"turn": {"id": turn_id, "status": "completed"}},
        }
    )
    for _ in range(100):
        if adapter.active_turn is None:
            break
        await asyncio.sleep(0.01)
    assert adapter.active_turn is None
    await adapter.close()


async def exercise_codex_close_timeout(module, root: pathlib.Path) -> None:
    project = root / "codex-close-timeout-project"
    project.mkdir()
    transport = FakeCodexWebSocket(drop_unsubscribe=True)
    adapter = module.CodexAdapter(
        str(project), THREAD_ID, {}, str(root / "codex-close-timeout.sock")
    )
    adapter.websocket = transport

    async def emit(event_type, payload, *, turn_id=None, item_id=None):
        return {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }

    await adapter.start(emit)
    await asyncio.wait_for(adapter.close(), 2)
    assert any(
        value.get("method") == "thread/unsubscribe" for value in transport.sent
    )
    assert transport.closed is True


async def exercise_claude_adapter(module, root: pathlib.Path) -> None:
    project = root / "claude-project"
    project.mkdir()
    received: asyncio.Queue = asyncio.Queue()
    event_loop_thread = threading.get_ident()
    sdk_load_threads: list[int] = []
    session_info_threads: list[int] = []

    class PermissionResultAllow:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class PermissionResultDeny:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class ClaudeAgentOptions:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class FakeClient:
        def __init__(self, options):
            self.options = options
            self.queries: list[str] = []
            self.interrupted = False
            self.disconnected = False

        async def connect(self):
            return None

        async def receive_messages(self):
            while True:
                value = await received.get()
                if value is None:
                    return
                yield value

        async def query(self, text):
            self.queries.append(text)

        async def interrupt(self):
            self.interrupted = True

        async def disconnect(self):
            self.disconnected = True
            await received.put(None)

    def get_session_info(session_id, **_kwargs):
        session_info_threads.append(threading.get_ident())
        return SimpleNamespace(session_id=session_id)

    history_messages = [
            SimpleNamespace(
                uuid="13131313-1313-4313-8313-131313131313",
                type="user",
                timestamp="2027-01-15T08:00:00.250Z",
                message={
                    "role": "user",
                    "content": [{"type": "text", "text": "historic question"}],
                },
            ),
            SimpleNamespace(
                uuid="14141414-1414-4414-8414-141414141414",
                type="assistant",
                message={
                    "role": "assistant",
                    "content": [{"type": "text", "text": "historic answer"}],
                },
            ),
        ]

    history_calls: list[tuple[int, int]] = []

    def get_session_messages(
        _session_id, *, directory, limit, offset
    ):
        assert directory == str(project)
        history_calls.append((limit, offset))
        return list(history_messages[offset : offset + limit])

    sdk = SimpleNamespace(
        ClaudeSDKClient=FakeClient,
        ClaudeAgentOptions=ClaudeAgentOptions,
        get_session_info=get_session_info,
        get_session_messages=get_session_messages,
        PermissionResultAllow=PermissionResultAllow,
        PermissionResultDeny=PermissionResultDeny,
    )

    def load_sdk():
        sdk_load_threads.append(threading.get_ident())
        return sdk

    new_adapter = module.ClaudeAdapter(
        str(project),
        THREAD_ID,
        {
            "_newSession": True,
            "model": "fable",
            "effort": "max",
            "permissionMode": "default",
        },
    )
    new_adapter._load_sdk = load_sdk
    new_events: list[dict] = []

    async def emit_new(event_type, payload, *, turn_id=None, item_id=None):
        event = {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }
        new_events.append(event)
        return event

    assert await new_adapter.start(emit_new) == THREAD_ID
    new_options = new_adapter.client.options.kwargs
    assert new_options["session_id"] == THREAD_ID
    assert new_options["model"] == "fable"
    assert new_options["effort"] == "max"
    assert "extra_args" not in new_options
    assert "replay_user_messages" not in new_options
    await new_adapter.close()
    assert received.get_nowait() is None

    adapter = module.ClaudeAdapter(
        str(project),
        THREAD_ID,
        {"effort": "high", "permissionMode": "default"},
    )
    adapter._load_sdk = load_sdk
    events: list[dict] = []

    async def emit(event_type, payload, *, turn_id=None, item_id=None):
        event = {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }
        events.append(event)
        return event

    assert await adapter.start(emit) == THREAD_ID
    assert sdk_load_threads and all(
        thread_id != event_loop_thread for thread_id in sdk_load_threads
    )
    assert session_info_threads and all(
        thread_id != event_loop_thread for thread_id in session_info_threads
    )
    assert adapter.client.options.kwargs["include_partial_messages"] is True
    assert adapter.client.options.kwargs["effort"] == "high"
    assert "replay_user_messages" not in adapter.client.options.kwargs
    history, older = await adapter.history(None, 100)
    assert older is False
    assert history_calls == [(module.CLAUDE_HISTORY_PAGE_MESSAGES, 0)]
    assert [item["payload"]["text"] for item in history] == [
        "historic question",
        "historic answer",
    ]
    assert [item["itemId"] for item in history] == [
        "13131313-1313-4313-8313-131313131313:0",
        "14141414-1414-4414-8414-141414141414:0",
    ]
    assert history[0]["occurredAt"] == 1_800_000_000_250
    attachment_path = project / "15151515-1515-4515-8515-151515151516.png"
    attachment_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    command_id = "15151515-1515-4515-8515-151515151515"
    turn = await adapter.start_turn(
        {
            "requestId": command_id,
            "payload": {
                "text": "hello",
                "attachments": [{"path": str(attachment_path)}],
            },
        }
    )
    assert turn["turnId"] == command_id
    assert turn["clientUserMessageId"] == command_id
    assert adapter.client.queries == [
        f"hello\n\nAttached image:\n- `{attachment_path}`"
    ]
    started = [event for event in events if event["type"] == "turn.started"]
    assert len(started) == 1
    assert started[0]["turnId"] == command_id
    await adapter.interrupt(command_id)
    assert adapter.client.interrupted is True

    UserMessage = type("UserMessage", (), {})
    user = UserMessage()
    user.uuid = "17171717-1717-4717-8717-171717171717"
    user.content = [{"type": "text", "text": "hello"}]
    AssistantMessage = type("AssistantMessage", (), {})
    assistant = AssistantMessage()
    assistant.uuid = "16161616-1616-4616-8616-161616161616"
    assistant.content = [{"type": "text", "text": "answer"}]
    ResultMessage = type("ResultMessage", (), {})
    result = ResultMessage()
    result.is_error = False
    result.usage = {"input_tokens": 2, "output_tokens": 3}
    await received.put(user)
    await received.put(assistant)
    await received.put(result)
    for _ in range(100):
        if any(event["type"] == "turn.completed" for event in events):
            break
        await asyncio.sleep(0.01)
    assert any(
        event["type"] == "message.completed"
        and event["payload"]["text"] == "answer"
        for event in events
    )
    live_user = next(
        event
        for event in events
        if event["type"] == "message.completed"
        and event["payload"].get("role") == "user"
    )
    assert live_user["itemId"] == "17171717-1717-4717-8717-171717171717:0"
    assert live_user["payload"]["clientUserMessageId"] == command_id
    live_assistant = next(
        event
        for event in events
        if event["type"] == "message.completed"
        and event["payload"].get("role") == "assistant"
        and event["payload"]["text"] == "answer"
    )
    assert live_assistant["itemId"] == "16161616-1616-4616-8616-161616161616:0"
    history_messages.extend(
        [
            SimpleNamespace(
                uuid=user.uuid,
                type="user",
                message={"role": "user", "content": user.content},
            ),
            SimpleNamespace(
                uuid=assistant.uuid,
                type="assistant",
                message={"role": "assistant", "content": assistant.content},
            ),
        ]
    )
    reconciled_history, _ = await adapter.history(None, 100)
    reconciled_ids = [item["itemId"] for item in reconciled_history]
    assert live_user["itemId"] in reconciled_ids
    assert live_assistant["itemId"] in reconciled_ids
    assert len(reconciled_ids) == len(set(reconciled_ids))

    callback = asyncio.create_task(
        adapter._can_use_tool(
            "Bash",
            {"command": "pwd", "tool_use_id": "tool-1"},
            SimpleNamespace(tool_use_id="tool-1", agent_id="main"),
        )
    )
    for _ in range(100):
        approval = next(
            (event for event in events if event["type"] == "approval.requested"),
            None,
        )
        if approval:
            break
        await asyncio.sleep(0.01)
    assert approval is not None
    await adapter.respond_approval(
        approval["payload"] | {"decision": "allow", "permissionChanges": None}
    )
    permission_result = await callback
    assert isinstance(permission_result, PermissionResultAllow)

    question_callback = asyncio.create_task(
        adapter._can_use_tool(
            "AskUserQuestion",
            {"questions": [{"question": "Choose"}], "tool_use_id": "tool-2"},
            SimpleNamespace(tool_use_id="tool-2", agent_id="main"),
        )
    )
    for _ in range(100):
        question = next(
            (
                event
                for event in reversed(events)
                if event["type"] == "question.requested"
            ),
            None,
        )
        if question:
            break
        await asyncio.sleep(0.01)
    assert question is not None
    await adapter.respond_question(
        question["payload"]
        | {
            "answers": [
                {
                    "questionID": "0",
                    "selectedOptionIDs": [],
                    "text": "A",
                }
            ]
        }
    )
    question_result = await question_callback
    assert question_result.kwargs["updated_input"]["answers"] == {"Choose": "A"}
    await adapter.close()
    assert adapter.client.disconnected is True


async def exercise_claude_history_paging(module, root: pathlib.Path) -> None:
    project = root / "claude-history-project"
    project.mkdir()

    def message_uuid(index: int) -> str:
        return f"00000000-0000-4000-8000-{index:012x}"

    messages = [
        SimpleNamespace(
            uuid=message_uuid(index),
            type="assistant",
            message={
                "role": "assistant",
                "content": [{"type": "text", "text": f"message {index}"}],
            },
        )
        for index in range(205)
    ]
    calls: list[tuple[int, int]] = []
    largest_page = 0

    def get_session_messages(
        _session_id, *, directory, limit, offset
    ):
        nonlocal largest_page
        assert directory == str(project)
        page = messages[offset : offset + limit]
        calls.append((limit, offset))
        largest_page = max(largest_page, len(page))
        return page

    adapter = module.ClaudeAdapter(str(project), THREAD_ID, {})
    adapter._sdk = SimpleNamespace(get_session_messages=get_session_messages)
    latest, has_older = await adapter.history(None, 10)
    assert has_older is True
    assert [item["payload"]["text"] for item in latest] == [
        f"message {index}" for index in range(195, 205)
    ]
    assert calls == [(100, 0), (100, 100), (100, 200)]
    assert largest_page == module.CLAUDE_HISTORY_PAGE_MESSAGES

    calls.clear()
    older, has_older = await adapter.history(f"{message_uuid(150)}:0", 10)
    assert has_older is True
    assert [item["payload"]["text"] for item in older] == [
        f"message {index}" for index in range(140, 150)
    ]
    assert calls == [(100, 0), (100, 100)]


async def exercise_claude_reconnect(module, root: pathlib.Path) -> None:
    project = root / "claude-reconnect-project"
    project.mkdir()
    queues = [asyncio.Queue(), asyncio.Queue()]
    clients = []
    history_calls: list[tuple[int, int]] = []
    command_id = "38383838-3838-4838-8838-383838383838"

    class ClaudeAgentOptions:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class FakeClient:
        def __init__(self, options):
            self.options = options
            self.queue = queues[len(clients)]
            self.queries: list[str] = []
            self.connected = False
            self.disconnected = False
            clients.append(self)

        async def connect(self):
            self.connected = True

        async def receive_messages(self):
            while True:
                value = await self.queue.get()
                if isinstance(value, Exception):
                    raise value
                if value is None:
                    return
                yield value

        async def query(self, text):
            self.queries.append(text)

        async def interrupt(self):
            return None

        async def disconnect(self):
            self.disconnected = True

    history_messages = [
        SimpleNamespace(
            uuid="39393939-3939-4939-8939-393939393939",
            type="user",
            message={
                "role": "user",
                "content": [{"type": "text", "text": "recover claude"}],
            },
        ),
        SimpleNamespace(
            uuid="40404040-4040-4040-8040-404040404040",
            type="assistant",
            message={
                "role": "assistant",
                "content": [{"type": "text", "text": "saved partial"}],
            },
        ),
    ]

    def get_session_info(session_id, **_kwargs):
        return SimpleNamespace(session_id=session_id)

    def get_session_messages(
        _session_id, *, directory, limit, offset
    ):
        assert directory == str(project)
        history_calls.append((limit, offset))
        return history_messages[offset : offset + limit]

    sdk = SimpleNamespace(
        ClaudeSDKClient=FakeClient,
        ClaudeAgentOptions=ClaudeAgentOptions,
        get_session_info=get_session_info,
        get_session_messages=get_session_messages,
    )
    adapter = module.ClaudeAdapter(str(project), THREAD_ID, {})
    adapter._load_sdk = lambda: sdk
    events: list[dict] = []

    async def emit(event_type, payload, *, turn_id=None, item_id=None):
        event = {
            "type": event_type,
            "payload": payload,
            "turnId": turn_id,
            "itemId": item_id,
        }
        events.append(event)
        return event

    await adapter.start(emit)
    first_generation = adapter.connection_generation
    await adapter.start_turn(
        {"requestId": command_id, "payload": {"text": "recover claude"}}
    )
    assert clients[0].queries == ["recover claude"]
    await queues[0].put(RuntimeError("transport ended"))
    for _ in range(200):
        if any(
            event["type"] == "session.state"
            and event["payload"]["reason"] == "providerReconnected"
            for event in events
        ):
            break
        await asyncio.sleep(0.01)
    assert len(clients) == 2
    assert clients[0].disconnected is True
    assert clients[1].options.kwargs["resume"] == THREAD_ID
    assert adapter.connection_generation != first_generation
    assert adapter.active_turn is None
    assert history_calls == [(module.CLAUDE_HISTORY_PAGE_MESSAGES, 0)]
    assert any(
        event["type"] == "message.completed"
        and event["itemId"] == "40404040-4040-4040-8040-404040404040:0"
        for event in events
    )
    reconciled_user = next(
        event
        for event in events
        if event["itemId"] == "39393939-3939-4939-8939-393939393939:0"
    )
    assert reconciled_user["payload"]["clientUserMessageId"] == command_id
    assert reconciled_user["turnId"] == command_id
    assert any(
        event["type"] == "turn.failed"
        and event["turnId"] == command_id
        and event["payload"]["reconciled"] is True
        for event in events
    )
    next_command = "41414141-4141-4141-8141-414141414141"
    await adapter.start_turn(
        {"requestId": next_command, "payload": {"text": "continue"}}
    )
    assert clients[1].queries == ["continue"]
    ResultMessage = type("ResultMessage", (), {})
    result = ResultMessage()
    result.is_error = False
    result.usage = {}
    await queues[1].put(result)
    for _ in range(100):
        if adapter.active_turn is None:
            break
        await asyncio.sleep(0.01)
    assert adapter.active_turn is None
    await adapter.close()
    assert clients[1].disconnected is True


def exercise_validation(module) -> None:
    codex_capabilities = module.chat_capabilities("codex")
    claude_capabilities = module.chat_capabilities("claude")
    assert codex_capabilities["supportsAttachments"] is True
    assert claude_capabilities["supportsAttachments"] is True
    assert "file-attachments-v1" in codex_capabilities["features"]
    assert "file-attachments-v1" not in claude_capabilities["features"]
    assert codex_capabilities["features"] == sorted(
        set(codex_capabilities["features"])
    )
    assert claude_capabilities["features"] == sorted(
        set(claude_capabilities["features"])
    )
    normalized = module.validate_launch_arguments(
        [
            "--model",
            "example-model",
            "--effort=high",
            "--sandbox",
            "workspace-write",
            "--fast",
        ]
    )
    assert normalized["model"] == "example-model"
    assert normalized["effort"] == "high"
    assert normalized["sandbox"] == "workspace-write"
    assert normalized["fastMode"] is True
    assert module.public_launch_options(
        normalized | {"_newSession": True}
    ) == normalized
    for invalid in (
        ["--unknown"],
        ["--model"],
        ["--sandbox", "invalid"],
        ["--permission-mode", "invalid"],
    ):
        try:
            module.validate_launch_arguments(invalid)
        except module.ChatError:
            pass
        else:
            raise AssertionError(f"accepted invalid launch arguments: {invalid}")

    deeply_nested: object = "value"
    for _ in range(module.MAX_JSON_DEPTH + 2):
        deeply_nested = [deeply_nested]
    raw = json.dumps(deeply_nested).encode("utf-8")
    try:
        module.load_record(raw)
    except module.ChatError as error:
        assert error.code == "invalidJSON"
    else:
        raise AssertionError("accepted deeply nested JSON")
    try:
        module.load_record(b"\xff")
    except module.ChatError as error:
        assert error.code == "invalidEncoding"
    else:
        raise AssertionError("accepted invalid UTF-8")
    try:
        module.load_record(b"{" + b"x" * module.MAX_RECORD_BYTES + b"}")
    except module.ChatError as error:
        assert error.code == "recordTooLarge"
    else:
        raise AssertionError("accepted oversized JSON")


async def exercise_early_attach(module, root: pathlib.Path) -> None:
    runtime = root / "er"
    runtime.mkdir(mode=0o700)
    project = root / "workspace" / "example-repository"

    history = [
        {
            "type": "message.completed",
            "turnId": THREAD_ID,
            "itemId": "33333333-3333-4333-8333-333333333333",
            "payload": {"role": "user", "text": "older", "status": "completed"},
        }
    ]

    class GatedProvider(module.FakeProvider):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.release = asyncio.Event()

        async def start(self, emit):
            await self.release.wait()
            return await super().start(emit)

    provider = GatedProvider(str(project), THREAD_ID, {}, scripted_history=history)
    broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        RELAY_ID,
        provider,
        {},
    )
    published_ready = False
    write_state = broker._write_state

    def verify_attach_surface_before_state(status):
        nonlocal published_ready
        if status == "ready":
            socket_info = os.lstat(broker.socket_path)
            assert stat.S_ISSOCK(socket_info.st_mode)
            assert stat.S_IMODE(socket_info.st_mode) == 0o600
            published_ready = True
        write_state(status)

    broker._write_state = verify_attach_surface_before_state
    broker_task = asyncio.create_task(broker.run())
    await wait_attach_surface(broker)
    assert published_ready is True

    # The state file reports ready while the provider is still resuming.
    state = json.loads(pathlib.Path(broker.state_path).read_text(encoding="utf-8"))
    assert state["status"] == "ready"
    assert state["providerThreadId"] == THREAD_ID

    reader, writer = await asyncio.open_unix_connection(broker.socket_path)
    client = ProtocolClient(module, reader, writer, broker.relay_id)
    hello, _ = await client.attach()
    assert hello["payload"]["connectionState"] == "connecting"
    placeholder = next(
        record
        for record in client.records
        if record["type"] == "conversation.snapshot"
    )
    assert placeholder["payload"]["items"] == []
    assert placeholder["payload"]["connectionState"] == "connecting"

    # Commands are answered while the provider is still resuming.
    ping_id, ping = client.command("ping", {})
    await client.send(ping)
    assert (await client.read_type("ack", ping_id))["payload"]["pong"] is True

    provider.release.set()
    rebuilt = await client.read_type("conversation.snapshot")
    assert rebuilt["snapshotGeneration"] != placeholder["snapshotGeneration"]
    assert rebuilt["payload"]["items"][0]["payload"]["text"] == "older"
    assert rebuilt["payload"]["baseSeq"] == rebuilt["seq"]
    state_event = await client.read_type("session.state")
    assert state_event["payload"]["reason"] == "providerReady"
    assert state_event["payload"]["connectionState"] == "streaming"

    # Live events continue on the rebuilt generation without re-attaching.
    event = await broker.emit(
        "message.delta",
        {"role": "assistant", "text": "stream"},
        turn_id=THREAD_ID,
        item_id="44444444-4444-4444-8444-444444444444",
    )
    delta = await client.read_type("message.delta")
    assert delta["seq"] == event["seq"]
    assert delta["snapshotGeneration"] == rebuilt["snapshotGeneration"]
    await client.close()
    broker.stop_event.set()
    await asyncio.wait_for(broker_task, 5)

    # A provider that fails to resume ends the admitted session cleanly.
    class FailingProvider(GatedProvider):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.close_calls = 0

        async def start(self, emit):
            await self.release.wait()
            raise module.ChatError(
                "notFound", "The provider session was not found.", exit_code=66
            )

        async def close(self):
            self.close_calls += 1

    failing_runtime = root / "ef"
    failing_runtime.mkdir(mode=0o700)
    failing_intent = failing_runtime / f"{RELAY_ID}.chat-intent"
    failing_intent.write_text("intent\n", encoding="utf-8")
    failing_intent.chmod(0o600)
    failing_provider = FailingProvider(str(project), THREAD_ID, {})
    failing_broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(failing_runtime),
        RELAY_ID,
        failing_provider,
        {},
    )
    failing_task = asyncio.create_task(failing_broker.run())
    await wait_attach_surface(failing_broker)
    reader, writer = await asyncio.open_unix_connection(failing_broker.socket_path)
    failing_client = ProtocolClient(module, reader, writer, failing_broker.relay_id)
    await failing_client.attach()
    failing_provider.release.set()
    ended = await failing_client.read_type("session.ended")
    assert ended["payload"]["reason"] == "notFound"
    try:
        await asyncio.wait_for(failing_task, 5)
    except module.ChatError as error:
        assert error.code == "notFound"
    else:
        raise AssertionError("failed resume must propagate")
    state = json.loads(
        pathlib.Path(failing_broker.state_path).read_text(encoding="utf-8")
    )
    assert state["status"] == "stopped"
    assert not pathlib.Path(failing_broker.socket_path).exists()
    # The restart intent must not survive a failed resume, or boot restore
    # keeps relaunching a doomed broker.
    assert not failing_intent.exists()
    # The provider must be closed on a failed start, or a half-connected
    # Codex websocket leaves its blocking reader thread alive forever.
    assert failing_provider.close_calls == 1
    await failing_client.close()

    # A stop during the resume window interrupts the resume, ends the session
    # for other clients, releases the provider lock, and drops the intent.
    stopping_runtime = root / "es"
    stopping_runtime.mkdir(mode=0o700)
    stopping_intent = stopping_runtime / f"{RELAY_ID}.chat-intent"
    stopping_intent.write_text("intent\n", encoding="utf-8")
    stopping_intent.chmod(0o600)
    gated = GatedProvider(str(project), THREAD_ID, {}, scripted_history=history)
    stopping_broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(stopping_runtime),
        RELAY_ID,
        gated,
        {},
    )
    stopping_task = asyncio.create_task(stopping_broker.run())
    await wait_attach_surface(stopping_broker)
    reader, writer = await asyncio.open_unix_connection(stopping_broker.socket_path)
    watcher = ProtocolClient(module, reader, writer, stopping_broker.relay_id)
    await watcher.attach()
    reader, writer = await asyncio.open_unix_connection(stopping_broker.socket_path)
    stopper = ProtocolClient(module, reader, writer, stopping_broker.relay_id)
    await stopper.attach()
    stop_id, stop = stopper.command("session.stop", {})
    await stopper.send(stop)
    await stopper.read_type("ack", stop_id)
    ended = await watcher.read_type("session.ended")
    assert ended["payload"]["reason"] == "stopped"
    # The provider gate is never released: completion proves the stop
    # cancelled the in-flight resume rather than waiting it out.
    await asyncio.wait_for(stopping_task, 5)
    assert stopping_broker.provider_lock_descriptor is None
    state = json.loads(
        pathlib.Path(stopping_broker.state_path).read_text(encoding="utf-8")
    )
    assert state["status"] == "stopped"
    assert not pathlib.Path(stopping_broker.socket_path).exists()
    assert not stopping_intent.exists()
    await watcher.close()
    await stopper.close()


def exercise_snapshot_trim(module, root: pathlib.Path) -> None:
    runtime = root / "tr"
    runtime.mkdir(mode=0o700)
    project = root / "workspace" / "example-repository"
    provider = module.FakeProvider(str(project), THREAD_ID, {})
    broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        RELAY_ID,
        provider,
        {},
    )
    tool_id = "abababab-abab-4bab-8bab-abababababab"
    broker._apply_to_snapshot(
        {
            "type": "tool.started",
            "itemId": tool_id,
            "turnId": THREAD_ID,
            "occurredAt": 1,
            "payload": {"kind": "shell", "title": "Command", "output": ""},
        }
    )
    broker._apply_to_snapshot(
        {
            "type": "tool.updated",
            "itemId": tool_id,
            "turnId": THREAD_ID,
            "occurredAt": 2,
            "payload": {"status": "running", "outputDelta": "first "},
        }
    )
    broker._apply_to_snapshot(
        {
            "type": "tool.updated",
            "itemId": tool_id,
            "turnId": THREAD_ID,
            "occurredAt": 3,
            "payload": {"status": "running", "outputDelta": "second"},
        }
    )
    running_tool = next(
        item
        for item in broker.snapshot_payload()["items"]
        if item["itemId"] == tool_id
    )
    assert running_tool["payload"]["output"] == "first second"
    assert "outputDelta" not in running_tool["payload"]
    broker._apply_to_snapshot(
        {
            "type": "tool.updated",
            "itemId": tool_id,
            "turnId": THREAD_ID,
            "occurredAt": 4,
            "payload": {
                "status": "running",
                "output": "authoritative",
                "outputDelta": "must-not-append",
            },
        }
    )
    assert broker.items[tool_id]["payload"]["output"] == "authoritative"
    broker.items.clear()
    broker.snapshot_text_chunks.clear()

    chunks = module.BoundedTextChunks()
    delta = "x" * 1024
    for _ in range(1024):
        chunks.append(delta)
    assert len(chunks.chunks) == 1024
    assert chunks.original_byte_count == module.MAX_ITEM_BYTES
    assert chunks.materialize() == delta * 1024
    chunks.append(delta)
    assert chunks.truncated
    assert len(chunks.materialize().encode("utf-8")) <= module.MAX_ITEM_BYTES
    assert chunks.original_byte_count == module.MAX_ITEM_BYTES + len(delta)

    total = 600
    for index in range(total):
        item_id = f"{index:08d}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        broker.items[item_id] = {
            "type": "message.completed",
            "itemId": item_id,
            "turnId": THREAD_ID,
            "payload": {"role": "assistant", "text": "x" * 4096, "status": "completed"},
        }
    item_size = len(
        json.dumps(
            next(iter(broker.items.values())),
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    )
    snapshot, encoded = broker.bounded_snapshot_event()
    assert len(encoded) <= module.MAX_RECORD_BYTES
    limit = module.MAX_RECORD_BYTES - 16 * 1024
    payload_size = len(
        json.dumps(
            snapshot["payload"], separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
    )
    assert payload_size <= limit
    items = snapshot["payload"]["items"]
    assert 0 < len(items) < total
    # The newest suffix survives and the trim does not over-shed: the
    # retained payload sits within one item of the cap.
    assert items[-1]["itemId"] == f"{total - 1:08d}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    assert payload_size > limit - 2 * (item_size + 1)
    assert snapshot["payload"]["hasOlderHistory"] is True
    assert snapshot["payload"]["oldestItemId"] == items[0]["itemId"]
    assert broker.oldest_item_id == items[0]["itemId"]

    # An unshrinkable snapshot still fails closed.
    broker.items.clear()
    broker.items["ffffffff-ffff-4fff-8fff-ffffffffffff"] = {
        "type": "message.completed",
        "itemId": "ffffffff-ffff-4fff-8fff-ffffffffffff",
        "turnId": THREAD_ID,
        "payload": {"role": "assistant", "text": "x" * (2 * module.MAX_RECORD_BYTES)},
    }
    broker.approvals["gggg"] = {"title": "y" * (2 * module.MAX_RECORD_BYTES)}
    try:
        broker.bounded_snapshot_event()
    except module.ChatError as error:
        assert error.code == "snapshotTooLarge"
    else:
        raise AssertionError("accepted an unshrinkable snapshot")


def run() -> None:
    module = load_broker()
    exercise_validation(module)
    exercise_unix_websocket_close(module)
    with tempfile.TemporaryDirectory(
        prefix="tr-chat.", dir="/tmp"
    ) as root:
        root_path = pathlib.Path(os.path.realpath(root))
        exercise_attachment_upload(module, root_path)
        asyncio.run(exercise_attachment_lifecycle(module, root_path))
        asyncio.run(exercise_protocol(module, root_path))
        asyncio.run(exercise_early_attach(module, root_path))
        exercise_snapshot_trim(module, root_path)
        asyncio.run(exercise_codex_adapter(module, root_path))
        asyncio.run(exercise_codex_reconnect(module, root_path))
        asyncio.run(exercise_codex_close_timeout(module, root_path))
        asyncio.run(exercise_claude_adapter(module, root_path))
        asyncio.run(exercise_claude_history_paging(module, root_path))
        asyncio.run(exercise_claude_reconnect(module, root_path))
    print("Terminal Relay chat broker tests passed")


if __name__ == "__main__":
    run()
