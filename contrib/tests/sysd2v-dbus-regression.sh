#!/bin/sh
set -u

repo_dir=$(
  CDPATH= cd -- "$(dirname "$0")/../.." && pwd
)
sysd2v=$repo_dir/contrib/sysd2v.sh

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

pass=0
fail=0

pass_case() {
  echo "PASS - $1"
  pass=$((pass + 1))
}

fail_case() {
  echo "FAIL - $1"
  fail=$((fail + 1))
}

check_equal() {
  name=$1
  got=$2
  want=$3
  if [ "$got" = "$want" ]
  then
    pass_case "$name"
  else
    fail_case "$name (got '$got', want '$want')"
  fi
}

check_contains() {
  name=$1
  needle=$2
  haystack_file=$3
  if grep -Fq "$needle" "$haystack_file"
  then
    pass_case "$name"
  else
    fail_case "$name (missing '$needle')"
  fi
}

check_exists() {
  name=$1
  path=$2
  if [ -e "$path" ]
  then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

check_missing() {
  name=$1
  path=$2
  if [ ! -e "$path" ]
  then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

check_order() {
  name=$1
  first=$2
  second=$3
  haystack_file=$4
  first_line=$(grep -Fn "$first" "$haystack_file" | head -n 1 | cut -d: -f1)
  second_line=$(grep -Fn "$second" "$haystack_file" | head -n 1 | cut -d: -f1)
  if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]
  then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

service=$tmpdir/dbus.service
generated=$tmpdir/generated.init

cat > "$service" <<'EOF'
[Unit]
Description=DBus test service

[Service]
Type=dbus
BusName=org.example.Demo
ExecStart=/bin/true
TimeoutStartSec=4s

[Install]
WantedBy=multi-user.target
EOF

"$sysd2v" "$service" > "$generated"

# shellcheck disable=SC1090
INIT_D_SCRIPT_SOURCED=true
. "$generated"

# 1) Missing dbus-send should not fail startup.
emptydir=$tmpdir/empty
mkdir -p "$emptydir"
do_start_cmd() { return 0; }
out1=$tmpdir/out1
PATH=$emptydir do_start_cmd_override > "$out1" 2>&1
rc=$?
check_equal "missing dbus-send returns success" "$rc" "0"
check_contains "missing dbus-send prints warning" \
  "dbus-send not found" "$out1"
unset -f do_start_cmd

# 2) Deterministic polling stubs.
stubdir=$tmpdir/stubs
counter=$tmpdir/counter
mkdir -p "$stubdir"
cat > "$stubdir/dbus-send" <<'EOF'
#!/bin/sh
counter=${DBUS_COUNTER:?}
mode=${DBUS_MODE:-eventual}
n=0
[ -f "$counter" ] && n=$(cat "$counter")
n=$((n + 1))
echo "$n" > "$counter"
if [ "$mode" = eventual ] && [ "$n" -ge 3 ]
then
  echo "boolean true"
else
  echo "boolean false"
fi
EOF
cat > "$stubdir/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stubdir/dbus-send" "$stubdir/sleep"

# 3) Bus appears after 3 polls.
rm -f "$counter"
do_start_cmd() { return 0; }
out2=$tmpdir/out2
PATH=$stubdir:/bin DBUS_COUNTER=$counter DBUS_MODE=eventual \
  do_start_cmd_override > "$out2" 2>&1
rc=$?
calls=$(cat "$counter")
check_equal "eventual bus ownership succeeds" "$rc" "0"
check_equal "eventual bus ownership polls expected count" "$calls" "3"
unset -f do_start_cmd

# 4) Bus never appears -> timeout failure.
rm -f "$counter"
do_start_cmd() { return 0; }
out3=$tmpdir/out3
PATH=$stubdir:/bin DBUS_COUNTER=$counter DBUS_MODE=never \
  do_start_cmd_override > "$out3" 2>&1
rc=$?
calls=$(cat "$counter")
check_equal "dbus timeout fails with status 2" "$rc" "2"
check_equal "dbus timeout uses full configured attempts" "$calls" "4"
unset -f do_start_cmd

# 5) Start command failure should short-circuit.
rm -f "$counter"
do_start_cmd() { return 7; }
out4=$tmpdir/out4
PATH=$stubdir:/bin DBUS_COUNTER=$counter DBUS_MODE=eventual \
  do_start_cmd_override > "$out4" 2>&1
rc=$?
check_equal "start command failure propagates" "$rc" "7"
if [ ! -e "$counter" ]
then
  pass_case "start command failure skips dbus polls"
else
  fail_case "start command failure skips dbus polls"
fi
unset -f do_start_cmd

# 6) Unsupported timeout should warn and fall back to 60.
bad_service=$tmpdir/dbus-bad-timeout.service
bad_out=$tmpdir/dbus-bad-timeout.init
bad_err=$tmpdir/dbus-bad-timeout.err
cat > "$bad_service" <<'EOF'
[Unit]
Description=DBus bad timeout

[Service]
Type=dbus
BusName=org.example.Bad
ExecStart=/bin/true
TimeoutStartSec=2min

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$bad_service" > "$bad_out" 2> "$bad_err"
check_contains "unsupported timeout warns at conversion" \
  "unsupported timeout '2min'" "$bad_err"
check_contains "unsupported timeout falls back to 60" \
  "__dbus_wait_i -lt 60" "$bad_out"

# 7) Start pre-check should skip start-pre work if already running.
pre_service=$tmpdir/precheck.service
pre_out=$tmpdir/precheck.init
pre_marker=$tmpdir/pre-marker
started_marker=$tmpdir/started-marker
cat > "$pre_service" <<EOF
[Unit]
Description=Start pre-check

[Service]
Type=simple
ExecStart=/bin/true
ExecStartPre=/usr/bin/touch $pre_marker

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$pre_service" > "$pre_out"
check_contains "start pre-check command is generated" \
  "do_status >/dev/null 2>&1 && return 1" "$pre_out"

INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$pre_out"
do_status() { return 0; }
do_start_cmd() { touch "$started_marker"; return 0; }
out5=$tmpdir/out5
do_start_cmd_override > "$out5" 2>&1
rc=$?
check_equal "start pre-check returns already-running status" "$rc" "1"
if [ ! -e "$pre_marker" ] && [ ! -e "$started_marker" ]
then
  pass_case "start pre-check skips start-pre and start command"
else
  fail_case "start pre-check skips start-pre and start command"
fi
unset -f do_start_cmd do_status

# 8) ExecCondition generation should be present and warn on unsupported statuses.
condition_service=$tmpdir/condition.service
condition_out=$tmpdir/condition.init
condition_err=$tmpdir/condition.err
cat > "$condition_service" <<EOF
[Unit]
Description=ExecCondition generation

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 1'
ExecStartPre=/usr/bin/touch $tmpdir/condition-pre-generated
ExecStart=/bin/true
SuccessExitStatus=75 TEMPFAIL

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_service" > "$condition_out" 2> "$condition_err"
check_contains "ExecCondition handling is generated"   "__exec_condition_rc=\$?" "$condition_out"
check_order "ExecCondition is generated before ExecStartPre"   "__exec_condition_rc=\$?"   "/usr/bin/touch $tmpdir/condition-pre-generated" "$condition_out"
check_contains "unsupported SuccessExitStatus warns at conversion"   "unsupported SuccessExitStatus 'TEMPFAIL'" "$condition_err"

# 9) Exit 0 should continue startup.
condition_ok_service=$tmpdir/condition-ok.service
condition_ok_out=$tmpdir/condition-ok.init
condition_ok_marker=$tmpdir/condition-ok-marker
condition_ok_pre=$tmpdir/condition-ok-pre
condition_ok_post=$tmpdir/condition-ok-post
condition_ok_start=$tmpdir/condition-ok-start
cat > "$condition_ok_service" <<EOF
[Unit]
Description=ExecCondition success

[Service]
Type=simple
ExecCondition=/usr/bin/touch $condition_ok_marker
ExecStartPre=/usr/bin/touch $condition_ok_pre
ExecStart=/bin/true
ExecStartPost=/usr/bin/touch $condition_ok_post

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_ok_service" > "$condition_ok_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_ok_out"
do_start_cmd() { touch "$condition_ok_start"; return 0; }
out6=$tmpdir/out6
do_start_cmd_override > "$out6" 2>&1
rc=$?
check_equal "ExecCondition exit 0 returns success" "$rc" "0"
check_exists "ExecCondition exit 0 runs condition command" "$condition_ok_marker"
check_exists "ExecCondition exit 0 runs start-pre" "$condition_ok_pre"
check_exists "ExecCondition exit 0 runs start command" "$condition_ok_start"
check_exists "ExecCondition exit 0 runs start-post" "$condition_ok_post"
unset -f do_start_cmd

# 10) Exit 1 should skip startup but not fail.
condition_skip_service=$tmpdir/condition-skip.service
condition_skip_out=$tmpdir/condition-skip.init
condition_skip_pre=$tmpdir/condition-skip-pre
condition_skip_post=$tmpdir/condition-skip-post
condition_skip_start=$tmpdir/condition-skip-start
cat > "$condition_skip_service" <<EOF
[Unit]
Description=ExecCondition skip

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 1'
ExecStartPre=/usr/bin/touch $condition_skip_pre
ExecStart=/bin/true
ExecStartPost=/usr/bin/touch $condition_skip_post

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_skip_service" > "$condition_skip_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_skip_out"
do_start_cmd() { touch "$condition_skip_start"; return 0; }
out7=$tmpdir/out7
do_start_cmd_override > "$out7" 2>&1
rc=$?
check_equal "ExecCondition exit 1 returns success" "$rc" "0"
check_missing "ExecCondition exit 1 skips start-pre" "$condition_skip_pre"
check_missing "ExecCondition exit 1 skips start command" "$condition_skip_start"
check_missing "ExecCondition exit 1 skips start-post" "$condition_skip_post"
unset -f do_start_cmd

# 11) Numeric SuccessExitStatus should allow a non-zero condition to continue.
condition_success_service=$tmpdir/condition-success-exit.service
condition_success_out=$tmpdir/condition-success-exit.init
condition_success_pre=$tmpdir/condition-success-pre
condition_success_post=$tmpdir/condition-success-post
condition_success_start=$tmpdir/condition-success-start
cat > "$condition_success_service" <<EOF
[Unit]
Description=ExecCondition SuccessExitStatus

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 75'
ExecStartPre=/usr/bin/touch $condition_success_pre
ExecStart=/bin/true
ExecStartPost=/usr/bin/touch $condition_success_post
SuccessExitStatus=75

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_success_service" > "$condition_success_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_success_out"
do_start_cmd() { touch "$condition_success_start"; return 0; }
out8=$tmpdir/out8
do_start_cmd_override > "$out8" 2>&1
rc=$?
check_equal "SuccessExitStatus allows non-zero condition" "$rc" "0"
check_exists "SuccessExitStatus runs start-pre" "$condition_success_pre"
check_exists "SuccessExitStatus runs start command" "$condition_success_start"
check_exists "SuccessExitStatus runs start-post" "$condition_success_post"
unset -f do_start_cmd

# 12) Exit 126 should be a hard failure.
condition_126_cmd=$tmpdir/condition-126.sh
condition_126_service=$tmpdir/condition-126.service
condition_126_out=$tmpdir/condition-126.init
condition_126_pre=$tmpdir/condition-126-pre
condition_126_start=$tmpdir/condition-126-start
cat > "$condition_126_cmd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 644 "$condition_126_cmd"
cat > "$condition_126_service" <<EOF
[Unit]
Description=ExecCondition 126

[Service]
Type=simple
ExecCondition=$condition_126_cmd
ExecStartPre=/usr/bin/touch $condition_126_pre
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_126_service" > "$condition_126_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_126_out"
do_start_cmd() { touch "$condition_126_start"; return 0; }
out9=$tmpdir/out9
do_start_cmd_override > "$out9" 2>&1
rc=$?
check_equal "ExecCondition 126 returns hard failure" "$rc" "2"
check_missing "ExecCondition 126 skips start-pre" "$condition_126_pre"
check_missing "ExecCondition 126 skips start command" "$condition_126_start"
unset -f do_start_cmd

# 13) Exit 127 should be a hard failure and stop later conditions.
condition_127_service=$tmpdir/condition-127.service
condition_127_out=$tmpdir/condition-127.init
condition_127_late=$tmpdir/condition-127-late
condition_127_pre=$tmpdir/condition-127-pre
condition_127_start=$tmpdir/condition-127-start
cat > "$condition_127_service" <<EOF
[Unit]
Description=ExecCondition 127

[Service]
Type=simple
ExecCondition=/does/not/exist
ExecCondition=/usr/bin/touch $condition_127_late
ExecStartPre=/usr/bin/touch $condition_127_pre
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_127_service" > "$condition_127_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_127_out"
do_start_cmd() { touch "$condition_127_start"; return 0; }
out10=$tmpdir/out10
do_start_cmd_override > "$out10" 2>&1
rc=$?
check_equal "ExecCondition 127 returns hard failure" "$rc" "2"
check_missing "ExecCondition 127 skips later conditions" "$condition_127_late"
check_missing "ExecCondition 127 skips start-pre" "$condition_127_pre"
check_missing "ExecCondition 127 skips start command" "$condition_127_start"
unset -f do_start_cmd

# 14) SuccessExitStatus=126 should continue startup.
condition_126_success_service=$tmpdir/condition-126-success.service
condition_126_success_out=$tmpdir/condition-126-success.init
condition_126_success_pre=$tmpdir/condition-126-success-pre
condition_126_success_start=$tmpdir/condition-126-success-start
cat > "$condition_126_success_service" <<EOF
[Unit]
Description=ExecCondition 126 success

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 126'
ExecStartPre=/usr/bin/touch $condition_126_success_pre
ExecStart=/bin/true
SuccessExitStatus=126

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_126_success_service" > "$condition_126_success_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_126_success_out"
do_start_cmd() { touch "$condition_126_success_start"; return 0; }
out13=$tmpdir/out13
do_start_cmd_override > "$out13" 2>&1
rc=$?
check_equal "SuccessExitStatus 126 allows non-zero condition" "$rc" "0"
check_exists "SuccessExitStatus 126 runs start-pre" "$condition_126_success_pre"
check_exists "SuccessExitStatus 126 runs start command" "$condition_126_success_start"
unset -f do_start_cmd

# 15) SuccessExitStatus=127 should continue startup.
condition_127_success_service=$tmpdir/condition-127-success.service
condition_127_success_out=$tmpdir/condition-127-success.init
condition_127_success_pre=$tmpdir/condition-127-success-pre
condition_127_success_start=$tmpdir/condition-127-success-start
cat > "$condition_127_success_service" <<EOF
[Unit]
Description=ExecCondition 127 success

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 127'
ExecStartPre=/usr/bin/touch $condition_127_success_pre
ExecStart=/bin/true
SuccessExitStatus=127

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_127_success_service" > "$condition_127_success_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_127_success_out"
do_start_cmd() { touch "$condition_127_success_start"; return 0; }
out14=$tmpdir/out14
do_start_cmd_override > "$out14" 2>&1
rc=$?
check_equal "SuccessExitStatus 127 allows non-zero condition" "$rc" "0"
check_exists "SuccessExitStatus 127 runs start-pre" "$condition_127_success_pre"
check_exists "SuccessExitStatus 127 runs start command" "$condition_127_success_start"
unset -f do_start_cmd

# 16) Empty SuccessExitStatus assignment should reset prior values.
condition_reset_service=$tmpdir/condition-reset.service
condition_reset_out=$tmpdir/condition-reset.init
condition_reset_pre=$tmpdir/condition-reset-pre
condition_reset_start=$tmpdir/condition-reset-start
cat > "$condition_reset_service" <<EOF
[Unit]
Description=ExecCondition SuccessExitStatus reset

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 75'
ExecStartPre=/usr/bin/touch $condition_reset_pre
ExecStart=/bin/true
SuccessExitStatus=75
SuccessExitStatus=
SuccessExitStatus=76

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_reset_service" > "$condition_reset_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_reset_out"
do_start_cmd() { touch "$condition_reset_start"; return 0; }
out17=$tmpdir/out17
do_start_cmd_override > "$out17" 2>&1
rc=$?
check_equal "Empty SuccessExitStatus resets prior values" "$rc" "0"
check_missing "Empty SuccessExitStatus reset skips start-pre" "$condition_reset_pre"
check_missing "Empty SuccessExitStatus reset skips start command" "$condition_reset_start"
unset -f do_start_cmd

# 17) Dash-prefixed ExecCondition should ignore failures and continue.
condition_dash_service=$tmpdir/condition-dash.service
condition_dash_out=$tmpdir/condition-dash.init
condition_dash_pre=$tmpdir/condition-dash-pre
condition_dash_start=$tmpdir/condition-dash-start
cat > "$condition_dash_service" <<EOF
[Unit]
Description=ExecCondition dash prefix

[Service]
Type=simple
ExecCondition=-/bin/sh -c 'exit 127'
ExecStartPre=/usr/bin/touch $condition_dash_pre
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_dash_service" > "$condition_dash_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_dash_out"
do_start_cmd() { touch "$condition_dash_start"; return 0; }
out18=$tmpdir/out18
do_start_cmd_override > "$out18" 2>&1
rc=$?
check_equal "Dash-prefixed ExecCondition ignores failure" "$rc" "0"
check_exists "Dash-prefixed ExecCondition runs start-pre" "$condition_dash_pre"
check_exists "Dash-prefixed ExecCondition runs start command" "$condition_dash_start"
unset -f do_start_cmd

# 18) Later conditions should not run after a skip.
condition_multi_service=$tmpdir/condition-multi.service
condition_multi_out=$tmpdir/condition-multi.init
condition_multi_late=$tmpdir/condition-multi-late
condition_multi_pre=$tmpdir/condition-multi-pre
condition_multi_start=$tmpdir/condition-multi-start
cat > "$condition_multi_service" <<EOF
[Unit]
Description=ExecCondition multi

[Service]
Type=simple
ExecCondition=/bin/sh -c 'exit 1'
ExecCondition=/usr/bin/touch $condition_multi_late
ExecStartPre=/usr/bin/touch $condition_multi_pre
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
"$sysd2v" "$condition_multi_service" > "$condition_multi_out"
INIT_D_SCRIPT_SOURCED=true
# shellcheck disable=SC1090
. "$condition_multi_out"
do_start_cmd() { touch "$condition_multi_start"; return 0; }
out19=$tmpdir/out19
do_start_cmd_override > "$out19" 2>&1
rc=$?
check_equal "ExecCondition skip stops later conditions" "$rc" "0"
check_missing "ExecCondition skip prevents later conditions" "$condition_multi_late"
check_missing "ExecCondition skip prevents start-pre" "$condition_multi_pre"
check_missing "ExecCondition skip prevents start command" "$condition_multi_start"
unset -f do_start_cmd

echo "SUMMARY - $pass passed, $fail failed"
[ "$fail" -eq 0 ]
