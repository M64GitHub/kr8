#!/bin/zsh
# The REAL look: run kr8 in a new kitty window (silent: --silent, a
# scratch KR8_HOME), screenshot it, print kr8's and kitty's CPU, close it.
#
#   tools/look.sh OUT.png SECONDS "KEYS" DIR...
#
# KEYS is kr8's --keys script ("60:j,62:space"; frames at 60 fps, so
# start at ~60 to let the window settle). AeroSpace tiles the window, so
# sizes vary. Needs Screen Recording permission for the terminal.
set -u
out=$1; secs=$2; keys=$3; shift 3
here=${0:A:h:h}
home=${KR8_LOOK_HOME:-${TMPDIR:-/tmp}kr8-look-home}
mkdir -p $home
title="kr8look$$"
KR8_HOME=$home kitty --title $title $here/zig-out/bin/kr8 --silent --keys "$keys" "$@" &
kpid=$!
sleep $secs
kp=$(pgrep -f "^$here/zig-out/bin/kr8" | head -1)
kk=$(pgrep -f "kitty --title $title" | head -1)
[ -n "$kp" ] && echo "kr8   cpu: $(top -l 2 -s 1 -pid $kp -stats cpu | tail -1)%  rss: $(ps -o rss= -p $kp) KB"
[ -n "$kk" ] && echo "kitty cpu: $(top -l 2 -s 1 -pid $kk -stats cpu | tail -1)%"
wid=$(aerospace list-windows --all --format '%{window-id}|%{window-title}' | grep "$title" | head -1 | cut -d'|' -f1)
[ -n "$wid" ] && screencapture -x -o -l $wid $out && echo "saved $out"
kill -TERM $kpid 2>/dev/null; sleep 0.5; kill -0 $kpid 2>/dev/null && kill -9 $kpid
