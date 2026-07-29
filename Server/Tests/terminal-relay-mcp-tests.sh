#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
mcp="$repository_root/Server/terminal-relay-mcp"
test_root="$(mktemp -d /tmp/terminal-relay-mcp-tests.XXXXXX)"
stub_helper="$test_root/terminal-relay-session"
helper_log="$test_root/helper.log"

cleanup() {
    case "$test_root" in
        /tmp/terminal-relay-mcp-tests.*) /bin/rm -rf -- "$test_root" ;;
    esac
}
trap cleanup EXIT

cat > "$stub_helper" <<'STUB_HELPER'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TERMINAL_RELAY_MCP_HELPER_LOG"
case "$1" in
    list-projects)
        printf '%s\n' \
            '__TERMINAL_RELAY_SESSION_V1__' \
            'project|alpha' \
            'project|beta'
        ;;
    status)
        printf '%s\n' \
            '__TERMINAL_RELAY_SESSION_V1__' \
            'session|claude|alpha|0|cccccccc-cccc-4ccc-8ccc-cccccccccccc|123||0|cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        ;;
    threads-v2)
        if [[ "$3" == "slow" ]]; then
            sleep 1
        fi
        if [[ "$3" == "oversized" ]]; then
            python3 - <<'PYTHON_OVERSIZED'
print("__TERMINAL_RELAY_THREADS_V2__")
print('{"threads":[],"padding":"' + ("x" * 1048600) + '","nextCursor":null}')
PYTHON_OVERSIZED
            exit 0
        fi
        if [[ "$3" == "inconsistent" ]]; then
            printf '%s\n' \
                '__TERMINAL_RELAY_THREADS_V2__' \
                '{"threads":[{"provider":"codex","threadID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Unsafe","updatedAt":1,"archived":false,"activityState":"unknown","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}'
            exit 0
        fi
        if [[ "$2" == "claude" ]]; then
            printf '%s\n' \
                '__TERMINAL_RELAY_THREADS_V2__' \
                '{"threads":[{"provider":"claude","threadID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","title":"Inactive Claude task","updatedAt":110,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}'
        else
            printf '%s\n' \
                '__TERMINAL_RELAY_THREADS_V2__' \
                '{"threads":[{"provider":"codex","threadID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Dormant task","updatedAt":100,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}'
        fi
        ;;
    thread-create)
        if [[ "${2:-}" == "failure" ]]; then
            printf '%s\n' 'private-terminal-output-must-not-escape' >&2
            exit 75
        fi
        printf '%s\n' \
            '__TERMINAL_RELAY_THREADS_V1__' \
            '{"threads":[{"provider":"codex","threadID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Managed task","updatedAt":200,"archived":false,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}'
        ;;
    thread-rename-v2|thread-unarchive-v2)
        provider="$2"
        thread_id="$4"
        title='Managed task'
        [[ "$provider" != "claude" ]] || title='Managed Claude task'
        printf '%s\n' \
            '__TERMINAL_RELAY_THREADS_V2__' \
            "{\"threads\":[{\"provider\":\"$provider\",\"threadID\":\"$thread_id\",\"title\":\"$title\",\"updatedAt\":200,\"archived\":false,\"activityState\":\"inactive\",\"activeInstanceToken\":null,\"isWorking\":null,\"capabilities\":{\"resume\":true,\"rename\":true,\"archive\":true,\"unarchive\":false}}],\"nextCursor\":null}"
        ;;
    thread-archive-v2)
        provider="$2"
        thread_id="$4"
        printf '%s\n' \
            '__TERMINAL_RELAY_THREADS_V2__' \
            "{\"threads\":[{\"provider\":\"$provider\",\"threadID\":\"$thread_id\",\"title\":\"Managed task\",\"updatedAt\":200,\"archived\":true,\"activityState\":\"inactive\",\"activeInstanceToken\":null,\"isWorking\":null,\"capabilities\":{\"resume\":false,\"rename\":false,\"archive\":false,\"unarchive\":true}}],\"nextCursor\":null}"
        ;;
    thread-resume-v2)
        provider="$2"
        thread_id="$4"
        instance='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
        [[ "$provider" != "claude" ]] || instance='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
        printf '%s\n' \
            '__TERMINAL_RELAY_SESSION_V1__' \
            "session|$provider|alpha|0|$instance|200||0|$thread_id"
        ;;
    *) exit 64 ;;
esac
STUB_HELPER
chmod 0755 "$stub_helper"

TERMINAL_RELAY_MCP_TEST_MODE=1 \
TERMINAL_RELAY_MCP_TEST_HELPER="$stub_helper" \
TERMINAL_RELAY_MCP_HELPER_LOG="$helper_log" \
python3 - "$mcp" "$test_root/responses.jsonl" <<'PYTHON_TEST'
import json
import os
import subprocess
import sys

mcp, response_path = sys.argv[1:]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "list_projects", "arguments": {}},
    },
    {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {
            "name": "list_threads",
            "arguments": {"repository": "alpha"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {
            "name": "start_thread",
            "arguments": {"repository": "alpha"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": {
            "name": "resume_thread",
            "arguments": {
                "repository": "alpha",
                "thread_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": {
            "name": "rename_thread",
            "arguments": {
                "repository": "alpha",
                "thread_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "name": "Managed task",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 8,
        "method": "tools/call",
        "params": {
            "name": "archive_thread",
            "arguments": {
                "repository": "alpha",
                "thread_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 9,
        "method": "tools/call",
        "params": {
            "name": "unarchive_thread",
            "arguments": {
                "repository": "alpha",
                "thread_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 10,
        "method": "tools/call",
        "params": {
            "name": "list_projects",
            "arguments": {"unsupported": True},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 11,
        "method": "tools/call",
        "params": {
            "name": "start_thread",
            "arguments": {"repository": "failure"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 12,
        "method": "tools/call",
        "params": {
            "name": "resume_thread",
            "arguments": {
                "repository": "alpha",
                "thread_id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 13,
        "method": "tools/call",
        "params": {
            "name": "resume_thread",
            "arguments": {
                "repository": "alpha",
                "provider": "claude",
                "thread_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 14,
        "method": "tools/call",
        "params": {
            "name": "rename_thread",
            "arguments": {
                "repository": "alpha",
                "provider": "claude",
                "thread_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "name": "Managed Claude task",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 15,
        "method": "tools/call",
        "params": {
            "name": "archive_thread",
            "arguments": {
                "repository": "alpha",
                "provider": "claude",
                "thread_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 16,
        "method": "tools/call",
        "params": {
            "name": "unarchive_thread",
            "arguments": {
                "repository": "alpha",
                "provider": "claude",
                "thread_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 17,
        "method": "tools/call",
        "params": {
            "name": "list_threads",
            "arguments": {"repository": "inconsistent"},
        },
    },
]
process = subprocess.run(
    [mcp],
    input="\n".join(json.dumps(request) for request in requests) + "\n",
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ,
    timeout=10,
    check=True,
)
responses = [json.loads(line) for line in process.stdout.splitlines()]
assert len(responses) == len(requests), responses
assert responses[0]["result"]["serverInfo"]["name"] == "terminal-relay"
assert "tell me about my open threads" in responses[0]["result"]["instructions"]
tools = {tool["name"]: tool for tool in responses[1]["result"]["tools"]}
assert set(tools) == {
    "list_projects",
    "list_threads",
    "start_thread",
    "resume_thread",
    "rename_thread",
    "archive_thread",
    "unarchive_thread",
}
assert tools["list_projects"]["annotations"]["readOnlyHint"] is True
assert tools["archive_thread"]["annotations"]["destructiveHint"] is True
assert "open threads" in tools["list_projects"]["description"]
assert "Codex and Claude conversations" in tools["list_threads"]["description"]
assert responses[2]["result"]["structuredContent"] == {"projects": ["alpha", "beta"]}
threads = responses[3]["result"]["structuredContent"]["threads"]
assert {(thread["provider"], thread["threadID"]) for thread in threads} == {
    ("codex", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
    ("claude", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
    ("claude", "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
}
assert responses[4]["result"]["structuredContent"]["threads"][0]["title"] == "Managed task"
resumed = responses[5]["result"]["structuredContent"]["threads"]
assert resumed[0]["threadID"] == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
assert resumed[0]["activeInstanceToken"] == "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
assert responses[6]["result"]["structuredContent"]["threads"][0]["title"] == "Managed task"
assert responses[7]["result"]["structuredContent"]["threads"][0]["archived"] is True
assert responses[8]["result"]["structuredContent"]["threads"][0]["archived"] is False
assert responses[9]["result"]["isError"] is True
assert responses[10]["result"]["isError"] is True
assert "private-terminal-output" not in responses[10]["result"]["content"][0]["text"]
assert responses[11]["result"]["isError"] is True
claude_resumed = responses[12]["result"]["structuredContent"]["threads"][0]
assert claude_resumed["provider"] == "claude"
assert claude_resumed["threadID"] == "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
assert claude_resumed["activeInstanceToken"] == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
assert responses[13]["result"]["structuredContent"]["threads"][0]["title"] == "Managed Claude task"
assert responses[14]["result"]["structuredContent"]["threads"][0]["archived"] is True
assert responses[15]["result"]["structuredContent"]["threads"][0]["archived"] is False
assert responses[16]["result"]["isError"] is True
with open(response_path, "w", encoding="utf-8") as response_file:
    response_file.write(process.stdout)
PYTHON_TEST

grep -Fxq 'list-projects' "$helper_log"
grep -Fxq 'threads-v2 codex alpha open' "$helper_log"
grep -Fxq 'threads-v2 claude alpha open' "$helper_log"
grep -Fxq 'status' "$helper_log"
grep -Fxq 'thread-create alpha' "$helper_log"
grep -Fxq \
    'thread-resume-v2 codex alpha aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
    "$helper_log"
grep -Fxq \
    'thread-rename-v2 codex alpha aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa Managed task' \
    "$helper_log"
grep -Fxq \
    'thread-archive-v2 codex alpha aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
    "$helper_log"
grep -Fxq \
    'thread-unarchive-v2 codex alpha aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
    "$helper_log"
grep -Fq \
    'thread-resume-v2 claude alpha bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb --settings {"terminalProgressBarEnabled":true} --mcp-config {"mcpServers":{"terminal_relay":{"command":"/usr/local/bin/terminal-relay-mcp"}}} --strict-mcp-config --dangerously-skip-permissions' \
    "$helper_log"
grep -Fxq \
    'thread-rename-v2 claude alpha bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb Managed Claude task' \
    "$helper_log"

TERMINAL_RELAY_MCP_TEST_MODE=1 \
TERMINAL_RELAY_MCP_TEST_HELPER="$stub_helper" \
TERMINAL_RELAY_MCP_HELPER_LOG="$helper_log" \
TERMINAL_RELAY_MCP_TEST_TIMEOUT_SECONDS=0.5 \
python3 - "$mcp" <<'PYTHON_BOUNDS'
import json
import os
import subprocess
import sys

mcp = sys.argv[1]
calls = [
    {
        "jsonrpc": "2.0",
        "id": 20,
        "method": "tools/call",
        "params": {
            "name": "list_threads",
            "arguments": {"repository": "oversized"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 21,
        "method": "tools/call",
        "params": {
            "name": "list_threads",
            "arguments": {"repository": "slow"},
        },
    },
]
process = subprocess.run(
    [mcp],
    input="\n".join(json.dumps(call) for call in calls) + "\n",
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ,
    timeout=5,
    check=True,
)
responses = [json.loads(line) for line in process.stdout.splitlines()]
assert responses[0]["result"]["isError"] is True
assert "oversized" in responses[0]["result"]["content"][0]["text"]
assert responses[1]["result"]["isError"] is True
assert "unavailable" in responses[1]["result"]["content"][0]["text"]

large_request = (
    '{"jsonrpc":"2.0","id":22,"method":"ping","padding":"'
    + ("x" * 1048576)
    + '"}\n'
)
large = subprocess.run(
    [mcp],
    input=large_request,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ,
    timeout=5,
    check=True,
)
response = json.loads(large.stdout)
assert response["error"]["message"] == "Request too large"
PYTHON_BOUNDS

! grep -Fq 'private-terminal-output-must-not-escape' "$test_root/responses.jsonl"
grep -Fq 'INSTALLED_HELPER = "/usr/local/bin/terminal-relay-session"' "$mcp"
! grep -Eq 'requests|urllib|https?://' "$mcp"

echo "PASS: terminal-relay-mcp tests"
