#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
helper="$repository_root/Server/terminal-relay-session"
tmux_path="${TERMINAL_RELAY_TEST_TMUX_PATH:-$(command -v tmux || true)}"
python_path="$(command -v python3 || true)"

[[ -x "$helper" ]] || { echo "The repository helper must already be executable: $helper" >&2; exit 69; }
[[ -n "$tmux_path" && -x "$tmux_path" ]] || { echo "tmux is required for integration tests." >&2; exit 69; }
[[ -n "$python_path" && -x "$python_path" ]] || { echo "python3 is required for the real flock test adapter." >&2; exit 69; }

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test_root="$(mktemp -d "$temporary_parent/terminal-relay-session-tests.XXXXXX")"
workspace_root="$test_root/workspace"
runtime_root="$test_root/runtime"
provider_socket_root="/tmp/terminal-relay-sockets-$$"
test_home="$test_root/home"
agent_log="$test_root/agent.log"
account_auth_log="$test_root/account-auth.log"
signal_log="$test_root/signal.log"
codex_app_server_log="$test_root/codex-app-server.log"
codex_app_server_control="$test_root/codex-app-server.control"
boot_id_file="$test_root/boot-id"
agent_update_status_file="$test_root/agent-update-status"
runtime_manifest_file="$test_root/runtime-manifest.json"
runtime_update_status_file="$test_root/runtime-update-status"
stub_agent="$test_root/stub-agent"
stub_codex="$test_root/stub-codex"
stub_codex_app_server="$test_root/stub-codex-app-server"
stub_claude_sessions="$test_root/stub-claude-sessions"
claude_sessions_state="$test_root/claude-sessions.json"
flock_adapter="$test_root/flock"
signal_adapter="$test_root/signal"
tmux_socket="terminal-relay-test-$(/usr/bin/id -u)-$$-$RANDOM"
harness_socket="$tmux_socket-harness"
rotation_codex_socket="/tmp/terminal-relay-codex-rotation-$$.sock"

cleanup() {
    local cleanup_exit_code=$?
    local pid
    local command
    trap - EXIT INT TERM

    "$tmux_path" -f /dev/null -L "$harness_socket" kill-server 2>/dev/null || true
    "$tmux_path" -f /dev/null -L "$tmux_socket" kill-server 2>/dev/null || true
    /bin/rm -f -- "$rotation_codex_socket"
    if [[ "${provider_socket_root:-}" == /tmp/terminal-relay-sockets-[0-9]* ]]; then
        /bin/rm -rf -- "$provider_socket_root"
    fi

    if [[ -f "$agent_log" ]]; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
            if [[ "$command" == *"$stub_agent"* ]]; then
                /bin/kill -KILL "$pid" 2>/dev/null || true
            fi
        done < <(/usr/bin/sed -n 's/^start|pid=\([0-9]*\).*/\1/p' "$agent_log")
    fi

    if [[ -n "${test_root:-}" && -d "$test_root" ]]; then
        if [[ "$(dirname "$test_root")" != "$temporary_parent" \
            || "$(basename "$test_root")" != terminal-relay-session-tests.* ]]; then
            echo "Refusing to clean unexpected test directory: $test_root" >&2
            exit 1
        fi
        /bin/rm -rf -- "$test_root"
    fi
    exit "$cleanup_exit_code"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nExpected:\n%s\nActual:\n%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (missing '$2')"
}

session_status() {
    /bin/bash "$helper" status
}

session_line() {
    local tool="$1"
    local repository="${2:-}"
    local output
    output="$(session_status)" || return $?
    printf '%s\n' "$output" | /usr/bin/awk -F'|' -v tool="$tool" -v repository="$repository" \
        '$1 == "session" && $2 == tool && (repository == "" || $3 == repository) { print; exit }'
}

instance_from_line() {
    printf '%s\n' "$1" | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }'
}

title_hex_from_line() {
    printf '%s\n' "$1" | /usr/bin/awk -F'|' '$1 == "session" { print $7; exit }'
}

thread_id_from_line() {
    printf '%s\n' "$1" | /usr/bin/awk -F'|' '$1 == "session" { print $9; exit }'
}

encode_title() {
    "$python_path" -c 'import sys; print(sys.argv[1].encode("utf-8").hex())' "$1"
}

wait_for_session() {
    local tool="$1"
    local repository="$2"
    local clients="$3"
    local attempt=0
    local line=""
    local record_type
    local actual_tool
    local actual_repository
    local actual_clients
    local instance
    local working
    local thread_id
    local extra

    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        line="$(session_line "$tool" "$repository" 2>/dev/null || true)"
        IFS='|' read -r record_type actual_tool actual_repository actual_clients instance \
            activity title working thread_id presentation extra <<< "$line"
        if [[ "$record_type" == "session" \
            && "$actual_tool" == "$tool" \
            && "$actual_repository" == "$repository" \
            && "$actual_clients" == "$clients" \
            && "$instance" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ \
            && "$activity" =~ ^[0-9]+$ \
            && "$title" =~ ^([a-f0-9]{2})*$ \
            && "$working" =~ ^[01]?$ \
            && "$thread_id" =~ ^([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})?$ \
            && "$presentation" == "terminal" \
            && -z "${extra:-}" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
        sleep 0.05
    done
    echo "Last $tool status line: $line" >&2
    fail "timed out waiting for $tool/$repository with $clients clients"
}

wait_for_no_session() {
    local tool="$1"
    local attempt=0
    local line=""
    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        line="$(session_line "$tool" 2>/dev/null || true)"
        [[ -z "$line" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $tool to disappear: $line"
}

wait_for_log_lines() {
    local expected="$1"
    local attempt=0
    local actual=0
    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        actual="$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log" 2>/dev/null || true)"
        [[ "$actual" == "$expected" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $expected agent launches (saw $actual)"
}

wait_for_harness_exit() {
    local client_name="$1"
    local attempt=0
    while [[ $attempt -lt 100 ]]; do
        attempt=$((attempt + 1))
        if ! "$tmux_path" -f /dev/null -L "$harness_socket" has-session -t "$client_name" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    fail "harness client did not exit: $client_name"
}

start_client() {
    local client_name="$1"
    local working_directory="$2"
    shift 2
    local launch_script="$test_root/$client_name.sh"
    local launch_command
    local argument

    {
        printf '#!/bin/bash\n'
        printf 'cd %q\n' "$working_directory"
        printf 'unset TMUX\n'
        if [[ "${TERMINAL_RELAY_TEST_CLIENT_CONFIGURE_FAIL:-}" == "1" ]]; then
            printf 'export TERMINAL_RELAY_TEST_CONFIGURE_FAIL=1\n'
        fi
        if [[ -n "${TERMINAL_RELAY_TEST_CLIENT_PAUSE_BEFORE_ATTACH:-}" ]]; then
            printf 'export TERMINAL_RELAY_TEST_PAUSE_BEFORE_ATTACH=%q\n' \
                "$TERMINAL_RELAY_TEST_CLIENT_PAUSE_BEFORE_ATTACH"
        fi
        if [[ -n "${TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT:-}" ]]; then
            printf 'export TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=%q\n' \
                "$TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT"
        fi
        if [[ -n "${TERMINAL_RELAY_TEST_CODEX_APP_SERVER_SOCKET:-}" ]]; then
            printf 'export TERMINAL_RELAY_TEST_CODEX_APP_SERVER_SOCKET=%q\n' \
                "$TERMINAL_RELAY_TEST_CODEX_APP_SERVER_SOCKET"
        fi
        printf 'exec /bin/bash %q' "$helper"
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } > "$launch_script"
    /bin/chmod 700 "$launch_script"
    printf -v launch_command '%q' "$launch_script"
    "$tmux_path" -f /dev/null -L "$harness_socket" \
        new-session -d -s "$client_name" -c "$working_directory" "$launch_command"
}

assert_agent_lock_free() {
    local instance="$1"
    exec 5>"$runtime_root/$instance.lock"
    if ! "$flock_adapter" --nonblock 5; then
        exec 5>&-
        fail "$instance agent lock remained held"
    fi
    exec 5>&-
}

wait_for_agent_lock_free() {
    local instance="$1"
    local attempt=0
    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        exec 5>"$runtime_root/$instance.lock"
        if "$flock_adapter" --nonblock 5; then
            exec 5>&-
            return 0
        fi
        exec 5>&-
        sleep 0.05
    done
    fail "$instance agent lock remained held"
}

path_mode() {
    local path="$1"
    /usr/bin/stat -c '%a' "$path" 2>/dev/null \
        || /usr/bin/stat -f '%Lp' "$path" 2>/dev/null
}

run_stop_expect_75() {
    local tool="$1"
    local repository="$2"
    local instance="$3"
    local output
    local status
    set +e
    output="$(/bin/bash "$helper" stop "$tool" "$repository" "$instance" 2>&1)"
    status=$?
    set -e
    assert_equal "75" "$status" "stale stop exit status"
    printf '%s\n' "$output"
}

run_reattach_expect_75() {
    local tool="$1"
    local repository="$2"
    local instance="$3"
    local output
    local result
    set +e
    output="$(/bin/bash "$helper" reattach "$tool" "$repository" "$instance" 2>&1)"
    result=$?
    set -e
    assert_equal "75" "$result" "stale reattach exit status"
    printf '%s\n' "$output"
}

mkdir -p "$workspace_root/alpha/.codex" "$workspace_root/beta" "$workspace_root/zeta"
mkdir -p "$workspace_root/.hidden" "$workspace_root/bad name" "$test_home"
printf '[mcp_servers.test_server]\n' > "$workspace_root/alpha/.codex/config.toml"
long_name="$(printf '%101s' '' | /usr/bin/tr ' ' a)"
mkdir -p "$workspace_root/$long_name"
touch "$workspace_root/not-a-directory" "$agent_log"
printf '%s\n' '11111111-1111-4111-8111-111111111111' > "$boot_id_file"
ln -s "$workspace_root/alpha" "$workspace_root/link"

{
    printf '#!%s\n' "$python_path"
    cat <<'PYTHON_FLOCK'
import fcntl
import sys

arguments = sys.argv[1:]
nonblocking = False
if arguments and arguments[0] == "--nonblock":
    nonblocking = True
    arguments = arguments[1:]
if arguments and arguments[0] == "--unlock":
    arguments = arguments[1:]
    operation = fcntl.LOCK_UN
else:
    operation = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
if len(arguments) != 1 or not arguments[0].isdigit():
    sys.exit(64)
try:
    fcntl.flock(int(arguments[0]), operation)
except BlockingIOError:
    sys.exit(1)
PYTHON_FLOCK
} > "$flock_adapter"

cat > "$signal_adapter" <<'SIGNAL_ADAPTER'
#!/bin/bash
set -euo pipefail

[[ $# -eq 3 ]] || exit 64
pid="$1"
expected_start="$2"
signal_name="$3"
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || exit 75
case "$signal_name" in
    TERM|KILL) ;;
    *) exit 64 ;;
esac

if [[ -r "/proc/$pid/stat" ]]; then
    IFS= read -r stat_line < "/proc/$pid/stat" || exit 75
    stat_fields="${stat_line##*) }"
    [[ "$stat_fields" != "$stat_line" ]] || exit 75
    read -r -a stat_parts <<< "$stat_fields"
    [[ ${#stat_parts[@]} -ge 20 && "${stat_parts[19]}" =~ ^[0-9]+$ ]] || exit 75
    actual_start="proc_${stat_parts[19]}"
else
    started="$(LC_ALL=C /bin/ps -o lstart= -p "$pid" 2>/dev/null)" || exit 75
    started="${started#"${started%%[![:space:]]*}"}"
    [[ -n "$started" ]] || exit 75
    started="${started// /_}"
    started="${started//$'\t'/_}"
    actual_start="ps_$started"
fi
[[ "$actual_start" == "$expected_start" ]] || exit 75
command="$(/bin/ps -o command= -p "$pid" 2>/dev/null)" || exit 75
[[ "$command" == *"$TERMINAL_RELAY_TEST_SIGNAL_TARGET_PATH"* ]] || exit 75
printf 'signal|pid=%s|name=%s\n' "$pid" "$signal_name" \
    >> "$TERMINAL_RELAY_TEST_SIGNAL_LOG"
exec /bin/kill "-$signal_name" "$pid"
SIGNAL_ADAPTER

cat > "$stub_agent" <<'STUB_AGENT'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" && "${3:-}" == "--json" ]]; then
    if [[ "${TERMINAL_RELAY_TEST_ACCOUNT_AUTH_REQUIRED:-0}" == "1" ]]; then
        exit 77
    fi
    printf '%s\n' '{"loggedIn":true}'
    exit 0
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "login" ]]; then
    printf '%s\n' "$*" >> "$TERMINAL_RELAY_TEST_ACCOUNT_AUTH_LOG"
    exit 0
fi

if [[ "$*" == *"-p /usage"* ]]; then
    printf '%s\n' 'Current session: 12% used'
    printf '%s\n' 'Current week (all models): 34% used'
    exit 0
fi

printf 'start|pid=%s|cwd=%s|path=%s' "$$" "$PWD" "$PATH" \
    >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
if [[ -n "${TERMINAL_RELAY_ACCOUNT_ID:-}" ]]; then
    printf '|provider=%s|account=%s' \
        "${TERMINAL_RELAY_PROVIDER:-}" "$TERMINAL_RELAY_ACCOUNT_ID" \
        >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
fi
if [[ -n "${CODEX_HOME:-}" ]]; then
    printf '|CODEX_HOME=%s' "$CODEX_HOME" >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf '|CLAUDE_CONFIG_DIR=%s' "$CLAUDE_CONFIG_DIR" \
        >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
fi
if [[ -n "${ConEmuANSI:-}" ]]; then
    printf '|ConEmuANSI=%s' "$ConEmuANSI" >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
fi
for argument in "$@"; do
    printf '|%s' "$argument" >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
done
printf '\n' >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
printf '\033]2;relay-agent-running\007'

for argument in "$@"; do
    [[ "$argument" == "--exit-cleanly" ]] && exit 0
    if [[ "$argument" == "--stubborn" ]]; then
        trap '' HUP INT TERM
        while :; do :; done
    fi
done

trap 'exit 0' HUP INT TERM
while :; do sleep 1; done
STUB_AGENT

{
    printf '#!%s\n' "$python_path"
    cat <<'PYTHON_CODEX_APP_SERVER'
import base64
import hashlib
import json
import os
import signal
import socket
import sqlite3
import struct
import sys
import traceback


root = os.path.dirname(os.path.realpath(__file__))
log_path = os.path.join(root, "codex-app-server.log")
control_path = os.path.join(root, "codex-app-server.control")
threads_path = os.path.join(root, "codex-app-server-threads.json")


def load_threads():
    workspace = os.environ.get("TERMINAL_RELAY_TEST_WORKSPACE_ROOT", "/workspace")
    values = {
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": {
            "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "name": saved_thread_name("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            "cwd": os.path.join(workspace, "alpha"),
            "updatedAt": 100,
            "archived": False,
        }
    }
    try:
        with open(threads_path, encoding="utf-8") as threads_file:
            saved = json.load(threads_file)
        if isinstance(saved, dict):
            values.update(saved)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return values


def save_threads(values):
    with open(threads_path, "w", encoding="utf-8") as threads_file:
        json.dump(values, threads_file, separators=(",", ":"))


def report_uncaught(exception_type, exception, exception_traceback):
    with open(log_path, "a", encoding="utf-8") as log_file:
        traceback.print_exception(
            exception_type,
            exception,
            exception_traceback,
            file=log_file,
        )


sys.excepthook = report_uncaught


def stop_server(_signal_number, _frame):
    raise SystemExit(0)


def read_exact(connection, length):
    result = b""
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError
        result += chunk
    return result


def read_frame(connection):
    first, second = read_exact(connection, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(connection, 8))[0]
    mask = read_exact(connection, 4) if second & 0x80 else None
    payload = read_exact(connection, length)
    if mask is not None:
        payload = bytes(
            value ^ mask[index % 4] for index, value in enumerate(payload)
        )
    return opcode, payload


def send_json(connection, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    if len(payload) < 126:
        header = bytes([0x81, len(payload)])
    else:
        header = bytes([0x81, 126]) + struct.pack("!H", len(payload))
    connection.sendall(header + payload)


def saved_thread_name(thread_id):
    name = None
    index_path = os.path.join(
        os.path.expanduser("~"), ".codex", "session_index.jsonl"
    )
    try:
        with open(index_path, encoding="utf-8") as records:
            for line in records:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("id") == thread_id:
                    name = record.get("thread_name")
    except FileNotFoundError:
        pass
    return name


def serve_connection(connection):
    request = b""
    while b"\r\n\r\n" not in request:
        request += connection.recv(4096)
    headers = {}
    for line in request.split(b"\r\n")[1:]:
        name, separator, value = line.partition(b":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    key = headers[b"sec-websocket-key"]
    accept = base64.b64encode(
        hashlib.sha1(
            key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        ).digest()
    )
    connection.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )
    while True:
        opcode, payload = read_frame(connection)
        if opcode == 8:
            return
        if opcode != 1:
            continue
        request_value = json.loads(payload)
        request_id = request_value.get("id")
        if request_id is None:
            continue
        method = request_value.get("method")
        notifications = []
        response_error = None
        if method == "account/read":
            account_state = ""
            if os.path.exists(control_path):
                with open(control_path, encoding="utf-8") as control_file:
                    account_state = control_file.read().strip()
            if account_state == "signed-out":
                result = {"account": None, "requiresOpenaiAuth": True}
            else:
                result = {"account": {"type": "chatgpt"}}
        elif method == "thread/read":
            thread_id = request_value.get("params", {}).get("threadId")
            threads = load_threads()
            thread = threads.get(thread_id)
            if thread is None:
                workspace = os.environ.get("TERMINAL_RELAY_TEST_WORKSPACE_ROOT", "/workspace")
                thread = {
                    "id": thread_id,
                    "name": saved_thread_name(thread_id),
                    "cwd": os.path.join(workspace, "alpha"),
                    "updatedAt": 100,
                    "archived": False,
                }
            result = {
                "thread": thread
            }
        elif method == "thread/list":
            params = request_value.get("params", {})
            if params.get("sourceKinds") != ["cli", "vscode", "exec", "appServer"]:
                raise RuntimeError("thread/list omitted managed primary thread sources")
            threads = load_threads()
            result = {
                "data": [
                    thread for thread in threads.values()
                    if thread.get("cwd") == params.get("cwd")
                    and thread.get("archived", False) is params.get("archived", False)
                    and thread.get("id") != "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                ],
                "nextCursor": None,
            }
        elif method == "thread/loaded/list":
            result = {
                "data": ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
            }
        elif method == "thread/start":
            params = request_value.get("params", {})
            threads = load_threads()
            thread = {
                "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "name": None,
                "cwd": params.get("cwd"),
                "updatedAt": 200,
                "archived": False,
            }
            threads[thread["id"]] = thread
            save_threads(threads)
            database = os.path.join(
                os.path.expanduser("~"), ".codex", "state_5.sqlite"
            )
            with sqlite3.connect(database) as database_connection:
                database_connection.execute(
                    "insert or replace into threads "
                    "(id, title, preview, first_user_message, name, cwd, "
                    "updated_at, archived, source) "
                    "values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        thread["id"],
                        "",
                        "",
                        "",
                        None,
                        thread["cwd"],
                        thread["updatedAt"],
                        0,
                        "vscode",
                    ),
                )
            result = {
                "thread": thread
            }
        elif method == "turn/start":
            generated_thread_id = request_value.get("params", {}).get("threadId")
            turn_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
            result = {"turn": {"id": turn_id, "status": "inProgress"}}
            notifications = [
                {
                    "method": "item/completed",
                    "params": {
                        "threadId": generated_thread_id,
                        "turnId": turn_id,
                        "item": {
                            "type": "agentMessage",
                            "text": '{"title":"Generated Codex title"}',
                        },
                    },
                },
                {
                    "method": "turn/completed",
                    "params": {
                        "threadId": generated_thread_id,
                        "turn": {"id": turn_id, "status": "completed"},
                    },
                },
            ]
        elif method == "thread/name/set":
            params = request_value.get("params", {})
            threads = load_threads()
            thread = threads.get(params.get("threadId"))
            if thread is not None:
                thread["name"] = params.get("name")
                thread["updatedAt"] = 300
                save_threads(threads)
                database = os.path.join(
                    os.path.expanduser("~"), ".codex", "state_5.sqlite"
                )
                with sqlite3.connect(database) as database_connection:
                    database_connection.execute(
                        "update threads set title = ?, updated_at = ? where id = ?",
                        (params.get("name"), 300, params.get("threadId")),
                    )
            index_path = os.path.join(
                os.path.expanduser("~"), ".codex", "session_index.jsonl"
            )
            os.makedirs(os.path.dirname(index_path), exist_ok=True)
            with open(index_path, "a", encoding="utf-8") as index:
                index.write(
                    json.dumps(
                        {
                            "id": params.get("threadId"),
                            "thread_name": params.get("name"),
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                )
            result = {}
        elif method in ("thread/archive", "thread/unarchive"):
            params = request_value.get("params", {})
            threads = load_threads()
            thread = threads.get(params.get("threadId"))
            if thread is not None:
                thread["archived"] = method == "thread/archive"
                thread["updatedAt"] = 400
                save_threads(threads)
                database = os.path.join(
                    os.path.expanduser("~"), ".codex", "state_5.sqlite"
                )
                with sqlite3.connect(database) as database_connection:
                    database_connection.execute(
                        "update threads set archived = ?, updated_at = ? where id = ?",
                        (
                            1 if method == "thread/archive" else 0,
                            400,
                            params.get("threadId"),
                        ),
                    )
            result = {}
            if method == "thread/unarchive":
                response_error = {
                    "code": -32603,
                    "message": "thread metadata is not loaded",
                }
        else:
            result = {}
        if response_error is not None:
            send_json(connection, {"id": request_id, "error": response_error})
        else:
            send_json(connection, {"id": request_id, "result": result})
        for notification in notifications:
            send_json(connection, notification)


if sys.argv[1:3] != ["app-server", "--listen"] or len(sys.argv) != 4:
    raise SystemExit(64)
socket_url = sys.argv[3]
if not socket_url.startswith("unix://"):
    raise SystemExit(64)
socket_path = socket_url.removeprefix("unix://")
with open(log_path, "a", encoding="utf-8") as log_file:
    log_file.write(f"launch|pid={os.getpid()}|path={os.environ.get('PATH', '')}\n")
if os.path.exists(control_path):
    with open(control_path, encoding="utf-8") as control_file:
        if control_file.read().strip() == "fail":
            raise SystemExit(70)

signal.signal(signal.SIGHUP, stop_server)
signal.signal(signal.SIGINT, stop_server)
signal.signal(signal.SIGTERM, stop_server)
os.umask(0o077)
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    server.bind(socket_path)
    server.listen()
    while True:
        connection, _ = server.accept()
        with connection:
            try:
                serve_connection(connection)
            except (BrokenPipeError, ConnectionError, EOFError, json.JSONDecodeError):
                pass
finally:
    server.close()
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
PYTHON_CODEX_APP_SERVER
} > "$stub_codex_app_server"

{
    printf '#!/bin/bash\n'
    printf "if [[ \"\${1:-}\" == --config && \"\${3:-}\" == app-server ]]; then\n"
    printf '    shift 2\n'
    printf '    exec %q "$@"\n' "$stub_codex_app_server"
    printf "elif [[ \"\${1:-}\" == app-server ]]; then\n"
    printf '    exec %q "$@"\n' "$stub_codex_app_server"
    printf 'fi\n'
    printf 'exec %q "$@"\n' "$stub_agent"
} > "$stub_codex"

{
    printf '#!%s\n' "$python_path"
    cat <<'PYTHON_CLAUDE_SESSIONS'
import json
import os
import pathlib
import sys
import uuid

state_path = pathlib.Path(os.environ["TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_STATE"])


def load():
    with state_path.open(encoding="utf-8") as state_file:
        return json.load(state_file)


def save(value):
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    temporary.replace(state_path)


def canonical(value):
    result = str(uuid.UUID(value))
    if result != value:
        raise ValueError
    return result


def row(session_id, record, archive_directory):
    marker = pathlib.Path(archive_directory) / session_id
    archived = marker.is_file() and not marker.is_symlink()
    activity = record.get("activity", "inactive")
    mutable = activity == "inactive"
    return {
        "provider": "claude",
        "threadID": session_id,
        "title": record.get("title"),
        "updatedAt": record.get("updatedAt", 1),
        "archived": archived,
        "activityState": activity,
        "activeInstanceToken": None,
        "isWorking": None,
        "capabilities": {
            "resume": mutable and not archived,
            "rename": mutable and not archived,
            "archive": mutable and not archived,
            "unarchive": mutable and archived,
        },
    }


operation, *arguments = sys.argv[1:]
state = load()
if operation == "list":
    _project, archive_directory, archive_filter, *cursor = arguments
    offset = int(cursor[0]) if cursor else 0
    rows = [
        row(session_id, record, archive_directory)
        for session_id, record in state.items()
    ]
    rows.sort(key=lambda value: (-value["updatedAt"], value["threadID"]))
    rows = [
        value
        for value in rows
        if value["archived"] == (archive_filter == "archived")
    ]
    page = rows[offset : offset + 100]
    next_cursor = str(offset + 100) if len(rows) > offset + 100 else None
    print(json.dumps({"threads": page, "nextCursor": next_cursor}, separators=(",", ":")))
elif operation in {"read", "title", "activity", "rename"}:
    project = arguments[0]
    del project
    if operation in {"read", "rename"}:
        archive_directory = arguments[1]
        session_id = canonical(arguments[2])
    else:
        session_id = canonical(arguments[1])
        archive_directory = ""
    record = state.get(session_id)
    if not isinstance(record, dict):
        print("The requested Claude session was not found.", file=sys.stderr)
        raise SystemExit(66)
    if operation == "title":
        print(record.get("title") or "")
    elif operation == "activity":
        activity = record.get("activity", "inactive")
        if activity == "external-active":
            raise SystemExit(75)
        if activity != "inactive":
            raise SystemExit(70)
    elif operation == "rename":
        record["title"] = arguments[3]
        save(state)
        print(json.dumps({"threads": [row(session_id, record, archive_directory)], "nextCursor": None}, separators=(",", ":")))
    else:
        print(json.dumps({"threads": [row(session_id, record, archive_directory)], "nextCursor": None}, separators=(",", ":")))
else:
    raise SystemExit(64)
PYTHON_CLAUDE_SESSIONS
} > "$stub_claude_sessions"
printf '{}\n' > "$claude_sessions_state"

/bin/chmod 700 \
    "$flock_adapter" \
    "$signal_adapter" \
    "$stub_agent" \
    "$stub_codex" \
    "$stub_codex_app_server" \
    "$stub_claude_sessions"

echo "1/18 test overrides require explicit non-installed test mode; projects are sorted"
set +e
override_error="$(TERMINAL_RELAY_TEST_WORKSPACE_ROOT="$workspace_root" /bin/bash "$helper" list-projects 2>&1)"
override_status=$?
set -e
assert_equal "78" "$override_status" "override refusal without test mode"
assert_contains "$override_error" "require TERMINAL_RELAY_TEST_MODE=1" "override refusal message"

export TERMINAL_RELAY_TEST_MODE=1
export TERMINAL_RELAY_TEST_TMUX_PATH="$tmux_path"
export TERMINAL_RELAY_TEST_TMUX_SOCKET="$tmux_socket"
export TERMINAL_RELAY_TEST_WORKSPACE_ROOT="$workspace_root"
export TERMINAL_RELAY_TEST_RUNTIME_ROOT="$runtime_root"
export TERMINAL_RELAY_TEST_PROVIDER_SOCKET_ROOT="$provider_socket_root"
export TERMINAL_RELAY_TEST_CODEX_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_CLAUDE_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_PYTHON_PATH="$python_path"
export TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_ADAPTER_PATH="$stub_claude_sessions"
export TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_STATE="$claude_sessions_state"
export TERMINAL_RELAY_TEST_FLOCK_PATH="$flock_adapter"
export TERMINAL_RELAY_TEST_AGENT_LOG="$agent_log"
export TERMINAL_RELAY_TEST_ACCOUNT_AUTH_LOG="$account_auth_log"
export TERMINAL_RELAY_TEST_SIGNAL_PATH="$signal_adapter"
export TERMINAL_RELAY_TEST_SIGNAL_LOG="$signal_log"
export TERMINAL_RELAY_TEST_SIGNAL_TARGET_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_BOOT_ID_PATH="$boot_id_file"
export TERMINAL_RELAY_TEST_AGENT_UPDATE_STATUS_PATH="$agent_update_status_file"
export TERMINAL_RELAY_TEST_RUNTIME_MANIFEST_PATH="$runtime_manifest_file"
export TERMINAL_RELAY_TEST_RUNTIME_UPDATE_STATUS_PATH="$runtime_update_status_file"
export HOME="$test_home"

list_output="$(/bin/bash "$helper" list-projects)"
assert_equal \
    $'__TERMINAL_RELAY_SESSION_V1__\nproject|.hidden\nproject|alpha\nproject|beta\nproject|zeta' \
    "$list_output" \
    "list-projects response"
assert_equal "700" "$(path_mode "$runtime_root")" "persistent state-root mode"
assert_equal \
    "__TERMINAL_RELAY_AGENT_UPDATE_V1__" \
    "$(/bin/bash "$helper" update-status)" \
    "missing agent update status"
printf '%s\n' \
    '__TERMINAL_RELAY_AGENT_UPDATE_V1__' \
    'update|1785055200|success|0.85.0|2.1.0' \
    > "$agent_update_status_file"
/bin/chmod 644 "$agent_update_status_file"
assert_equal \
    $'__TERMINAL_RELAY_AGENT_UPDATE_V1__\nupdate|1785055200|success|0.85.0|2.1.0' \
    "$(/bin/bash "$helper" update-status)" \
    "successful agent update status"
printf '%s\n' \
    '__TERMINAL_RELAY_AGENT_UPDATE_V1__' \
    'update|1785055300|failure|0.85.0|2.1.0' \
    > "$agent_update_status_file"
assert_equal \
    $'__TERMINAL_RELAY_AGENT_UPDATE_V1__\nupdate|1785055300|failure|0.85.0|2.1.0' \
    "$(/bin/bash "$helper" update-status)" \
    "partially failed agent update status"
printf '%s\n' \
    '__TERMINAL_RELAY_AGENT_UPDATE_V1__' \
    'update|not-a-time|failure|unsafe value|2.1.0' \
    > "$agent_update_status_file"
set +e
malformed_update_output="$(/bin/bash "$helper" update-status 2>&1)"
malformed_update_status=$?
set -e
assert_equal "70" "$malformed_update_status" "malformed agent update status"
assert_contains "$malformed_update_output" "malformed" "malformed agent update diagnostic"
/bin/rm -f -- "$agent_update_status_file"
printf '%s\n' \
    '{"runtimeVersion":2000000000,"protocol":{"minimum":1,"maximum":2},"capabilities":["agent-sessions","chat-v1","chat-v2","file-attachments-v1","provider-accounts-v1","runtime-updates-v1","threads-v1","threads-v2","threads-v3"]}' \
    > "$runtime_manifest_file"
/bin/chmod 644 "$runtime_manifest_file"
assert_equal \
    $'__TERMINAL_RELAY_RUNTIME_INFO_V1__\nruntime|2000000000|1|2|agent-sessions,chat-v1,chat-v2,file-attachments-v1,provider-accounts-v1,runtime-updates-v1,threads-v1,threads-v2,threads-v3' \
    "$(/bin/bash "$helper" runtime-info)" \
    "worker runtime information"
assert_equal \
    "__TERMINAL_RELAY_RUNTIME_UPDATE_V1__" \
    "$(/bin/bash "$helper" runtime-update-status)" \
    "missing worker runtime update status"
printf '%s\n' \
    '__TERMINAL_RELAY_RUNTIME_UPDATE_V1__' \
    'runtime-update|1785055400|checking|2000000000|2000000001|none' \
    > "$runtime_update_status_file"
/bin/chmod 644 "$runtime_update_status_file"
assert_equal \
    $'__TERMINAL_RELAY_RUNTIME_UPDATE_V1__\nruntime-update|1785055400|checking|2000000000|2000000001|none' \
    "$(/bin/bash "$helper" runtime-update-status)" \
    "worker runtime update progress"
runtime_request_output="$(/bin/bash "$helper" runtime-update-request)"
assert_contains "$runtime_request_output" \
    "__TERMINAL_RELAY_RUNTIME_UPDATE_V1__" \
    "worker runtime request marker"
assert_contains "$runtime_request_output" "|accepted" "worker runtime request result"
assert_equal "600" "$(path_mode "$runtime_root/runtime-update-request")" \
    "worker runtime request mode"

echo "2/18 concurrent starts create independent terminals with distinct tokens"
start_one_output="$test_root/start-one.out"
start_two_output="$test_root/start-two.out"
/bin/bash "$helper" start codex alpha --candidate-one > "$start_one_output" 2>&1 &
start_one_pid=$!
/bin/bash "$helper" start codex alpha --candidate-two > "$start_two_output" 2>&1 &
start_two_pid=$!
wait "$start_one_pid"
wait "$start_two_pid"
start_one_line="$(/usr/bin/awk -F'|' '$1 == "session" { print; exit }' "$start_one_output")"
start_two_line="$(/usr/bin/awk -F'|' '$1 == "session" { print; exit }' "$start_two_output")"
first_instance="$(instance_from_line "$start_one_line")"
parallel_instance="$(instance_from_line "$start_two_line")"
[[ "$first_instance" != "$parallel_instance" ]] || fail "concurrent starts reused an instance"
wait_for_session codex alpha 0 >/dev/null
assert_equal "600" "$(path_mode "$runtime_root/$first_instance.intent")" "Codex restart-intent mode"
assert_equal "600" "$(path_mode "$runtime_root/$parallel_instance.intent")" "parallel restart-intent mode"
wait_for_log_lines 2
first_log="$(/usr/bin/sed -n '1p' "$agent_log")"
second_parallel_log="$(/usr/bin/sed -n '2p' "$agent_log")"
assert_contains "$first_log$second_parallel_log" "--candidate-one" "first concurrent launch argument"
assert_contains "$first_log$second_parallel_log" "--candidate-two" "second concurrent launch argument"
assert_contains "$first_log$second_parallel_log" "mcp_servers.test_server={enabled=false}" "Codex MCP disable argument"
assert_contains "$first_log$second_parallel_log" \
    "|path=/usr/local/bin:/usr/bin:/bin" "Codex client safe PATH"
sleep 0.2
assert_equal "2" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "concurrent launch count"
/bin/bash "$helper" stop codex alpha "$parallel_instance"

codex_thread_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
mkdir -p "$test_home/.codex"
"$python_path" - "$test_home/.codex/state_5.sqlite" "$codex_thread_id" <<'PYTHON_CODEX_TITLE'
import sqlite3
import sys

database, thread_id = sys.argv[1:]
connection = sqlite3.connect(database)
connection.execute(
    "create table threads ("
    "id text primary key, title text not null, preview text, "
    "first_user_message text, name text, cwd text, "
    "updated_at integer, archived integer, source text)"
)
connection.execute(
    "insert into threads "
    "(id, title, preview, first_user_message, name, cwd, "
    "updated_at, archived, source) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    (
        thread_id,
        "First Codex prompt",
        "Original user prompt",
        "Original user prompt",
        "Generated Codex name",
        None,
        100,
        0,
        "cli",
    ),
)
connection.commit()
connection.close()
PYTHON_CODEX_TITLE
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    select-pane -t "terminal-relay-codex-$first_instance" \
    -T "$codex_thread_id | Ready"
codex_title_status="$(wait_for_session codex alpha 0)"
assert_equal \
    "$(encode_title "Generated Codex name")" \
    "$(title_hex_from_line "$codex_title_status")" \
    "Codex database name"
assert_equal \
    "0" \
    "$(printf '%s\n' "$codex_title_status" | /usr/bin/awk -F'|' '$1 == "session" { print $8; exit }')" \
    "Codex ready state"
assert_equal \
    "$codex_thread_id" \
    "$(thread_id_from_line "$codex_title_status")" \
    "Codex thread id"
"$python_path" - "$test_home/.codex/state_5.sqlite" "$codex_thread_id" <<'PYTHON_CODEX_TITLE_FALLBACK'
import sqlite3
import sys

database, thread_id = sys.argv[1:]
connection = sqlite3.connect(database)
connection.execute(
    "update threads set name = null where id = ?",
    (thread_id,),
)
connection.commit()
connection.close()
PYTHON_CODEX_TITLE_FALLBACK
codex_fallback_title_status="$(wait_for_session codex alpha 0)"
assert_equal \
    "$(encode_title "First Codex prompt")" \
    "$(title_hex_from_line "$codex_fallback_title_status")" \
    "Codex database title fallback"
printf '%s\n' \
    '{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","thread_name":"Generated Codex title"}' \
    > "$test_home/.codex/session_index.jsonl"
codex_persisted_title_status="$(wait_for_session codex alpha 0)"
assert_equal \
    "$(encode_title "Generated Codex title")" \
    "$(title_hex_from_line "$codex_persisted_title_status")" \
    "Codex persisted thread name"
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    select-pane -t "terminal-relay-codex-$first_instance" \
    -T "Original user prompt | Ready"
codex_prompt_pane_status="$(wait_for_session codex alpha 0)"
assert_equal \
    "$(encode_title "Generated Codex title")" \
    "$(title_hex_from_line "$codex_prompt_pane_status")" \
    "Codex persisted name for a prompt-titled pane"
assert_equal \
    "$codex_thread_id" \
    "$(thread_id_from_line "$codex_prompt_pane_status")" \
    "Codex inferred thread id for a prompt-titled pane"
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    select-pane -t "terminal-relay-codex-$first_instance" \
    -T "Renamed live thread | Working"
codex_working_status="$(wait_for_session codex alpha 0)"
assert_equal \
    "$(encode_title "Renamed live thread")" \
    "$(title_hex_from_line "$codex_working_status")" \
    "Codex live pane name"
assert_equal \
    "1" \
    "$(printf '%s\n' "$codex_working_status" | /usr/bin/awk -F'|' '$1 == "session" { print $8; exit }')" \
    "Codex working state"

start_client client-one "$workspace_root/alpha" reattach codex alpha "$first_instance"
start_client client-two "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_session codex alpha 2 >/dev/null

assert_equal "off" "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv status)" "tmux status bar"
assert_equal "on" "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv set-titles)" "tmux title setting"
assert_equal '#{pane_title}' "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv set-titles-string)" "tmux title format"

echo "3/18 configure failure on a later attach leaves the shared session untouched"
TERMINAL_RELAY_TEST_CLIENT_CONFIGURE_FAIL=1 \
    start_client configure-failure "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_harness_exit configure-failure
after_failure="$(wait_for_session codex alpha 2)"
assert_equal "$first_instance" "$(instance_from_line "$after_failure")" "instance after configure failure"
assert_equal "2" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "launch count after configure failure"
start_client reattach-client "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_session codex alpha 3 >/dev/null
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t reattach-client
wait_for_session codex alpha 2 >/dev/null

echo "4/18 the same agent can run concurrently in another repository"
other_project_output="$(/bin/bash "$helper" start codex beta --other-project)"
other_project_instance="$(instance_from_line "$other_project_output")"
[[ "$other_project_instance" != "$first_instance" ]] || fail "other project reused an instance"
wait_for_log_lines 3
/bin/bash "$helper" stop codex beta "$other_project_instance"

echo "5/18 both client connections can disappear while the launch survives"
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-one
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-two 2>/dev/null || true
detached_status="$(wait_for_session codex alpha 0)"
assert_equal "$first_instance" "$(instance_from_line "$detached_status")" "instance after detach"

echo "6/18 an arbitrary stale token cannot stop the active launch"
stale_instance="00000000-0000-0000-0000-000000000000"
[[ "$stale_instance" != "$first_instance" ]] \
    || stale_instance="11111111-1111-1111-1111-111111111111"
stale_output="$(run_stop_expect_75 codex alpha "$stale_instance")"
assert_contains "$stale_output" "stop request is stale" "stale stop diagnostic"
stale_reattach_output="$(run_reattach_expect_75 codex alpha "$stale_instance")"
assert_contains "$stale_reattach_output" "has ended" "stale reattach diagnostic"
still_running="$(wait_for_session codex alpha 0)"
assert_equal "$first_instance" "$(instance_from_line "$still_running")" "instance after stale stop"

echo "7/18 exact stop ends the first launch and a same-repository replacement gets a new token"
/bin/bash "$helper" stop codex alpha "$first_instance"
wait_for_no_session codex
assert_agent_lock_free "$first_instance"
ended_reattach_output="$(run_reattach_expect_75 codex alpha "$first_instance")"
assert_contains "$ended_reattach_output" "has ended" "ended launch reattach diagnostic"
second_start_output="$(/bin/bash "$helper" start codex alpha --stubborn)"
second_status="$(printf '%s\n' "$second_start_output" | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')"
second_instance="$(instance_from_line "$second_status")"
[[ "$second_instance" != "$first_instance" ]] || fail "replacement reused the old instance token"
wait_for_log_lines 4
wait_for_session codex alpha 0 >/dev/null

echo "8/18 the old same-repository token cannot stop its replacement"
old_token_output="$(run_stop_expect_75 codex alpha "$first_instance")"
assert_contains "$old_token_output" "stop request is stale" "same-repository stale stop"
old_reattach_output="$(run_reattach_expect_75 codex alpha "$first_instance")"
assert_contains "$old_reattach_output" "has ended" "same-repository stale reattach"
replacement_status="$(wait_for_session codex alpha 0)"
assert_equal "$second_instance" "$(instance_from_line "$replacement_status")" "replacement after stale stop"

echo "9/18 paused stale reattach fails closed across stubborn stop and replacement"
pause_file="$test_root/pause-before-attach"
touch "$pause_file"
TERMINAL_RELAY_TEST_CLIENT_PAUSE_BEFORE_ATTACH="$pause_file" \
    start_client paused-reattach "$workspace_root/alpha" reattach codex alpha "$second_instance"
attempt=0
while [[ ! -f "$pause_file.ready" && $attempt -lt 100 ]]; do
    attempt=$((attempt + 1))
    sleep 0.05
done
[[ -f "$pause_file.ready" ]] || fail "paused reattach never reached the unlock/exec boundary"
/bin/bash "$helper" stop codex alpha "$second_instance"
wait_for_no_session codex
assert_agent_lock_free "$second_instance"
signal_output="$(/bin/cat "$signal_log")"
assert_contains "$signal_output" "name=TERM" "stubborn launch TERM through test signal adapter"
assert_contains "$signal_output" "name=KILL" "stubborn launch KILL through test signal adapter"
third_start_output="$(/bin/bash "$helper" start codex alpha --after-stubborn)"
third_status="$(printf '%s\n' "$third_start_output" | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')"
third_instance="$(instance_from_line "$third_status")"
wait_for_log_lines 5
[[ "$third_instance" != "$second_instance" ]] || fail "post-stubborn launch reused its instance token"
/bin/rm -f -- "$pause_file"
wait_for_harness_exit paused-reattach
post_pause_status="$(wait_for_session codex alpha 0)"
assert_equal "$third_instance" "$(instance_from_line "$post_pause_status")" "replacement after paused stale reattach"
paused_old_stop="$(run_stop_expect_75 codex alpha "$second_instance")"
assert_contains "$paused_old_stop" "stop request is stale" "post-pause stale stop"

start_client client-three "$workspace_root/alpha" reattach codex alpha "$third_instance"
wait_for_session codex alpha 1 >/dev/null
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-three 2>/dev/null || true
wait_for_session codex alpha 0 >/dev/null

echo "10/18 legacy Claude launch infers its repository, preserves environment, and exits cleanly"
export ConEmuANSI=1
printf '%s\n' '{"theme":"dark","oauthAccount":{"test":true}}' > "$test_home/.claude.json"
/bin/chmod 600 "$test_home/.claude.json"
start_client clean-client "$workspace_root/beta" claude --exit-cleanly
wait_for_log_lines 6
wait_for_no_session claude
clean_log="$(/usr/bin/sed -n '6p' "$agent_log")"
assert_contains "$clean_log" "cwd=$workspace_root/beta" "legacy inferred repository"
assert_contains "$clean_log" "ConEmuANSI=1" "Claude terminal environment"
"$python_path" - "$test_home/.claude.json" <<'PYTHON_VERIFY_CLAUDE_ONBOARDING'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
assert config["hasCompletedOnboarding"] is True
assert config["theme"] == "dark"
assert config["oauthAccount"] == {"test": True}
PYTHON_VERIFY_CLAUDE_ONBOARDING
assert_equal "600" "$(path_mode "$test_home/.claude.json")" "Claude global config mode"
assert_equal "1" "$(/usr/bin/find "$runtime_root" -maxdepth 1 -name '*.intent' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
    "clean Claude exit retained restart intent"

echo "11/18 final exact stop removes metadata only after process and lock release"
/bin/bash "$helper" stop codex alpha "$third_instance"
wait_for_no_session codex
assert_agent_lock_free "$third_instance"
assert_equal "__TERMINAL_RELAY_SESSION_V1__" "$(session_status)" "final empty status"
[[ ! -e "$runtime_root/$third_instance.intent" ]] || fail "exact Codex stop retained restart intent"
repeat_output="$(run_stop_expect_75 codex alpha "$third_instance")"
assert_contains "$repeat_output" "stop request is stale" "repeated stop diagnostic"

echo "12/18 caller-supplied provider lifecycle flags are rejected"
set +e
managed_codex_output="$(/bin/bash "$helper" start codex alpha resume 2>&1)"
managed_codex_status=$?
managed_claude_output="$(/bin/bash "$helper" start claude beta --resume other 2>&1)"
managed_claude_status=$?
set -e
assert_equal "64" "$managed_codex_status" "managed Codex resume flag status"
assert_contains "$managed_codex_output" "manages Codex resume" "managed Codex resume diagnostic"
assert_equal "64" "$managed_claude_status" "managed Claude resume flag status"
assert_contains "$managed_claude_output" "manages Claude session" "managed Claude resume diagnostic"

echo "13/18 Codex survives a simulated reboot with one idempotent resume launch"
unset ConEmuANSI
codex_reboot_output="$(/bin/bash "$helper" start codex alpha --reboot-codex)"
codex_reboot_instance="$(printf '%s\n' "$codex_reboot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
wait_for_log_lines 7
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    select-pane -t "terminal-relay-codex-$codex_reboot_instance" \
    -T "$codex_thread_id | Ready"
codex_bound_status="$(wait_for_session codex alpha 0)"
assert_equal "$codex_thread_id" "$(thread_id_from_line "$codex_bound_status")" \
    "Codex reboot provider thread binding"
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free "$codex_reboot_instance"
printf '%s\n' '22222222-2222-4222-8222-222222222222' > "$boot_id_file"
/bin/bash "$helper" restore > "$test_root/restore-one.out" 2>&1 &
restore_one_pid=$!
/bin/bash "$helper" restore > "$test_root/restore-two.out" 2>&1 &
restore_two_pid=$!
wait "$restore_one_pid"
wait "$restore_two_pid"
restored_codex_status="$(wait_for_session codex alpha 0)"
assert_equal "$codex_reboot_instance" "$(instance_from_line "$restored_codex_status")" "restored Codex instance"
wait_for_log_lines 8
codex_resume_log="$(/usr/bin/sed -n '8p' "$agent_log")"
assert_contains "$codex_resume_log" "|resume|$codex_thread_id|--reboot-codex" \
    "Codex exact resume arguments"
assert_equal "8" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "idempotent restore count"

echo "14/18 explicit stop prevents a later Codex reboot restore"
/bin/bash "$helper" stop codex alpha "$codex_reboot_instance"
wait_for_no_session codex
printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "8" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "stopped Codex restore count"

echo "15/18 Claude resumes the UUID-bound provider conversation after reboot"
claude_reboot_output="$(/bin/bash "$helper" start claude beta \
    --model fable \
    --effort max \
    --settings worker-settings.json \
    --reboot-claude)"
claude_reboot_instance="$(printf '%s\n' "$claude_reboot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
claude_provider_thread_id="$(printf '%s\n' "$claude_reboot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $9; exit }')"
[[ "$claude_reboot_instance" != "$claude_provider_thread_id" ]] \
    || fail "Claude relay and provider identifiers were not separated"
wait_for_log_lines 9
claude_initial_log="$(/usr/bin/sed -n '9p' "$agent_log")"
assert_contains "$claude_initial_log" \
    "|--session-id|$claude_provider_thread_id|--model|fable|--effort|max|--settings|worker-settings.json|--reboot-claude" \
    "Claude initial provider session id"
"$python_path" - "$claude_sessions_state" "$claude_provider_thread_id" <<'PYTHON_CLAUDE_TITLE'
import json
import sys

path, session_id = sys.argv[1:]
with open(path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state[session_id] = {
    "title": "Generated Claude title",
    "updatedAt": 200,
    "activity": "inactive",
}
with open(path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file, separators=(",", ":"))
PYTHON_CLAUDE_TITLE
claude_generated_title_status="$(wait_for_session claude beta 0)"
assert_equal \
    "$(encode_title "Generated Claude title")" \
    "$(title_hex_from_line "$claude_generated_title_status")" \
    "Claude generated title"
assert_equal \
    "$claude_provider_thread_id" \
    "$(thread_id_from_line "$claude_generated_title_status")" \
    "Claude thread id"
"$python_path" - "$claude_sessions_state" "$claude_provider_thread_id" <<'PYTHON_CLAUDE_RENAME'
import json
import sys

path, session_id = sys.argv[1:]
with open(path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state[session_id]["title"] = "Renamed Claude title"
with open(path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file, separators=(",", ":"))
PYTHON_CLAUDE_RENAME
claude_custom_title_status="$(wait_for_session claude beta 0)"
assert_equal \
    "$(encode_title "Renamed Claude title")" \
    "$(title_hex_from_line "$claude_custom_title_status")" \
    "Claude custom title"
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free "$claude_reboot_instance"
printf '%s\n' '44444444-4444-4444-8444-444444444444' > "$boot_id_file"
/bin/bash "$helper" restore
restored_claude_status="$(wait_for_session claude beta 0)"
assert_equal "$claude_reboot_instance" "$(instance_from_line "$restored_claude_status")" "restored Claude instance"
wait_for_log_lines 10
claude_resume_log="$(/usr/bin/sed -n '10p' "$agent_log")"
assert_contains "$claude_resume_log" \
    "|--resume|$claude_provider_thread_id|--settings|worker-settings.json|--reboot-claude" \
    "Claude exact resume arguments"
[[ "$claude_resume_log" != *"|--model|"* \
    && "$claude_resume_log" != *"|--effort|"* ]] \
    || fail "Claude resume overrode provider-restored model state"
/bin/bash "$helper" stop claude beta "$claude_reboot_instance"
wait_for_no_session claude
printf '%s\n' '55555555-5555-4555-8555-555555555555' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "10" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "stopped Claude restore count"

claude_rename_output="$(/bin/bash "$helper" \
    thread-rename-v2 claude beta "$claude_provider_thread_id" "Managed Claude title")"
assert_equal "__TERMINAL_RELAY_THREADS_V2__" \
    "$(printf '%s\n' "$claude_rename_output" | /usr/bin/sed -n '1p')" \
    "Claude V2 rename marker"
assert_contains "$claude_rename_output" '"title":"Managed Claude title"' \
    "Claude V2 rename result"
claude_archive_output="$(/bin/bash "$helper" \
    thread-archive-v2 claude beta "$claude_provider_thread_id")"
assert_contains "$claude_archive_output" '"archived":true' "Claude archive result"
claude_archive_marker="$runtime_root/claude-archives/beta/$claude_provider_thread_id"
assert_equal "version|1" "$(< "$claude_archive_marker")" "Claude archive marker"
assert_equal "600" "$(path_mode "$claude_archive_marker")" "Claude archive marker mode"
printf '%s\n' '55666666-6666-4666-8666-666666666666' > "$boot_id_file"
/bin/bash "$helper" restore
claude_archived_catalog="$(/bin/bash "$helper" threads-v2 claude beta archived)"
assert_contains "$claude_archived_catalog" "\"threadID\":\"$claude_provider_thread_id\"" \
    "Claude archive persistence"
/bin/bash "$helper" \
    thread-unarchive-v2 claude beta "$claude_provider_thread_id" >/dev/null
[[ ! -e "$claude_archive_marker" ]] || fail "Claude unarchive retained its marker"

external_claude_id="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
unknown_claude_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
"$python_path" - \
    "$claude_sessions_state" "$external_claude_id" "$unknown_claude_id" <<'PYTHON_CLAUDE_ACTIVITY'
import json
import sys

path, external_id, unknown_id = sys.argv[1:]
with open(path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state[external_id] = {
    "title": "External Claude session",
    "updatedAt": 150,
    "activity": "external-active",
}
state[unknown_id] = {
    "title": "Unknown Claude session",
    "updatedAt": 140,
    "activity": "unknown",
}
with open(path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file, separators=(",", ":"))
PYTHON_CLAUDE_ACTIVITY
claude_open_catalog="$(/bin/bash "$helper" threads-v2 claude beta open)"
printf '%s\n' "$claude_open_catalog" | "$python_path" -c '
import json
import sys

lines = sys.stdin.read().splitlines()
assert lines[0] == "__TERMINAL_RELAY_THREADS_V2__"
rows = {row["threadID"]: row for row in json.loads(lines[1])["threads"]}
assert rows[sys.argv[1]]["activityState"] == "external-active"
assert rows[sys.argv[1]]["capabilities"]["resume"] is False
assert rows[sys.argv[2]]["activityState"] == "unknown"
assert rows[sys.argv[2]]["capabilities"]["archive"] is False
' "$external_claude_id" "$unknown_claude_id"

set +e
/bin/bash "$helper" thread-resume-v2 claude beta "$claude_provider_thread_id" \
    --model opus --effort high --settings worker-settings.json \
    > "$test_root/claude-resume-one.out" 2>&1 &
claude_resume_one_pid=$!
/bin/bash "$helper" thread-resume-v2 claude beta "$claude_provider_thread_id" \
    --model opus --effort high --settings worker-settings.json \
    > "$test_root/claude-resume-two.out" 2>&1 &
claude_resume_two_pid=$!
wait "$claude_resume_one_pid"
claude_resume_one_status=$?
wait "$claude_resume_two_pid"
claude_resume_two_status=$?
set -e
if [[ "$claude_resume_one_status" == "0" && "$claude_resume_two_status" == "75" ]]; then
    claude_concurrent_output="$test_root/claude-resume-one.out"
elif [[ "$claude_resume_one_status" == "75" && "$claude_resume_two_status" == "0" ]]; then
    claude_concurrent_output="$test_root/claude-resume-two.out"
else
    fail "concurrent Claude resume returned $claude_resume_one_status and $claude_resume_two_status"
fi
claude_concurrent_instance="$(/usr/bin/awk -F'|' \
    '$1 == "session" { print $5; exit }' "$claude_concurrent_output")"
[[ -n "$claude_concurrent_instance" \
    && "$claude_concurrent_instance" != "$claude_provider_thread_id" ]] \
    || fail "concurrent Claude resume did not return a distinct relay token"
wait_for_log_lines 11
claude_v2_resume_log="$(/usr/bin/sed -n '11p' "$agent_log")"
assert_contains "$claude_v2_resume_log" \
    "|--resume|$claude_provider_thread_id|--settings|worker-settings.json" \
    "Claude V2 exact resume"
[[ "$claude_v2_resume_log" != *"|--model|"* \
    && "$claude_v2_resume_log" != *"|--effort|"* ]] \
    || fail "Claude V2 resume overrode provider-restored model state"
/bin/bash "$helper" stop claude beta "$claude_concurrent_instance"
wait_for_no_session claude

echo "16/18 a same-boot death is not resurrected now or on a later reboot"
same_boot_output="$(/bin/bash "$helper" start codex zeta --same-boot-death)"
same_boot_instance="$(printf '%s\n' "$same_boot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
[[ -n "$same_boot_instance" ]] || fail "same-boot launch did not return an instance"
wait_for_log_lines 12
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free "$same_boot_instance"
/bin/bash "$helper" restore
assert_equal "12" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "same-boot restore count"
assert_equal "__TERMINAL_RELAY_SESSION_V1__" "$(session_status)" "same-boot dead status"
printf '%s\n' '66666666-6666-4666-8666-666666666666' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "12" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "later restore after same-boot cleanup"

echo "17/18 corrupt persistent state fails closed without launching an agent"
corrupt_instance="99999999-9999-4999-8999-999999999999"
printf '%s\n' 'version|1' 'tool|codex' 'repository|alpha' > "$runtime_root/$corrupt_instance.intent"
/bin/chmod 600 "$runtime_root/$corrupt_instance.intent"
printf '%s\n' '77777777-7777-4777-8777-777777777777' > "$boot_id_file"
set +e
corrupt_output="$(/bin/bash "$helper" restore 2>&1)"
corrupt_status=$?
set -e
assert_equal "70" "$corrupt_status" "corrupt restore status"
assert_contains "$corrupt_output" "restart intent for" "corrupt restore diagnostic"
assert_equal "12" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "corrupt restore launch count"
/bin/rm -f -- "$runtime_root/$corrupt_instance.intent"

echo "18/18 shared Codex launches leave MCP configuration on the app server"
shared_instance="88888888-8888-4888-8888-888888888888"
printf '%s\n' \
    'tool|codex' \
    'repository|alpha' \
    "instance|$shared_instance" \
    'pid|0' \
    'start|pending' \
    > "$runtime_root/$shared_instance.session"
printf '%s\n' \
    'version|1' \
    'tool|codex' \
    'repository|alpha' \
    "instance|$shared_instance" \
    'boot|77777777-7777-4777-8777-777777777777' \
    'argc|1' \
    'arg|2d2d657869742d636c65616e6c79' \
    > "$runtime_root/$shared_instance.intent"
/bin/chmod 600 "$runtime_root/$shared_instance.intent"
shared_codex_socket="/tmp/terminal-relay-codex-test-$$.sock"
TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=1 \
    TERMINAL_RELAY_TEST_CODEX_APP_SERVER_SOCKET="$shared_codex_socket" \
    start_client shared-codex "$workspace_root/alpha" \
        __run-agent codex alpha "$shared_instance" initial --exit-cleanly
wait_for_harness_exit shared-codex
wait_for_log_lines 13
shared_codex_log="$(/usr/bin/sed -n '13p' "$agent_log")"
assert_contains "$shared_codex_log" \
    "--remote|unix://$shared_codex_socket" "shared Codex remote arguments"
if [[ "$shared_codex_log" == *"mcp_servers.test_server"* ]]; then
    fail "shared Codex launch forwarded client-side MCP overrides"
fi

echo "Codex app-server restart waits for live terminals and clears only after readiness"
wait_for_no_session codex
: > "$codex_app_server_log"
printf '%s\n' ready > "$codex_app_server_control"
export TERMINAL_RELAY_TEST_CODEX_PATH="$stub_codex"
export TERMINAL_RELAY_TEST_CODEX_APP_SERVER_SOCKET="$rotation_codex_socket"
codex_restart_marker="$runtime_root/codex-app-server-restart-required"
codex_account_session="terminal-relay-account-server"
codex_rotation_guard="terminal-relay-codex-rotation-guard"
claude_rotation_guard="terminal-relay-claude-rotation-guard"

if ! /bin/bash "$helper" codex-account >/dev/null; then
    /bin/cat "$codex_app_server_log" >&2
    fail "initial Codex app-server launch did not become ready"
fi
if ! /bin/bash "$helper" __verify-codex-account >/dev/null; then
    fail "authenticated shared Codex account did not pass verification"
fi
printf '%s\n' signed-out > "$codex_app_server_control"
set +e
signed_out_output="$(/bin/bash "$helper" __verify-codex-account 2>&1)"
signed_out_status=$?
set -e
assert_equal "77" "$signed_out_status" "signed-out shared Codex account status"
assert_contains \
    "$signed_out_output" \
    "Codex is not authenticated" \
    "signed-out shared Codex account diagnostic"
printf '%s\n' ready > "$codex_app_server_control"
/bin/rm -f -- "$test_home/.codex/session_index.jsonl"
generated_title_result="$(TERMINAL_RELAY_TEST_CODEX_TITLE_GENERATION=1 \
    /bin/bash "$helper" __generate-codex-titles --active)"
assert_contains \
    "$generated_title_result" \
    '"generated":1' \
    "Codex generated title count"
generated_codex_title="$("$python_path" - "$test_home/.codex/session_index.jsonl" \
    "$codex_thread_id" <<'PYTHON_GENERATED_CODEX_TITLE'
import json
import sys

index_path, thread_id = sys.argv[1:]
title = ""
with open(index_path, encoding="utf-8") as records:
    for line in records:
        record = json.loads(line)
        if record.get("id") == thread_id:
            title = record.get("thread_name", "")
print(title)
PYTHON_GENERATED_CODEX_TITLE
)"
assert_equal \
    "Generated Codex title" \
    "$generated_codex_title" \
    "Codex generated title persistence"
assert_equal \
    "1" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "initial Codex app-server launch count"
initial_account_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "$codex_account_session" '#{pane_pid}')"
[[ "$initial_account_pid" =~ ^[1-9][0-9]*$ ]] \
    || fail "initial Codex account server has an invalid pid"
assert_contains \
    "$(/bin/cat "$codex_app_server_log")" \
    "path=/usr/local/bin:/usr/bin:/bin" \
    "Codex app-server safe PATH"

"$tmux_path" -f /dev/null -L "$tmux_socket" \
    new-session -d -s "$codex_rotation_guard" "/bin/sleep 30"
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    new-session -d -s "$claude_rotation_guard" "/bin/sleep 30"
/bin/bash "$helper" __schedule-codex-app-server-restart
assert_equal "600" "$(path_mode "$codex_restart_marker")" "Codex restart marker mode"
/bin/bash "$helper" codex-account >/dev/null
[[ -f "$codex_restart_marker" ]] \
    || fail "Codex restart marker cleared while a Codex terminal was active"
assert_equal \
    "1" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "deferred Codex app-server launch count"
assert_equal \
    "$initial_account_pid" \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" \
        display-message -p -t "$codex_account_session" '#{pane_pid}')" \
    "deferred Codex account-server pid"

"$tmux_path" -f /dev/null -L "$tmux_socket" \
    kill-session -t "$codex_rotation_guard"
/bin/bash "$helper" codex-account >/dev/null
[[ ! -e "$codex_restart_marker" ]] \
    || fail "Codex restart marker remained after successful deferred rotation"
assert_equal \
    "2" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "deferred Codex app-server rotation count"
rotated_account_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "$codex_account_session" '#{pane_pid}')"
[[ "$rotated_account_pid" =~ ^[1-9][0-9]*$ \
    && "$rotated_account_pid" != "$initial_account_pid" ]] \
    || fail "Codex account server did not rotate after the last Codex terminal exited"
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    has-session -t "$claude_rotation_guard" \
    || fail "Codex rotation disturbed an unrelated tmux session"

printf '%s\n' fail > "$codex_app_server_control"
/bin/bash "$helper" __schedule-codex-app-server-restart
set +e
failed_rotation_output="$(/bin/bash "$helper" codex-account 2>&1)"
failed_rotation_status=$?
set -e
assert_equal "70" "$failed_rotation_status" "failed Codex app-server rotation status"
assert_contains \
    "$failed_rotation_output" \
    "did not become ready" \
    "failed Codex app-server rotation diagnostic"
[[ -f "$codex_restart_marker" ]] \
    || fail "Codex restart marker cleared before replacement readiness"
assert_equal \
    "3" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "failed Codex app-server rotation count"
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    has-session -t "$claude_rotation_guard" \
    || fail "failed Codex rotation disturbed an unrelated tmux session"

printf '%s\n' ready > "$codex_app_server_control"
/bin/bash "$helper" codex-account >/dev/null
[[ ! -e "$codex_restart_marker" ]] \
    || fail "Codex restart marker remained after replacement readiness"
assert_equal \
    "4" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "successful Codex app-server retry count"
ready_account_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "$codex_account_session" '#{pane_pid}')"

echo "Codex start reservation closes the readiness-to-tmux race"
reservation_pause="$test_root/pause-after-codex-reservation"
reservation_start_output="$test_root/reservation-start.out"
reservation_schedule_started="$test_root/reservation-schedule.started"
reservation_schedule_done="$test_root/reservation-schedule.done"
reservation_account_started="$test_root/reservation-account.started"
reservation_account_done="$test_root/reservation-account.done"
: > "$reservation_pause"
export TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=1
export TERMINAL_RELAY_TEST_PAUSE_AFTER_CODEX_RESERVATION="$reservation_pause"
/bin/bash "$helper" start codex alpha --reservation-race \
    > "$reservation_start_output" 2>&1 &
reservation_start_pid=$!
attempt=0
while [[ ! -f "$reservation_pause.ready" && $attempt -lt 100 ]]; do
    attempt=$((attempt + 1))
    sleep 0.05
done
[[ -f "$reservation_pause.ready" ]] \
    || fail "Codex start did not reach the reserved account-server boundary"
exec 5>"$runtime_root/codex-app-server.lock"
if "$flock_adapter" --nonblock 5; then
    exec 5>&-
    fail "Codex start released the account-server lock before tmux registration"
fi
exec 5>&-

(
    : > "$reservation_schedule_started"
    /bin/bash "$helper" __schedule-codex-app-server-restart
    : > "$reservation_schedule_done"
) &
reservation_schedule_pid=$!
(
    : > "$reservation_account_started"
    /bin/bash "$helper" codex-account >/dev/null
    : > "$reservation_account_done"
) &
reservation_account_pid=$!
attempt=0
while { [[ ! -f "$reservation_schedule_started" \
    || ! -f "$reservation_account_started" ]]; } && [[ $attempt -lt 100 ]]; do
    attempt=$((attempt + 1))
    sleep 0.05
done
[[ -f "$reservation_schedule_started" && -f "$reservation_account_started" ]] \
    || fail "concurrent Codex restart requests did not start"
[[ ! -e "$reservation_schedule_done" && ! -e "$reservation_account_done" ]] \
    || fail "a Codex restart request crossed the held start reservation"

/bin/rm -f -- "$reservation_pause"
unset TERMINAL_RELAY_TEST_PAUSE_AFTER_CODEX_RESERVATION
wait "$reservation_start_pid"
wait "$reservation_schedule_pid"
wait "$reservation_account_pid"
reservation_start_line="$(/usr/bin/awk -F'|' '$1 == "session" { print; exit }' \
    "$reservation_start_output")"
reservation_instance="$(instance_from_line "$reservation_start_line")"
[[ "$reservation_instance" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || fail "reserved Codex start returned an invalid instance"
wait_for_session codex alpha 0 >/dev/null
[[ -f "$codex_restart_marker" ]] \
    || fail "Codex restart marker was lost across the start reservation"
assert_equal \
    "4" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "Codex app-server count across the start reservation"
assert_equal \
    "$ready_account_pid" \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" \
        display-message -p -t "$codex_account_session" '#{pane_pid}')" \
    "Codex account-server pid across the start reservation"

/bin/bash "$helper" stop codex alpha "$reservation_instance"
wait_for_no_session codex
/bin/bash "$helper" codex-account >/dev/null
[[ ! -e "$codex_restart_marker" ]] \
    || fail "Codex restart marker remained after the reserved terminal stopped"
assert_equal \
    "5" \
    "$(/usr/bin/awk -F'|' '$1 == "launch" { count++ } END { print count + 0 }' "$codex_app_server_log")" \
    "Codex app-server rotation count after reserved terminal stop"
unset TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    kill-session -t "$claude_rotation_guard"

echo "Thread catalog mutations and exact resume stay worker-scoped"
export TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=1
active_threads="$(/bin/bash "$helper" threads alpha active)"
assert_contains "$active_threads" "__TERMINAL_RELAY_THREADS_V1__" \
    "thread protocol marker"
assert_contains "$active_threads" "$codex_thread_id" "active thread catalog"
created_thread_output="$(/bin/bash "$helper" thread-create alpha)"
created_thread_id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
assert_contains "$created_thread_output" "$created_thread_id" "created thread"
renamed_thread_output="$(/bin/bash "$helper" thread-rename alpha "$created_thread_id" "Worker task")"
assert_contains "$renamed_thread_output" '"title":"Worker task"' "renamed thread"
resumed_thread_output="$(/bin/bash "$helper" thread-resume alpha "$created_thread_id" --managed-thread)"
resumed_thread_instance="$(instance_from_line "$(printf '%s\n' "$resumed_thread_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')")"
assert_equal "$created_thread_id" "$(thread_id_from_line "$resumed_thread_output")" \
    "resumed thread provider id"
set +e
active_archive_output="$(/bin/bash "$helper" thread-archive alpha "$created_thread_id" 2>&1)"
active_archive_status=$?
set -e
assert_equal "75" "$active_archive_status" "active thread archive rejection"
assert_contains "$active_archive_output" "Active threads cannot" "active thread rejection diagnostic"
/bin/bash "$helper" stop codex alpha "$resumed_thread_instance"
/bin/bash "$helper" thread-archive alpha "$created_thread_id" >/dev/null
archived_threads="$(/bin/bash "$helper" threads alpha archived)"
assert_contains "$archived_threads" "$created_thread_id" "archived thread catalog"
/bin/bash "$helper" thread-unarchive alpha "$created_thread_id" >/dev/null
unset TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT

claude_account_output="$(/bin/bash "$helper" claude-account)"
assert_contains \
    "$claude_account_output" \
    "__TERMINAL_RELAY_CLAUDE_AUTH__" \
    "Claude account auth marker"
assert_contains \
    "$claude_account_output" \
    "Current session: 12% used" \
    "Claude account usage output"

echo "A signed-runtime-style helper replacement preserves attached sessions and provider metadata"
current_runtime_helper="$helper"
upgrade_helper="$test_root/terminal-relay-session.previous"
/bin/cp "$current_runtime_helper" "$upgrade_helper"
printf '\n# Simulated previous worker runtime.\n' >> "$upgrade_helper"
/bin/chmod 755 "$upgrade_helper"
helper="$upgrade_helper"

upgrade_codex_output="$(/bin/bash "$helper" start codex alpha --runtime-upgrade)"
upgrade_codex_instance="$(instance_from_line "$(printf '%s\n' "$upgrade_codex_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')")"
upgrade_claude_output="$(/bin/bash "$helper" start claude beta --runtime-upgrade)"
upgrade_claude_line="$(printf '%s\n' "$upgrade_claude_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')"
upgrade_claude_instance="$(instance_from_line "$upgrade_claude_line")"
upgrade_claude_thread_id="$(thread_id_from_line "$upgrade_claude_line")"
upgrade_codex_thread_id="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
upgrade_dormant_codex_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
upgrade_archived_codex_id="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
upgrade_archived_claude_id="ffffffff-ffff-4fff-8fff-ffffffffffff"

wait_for_session codex alpha 0 >/dev/null
wait_for_session claude beta 0 >/dev/null
"$tmux_path" -f /dev/null -L "$tmux_socket" \
    select-pane -t "terminal-relay-codex-$upgrade_codex_instance" \
    -T "$upgrade_codex_thread_id | Ready"
wait_for_session codex alpha 0 >/dev/null
start_client runtime-upgrade-codex "$workspace_root/alpha" \
    reattach codex alpha "$upgrade_codex_instance"
start_client runtime-upgrade-claude "$workspace_root/beta" \
    reattach claude beta "$upgrade_claude_instance"
upgrade_codex_before="$(wait_for_session codex alpha 1)"
upgrade_claude_before="$(wait_for_session claude beta 1)"
upgrade_codex_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "terminal-relay-codex-$upgrade_codex_instance" '#{pane_pid}')"
upgrade_claude_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "terminal-relay-claude-$upgrade_claude_instance" '#{pane_pid}')"

mkdir -p \
    "$test_home/.codex/sessions" \
    "$test_home/.codex/archived_sessions" \
    "$runtime_root/claude-archives/beta" \
    "$test_root/other-worker-provider-state"
printf '%s\n' "$upgrade_dormant_codex_id" \
    > "$test_home/.codex/sessions/$upgrade_dormant_codex_id.json"
printf '%s\n' "$upgrade_archived_codex_id" \
    > "$test_home/.codex/archived_sessions/$upgrade_archived_codex_id.json"
printf '%s\n' 'version|1' \
    > "$runtime_root/claude-archives/beta/$upgrade_archived_claude_id"
printf '%s\n' 'other-worker-state' \
    > "$test_root/other-worker-provider-state/unchanged"
provider_state_before="$(/usr/bin/shasum -a 256 \
    "$test_home/.codex/sessions/$upgrade_dormant_codex_id.json" \
    "$test_home/.codex/archived_sessions/$upgrade_archived_codex_id.json" \
    "$runtime_root/claude-archives/beta/$upgrade_archived_claude_id")"
other_worker_state_before="$(/usr/bin/shasum -a 256 \
    "$test_root/other-worker-provider-state/unchanged")"

/usr/bin/install -m 0755 "$current_runtime_helper" "$test_root/runtime-helper.next"
/bin/mv -f "$test_root/runtime-helper.next" "$helper"

upgrade_codex_after="$(wait_for_session codex alpha 1)"
upgrade_claude_after="$(wait_for_session claude beta 1)"
assert_equal "$upgrade_codex_before" "$upgrade_codex_after" \
    "Codex session identity across runtime replacement"
assert_equal "$upgrade_claude_before" "$upgrade_claude_after" \
    "Claude session identity across runtime replacement"
assert_equal "$upgrade_codex_pid" \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" \
        display-message -p -t "terminal-relay-codex-$upgrade_codex_instance" '#{pane_pid}')" \
    "Codex process across runtime replacement"
assert_equal "$upgrade_claude_pid" \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" \
        display-message -p -t "terminal-relay-claude-$upgrade_claude_instance" '#{pane_pid}')" \
    "Claude process across runtime replacement"
assert_equal "$upgrade_codex_thread_id" "$(thread_id_from_line "$upgrade_codex_after")" \
    "Codex provider thread across runtime replacement"
assert_equal "$upgrade_claude_thread_id" "$(thread_id_from_line "$upgrade_claude_after")" \
    "Claude provider thread across runtime replacement"
assert_equal "$provider_state_before" "$(/usr/bin/shasum -a 256 \
    "$test_home/.codex/sessions/$upgrade_dormant_codex_id.json" \
    "$test_home/.codex/archived_sessions/$upgrade_archived_codex_id.json" \
    "$runtime_root/claude-archives/beta/$upgrade_archived_claude_id")" \
    "dormant and archived provider metadata across runtime replacement"
assert_equal "$other_worker_state_before" "$(/usr/bin/shasum -a 256 \
    "$test_root/other-worker-provider-state/unchanged")" \
    "other worker state across runtime replacement"
assert_contains "$(/bin/bash "$helper" status)" "__TERMINAL_RELAY_SESSION_V1__" \
    "legacy session protocol after runtime replacement"
assert_contains "$(/bin/bash "$helper" threads-v2 claude beta open)" \
    "__TERMINAL_RELAY_THREADS_V2__" \
    "current thread protocol after runtime replacement"
assert_contains "$(/bin/bash "$helper" runtime-info)" \
    "__TERMINAL_RELAY_RUNTIME_INFO_V1__" \
    "runtime information after runtime replacement"

/bin/bash "$helper" __schedule-codex-app-server-restart
[[ -f "$codex_restart_marker" ]] \
    || fail "runtime replacement restart marker did not wait for an attached Codex terminal"
"$tmux_path" -f /dev/null -L "$harness_socket" \
    kill-session -t runtime-upgrade-codex
"$tmux_path" -f /dev/null -L "$harness_socket" \
    kill-session -t runtime-upgrade-claude
wait_for_session codex alpha 0 >/dev/null
wait_for_session claude beta 0 >/dev/null
/bin/bash "$helper" stop codex alpha "$upgrade_codex_instance"
/bin/bash "$helper" stop claude beta "$upgrade_claude_instance"
wait_for_no_session codex
wait_for_no_session claude
TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=1 \
    /bin/bash "$helper" codex-account >/dev/null
[[ ! -e "$codex_restart_marker" ]] \
    || fail "runtime replacement restart marker remained after attached terminals drained"

helper="$current_runtime_helper"

echo "Provider profiles activate only on a same-provider second account and route concurrent launches"
provider_accounts_root="$test_home/.local/share/terminal-relay/provider-accounts-v1"
initial_accounts_output="$(/bin/bash "$helper" provider-accounts-v1)"
assert_contains "$initial_accounts_output" \
    "__TERMINAL_RELAY_PROVIDER_ACCOUNTS_V1__" \
    "provider account protocol marker"
read -r legacy_codex_account legacy_claude_account < <(
    printf '%s\n' "$initial_accounts_output" | "$python_path" -c '
import json
import sys
lines = sys.stdin.read().splitlines()
value = json.loads(lines[1])
by_provider = {row["provider"]: row for row in value["accounts"]}
assert set(by_provider) == {"codex", "claude"}
assert all(row["storageKind"] == "legacyDefault" for row in by_provider.values())
print(by_provider["codex"]["accountID"], by_provider["claude"]["accountID"])
'
)
[[ ! -e "$provider_accounts_root/activated" ]] \
    || fail "importing one legacy profile per provider activated account routing"
assert_equal "700" "$(path_mode "$provider_accounts_root")" \
    "provider account root mode"
assert_equal "600" \
    "$(path_mode "$provider_accounts_root/$legacy_codex_account/profile")" \
    "legacy Codex profile mode"

legacy_activation_start="$(/bin/bash "$helper" start \
    codex alpha --activation-guard)"
legacy_activation_instance="$(printf '%s\n' "$legacy_activation_start" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
wait_for_log_lines "$(( $(/usr/bin/awk 'END { print NR + 0 }' "$agent_log") ))"
set +e
blocked_account_output="$(/bin/bash "$helper" \
    provider-account-create-v1 codex "Blocked Codex" 2>&1)"
blocked_account_result=$?
set -e
assert_equal "75" "$blocked_account_result" \
    "second account while legacy task is live"
assert_contains "$blocked_account_output" "Stop every legacy codex task" \
    "legacy activation guard diagnostic"
[[ ! -e "$provider_accounts_root/activated" ]] \
    || fail "blocked account creation wrote the activation marker"
codex_profile_count="$(/usr/bin/grep -l '^provider|codex$' \
    "$provider_accounts_root"/*/profile | /usr/bin/wc -l \
    | /usr/bin/tr -d '[:space:]')"
assert_equal "1" "$codex_profile_count" \
    "blocked account creation left an isolated profile"
/bin/bash "$helper" stop codex alpha "$legacy_activation_instance"

isolated_codex_output="$(/bin/bash "$helper" \
    provider-account-create-v1 codex "Second Codex")"
isolated_codex_account="$(printf '%s\n' "$isolated_codex_output" \
    | "$python_path" -c '
import json
import sys
lines = sys.stdin.read().splitlines()
value = json.loads(lines[1])
assert len(value["accounts"]) == 1
row = value["accounts"][0]
assert row["provider"] == "codex"
assert row["status"] == "authRequired"
assert row["storageKind"] == "isolated"
print(row["accountID"])
')"
assert_equal "600" "$(path_mode "$provider_accounts_root/activated")" \
    "provider account activation marker mode"
assert_equal "version|1" "$(< "$provider_accounts_root/activated")" \
    "provider account activation marker"
assert_equal "700" \
    "$(path_mode "$provider_accounts_root/$isolated_codex_account/data")" \
    "isolated Codex data mode"
set +e
legacy_status_error="$(/bin/bash "$helper" status 2>&1)"
legacy_status_result=$?
set -e
assert_equal "76" "$legacy_status_result" \
    "legacy status after account activation"
assert_contains "$legacy_status_error" "choose an account" \
    "legacy status activation diagnostic"

/bin/bash "$helper" provider-account-rename-v1 \
    codex "$isolated_codex_account" "Work Codex" >/dev/null
for account_id in "$isolated_codex_account"; do
    profile="$provider_accounts_root/$account_id/profile"
    /usr/bin/sed 's/^status|authRequired$/status|active/' "$profile" \
        > "$profile.next"
    /bin/chmod 600 "$profile.next"
    /bin/mv -f "$profile.next" "$profile"
done

isolated_claude_output="$(/bin/bash "$helper" \
    provider-account-create-v1 claude "Second Claude")"
isolated_claude_account="$(printf '%s\n' "$isolated_claude_output" \
    | "$python_path" -c '
import json
import sys
lines = sys.stdin.read().splitlines()
value = json.loads(lines[1])
row = value["accounts"][0]
assert row["provider"] == "claude"
assert row["storageKind"] == "isolated"
print(row["accountID"])
')"
profile="$provider_accounts_root/$isolated_claude_account/profile"
claude_login_output="$(/bin/bash "$helper" provider-account-login-v1 \
    claude "$isolated_claude_account")"
assert_contains "$claude_login_output" "account|claude|$isolated_claude_account" \
    "Claude login account route"
assert_equal "auth login --claudeai" "$(< "$account_auth_log")" \
    "Claude personal account login mode"
set +e
claude_auth_required_status="$(TERMINAL_RELAY_TEST_ACCOUNT_AUTH_REQUIRED=1 \
    /bin/bash "$helper" provider-account-status-v1 \
        claude "$isolated_claude_account")"
claude_auth_required_result=$?
set -e
assert_equal "0" "$claude_auth_required_result" \
    "auth-required account status response"
printf '%s\n' "$claude_auth_required_status" | "$python_path" -c '
import json
import sys
lines = sys.stdin.read().splitlines()
assert len(lines) == 2
value = json.loads(lines[1])
assert value["accounts"][0]["status"] == "authRequired"
'
claude_profile_status="$(/bin/bash "$helper" provider-account-status-v1 \
    claude "$isolated_claude_account")"
assert_contains "$claude_profile_status" \
    "__TERMINAL_RELAY_PROVIDER_ACCOUNTS_V1__" \
    "provider account status marker"
printf '%s\n' "$claude_profile_status" | "$python_path" -c '
import json
import sys
lines = sys.stdin.read().splitlines()
assert len(lines) == 2
value = json.loads(lines[1])
assert len(value["accounts"]) == 1
assert value["accounts"][0]["status"] == "active"
'

export TERMINAL_RELAY_TEST_CODEX_PATH="$stub_codex"
export TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT=1
account_log_before="$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")"
legacy_account_start="$(/bin/bash "$helper" start-v2 \
    codex "$legacy_codex_account" alpha --account-one)"
isolated_account_start="$(/bin/bash "$helper" start-v2 \
    codex "$isolated_codex_account" beta --account-two)"
claude_account_start="$(/bin/bash "$helper" start-v2 \
    claude "$isolated_claude_account" beta --account-claude)"
legacy_account_instance="$(printf '%s\n' "$legacy_account_start" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $6; exit }')"
isolated_account_instance="$(printf '%s\n' "$isolated_account_start" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $6; exit }')"
claude_account_instance="$(printf '%s\n' "$claude_account_start" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $6; exit }')"
assert_contains "$legacy_account_start" "__TERMINAL_RELAY_SESSION_V2__" \
    "legacy profile account-aware start marker"
assert_contains "$isolated_account_start" "$isolated_codex_account" \
    "isolated Codex start account"
assert_contains "$claude_account_start" "$isolated_claude_account" \
    "isolated Claude start account"
wait_for_log_lines "$((account_log_before + 3))"
account_logs="$(/usr/bin/tail -n 3 "$agent_log")"
assert_contains "$account_logs" \
    "account=$isolated_codex_account" "isolated Codex process account"
assert_contains "$account_logs" \
    "CODEX_HOME=$provider_accounts_root/$isolated_codex_account/data" \
    "isolated Codex home"
assert_contains "$account_logs" \
    "account=$isolated_claude_account" "isolated Claude process account"
assert_contains "$account_logs" \
    "CLAUDE_CONFIG_DIR=$provider_accounts_root/$isolated_claude_account/data" \
    "isolated Claude config directory"
[[ -f "$provider_accounts_root/$isolated_claude_account/data/.claude.json" ]] \
    || fail "isolated Claude onboarding state was not account-scoped"

account_status_output="$(/bin/bash "$helper" status-v2)"
assert_contains "$account_status_output" "__TERMINAL_RELAY_SESSION_V2__" \
    "account-aware status marker"
assert_contains "$account_status_output" \
    "session|codex|$legacy_codex_account|alpha" \
    "legacy Codex profile in account-aware status"
assert_contains "$account_status_output" \
    "session|codex|$isolated_codex_account|beta" \
    "isolated Codex profile in account-aware status"
assert_contains "$account_status_output" \
    "session|claude|$isolated_claude_account|beta" \
    "isolated Claude profile in account-aware status"
[[ -S "$provider_socket_root/codex-$legacy_codex_account.sock" \
    && -S "$provider_socket_root/codex-$isolated_codex_account.sock" ]] \
    || fail "Codex profiles did not receive independent app-server sockets"
assert_contains "$(< "$runtime_root/$isolated_account_instance.intent")" \
    $'version|3\n' "account-aware terminal intent version"
assert_contains "$(< "$runtime_root/$isolated_account_instance.intent")" \
    "account|$isolated_codex_account" "account-aware terminal intent route"
assert_contains "$(< "$runtime_root/$claude_account_instance.session")" \
    "account|$isolated_claude_account" "account-aware terminal metadata route"

account_restore_log_before="$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")"
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free "$legacy_account_instance"
wait_for_agent_lock_free "$isolated_account_instance"
wait_for_agent_lock_free "$claude_account_instance"
printf '%s\n' '12121212-1212-4121-8121-121212121212' > "$boot_id_file"
/bin/bash "$helper" restore >/dev/null
expected_account_restore_logs=$((account_restore_log_before + 3))
wait_for_log_lines "$expected_account_restore_logs"
account_status_output="$(/bin/bash "$helper" status-v2)"
assert_contains "$account_status_output" \
    "session|codex|$legacy_codex_account|alpha|0|$legacy_account_instance" \
    "legacy Codex profile after account-aware restore"
assert_contains "$account_status_output" \
    "session|codex|$isolated_codex_account|beta|0|$isolated_account_instance" \
    "isolated Codex profile after account-aware restore"
assert_contains "$account_status_output" \
    "session|claude|$isolated_claude_account|beta|0|$claude_account_instance" \
    "isolated Claude profile after account-aware restore"

legacy_codex_profile="$provider_accounts_root/$legacy_codex_account/profile"
/usr/bin/sed 's/^status|active$/status|authRequired/' \
    "$legacy_codex_profile" > "$legacy_codex_profile.next"
/bin/chmod 600 "$legacy_codex_profile.next"
/bin/mv -f "$legacy_codex_profile.next" "$legacy_codex_profile"
isolated_status_output="$(/bin/bash "$helper" status-v2 \
    2> "$test_root/status-v2-isolation.err")"
assert_contains "$isolated_status_output" \
    "session|codex|$isolated_codex_account|beta" \
    "healthy Codex profile survives status isolation"
assert_contains "$isolated_status_output" \
    "session|claude|$isolated_claude_account|beta" \
    "healthy Claude profile survives status isolation"
[[ "$isolated_status_output" != *"session|codex|$legacy_codex_account|alpha"* ]] \
    || fail "auth-required terminal profile leaked into account-aware status"
assert_contains "$(< "$test_root/status-v2-isolation.err")" \
    "provider account '$legacy_codex_account' is unavailable" \
    "account-aware status isolation diagnostic"
/usr/bin/sed 's/^status|authRequired$/status|active/' \
    "$legacy_codex_profile" > "$legacy_codex_profile.next"
/bin/chmod 600 "$legacy_codex_profile.next"
/bin/mv -f "$legacy_codex_profile.next" "$legacy_codex_profile"

legacy_account_server_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "terminal-relay-account-$legacy_codex_account" '#{pane_pid}')"
isolated_account_server_pid="$("$tmux_path" -f /dev/null -L "$tmux_socket" \
    display-message -p -t "terminal-relay-account-$isolated_codex_account" '#{pane_pid}')"
/bin/bash "$helper" __schedule-all-codex-app-server-restarts
[[ -f "$codex_restart_marker" \
    && -f "$runtime_root/codex-$legacy_codex_account-app-server-restart-required" \
    && -f "$runtime_root/codex-$isolated_codex_account-app-server-restart-required" ]] \
    || fail "update scheduling omitted an account-scoped Codex restart marker"

/bin/bash "$helper" stop-v2 codex "$legacy_codex_account" \
    alpha "$legacy_account_instance"
/bin/bash "$helper" stop-v2 codex "$isolated_codex_account" \
    beta "$isolated_account_instance"
/bin/bash "$helper" stop-v2 claude "$isolated_claude_account" \
    beta "$claude_account_instance"
/bin/bash "$helper" codex-account-v2 "$legacy_codex_account" >/dev/null
/bin/bash "$helper" codex-account-v2 "$isolated_codex_account" >/dev/null
[[ ! -e "$runtime_root/codex-$legacy_codex_account-app-server-restart-required" \
    && ! -e "$runtime_root/codex-$isolated_codex_account-app-server-restart-required" ]] \
    || fail "account-scoped Codex restart markers remained after profile rotation"
[[ "$legacy_account_server_pid" != \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" display-message -p \
        -t "terminal-relay-account-$legacy_codex_account" '#{pane_pid}')" ]] \
    || fail "legacy Codex profile app-server did not rotate"
[[ "$isolated_account_server_pid" != \
    "$("$tmux_path" -f /dev/null -L "$tmux_socket" display-message -p \
        -t "terminal-relay-account-$isolated_codex_account" '#{pane_pid}')" ]] \
    || fail "isolated Codex profile app-server did not rotate"
unset TERMINAL_RELAY_TEST_CODEX_SHARED_ACCOUNT

echo "PASS: terminal-relay-session integration tests"
