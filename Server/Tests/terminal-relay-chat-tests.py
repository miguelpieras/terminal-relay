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
        claude_file, claude_request, claude_legacy = broker.resolve_turn_attachment(
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
    finally:
        broker.provider_name = "codex"
    assert claude_file["kind"] == "file"
    assert claude_file["path"] == str(unsupported_path)
    assert claude_file["displayName"] == "opaque.txt"
    assert claude_request == unsupported_request
    assert claude_legacy is None
    module.discard_attachment_request(str(runtime), relay_id, unsupported_request)
    assert not unsupported_directory.exists()

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

    # The delta was the first conversation event, so the broker persisted its
    # last-event time immediately. Keepalives and read-only requests must not
    # bump it, and a follow-up event inside the throttle window updates only
    # the in-memory value.
    on_disk = json.loads(
        pathlib.Path(broker.state_path).read_text(encoding="utf-8")
    )
    assert on_disk["activityAt"] == broker.activity_at > 0
    noted_activity = broker.activity_at
    await broker._publish("session.heartbeat", {"connectionState": "streaming"})
    await broker.emit(
        "history.page",
        {"items": [], "hasOlderHistory": False, "oldestItemId": None},
    )
    assert broker.activity_at == noted_activity
    broker._note_activity()
    on_disk = json.loads(
        pathlib.Path(broker.state_path).read_text(encoding="utf-8")
    )
    assert on_disk["activityAt"] == broker.persisted_activity_at == noted_activity
    assert broker.activity_at >= noted_activity

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

    # Slow readers are bounded independently, with enough headroom that a
    # client stalled by a UI scroll hitch queues instead of being dropped.
    assert module.MAX_CLIENT_RECORDS >= 2048
    assert module.MAX_CLIENT_BYTES >= 16 * 1024 * 1024
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

    # A failed turn must surface the provider's own error text so clients can
    # show it instead of a generic banner (e.g. Codex usage limits).
    transport.incoming.put(
        {
            "method": "turn/completed",
            "params": {
                "turn": {
                    "id": next_result["turnId"],
                    "status": "failed",
                    "error": {
                        "message": "You've hit your usage limit.",
                        "codexErrorInfo": "usageLimitExceeded",
                    },
                }
            },
        }
    )
    for _ in range(100):
        if any(event["type"] == "turn.failed" for event in events):
            break
        await asyncio.sleep(0.01)
    failed = next(event for event in events if event["type"] == "turn.failed")
    assert failed["payload"]["message"] == "You've hit your usage limit."
    assert failed["turnId"] == next_result["turnId"]
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
    # A delta that races the reconnect handshake: its bytes are already part
    # of the thread/read text, so replaying it would duplicate them.
    second.incoming.put(
        {
            "method": "item/agentMessage/delta",
            "params": {"itemId": assistant_item_id, "delta": "partial"},
        }
    )
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
    assert reconciled_user["type"] == "message.completed"
    reconciled_assistant = next(
        event for event in events if event["itemId"] == assistant_item_id
    )
    assert reconciled_assistant["type"] == "message.started"
    assert reconciled_assistant["payload"]["status"] == "streaming"
    assert not any(
        event["type"] == "message.delta"
        and event["itemId"] == assistant_item_id
        for event in events
    )
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


async def exercise_codex_reconcile_failed_turn(module, root: pathlib.Path) -> None:
    # A turn that fails while the provider connection is down is delivered
    # via the thread/read reconcile, not a live notification; the reconciled
    # turn.failed must still carry the provider's error text.
    project = root / "codex-reconcile-failed-project"
    project.mkdir()
    command_id = "38383838-3838-4838-8838-383838383838"
    failed_turn_id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    first = FakeCodexWebSocket()
    second = FakeCodexWebSocket(
        thread_turns=[
            {
                "id": failed_turn_id,
                "status": "failed",
                "error": {
                    "message": "You've hit your usage limit.",
                    "codexErrorInfo": "usageLimitExceeded",
                },
                "items": [],
            }
        ]
    )
    adapter = module.CodexAdapter(
        str(project), THREAD_ID, {}, str(root / "codex-reconcile-failed.sock")
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
    result = await adapter.start_turn(
        {
            "requestId": command_id,
            "payload": {"text": "will fail", "attachments": [], "options": {}},
        }
    )
    assert result["turnId"] == failed_turn_id
    assert adapter.active_turn == failed_turn_id
    first.incoming.put(None)
    for _ in range(200):
        if any(event["type"] == "turn.failed" for event in events):
            break
        await asyncio.sleep(0.01)
    failed_event = next(
        event for event in events if event["type"] == "turn.failed"
    )
    assert failed_event["turnId"] == failed_turn_id
    assert failed_event["payload"]["reconciled"] is True
    assert failed_event["payload"]["message"] == "You've hit your usage limit."
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
            self.model_calls: list[str] = []
            self.permission_calls: list[str] = []

        async def connect(self):
            return None

        async def set_model(self, model):
            self.model_calls.append(model)

        async def set_permission_mode(self, mode):
            self.permission_calls.append(mode)

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

    SystemMessage = type("SystemMessage", (), {})
    system = SystemMessage()
    system.subtype = "init"
    system.data = {"type": "system", "subtype": "init", "session_id": THREAD_ID}
    events_before_system = len(events)
    await received.put(system)
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
    assert not any(
        "SystemMessage" in json.dumps(event)
        for event in events[events_before_system:]
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
    StreamEvent = type("StreamEvent", (), {})
    stream_start = StreamEvent()
    stream_start.uuid = "20202020-2020-4020-8020-202020202020"
    stream_start.session_id = THREAD_ID
    stream_start.event = {"type": "message_start", "message": {"id": "msg_1"}}
    first_delta = StreamEvent()
    first_delta.uuid = "21212121-2121-4121-8121-212121212121"
    first_delta.session_id = THREAD_ID
    first_delta.event = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": "Hel"},
    }
    second_delta = StreamEvent()
    second_delta.uuid = "22222222-2222-4222-8222-222222222222"
    second_delta.session_id = THREAD_ID
    second_delta.event = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": "lo"},
    }
    streamed_assistant = AssistantMessage()
    streamed_assistant.uuid = "23232323-2323-4323-8323-232323232323"
    streamed_assistant.content = [{"type": "text", "text": "Hello"}]
    for value in (stream_start, first_delta, second_delta, streamed_assistant):
        await received.put(value)
    for _ in range(100):
        if any(
            event["type"] == "message.completed"
            and event["payload"]["text"] == "Hello"
            for event in events
        ):
            break
        await asyncio.sleep(0.01)
    delta_ids = {
        event["itemId"]
        for event in events
        if event["type"] == "message.delta"
    }
    # Stream envelopes carry random uuids; all deltas of one message must
    # share a single stable item id that the completed message adopts.
    assert len(delta_ids) == 1
    streamed_completed = next(
        event
        for event in events
        if event["type"] == "message.completed"
        and event["payload"]["text"] == "Hello"
    )
    assert streamed_completed["itemId"] in delta_ids
    assert adapter.partial_blocks == {}

    # A thinking block occupies API stream index 0, so the text deltas stream
    # at index 1 — but the completed content list may contain only the
    # TextBlock (signature-only thinking is dropped), putting the text at
    # list position 0. The completion must reuse the streamed index or the
    # reply duplicates: one row from the stream, one from the completion.
    misaligned_start = StreamEvent()
    misaligned_start.uuid = "30303030-3030-4030-8030-303030303030"
    misaligned_start.session_id = THREAD_ID
    misaligned_start.event = {"type": "message_start", "message": {"id": "msg_2"}}
    misaligned_delta = StreamEvent()
    misaligned_delta.uuid = "31313131-3131-4131-8131-313131313131"
    misaligned_delta.session_id = THREAD_ID
    misaligned_delta.event = {
        "type": "content_block_delta",
        "index": 1,
        "delta": {"type": "text_delta", "text": "Hey! What can I help you with today?"},
    }
    misaligned_assistant = AssistantMessage()
    misaligned_assistant.uuid = "32323232-3232-4232-8232-323232323232"
    misaligned_assistant.content = [
        {"text": "Hey! What can I help you with today?"}
    ]
    events_before_misaligned = len(events)
    for value in (misaligned_start, misaligned_delta, misaligned_assistant):
        await received.put(value)
    for _ in range(100):
        if any(
            event["type"] == "message.completed"
            and event["payload"]["text"]
            == "Hey! What can I help you with today?"
            for event in events[events_before_misaligned:]
        ):
            break
        await asyncio.sleep(0.01)
    misaligned_events = events[events_before_misaligned:]
    misaligned_delta_ids = {
        event["itemId"]
        for event in misaligned_events
        if event["type"] == "message.delta"
    }
    assert len(misaligned_delta_ids) == 1
    misaligned_completed = next(
        event
        for event in misaligned_events
        if event["type"] == "message.completed"
    )
    assert misaligned_completed["itemId"] in misaligned_delta_ids
    assert misaligned_completed["payload"]["blockIndex"] == 1
    assert len(
        [
            event
            for event in misaligned_events
            if event["type"] == "message.completed"
        ]
    ) == 1

    # Thought text streams live into one reasoning row: thinking deltas share
    # a stable item id, the completed thinking block adopts it byte-for-byte,
    # and the completed text still lands on its own streamed index.
    thinking_start = StreamEvent()
    thinking_start.uuid = "33333333-3333-4333-8333-333333333333"
    thinking_start.session_id = THREAD_ID
    thinking_start.event = {"type": "message_start", "message": {"id": "msg_3"}}
    first_thinking = StreamEvent()
    first_thinking.uuid = "34343434-3434-4434-8434-343434343434"
    first_thinking.session_id = THREAD_ID
    first_thinking.event = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": "Let me "},
    }
    second_thinking = StreamEvent()
    second_thinking.uuid = "35353535-3535-4535-8535-353535353535"
    second_thinking.session_id = THREAD_ID
    second_thinking.event = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": "think."},
    }
    signature_fragment = StreamEvent()
    signature_fragment.uuid = "36363636-3636-4636-8636-363636363636"
    signature_fragment.session_id = THREAD_ID
    signature_fragment.event = {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "signature_delta", "signature": "sig-2"},
    }
    thinking_text_delta = StreamEvent()
    thinking_text_delta.uuid = "37373737-3737-4737-8737-373737373737"
    thinking_text_delta.session_id = THREAD_ID
    thinking_text_delta.event = {
        "type": "content_block_delta",
        "index": 1,
        "delta": {"type": "text_delta", "text": "Answer."},
    }
    thinking_assistant = AssistantMessage()
    thinking_assistant.uuid = "38383838-3838-4838-8838-383838383838"
    thinking_assistant.content = [
        {"thinking": "Let me think.", "signature": "sig-2"},
        {"text": "Answer."},
    ]
    events_before_thinking = len(events)
    for value in (
        thinking_start,
        first_thinking,
        second_thinking,
        signature_fragment,
        thinking_text_delta,
        thinking_assistant,
    ):
        await received.put(value)
    for _ in range(100):
        if any(
            event["type"] == "message.completed"
            and event["payload"]["text"] == "Answer."
            for event in events[events_before_thinking:]
        ):
            break
        await asyncio.sleep(0.01)
    thinking_events = events[events_before_thinking:]
    reasoning_delta_ids = {
        event["itemId"]
        for event in thinking_events
        if event["type"] == "reasoning.delta"
    }
    assert len(reasoning_delta_ids) == 1
    assert "".join(
        event["payload"]["text"]
        for event in thinking_events
        if event["type"] == "reasoning.delta"
    ) == "Let me think."
    reasoning_completed = next(
        event
        for event in thinking_events
        if event["type"] == "reasoning.completed"
    )
    assert reasoning_completed["itemId"] in reasoning_delta_ids
    assert reasoning_completed["payload"]["text"] == "Let me think."
    thinking_completed_message = next(
        event
        for event in thinking_events
        if event["type"] == "message.completed"
    )
    thinking_message_delta_ids = {
        event["itemId"]
        for event in thinking_events
        if event["type"] == "message.delta"
    }
    assert thinking_completed_message["itemId"] in thinking_message_delta_ids
    # Reasoning and text rows share the streamed message uuid at their own
    # block indexes.
    assert reasoning_completed["itemId"].endswith(":0")
    assert thinking_completed_message["itemId"].endswith(":1")
    assert reasoning_completed["itemId"].split(":")[0] == (
        thinking_completed_message["itemId"].split(":")[0]
    )
    assert adapter.partial_thinking == {}

    # Live SDK content blocks are dataclasses whose asdict form has no "type"
    # key. Shape classification must map them like typed blocks instead of
    # rendering placeholder "generic" tool rows.
    shaped_assistant = AssistantMessage()
    shaped_assistant.uuid = "24242424-2424-4424-8424-242424242424"
    shaped_assistant.content = [
        {"thinking": "", "signature": "sig-1"},
        {"text": "shaped answer"},
        {"id": "tool-9", "name": "Bash", "input": {"command": "ls"}},
    ]
    shaped_result = UserMessage()
    shaped_result.uuid = "25252525-2525-4525-8525-252525252525"
    shaped_result.content = [
        {"tool_use_id": "tool-9", "content": "listing", "is_error": False}
    ]
    await received.put(shaped_assistant)
    await received.put(shaped_result)
    for _ in range(100):
        if any(
            event["type"] == "tool.completed"
            and event["itemId"] == f"{shaped_assistant.uuid}:2"
            for event in events
        ):
            break
        await asyncio.sleep(0.01)
    assert not any(
        event["payload"].get("title") == "generic" for event in events
    )
    shaped_message = next(
        event
        for event in events
        if event["type"] == "message.completed"
        and event["payload"]["text"] == "shaped answer"
    )
    assert shaped_message["itemId"] == f"{shaped_assistant.uuid}:1"
    # A signature-only thinking block renders nothing.
    assert not any(
        event["itemId"] == f"{shaped_assistant.uuid}:0" for event in events
    )
    shaped_tool = next(
        event for event in events if event["type"] == "tool.started"
    )
    assert shaped_tool["itemId"] == f"{shaped_assistant.uuid}:2"
    assert shaped_tool["payload"]["title"] == "Bash"
    shaped_tool_result = next(
        event
        for event in events
        if event["type"] == "tool.completed"
        and event["itemId"] == f"{shaped_assistant.uuid}:2"
    )
    assert shaped_tool_result["payload"]["output"] == "listing"
    # A merge into the started tool must not rename it.
    assert "title" not in shaped_tool_result["payload"]

    # Only the first user text of a turn is the optimistic echo; later
    # user-role records must not adopt its identity, and sidechain records
    # must not render at all.
    late_user = UserMessage()
    late_user.uuid = "26262626-2626-4626-8626-262626262626"
    late_user.content = [{"text": "[Request interrupted by user]"}]
    sidechain_user = UserMessage()
    sidechain_user.uuid = "27272727-2727-4727-8727-272727272727"
    sidechain_user.parent_tool_use_id = "tool-9"
    sidechain_user.content = [{"text": "subagent prompt"}]
    # The sidechain record goes first: the receive loop is sequential, so
    # once the later user event exists the sidechain was fully processed.
    await received.put(sidechain_user)
    await received.put(late_user)
    for _ in range(100):
        if any(
            event["itemId"] == f"{late_user.uuid}:0" for event in events
        ):
            break
        await asyncio.sleep(0.01)
    late_user_event = next(
        event for event in events if event["itemId"] == f"{late_user.uuid}:0"
    )
    assert late_user_event["type"] == "message.completed"
    assert "clientUserMessageId" not in late_user_event["payload"]
    assert not any(
        sidechain_user.uuid in str(event.get("itemId")) for event in events
    )

    history_messages.extend(
        [
            SimpleNamespace(
                uuid=user.uuid,
                type="user",
                message={"role": "user", "content": user.content},
            ),
            SimpleNamespace(
                uuid="18181818-1818-4818-8818-181818181818",
                type="system",
                subtype="init",
                message={
                    "content": [{"type": "text", "text": "internal notice"}]
                },
            ),
            SimpleNamespace(
                uuid="19191919-1919-4919-8919-191919191919",
                type="user",
                isMeta=True,
                message={
                    "role": "user",
                    "content": [{"type": "text", "text": "meta caveat"}],
                },
            ),
            SimpleNamespace(
                uuid=assistant.uuid,
                type="assistant",
                message={"role": "assistant", "content": assistant.content},
            ),
        ]
    )
    # Server-side tools keep the same row across the live stream and the
    # history rebuild: the stored JSONL types normalize to tool_use and
    # tool_result.
    history_messages.append(
        SimpleNamespace(
            uuid="28282828-2828-4828-8828-282828282828",
            type="assistant",
            message={
                "role": "assistant",
                "content": [
                    {
                        "type": "server_tool_use",
                        "id": "srv-1",
                        "name": "web_search",
                        "input": {"query": "docs"},
                    },
                    {
                        "type": "web_search_tool_result",
                        "tool_use_id": "srv-1",
                        "content": [{"title": "Doc"}],
                    },
                ],
            },
        )
    )
    reconciled_history, _ = await adapter.history(None, 100)
    reconciled_ids = [item["itemId"] for item in reconciled_history]
    assert live_user["itemId"] in reconciled_ids
    assert live_assistant["itemId"] in reconciled_ids
    assert len(reconciled_ids) == len(set(reconciled_ids))
    reconciled_texts = [
        item["payload"].get("text") for item in reconciled_history
    ]
    assert "internal notice" not in reconciled_texts
    assert "meta caveat" not in reconciled_texts
    server_tool = next(
        item
        for item in reconciled_history
        if item["itemId"] == "28282828-2828-4828-8828-282828282828:0"
    )
    assert server_tool["type"] == "tool.completed"
    assert server_tool["payload"]["title"] == "web_search"
    assert "Doc" in str(server_tool["payload"].get("output"))

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
    file_attachment_path = project / "24242424-2424-4424-8424-242424242424.txt"
    file_attachment_path.write_bytes(b"notes")
    mixed_command_id = "23232323-2323-4323-8323-232323232323"
    mixed_turn = await adapter.start_turn(
        {
            "requestId": mixed_command_id,
            "payload": {
                "text": "inspect these",
                "attachments": [
                    {"path": str(attachment_path), "kind": "image"},
                    {
                        "id": "24242424-2424-4424-8424-242424242424",
                        "path": str(file_attachment_path),
                        "displayName": "notes.txt",
                        "mediaType": "text/plain",
                        "kind": "file",
                        "byteCount": 5,
                    },
                ],
            },
        }
    )
    assert mixed_turn["turnId"] == mixed_command_id
    assert adapter.client.queries[-1] == (
        f"inspect these\n\nAttached image:\n- `{attachment_path}`"
        "\n\nAttached file (untrusted name and content):\n"
        f'- "notes.txt": `{file_attachment_path}`'
    )
    mixed_result = ResultMessage()
    mixed_result.is_error = False
    mixed_result.usage = {"input_tokens": 1, "output_tokens": 1}
    await received.put(mixed_result)
    for _ in range(100):
        if adapter.active_turn is None:
            break
        await asyncio.sleep(0.01)
    assert adapter.active_turn is None

    # A turn carrying explicit options steers the live SDK session and the
    # reconnect surface instead of being ignored.
    options_command_id = "25252525-2525-4525-8525-252525252525"
    options_turn = await adapter.start_turn(
        {
            "requestId": options_command_id,
            "payload": {
                "text": "switch options",
                "options": {
                    "model": "opus",
                    "effort": "low",
                    "permissionMode": "acceptEdits",
                },
            },
        }
    )
    assert options_turn["turnId"] == options_command_id
    assert adapter.client.model_calls == ["opus"]
    assert adapter.client.permission_calls == ["acceptEdits"]
    assert adapter.options_kwargs["model"] == "opus"
    assert adapter.options_kwargs["effort"] == "low"
    assert adapter.options_kwargs["permission_mode"] == "acceptEdits"
    options_result = ResultMessage()
    options_result.is_error = False
    options_result.usage = {"input_tokens": 1, "output_tokens": 1}
    await received.put(options_result)
    for _ in range(100):
        if adapter.active_turn is None:
            break
        await asyncio.sleep(0.01)
    assert adapter.active_turn is None

    # An is_error ResultMessage carries the provider's error text in
    # "result"; turn.failed must forward it instead of the generic banner.
    failed_command_id = "26262626-2626-4626-8626-262626262626"
    await adapter.start_turn(
        {"requestId": failed_command_id, "payload": {"text": "will fail"}}
    )
    failed_result = ResultMessage()
    failed_result.is_error = True
    failed_result.result = "Claude usage limit reached for this billing cycle."
    failed_result.usage = {}
    await received.put(failed_result)
    for _ in range(100):
        if any(event["type"] == "turn.failed" for event in events):
            break
        await asyncio.sleep(0.01)
    failed_event = next(
        event for event in events if event["type"] == "turn.failed"
    )
    assert failed_event["payload"]["message"] == (
        "Claude usage limit reached for this billing cycle."
    )
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
    rebuild_requests: list[bool] = []

    async def request_rebuild():
        rebuild_requests.append(True)

    adapter.request_snapshot_rebuild = request_rebuild

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
    # The reconnect must replace the transcript through one snapshot rebuild
    # instead of re-emitting history records as live events, which duplicated
    # rows whose live identity differs from the JSONL identity.
    assert rebuild_requests == [True]
    assert history_calls == []
    assert not any(
        event["type"] == "message.completed" for event in events
    )
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
    # turn_error_message powers both the live and the reconcile turn.failed
    # paths; it must tolerate every malformed turn shape.
    assert module.turn_error_message(
        {"status": "failed", "error": {"message": "limit hit"}}
    ) == "limit hit"
    assert module.turn_error_message({"error": {"message": "  "}}) is None
    assert module.turn_error_message({"error": "boom"}) is None
    assert module.turn_error_message({"status": "failed"}) is None
    assert module.turn_error_message(None) is None
    assert module.turn_error_message(
        {"error": {"message": "x" * 2000}}
    ) == "x" * 1000

    codex_capabilities = module.chat_capabilities("codex")
    claude_capabilities = module.chat_capabilities("claude")
    assert codex_capabilities["supportsAttachments"] is True
    assert claude_capabilities["supportsAttachments"] is True
    assert "file-attachments-v1" in codex_capabilities["features"]
    assert "file-attachments-v1" in claude_capabilities["features"]
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

    # A peer attaching without a replay cursor broadcasts a rebuilt snapshot
    # into every attached client. Clients suppress the visible transcript
    # reset only while that broadcast stays on the same generation, consumes
    # exactly the next sequence, and still covers every materialized item.
    peer_reader, peer_writer = await asyncio.open_unix_connection(
        broker.socket_path
    )
    peer = ProtocolClient(module, peer_reader, peer_writer, broker.relay_id)
    await peer.attach()
    broadcast = await client.read_type("conversation.snapshot")
    assert broadcast["snapshotGeneration"] == rebuilt["snapshotGeneration"]
    assert broadcast["payload"]["snapshotGeneration"] == rebuilt["snapshotGeneration"]
    assert broadcast["payload"]["baseSeq"] == delta["seq"] + 1
    assert broadcast["payload"]["baseSeq"] == broadcast["seq"]
    broadcast_items = {
        item["itemId"] for item in broadcast["payload"]["items"]
    }
    assert "33333333-3333-4333-8333-333333333333" in broadcast_items
    assert "44444444-4444-4444-8444-444444444444" in broadcast_items
    # The stream stays continuous for the already-attached client: the
    # broadcast ack consumes one sequence, then live events continue.
    follow_up = await broker.emit(
        "message.delta",
        {"role": "assistant", "text": " more"},
        turn_id=THREAD_ID,
        item_id="44444444-4444-4444-8444-444444444444",
    )
    tail = await client.read_type("message.delta")
    assert tail["seq"] == follow_up["seq"]
    assert tail["seq"] == broadcast["seq"] + 2
    assert tail["snapshotGeneration"] == rebuilt["snapshotGeneration"]
    await peer.close()
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

    # A resume that hangs past the connect deadline ends the session instead
    # of heartbeating "connecting" to attached clients forever.
    deadline_runtime = root / "ed"
    deadline_runtime.mkdir(mode=0o700)
    deadline_intent = deadline_runtime / f"{RELAY_ID}.chat-intent"
    deadline_intent.write_text("intent\n", encoding="utf-8")
    deadline_intent.chmod(0o600)
    hung_provider = GatedProvider(str(project), THREAD_ID, {}, scripted_history=history)
    deadline_broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(deadline_runtime),
        RELAY_ID,
        hung_provider,
        {},
    )
    original_deadline = module.PROVIDER_CONNECT_DEADLINE_SECONDS
    # Roomy enough that the attach handshake always registers the client
    # before the deadline fires; the gate is never released, so only the
    # deadline can end the run.
    module.PROVIDER_CONNECT_DEADLINE_SECONDS = 1.0
    try:
        deadline_task = asyncio.create_task(deadline_broker.run())
        await wait_attach_surface(deadline_broker)
        reader, writer = await asyncio.open_unix_connection(
            deadline_broker.socket_path
        )
        stuck_client = ProtocolClient(module, reader, writer, deadline_broker.relay_id)
        await stuck_client.attach()
        # The provider gate is never released: only the deadline can end this.
        ended = await stuck_client.read_type("session.ended")
        assert ended["payload"]["reason"] == "resumeTimeout"
        try:
            await asyncio.wait_for(deadline_task, 10)
        except module.ChatError as error:
            assert error.code == "resumeTimeout"
        else:
            raise AssertionError("a hung resume must propagate the deadline failure")
    finally:
        module.PROVIDER_CONNECT_DEADLINE_SECONDS = original_deadline
    state = json.loads(
        pathlib.Path(deadline_broker.state_path).read_text(encoding="utf-8")
    )
    assert state["status"] == "stopped"
    assert not pathlib.Path(deadline_broker.socket_path).exists()
    assert not deadline_intent.exists()
    # The provider flock must release on the deadline path even if a wedged
    # resume thread would keep the process alive.
    assert deadline_broker.provider_lock_descriptor is None
    await stuck_client.close()


def write_intent_file(
    path: pathlib.Path,
    provider: str,
    repository: str,
    relay_id: str,
    thread_id: str,
    boot_id: str,
    arguments: list[str],
) -> None:
    """Write a restart intent exactly as the session helper does."""
    lines = [
        "version|1",
        f"provider|{provider}",
        f"repository|{repository}",
        f"relay|{relay_id}",
        f"thread|{thread_id}",
        f"boot|{boot_id}",
        f"argc|{len(arguments)}",
    ]
    lines += [f"arg|{argument.encode('utf-8').hex()}" for argument in arguments]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


def read_intent_file(path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    fields: dict[str, str] = {}
    arguments: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("|")
        if key == "arg":
            arguments.append(bytes.fromhex(value).decode("utf-8"))
        else:
            assert key not in fields, f"duplicate intent field {key}"
            fields[key] = value
    return fields, arguments


async def exercise_option_adoption(module, root: pathlib.Path) -> None:
    runtime = root / "adopt-runtime"
    project = root / "adopt-project"
    runtime.mkdir(mode=0o700)
    os.chmod(runtime, 0o700)
    project.mkdir()
    boot_id = "b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0"
    stale_boot_id = "c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1"
    boot_path = root / "adopt-boot-id"
    boot_path.write_text(f"{boot_id}\n", encoding="utf-8")

    initial_arguments = ["--model", "gpt-5", "--effort", "medium"]
    launch_options = module.validate_launch_arguments(initial_arguments)
    provider = module.FakeProvider(str(project), THREAD_ID, launch_options)
    broker = module.ChatBroker(
        "codex",
        "example-repository",
        str(project),
        str(runtime),
        RELAY_ID,
        provider,
        launch_options,
    )
    intent_path = runtime / f"{RELAY_ID}.chat-intent"
    write_intent_file(
        intent_path,
        "codex",
        "example-repository",
        RELAY_ID,
        THREAD_ID,
        stale_boot_id,
        initial_arguments,
    )
    original_boot_path = module.BOOT_ID_PATH
    module.BOOT_ID_PATH = str(boot_path)
    try:
        broker_task = asyncio.create_task(broker.run())
        await wait_ready(broker)
        client = await connect(module, broker)

        turn_request, turn = client.command(
            "turn.start",
            {
                "text": "switch",
                "attachments": [],
                "model": "gpt-5-codex",
                "reasoningEffort": "high",
                "fastMode": True,
            },
        )
        await client.send(turn)
        await client.read_type("ack", turn_request)

        # The provider shares the adopted dict, so later turns and reconnects
        # merge against the user's latest explicit options.
        assert provider.launch_options is broker.launch_options
        assert broker.launch_options["model"] == "gpt-5-codex"
        assert broker.launch_options["effort"] == "high"
        assert broker.launch_options["fastMode"] is True

        fields, arguments = read_intent_file(intent_path)
        assert arguments, "the rewritten intent lost its launch arguments"
        assert fields == {
            "version": "1",
            "provider": "codex",
            "repository": "example-repository",
            "relay": RELAY_ID,
            "thread": THREAD_ID,
            "boot": boot_id,
            "argc": str(len(arguments)),
        }
        assert stat.S_IMODE(os.lstat(intent_path).st_mode) == 0o600
        # Relaunching from the rewritten intent restores exactly the adopted
        # options.
        assert module.public_launch_options(
            module.validate_launch_arguments(arguments)
        ) == module.public_launch_options(broker.launch_options)
        assert "gpt-5-codex" in arguments
        assert "--fast" in arguments
        assert not any(
            entry.name.endswith(".tmp") for entry in runtime.iterdir()
        )
        state = json.loads(
            pathlib.Path(broker.state_path).read_text(encoding="utf-8")
        )
        assert state["status"] == "ready"
        assert state["launchOptions"]["model"] == "gpt-5-codex"
        assert state["launchOptions"]["effort"] == "high"
        assert state["launchOptions"]["fastMode"] is True

        # Unchanged options leave the persisted intent untouched.
        provider.active_turn = None
        before = os.lstat(intent_path)
        repeat_request, repeat = client.command(
            "turn.start",
            {
                "text": "again",
                "attachments": [],
                "model": "gpt-5-codex",
                "reasoningEffort": "high",
                "fastMode": True,
            },
        )
        await client.send(repeat)
        await client.read_type("ack", repeat_request)
        after = os.lstat(intent_path)
        assert (before.st_ino, before.st_mtime_ns) == (
            after.st_ino,
            after.st_mtime_ns,
        )

        # An explicit permission mode survives the full-access round trip
        # instead of escalating back to bypassPermissions.
        downgraded = module.validate_launch_arguments(
            module.launch_arguments_for(
                {"permissionMode": "acceptEdits", "fullAccess": True}
            )
        )
        assert downgraded["permissionMode"] == "acceptEdits"
        assert downgraded["fullAccess"] is True

        # A permission mode outside the launch enum is rejected before it can
        # reach an adapter or the persisted options.
        provider.active_turn = None
        invalid_request, invalid = client.command(
            "turn.start",
            {
                "text": "poison",
                "attachments": [],
                "options": {"permissionMode": "yolo"},
            },
        )
        await client.send(invalid)
        invalid_error = await client.read_type("error", invalid_request)
        assert invalid_error["payload"]["code"] == "invalidOptions"

        # A rewrite that could not land keeps retrying on later turns until
        # the on-disk intent converges with the adopted options.
        intent_path.chmod(0o644)
        blocked_request, blocked = client.command(
            "turn.start",
            {
                "text": "blocked",
                "attachments": [],
                "model": "gpt-5-codex",
                "reasoningEffort": "xhigh",
                "fastMode": True,
            },
        )
        await client.send(blocked)
        await client.read_type("ack", blocked_request)
        assert broker.launch_options["effort"] == "xhigh"
        _, blocked_arguments = read_intent_file(intent_path)
        assert "xhigh" not in blocked_arguments
        intent_path.chmod(0o600)
        provider.active_turn = None
        retry_request, retry = client.command(
            "turn.start",
            {
                "text": "retry",
                "attachments": [],
                "model": "gpt-5-codex",
                "reasoningEffort": "xhigh",
                "fastMode": True,
            },
        )
        await client.send(retry)
        await client.read_type("ack", retry_request)
        _, converged_arguments = read_intent_file(intent_path)
        assert "xhigh" in converged_arguments
        assert not any(
            entry.name.endswith(".tmp") for entry in runtime.iterdir()
        )

        # A withdrawn intent is never resurrected by an option change: a
        # stopped conversation must stay stopped across boots.
        provider.active_turn = None
        intent_path.unlink()
        withdrawn_request, withdrawn = client.command(
            "turn.start",
            {
                "text": "later",
                "attachments": [],
                "model": "gpt-5",
                "reasoningEffort": "low",
            },
        )
        await client.send(withdrawn)
        await client.read_type("ack", withdrawn_request)
        assert broker.launch_options["effort"] == "low"
        assert not intent_path.exists()

        stop_request, stop = client.command("session.stop", {})
        await client.send(stop)
        await client.read_type("ack", stop_request)
        await asyncio.wait_for(broker_task, 5)
        await client.close()
    finally:
        module.BOOT_ID_PATH = original_boot_path


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

    # The snapshot must carry the last turn failure so cold attaches can
    # reproduce the honest error banner, and clear it once a turn starts.
    broker._apply_to_snapshot(
        {
            "type": "turn.failed",
            "turnId": THREAD_ID,
            "payload": {"status": "failed", "message": "usage limit reached"},
        }
    )
    assert broker.snapshot_payload()["lastErrorMessage"] == "usage limit reached"
    broker._apply_to_snapshot(
        {
            "type": "turn.started",
            "turnId": THREAD_ID,
            "payload": {"status": "streaming"},
        }
    )
    assert broker.snapshot_payload()["lastErrorMessage"] is None
    broker._apply_to_snapshot(
        {
            "type": "turn.completed",
            "turnId": THREAD_ID,
            "payload": {"status": "completed"},
        }
    )
    assert broker.snapshot_payload()["lastErrorMessage"] is None
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


def exercise_chat_bindings(module, root: pathlib.Path) -> None:
    import contextlib
    import io
    import time

    runtime = root / "bindings"
    runtime.mkdir(mode=0o700)

    def write_relay(
        relay_id: str,
        status: str,
        pid: int,
        age_seconds: int,
        activity_at=None,
    ) -> pathlib.Path:
        directory = runtime / f"chat-{relay_id}"
        directory.mkdir(mode=0o700)
        state = {
            "v": 1,
            "status": status,
            "provider": "codex",
            "repository": "example-repository",
            "relayId": relay_id,
            "providerThreadId": THREAD_ID,
            "pid": pid,
            "processStart": "proc_1",
            "socket": str(directory / "broker.sock"),
        }
        if activity_at is not None:
            state["activityAt"] = activity_at
        state_file = directory / "broker.json"
        state_file.write_text(json.dumps(state), encoding="utf-8")
        state_file.chmod(0o600)
        stamp = time.time() - age_seconds
        os.utime(directory, (stamp, stamp))
        return directory

    live_relay = "11111111-2222-4333-8444-555555555555"
    active_relay = "dddddddd-4444-4444-8444-444444444444"
    stale_stopped = write_relay(
        "aaaaaaaa-1111-4111-8111-111111111111", "stopped", 1,
        module.STOPPED_RELAY_SWEEP_SECONDS + 60,
    )
    fresh_stopped = write_relay(
        "bbbbbbbb-2222-4222-8222-222222222222", "stopped", 1, 60
    )
    dead_ready = write_relay(
        "cccccccc-3333-4333-8333-333333333333", "ready", 2 ** 22 - 1,
        module.STOPPED_RELAY_SWEEP_SECONDS + 60,
    )
    live_directory = write_relay(live_relay, "ready", os.getpid(), 60)
    active_directory = write_relay(
        active_relay, "ready", os.getpid(), 60, activity_at=1755000000
    )

    original_validate = module.validate_live_state_process
    module.validate_live_state_process = lambda state: None if state[
        "pid"
    ] == os.getpid() else original_validate(state)
    try:
        # A pre-activity state reads as 0 (unknown); a recorded last-event
        # time passes through as the fourth binding field.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            module.emit_chat_bindings(str(runtime), "codex", "example-repository")
        lines = [line for line in output.getvalue().splitlines() if line]
        assert lines == [
            f"{THREAD_ID}|{live_relay}|chat|0",
            f"{THREAD_ID}|{active_relay}|chat|1755000000",
        ]
        # Repository mismatch yields no bindings but must not touch live state.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            module.emit_chat_bindings(str(runtime), "codex", "other-repository")
        assert output.getvalue() == ""
        # The status listing reads every live broker in one spawn.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            module.emit_chat_status(str(runtime))
        lines = [line for line in output.getvalue().splitlines() if line]
        assert lines == [
            f"codex|example-repository|{live_relay}|{THREAD_ID}|0",
            f"codex|example-repository|{active_relay}|{THREAD_ID}|1755000000",
        ]
    finally:
        module.validate_live_state_process = original_validate

    # Long-stopped and long-dead relays are swept; fresh and live ones stay.
    assert not stale_stopped.exists()
    assert not dead_ready.exists()
    assert fresh_stopped.exists()
    assert live_directory.exists()
    assert active_directory.exists()

    # A replacement broker for the same relay re-seeds the persisted
    # last-event time so a worker reboot does not reset recency.
    seeded = module.ChatBroker(
        "codex",
        "example-repository",
        str(root),
        str(runtime),
        active_relay,
        module.FakeProvider(str(root), THREAD_ID, {}),
        {},
    )
    seeded._seed_activity_from_prior_state()
    assert seeded.activity_at == 1755000000


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
        asyncio.run(exercise_option_adoption(module, root_path))
        exercise_snapshot_trim(module, root_path)
        exercise_chat_bindings(module, root_path)
        asyncio.run(exercise_codex_adapter(module, root_path))
        asyncio.run(exercise_codex_reconnect(module, root_path))
        asyncio.run(exercise_codex_reconcile_failed_turn(module, root_path))
        asyncio.run(exercise_codex_close_timeout(module, root_path))
        asyncio.run(exercise_claude_adapter(module, root_path))
        asyncio.run(exercise_claude_history_paging(module, root_path))
        asyncio.run(exercise_claude_reconnect(module, root_path))
    print("Terminal Relay chat broker tests passed")


if __name__ == "__main__":
    run()
