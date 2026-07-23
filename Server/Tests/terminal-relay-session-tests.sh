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
test_home="$test_root/home"
agent_log="$test_root/agent.log"
signal_log="$test_root/signal.log"
boot_id_file="$test_root/boot-id"
stub_agent="$test_root/stub-agent"
flock_adapter="$test_root/flock"
signal_adapter="$test_root/signal"
tmux_socket="terminal-relay-test-$(/usr/bin/id -u)-$$-$RANDOM"
harness_socket="$tmux_socket-harness"

cleanup() {
    local cleanup_exit_code=$?
    local pid
    local command
    trap - EXIT INT TERM

    "$tmux_path" -f /dev/null -L "$harness_socket" kill-server 2>/dev/null || true
    "$tmux_path" -f /dev/null -L "$tmux_socket" kill-server 2>/dev/null || true

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
    local output
    output="$(session_status)" || return $?
    printf '%s\n' "$output" | /usr/bin/awk -F'|' -v tool="$tool" \
        '$1 == "session" && $2 == tool { print; exit }'
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
    local extra

    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        line="$(session_line "$tool" 2>/dev/null || true)"
        IFS='|' read -r record_type actual_tool actual_repository actual_clients instance extra <<< "$line"
        if [[ "$record_type" == "session" \
            && "$actual_tool" == "$tool" \
            && "$actual_repository" == "$repository" \
            && "$actual_clients" == "$clients" \
            && "$instance" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ \
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
    local tool="$1"
    exec 5>"$runtime_root/$tool.lock"
    if ! "$flock_adapter" --nonblock 5; then
        exec 5>&-
        fail "$tool agent lock remained held"
    fi
    exec 5>&-
}

wait_for_agent_lock_free() {
    local tool="$1"
    local attempt=0
    while [[ $attempt -lt 160 ]]; do
        attempt=$((attempt + 1))
        exec 5>"$runtime_root/$tool.lock"
        if "$flock_adapter" --nonblock 5; then
            exec 5>&-
            return 0
        fi
        exec 5>&-
        sleep 0.05
    done
    fail "$tool agent lock remained held"
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

started="$(LC_ALL=C /bin/ps -o lstart= -p "$pid" 2>/dev/null)" || exit 75
started="${started#"${started%%[![:space:]]*}"}"
[[ -n "$started" ]] || exit 75
started="${started// /_}"
started="${started//$'\t'/_}"
[[ "ps_$started" == "$expected_start" ]] || exit 75
command="$(/bin/ps -o command= -p "$pid" 2>/dev/null)" || exit 75
[[ "$command" == *"$TERMINAL_RELAY_TEST_SIGNAL_TARGET_PATH"* ]] || exit 75
printf 'signal|pid=%s|name=%s\n' "$pid" "$signal_name" \
    >> "$TERMINAL_RELAY_TEST_SIGNAL_LOG"
exec /bin/kill "-$signal_name" "$pid"
SIGNAL_ADAPTER

cat > "$stub_agent" <<'STUB_AGENT'
#!/bin/bash
set -euo pipefail

printf 'start|pid=%s|cwd=%s' "$$" "$PWD" >> "$TERMINAL_RELAY_TEST_AGENT_LOG"
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

/bin/chmod 700 "$flock_adapter" "$signal_adapter" "$stub_agent"

echo "1/17 test overrides require explicit non-installed test mode; projects are sorted"
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
export TERMINAL_RELAY_TEST_CODEX_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_CLAUDE_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_FLOCK_PATH="$flock_adapter"
export TERMINAL_RELAY_TEST_AGENT_LOG="$agent_log"
export TERMINAL_RELAY_TEST_SIGNAL_PATH="$signal_adapter"
export TERMINAL_RELAY_TEST_SIGNAL_LOG="$signal_log"
export TERMINAL_RELAY_TEST_SIGNAL_TARGET_PATH="$stub_agent"
export TERMINAL_RELAY_TEST_BOOT_ID_PATH="$boot_id_file"
export HOME="$test_home"

list_output="$(/bin/bash "$helper" list-projects)"
assert_equal \
    $'__TERMINAL_RELAY_SESSION_V1__\nproject|.hidden\nproject|alpha\nproject|beta\nproject|zeta' \
    "$list_output" \
    "list-projects response"
assert_equal "700" "$(path_mode "$runtime_root")" "persistent state-root mode"

echo "2/17 concurrent first clients create exactly one launch and share one token"
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
first_instance="${start_one_line##*|}"
assert_equal "$first_instance" "${start_two_line##*|}" "concurrent start instance"
first_status="$(wait_for_session codex alpha 0)"
first_instance="${first_status##*|}"
assert_equal "600" "$(path_mode "$runtime_root/codex.intent")" "Codex restart-intent mode"
wait_for_log_lines 1
first_log="$(/usr/bin/sed -n '1p' "$agent_log")"
if [[ "$first_log" != *"--candidate-one"* && "$first_log" != *"--candidate-two"* ]]; then
    fail "concurrent winner did not preserve either first-launch argument"
fi
assert_contains "$first_log" "mcp_servers.test_server={enabled=false}" "Codex MCP disable argument"
sleep 0.2
assert_equal "1" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "concurrent launch count"

start_client client-one "$workspace_root/alpha" reattach codex alpha "$first_instance"
start_client client-two "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_session codex alpha 2 >/dev/null

assert_equal "off" "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv status)" "tmux status bar"
assert_equal "on" "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv set-titles)" "tmux title setting"
assert_equal '#{pane_title}' "$("$tmux_path" -f /dev/null -L "$tmux_socket" show-options -gv set-titles-string)" "tmux title format"

echo "3/17 configure failure on a later attach leaves the shared session untouched"
TERMINAL_RELAY_TEST_CLIENT_CONFIGURE_FAIL=1 \
    start_client configure-failure "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_harness_exit configure-failure
after_failure="$(wait_for_session codex alpha 2)"
assert_equal "$first_instance" "${after_failure##*|}" "instance after configure failure"
assert_equal "1" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "launch count after configure failure"
start_client reattach-client "$workspace_root/alpha" reattach codex alpha "$first_instance"
wait_for_session codex alpha 3 >/dev/null
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t reattach-client
wait_for_session codex alpha 2 >/dev/null

echo "4/17 a different repository receives occupied exit 75"
set +e
conflict_output="$(/bin/bash "$helper" start codex beta 2>&1)"
conflict_status=$?
set -e
assert_equal "75" "$conflict_status" "wrong-project exit status"
assert_contains "$conflict_output" "already running for repository 'alpha'" "wrong-project error"

echo "5/17 both client connections can disappear while the launch survives"
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-one
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-two 2>/dev/null || true
detached_status="$(wait_for_session codex alpha 0)"
assert_equal "$first_instance" "${detached_status##*|}" "instance after detach"

echo "6/17 an arbitrary stale token cannot stop the active launch"
stale_instance="00000000-0000-0000-0000-000000000000"
[[ "$stale_instance" != "$first_instance" ]] \
    || stale_instance="11111111-1111-1111-1111-111111111111"
stale_output="$(run_stop_expect_75 codex alpha "$stale_instance")"
assert_contains "$stale_output" "Refusing stale stop" "stale stop diagnostic"
stale_reattach_output="$(run_reattach_expect_75 codex alpha "$stale_instance")"
assert_contains "$stale_reattach_output" "Refusing stale reattach" "stale reattach diagnostic"
still_running="$(wait_for_session codex alpha 0)"
assert_equal "$first_instance" "${still_running##*|}" "instance after stale stop"

echo "7/17 exact stop ends the first launch and a same-repository replacement gets a new token"
/bin/bash "$helper" stop codex alpha "$first_instance"
wait_for_no_session codex
assert_agent_lock_free codex
ended_reattach_output="$(run_reattach_expect_75 codex alpha "$first_instance")"
assert_contains "$ended_reattach_output" "has ended" "ended launch reattach diagnostic"
second_start_output="$(/bin/bash "$helper" start codex alpha --stubborn)"
second_status="$(printf '%s\n' "$second_start_output" | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')"
second_instance="${second_status##*|}"
[[ "$second_instance" != "$first_instance" ]] || fail "replacement reused the old instance token"
wait_for_log_lines 2
wait_for_session codex alpha 0 >/dev/null

echo "8/17 the old same-repository token cannot stop its replacement"
old_token_output="$(run_stop_expect_75 codex alpha "$first_instance")"
assert_contains "$old_token_output" "active launch is 'alpha' instance '$second_instance'" "same-repository stale stop"
old_reattach_output="$(run_reattach_expect_75 codex alpha "$first_instance")"
assert_contains "$old_reattach_output" "active launch is 'alpha' instance '$second_instance'" "same-repository stale reattach"
replacement_status="$(wait_for_session codex alpha 0)"
assert_equal "$second_instance" "${replacement_status##*|}" "replacement after stale stop"

echo "9/17 paused stale reattach fails closed across stubborn stop and replacement"
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
assert_agent_lock_free codex
signal_output="$(/bin/cat "$signal_log")"
assert_contains "$signal_output" "name=TERM" "stubborn launch TERM through test signal adapter"
assert_contains "$signal_output" "name=KILL" "stubborn launch KILL through test signal adapter"
third_start_output="$(/bin/bash "$helper" start codex alpha --after-stubborn)"
third_status="$(printf '%s\n' "$third_start_output" | /usr/bin/awk -F'|' '$1 == "session" { print; exit }')"
third_instance="${third_status##*|}"
wait_for_log_lines 3
[[ "$third_instance" != "$second_instance" ]] || fail "post-stubborn launch reused its instance token"
/bin/rm -f -- "$pause_file"
wait_for_harness_exit paused-reattach
post_pause_status="$(wait_for_session codex alpha 0)"
assert_equal "$third_instance" "${post_pause_status##*|}" "replacement after paused stale reattach"
paused_old_stop="$(run_stop_expect_75 codex alpha "$second_instance")"
assert_contains "$paused_old_stop" "active launch is 'alpha' instance '$third_instance'" "post-pause stale stop"

start_client client-three "$workspace_root/alpha" reattach codex alpha "$third_instance"
wait_for_session codex alpha 1 >/dev/null
"$tmux_path" -f /dev/null -L "$harness_socket" kill-session -t client-three 2>/dev/null || true
wait_for_session codex alpha 0 >/dev/null

echo "10/17 legacy Claude launch infers its repository, preserves environment, and exits cleanly"
export ConEmuANSI=1
start_client clean-client "$workspace_root/beta" claude --exit-cleanly
wait_for_log_lines 4
wait_for_no_session claude
clean_log="$(/usr/bin/sed -n '4p' "$agent_log")"
assert_contains "$clean_log" "cwd=$workspace_root/beta" "legacy inferred repository"
assert_contains "$clean_log" "ConEmuANSI=1" "Claude terminal environment"
[[ ! -e "$runtime_root/claude.intent" ]] || fail "clean Claude exit retained restart intent"

echo "11/17 final exact stop removes metadata only after process and lock release"
/bin/bash "$helper" stop codex alpha "$third_instance"
wait_for_no_session codex
assert_agent_lock_free codex
assert_equal "__TERMINAL_RELAY_SESSION_V1__" "$(session_status)" "final empty status"
[[ ! -e "$runtime_root/codex.intent" ]] || fail "exact Codex stop retained restart intent"
repeat_output="$(run_stop_expect_75 codex alpha "$third_instance")"
assert_contains "$repeat_output" "stop request is stale" "repeated stop diagnostic"

echo "12/17 caller-supplied provider lifecycle flags are rejected"
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

echo "13/17 Codex survives a simulated reboot with one idempotent resume launch"
unset ConEmuANSI
codex_reboot_output="$(/bin/bash "$helper" start codex alpha --reboot-codex)"
codex_reboot_instance="$(printf '%s\n' "$codex_reboot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
wait_for_log_lines 5
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free codex
printf '%s\n' '22222222-2222-4222-8222-222222222222' > "$boot_id_file"
/bin/bash "$helper" restore > "$test_root/restore-one.out" 2>&1 &
restore_one_pid=$!
/bin/bash "$helper" restore > "$test_root/restore-two.out" 2>&1 &
restore_two_pid=$!
wait "$restore_one_pid"
wait "$restore_two_pid"
restored_codex_status="$(wait_for_session codex alpha 0)"
assert_equal "$codex_reboot_instance" "${restored_codex_status##*|}" "restored Codex instance"
wait_for_log_lines 6
codex_resume_log="$(/usr/bin/sed -n '6p' "$agent_log")"
assert_contains "$codex_resume_log" "|resume|--last|--reboot-codex" "Codex resume arguments"
assert_equal "6" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "idempotent restore count"

echo "14/17 explicit stop prevents a later Codex reboot restore"
/bin/bash "$helper" stop codex alpha "$codex_reboot_instance"
wait_for_no_session codex
printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "6" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "stopped Codex restore count"

echo "15/17 Claude resumes the UUID-bound provider conversation after reboot"
claude_reboot_output="$(/bin/bash "$helper" start claude beta --reboot-claude)"
claude_reboot_instance="$(printf '%s\n' "$claude_reboot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
wait_for_log_lines 7
claude_initial_log="$(/usr/bin/sed -n '7p' "$agent_log")"
assert_contains "$claude_initial_log" \
    "|--session-id|$claude_reboot_instance|--reboot-claude" "Claude initial session id"
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free claude
printf '%s\n' '44444444-4444-4444-8444-444444444444' > "$boot_id_file"
/bin/bash "$helper" restore
restored_claude_status="$(wait_for_session claude beta 0)"
assert_equal "$claude_reboot_instance" "${restored_claude_status##*|}" "restored Claude instance"
wait_for_log_lines 8
claude_resume_log="$(/usr/bin/sed -n '8p' "$agent_log")"
assert_contains "$claude_resume_log" \
    "|--resume|$claude_reboot_instance|--reboot-claude" "Claude resume arguments"
/bin/bash "$helper" stop claude beta "$claude_reboot_instance"
wait_for_no_session claude
printf '%s\n' '55555555-5555-4555-8555-555555555555' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "8" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "stopped Claude restore count"

echo "16/17 a same-boot death is not resurrected now or on a later reboot"
same_boot_output="$(/bin/bash "$helper" start codex zeta --same-boot-death)"
same_boot_instance="$(printf '%s\n' "$same_boot_output" \
    | /usr/bin/awk -F'|' '$1 == "session" { print $5; exit }')"
[[ -n "$same_boot_instance" ]] || fail "same-boot launch did not return an instance"
wait_for_log_lines 9
"$tmux_path" -f /dev/null -L "$tmux_socket" kill-server
wait_for_agent_lock_free codex
/bin/bash "$helper" restore
assert_equal "9" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "same-boot restore count"
assert_equal "__TERMINAL_RELAY_SESSION_V1__" "$(session_status)" "same-boot dead status"
printf '%s\n' '66666666-6666-4666-8666-666666666666' > "$boot_id_file"
/bin/bash "$helper" restore
assert_equal "9" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "later restore after same-boot cleanup"

echo "17/17 corrupt persistent state fails closed without launching an agent"
printf '%s\n' 'version|1' 'tool|codex' 'repository|alpha' > "$runtime_root/codex.intent"
/bin/chmod 600 "$runtime_root/codex.intent"
printf '%s\n' '77777777-7777-4777-8777-777777777777' > "$boot_id_file"
set +e
corrupt_output="$(/bin/bash "$helper" restore 2>&1)"
corrupt_status=$?
set -e
assert_equal "70" "$corrupt_status" "corrupt restore status"
assert_contains "$corrupt_output" "restart intent is invalid" "corrupt restore diagnostic"
assert_equal "9" "$(/usr/bin/awk 'END { print NR + 0 }' "$agent_log")" "corrupt restore launch count"
/bin/rm -f -- "$runtime_root/codex.intent"

echo "PASS: terminal-relay-session integration tests"
