#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/drm/card0-eDP-1" "$tmpdir/drm/card0-DP-1"
export OMARCHY_DRM_PATH="$tmpdir/drm" CALL_LOG="$tmpdir/calls" TEST_STATE="$tmpdir"
export PATH="$tmpdir/bin:$ROOT/bin:$PATH"
monitor="$ROOT/bin/omarchy-system-docked-lid-inhibit"

cat >"$tmpdir/bin/busctl" <<'SH'
#!/bin/bash
printf 's "%s"\n' "$(<"$TEST_STATE/policy")"
SH
cat >"$tmpdir/bin/systemd-inhibit" <<'SH'
#!/bin/bash
printf 'acquired %s\n' "$*" >>"$CALL_LOG"
while [[ $1 == --* ]]; do shift; done
[[ ${SCENARIO:-} == "disconnect-during-acquire" ]] && echo disconnected >"$OMARCHY_DRM_PATH/card0-DP-1/status"
"$@"
echo released >>"$CALL_LOG"
SH
cat >"$tmpdir/bin/sleep" <<'SH'
#!/bin/bash
count=$(<"$TEST_STATE/count")
echo "$((count + 1))" >"$TEST_STATE/count"
echo tick >>"$CALL_LOG"
case "$SCENARIO:$count" in
  connect:0) echo connected >"$OMARCHY_DRM_PATH/card0-DP-1/status" ;;
  connect:1 | docked:0) echo disconnected >"$OMARCHY_DRM_PATH/card0-DP-1/status" ;;
  policy:0) echo suspend >"$TEST_STATE/policy" ;;
  disabled:0) exit 23 ;;
  *) exit 24 ;;
esac
SH
chmod +x "$tmpdir/bin/"*

reset_scenario() {
  export SCENARIO="$1"
  : >"$CALL_LOG"
  echo 0 >"$TEST_STATE/count"
  echo ignore >"$TEST_STATE/policy"
  echo connected >"$OMARCHY_DRM_PATH/card0-eDP-1/status"
  echo connected >"$OMARCHY_DRM_PATH/card0-DP-1/status"
  echo disabled >"$OMARCHY_DRM_PATH/card0-DP-1/enabled"
}

reset_scenario docked
"$monitor"
mapfile -t calls <"$CALL_LOG"
[[ ${calls[0]} == 'acquired --what=handle-lid-switch --mode=block --who=Omarchy --why=External monitor connected '* ]] ||
  fail "connected but disabled external display inhibits only lid handling"
[[ ${calls[1]} == "tick" && ${calls[2]} == "released" && ${#calls[@]} == 3 ]] ||
  fail "unplug releases the inhibitor on the next poll"
pass "logout and DPMS do not remove docked protection; unplug restores lid handling"

reset_scenario connect
echo disconnected >"$OMARCHY_DRM_PATH/card0-DP-1/status"
"$monitor"
mapfile -t calls <"$CALL_LOG"
[[ ${calls[0]} == "tick" && ${calls[1]} == acquired* && ${calls[3]} == "released" ]] ||
  fail "internal display alone does not inhibit; hotplug acquires the inhibitor"
pass "undocked lid handling is preserved and external hotplug acquires protection"

reset_scenario disconnect-during-acquire
"$monitor"
mapfile -t calls <"$CALL_LOG"
[[ ${calls[0]} == acquired* && ${calls[1]} == "released" && ${#calls[@]} == 2 ]] ||
  fail "disconnect during acquisition immediately releases protection"
pass "disconnect race cannot leave a stale inhibitor"

reset_scenario policy
"$monitor"
[[ $(tail -1 "$CALL_LOG") == "released" ]] || fail "policy change releases the inhibitor"
pass "administrator docked lid policy takes precedence"

reset_scenario disabled
echo suspend >"$TEST_STATE/policy"
status=0
"$monitor" || status=$?
[[ $status == 23 && $(<"$CALL_LOG") == "tick" ]] || fail "non-ignore policy must not acquire a lock"
pass "explicit docked suspend policy is never overridden"

# Upgrade is machine-wide but migrations run once for each user.
export OMARCHY_PATH="$ROOT"
unit_source="$ROOT/default/systemd/system/omarchy-docked-lid-inhibit.service"
cat >"$tmpdir/bin/systemctl" <<'SH'
#!/bin/bash
if [[ $1 == is-enabled ]]; then
  [[ -e $TEST_STATE/enabled ]]
elif [[ $1 == daemon-reload || ${!#} == "omarchy-docked-lid-inhibit.service" ]]; then
  echo "$*" >>"$CALL_LOG"
  if [[ $1 == enable ]]; then
    [[ -f $TEST_STATE/unit ]] || exit 1
    touch "$TEST_STATE/enabled"
  fi
fi
SH
cat >"$tmpdir/bin/install" <<'SH'
#!/bin/bash
set -euo pipefail
[[ $1 == "-Dm644" && $2 == "$OMARCHY_PATH/default/systemd/system/omarchy-docked-lid-inhibit.service" &&
  $3 == "/etc/systemd/system/omarchy-docked-lid-inhibit.service" ]] || exit 1
echo install >>"$CALL_LOG"
[[ ${INSTALL_FAIL:-0} == "0" ]] || exit 19
exec /usr/bin/install "$1" "$2" "$TEST_STATE/unit"
SH
cat >"$tmpdir/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$tmpdir/bin/systemctl" "$tmpdir/bin/install" "$tmpdir/bin/sudo"
: >"$CALL_LOG"
bash -euo pipefail "$ROOT/migrations/1790703856.sh"
bash -euo pipefail "$ROOT/migrations/1790703856.sh"
[[ $(<"$CALL_LOG") == $'install\ndaemon-reload\nenable --now omarchy-docked-lid-inhibit.service' ]] ||
  fail "migration must install before enabling and no-op for another user"
cmp -s "$unit_source" "$TEST_STATE/unit" || fail "migration installs the shipped system unit"
[[ $(stat -c %a "$TEST_STATE/unit") == "644" ]] || fail "migration installs the system unit with mode 0644"
pass "migration installs the system unit before enabling and is idempotent across users"

rm "$TEST_STATE/unit" "$TEST_STATE/enabled"
: >"$CALL_LOG"
bash -euo pipefail "$ROOT/install/config/enable-services.sh"
[[ $(<"$CALL_LOG") == $'install\nenable omarchy-docked-lid-inhibit.service' ]] ||
  fail "fresh installation must install before enabling without starting or reloading services"
cmp -s "$unit_source" "$TEST_STATE/unit" || fail "fresh installation installs the shipped system unit"
pass "fresh installation installs the unit and enables it for the next boot"

rm "$TEST_STATE/unit" "$TEST_STATE/enabled"
: >"$CALL_LOG"
status=0
INSTALL_FAIL=1 bash -euo pipefail "$ROOT/migrations/1790703856.sh" || status=$?
[[ $status == 19 && $(<"$CALL_LOG") == "install" && ! -e $TEST_STATE/enabled ]] ||
  fail "failed unit installation must leave the migration pending without enabling the service"
pass "failed unit installation stops the migration before activation"
