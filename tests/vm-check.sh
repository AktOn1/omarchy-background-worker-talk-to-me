#!/bin/bash
# Runs inside the Omarchy VM (vm-test): a session clears the screen and the end brings everything back.
set -u
T="${PLUGIN_DIR:-$HOME/.config/omarchy/plugins/$PLUGIN_ID}/bin/talk-to-me"
ws() { hyprctl -j monitors | jq -r '.[0].activeWorkspace.name'; }
fail() { echo "FAIL: $1"; "$T" end --quiet >/dev/null 2>&1; exit 1; }
for i in 1 2; do setsid nohup foot >/dev/null 2>&1 </dev/null & sleep 1.5; done
before=$(hyprctl -j clients | jq -c 'sort_by(.address)|[.[]|[.address,.workspace.name,.at,.size]]')
home=$(ws)
"$T" start "vm check" --countdown 1 >/dev/null || fail "start"
sleep 1.5
[[ $(ws) == talk-to-me-hidden-* ]] || fail "screen not cleared (on $(ws))"
[[ $(hyprctl -j clients | jq -c 'sort_by(.address)|[.[]|[.address,.workspace.name,.at,.size]]') == "$before" ]] || fail "a window was moved while hiding"
mkdir -p "$VM_TEST_OUT" && grim "$VM_TEST_OUT/hidden.png"
"$T" end --quiet || fail "end"
sleep 1.5
[[ $(ws) == "$home" ]] || fail "not back on workspace $home (on $(ws))"
echo "start: empty workspace, no window moved; end: back on workspace $home"
"$T" start "vm check 2" --countdown 1 --no-hide >/dev/null || fail "start --no-hide"
sleep 1.5
[[ $(ws) == "$home" ]] || fail "--no-hide still cleared the screen"
"$T" end --quiet
pkill -x foot
echo "--no-hide keeps the windows on screen"
# postponing (P, 2 minutes) must hold: a second start gets postpone:<min> at once and no countdown begins
"$T" start "vm check 3" --countdown 20 >/tmp/ttm-first 2>&1 &
sleep 3
wtype p; sleep 0.5; wtype 2; sleep 0.5; wtype -k Return
wait
grep -q '^postpone:2$' /tmp/ttm-first || fail "postpone P2 gave: $(cat /tmp/ttm-first)"
second=$("$T" start "vm check 4" --countdown 1 2>&1); rc=$?
[[ $second =~ ^postpone:[12]$ && $rc == 5 ]] || fail "start during postponement gave '$second' (exit $rc)"
[[ $("$T" status | jq -r .phase) == paused ]] || fail "postponement was overridden (phase $("$T" status | jq -r .phase))"
echo "start during a 2 minute postponement: $second, still paused"
"$T" end --quiet >/dev/null 2>&1
