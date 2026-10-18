#!/bin/bash
# Runs inside the Omarchy VM (vm-test): a session clears the screen and the end brings everything back.
set -u
T="${PLUGIN_DIR:-$HOME/.config/omarchy/plugins/$PLUGIN_ID}/bin/talk-to-me"
ws() { hyprctl -j monitors | jq -r '.[0].activeWorkspace.name'; }
fail() { echo "FAIL: $1"; "$T" end --quiet >/dev/null 2>&1; exit 1; }
for i in 1 2; do setsid nohup foot >/dev/null 2>&1 </dev/null & sleep 1.5; done
before=$(hyprctl -j clients | jq -c 'sort_by(.address)|[.[]|[.address,.workspace.name,.at,.size]]')
home=$(ws)
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check" --countdown 1 >/dev/null || fail "start"
sleep 1.5
[[ $(ws) == talk-to-me-hidden-* ]] || fail "screen not cleared (on $(ws))"
[[ $(hyprctl -j clients | jq -c 'sort_by(.address)|[.[]|[.address,.workspace.name,.at,.size]]') == "$before" ]] || fail "a window was moved while hiding"
mkdir -p "$VM_TEST_OUT" && grim "$VM_TEST_OUT/hidden.png"
"$T" end --quiet || fail "end"
sleep 1.5
[[ $(ws) == "$home" ]] || fail "not back on workspace $home (on $(ws))"
echo "start: empty workspace, no window moved; end: back on workspace $home"
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 2" --countdown 1 --no-hide >/dev/null || fail "start --no-hide"
sleep 1.5
[[ $(ws) == "$home" ]] || fail "--no-hide still cleared the screen"
"$T" end --quiet
pkill -x foot
echo "--no-hide keeps the windows on screen"
# a full title is shown, never cut off; a vague one is refused
"$T" start "demo" --countdown 1 >/dev/null 2>&1; [[ $? == 2 ]] || fail "short title was not refused"
LONG="Claude Code: checking that the complete sentence about what is tested and for which project is shown in full on the countdown card and on the running badge, wrapped over several lines"
"$T" start "$LONG" --help "watch the screen" --estimate 2m --countdown 6 >/tmp/ttm-long 2>&1 &
sleep 3; grim "$VM_TEST_OUT/long-title-countdown.png"
sleep 6; grim "$VM_TEST_OUT/long-title-badge.png"
"$T" status | grep -q 'several lines' || fail "status lost the end of the long title"
"$T" end --quiet; wait
echo "long title: kept whole in status, screenshots saved"
# postponing (Ctrl+P, 2 minutes) must hold: a second start gets postpone:<min> at once and no countdown begins
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 3" --countdown 20 >/tmp/ttm-first 2>&1 &
sleep 3
wtype -M ctrl -k p -m ctrl; sleep 0.5; wtype 2; sleep 0.5; wtype -k Return
wait
grep -q '^postpone:2$' /tmp/ttm-first || fail "postpone P2 gave: $(cat /tmp/ttm-first)"
second=$(TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 4" --countdown 1 2>&1); rc=$?
[[ $second =~ ^postpone:[12]$ && $rc == 5 ]] || fail "start during postponement gave '$second' (exit $rc)"
[[ $("$T" status | jq -r .phase) == paused ]] || fail "postponement was overridden (phase $("$T" status | jq -r .phase))"
echo "start during a 2 minute postponement: $second, still paused"
"$T" end --quiet >/dev/null 2>&1
# typed reply works through the plugin-drawn input box; Ctrl+V and Shift+Insert paste through wl-paste
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 5" --help "answer one question" --countdown 20 >/tmp/ttm-human 2>&1 &
sleep 3
wtype y; sleep 0.5; wtype -M ctrl -k y -m ctrl; wait
grep -q '^human$' /tmp/ttm-human || fail "Ctrl+Y did not give human: $(cat /tmp/ttm-human)"
echo -n PASTED | wl-copy >/dev/null 2>&1
"$T" ask "typed reply check" --text --timeout 20 >/tmp/ttm-reply 2>&1 &
sleep 3
wtype -M ctrl -k v -m ctrl; sleep 1; wtype -M shift -k Insert -m shift; sleep 1; wtype ok; wtype -k Return
wait
grep -qx 'text:PASTEDPASTEDok' /tmp/ttm-reply || fail "typed reply gave '$(cat /tmp/ttm-reply)' (expected text:PASTEDPASTEDok)"
pkill -x wl-copy
echo "typed reply arrives as text:PASTEDPASTEDok (Ctrl+V and Shift+Insert pasted through wl-paste)"
"$T" end --quiet >/dev/null 2>&1
# hotkeys need Ctrl: plain letters do nothing, Ctrl+N answers no
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 6" --help "answer one question" --countdown 20 >/tmp/ttm-human 2>&1 &
sleep 3
wtype -M ctrl -k y -m ctrl; wait
"$T" ask "plain key check" --timeout 20 >/tmp/ttm-ask 2>&1 &
sleep 3
wtype n; wtype y; sleep 1
kill -0 $! 2>/dev/null || fail "a plain key answered the question: $(cat /tmp/ttm-ask)"
wtype -M ctrl -k n -m ctrl; wait
grep -qx 'no' /tmp/ttm-ask || fail "Ctrl+N gave '$(cat /tmp/ttm-ask)' (expected no)"
echo "plain n/y ignored; Ctrl+N answers no"
# paused: a tap on Ctrl shrinks the card and moves it to the right edge
"$T" ask "pause layout check" --timeout 30 >/tmp/ttm-ask 2>&1 &
sleep 3
layer() { hyprctl -j layers | jq -c '[.. | objects | select(.namespace? == "background-worker-talk-to-me-prompt")] | .[0] | [.x,.y,.w,.h]'; }
mon_w=$(hyprctl -j monitors | jq '.[0].width')
before=$(layer)
wtype -k Control_L; sleep 1
after=$(layer)
read -r ax ay aw ah < <(echo "$after" | jq -r 'join(" ")')
read -r bx by bw bh < <(echo "$before" | jq -r 'join(" ")')
grab="$VM_TEST_OUT"; mkdir -p "$grab" && grim "$grab/paused.png"
(( aw < bw )) || fail "paused card not narrower ($before -> $after)"
(( ax + aw > mon_w - 60 )) || fail "paused card not at the right edge ($after, monitor $mon_w)"
echo "paused: card $bw x $bh -> $aw x $ah, right edge at $((ax + aw)) of $mon_w"
wtype -M ctrl -k q -m ctrl; wait
"$T" end --quiet >/dev/null 2>&1
# paused countdown bar: wide and centred at the top while counting, small and on the right while paused
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 7" --help "answer one question" --countdown 30 >/tmp/ttm-human 2>&1 &
sleep 3
read -r bx by bw bh < <(layer | jq -r 'join(" ")')
wtype -k Control_L; sleep 1
read -r ax ay aw ah < <(layer | jq -r 'join(" ")')
grim "$VM_TEST_OUT/paused-countdown.png"
(( bw > mon_w / 2 && bx + bw < mon_w - 100 )) || fail "running countdown bar not wide and centred ($bx $by $bw $bh)"
(( aw < bw / 2 + 40 && ax + aw > mon_w - 60 )) || fail "paused countdown bar not small and on the right ($ax $ay $aw $ah)"
echo "paused countdown: bar $bw x $bh at x=$bx -> $aw x $ah at x=$ax (right edge $((ax + aw)) of $mon_w)"
wtype -M ctrl -k q -m ctrl; wait
"$T" end --quiet >/dev/null 2>&1
# a window an agent opens with no session is held out of sight, and comes back once the agent announces itself
"$T" end --quiet >/dev/null 2>&1
pkill -x foot; sleep 1
AI_AGENT=vm-check setsid nohup foot >/dev/null 2>&1 </dev/null &
sleep 4
held=$(hyprctl -j clients | jq -r '[.[] | select(.class=="foot")][0].workspace.name')
grim "$VM_TEST_OUT/agent-window-held.png"
[[ $held == special:talk-to-me-held ]] || fail "unannounced agent window not held (on $held)"
TALK_TO_ME_ALLOW_SHORT_TITLE=1 "$T" start "vm check 8" --countdown 1 --no-hide >/dev/null || fail "start after held window"
sleep 7
back=$(hyprctl -j clients | jq -r '[.[] | select(.class=="foot")][0].workspace.name')
"$T" end --quiet >/dev/null 2>&1
pkill -x foot
[[ $back != special:* ]] || fail "held window not released when the session started (on $back)"
echo "agent window with no session: held on $held, released to workspace $back at talk-to-me start"
