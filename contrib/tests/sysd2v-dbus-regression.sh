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

echo "SUMMARY - $pass passed, $fail failed"
[ "$fail" -eq 0 ]
