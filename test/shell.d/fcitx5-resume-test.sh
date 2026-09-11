#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"
run_log="$test_tmp/systemd-run.log"

cat >"$mock_bin/systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$OMARCHY_TEST_LOG"
exit "${OMARCHY_TEST_RUN_RC:-0}"
SH
chmod +x "$mock_bin/systemd-run"

hook="$ROOT/default/systemd/system-sleep/fcitx5-resume"

PATH="$mock_bin:$PATH" OMARCHY_TEST_LOG="$run_log" bash "$hook" pre suspend
[[ ! -e $run_log ]] || fail "fcitx5 is left alone on the way into sleep"
pass "fcitx5 is left alone on the way into sleep"

PATH="$mock_bin:$PATH" OMARCHY_TEST_LOG="$run_log" bash "$hook" post suspend
grep -Fxq -- '--collect' "$run_log" || fail "fcitx5 restart transient unit is collected"
grep -Fxq -- '--on-active=1s' "$run_log" &&
  grep -Fxq -- '--timer-property=AccuracySec=100ms' "$run_log" ||
  fail "fcitx5 restarts within a second of resume, not whenever the timer coalesces"
grep -Fxq -- "$hook" "$run_log" || fail "fcitx5 restart schedules the installed sleep hook"
grep -Fxq -- 'restore' "$run_log" || fail "fcitx5 restart schedules the restore action"
pass "fcitx5 restart escapes the system-sleep cgroup through systemd-run"

if ! PATH="$mock_bin:$PATH" OMARCHY_TEST_LOG="$run_log" OMARCHY_TEST_RUN_RC=1 bash "$hook" post suspend; then
  fail "fcitx5 restart scheduling failure does not fail system sleep"
fi
pass "fcitx5 restart scheduling failure does not fail system sleep"

# restore runs as root in its own unit. Point it at a fake runtime directory
# and a sudo that records what it was asked to run.
runtime="$test_tmp/run/user"
mkdir -p "$runtime/1000" "$runtime/1001"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$runtime/1000/bus"
sed "s|/run/user/\*|$runtime/*|" "$hook" >"$test_tmp/fcitx5-resume"

cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_LOG"
SH
chmod +x "$mock_bin/sudo"

sudo_log="$test_tmp/sudo.log"
PATH="$mock_bin:$PATH" OMARCHY_TEST_LOG="$sudo_log" bash "$test_tmp/fcitx5-resume" restore
expected="-u #1000 env DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/1000/bus XDG_RUNTIME_DIR=$runtime/1000 systemctl --user try-restart omarchy-fcitx5.service"
[[ -f $sudo_log && $(<"$sudo_log") == "$expected" ]] ||
  fail "restore restarts fcitx5 as each user with a session bus, and only them" "$(cat "$sudo_log" 2>/dev/null)"
pass "restore restarts fcitx5 as each user with a session bus, and only them"
