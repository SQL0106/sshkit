#!/bin/bash
run() { local desc=$1; shift; local t=(); for i in $(seq 12); do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); t+=($(( (e-s)/1000000 ))); done; local sorted=($(printf '%s\n' "${t[@]}" | sort -n)); printf '%-32s min=%-4s med=%-4s\n' "$desc" "${sorted[0]}" "${sorted[5]}"; }
run "旧 rsh server echo" sh .agent/rsh.old server "echo hi"
run "新 rsh server echo" sh bin/rsh server "echo hi"
run "旧 rsh fedora echo" sh .agent/rsh.old fedora "echo hi"
run "新 rsh fedora echo" sh bin/rsh fedora "echo hi"
run "新 rsh fedora ssh-add(探测)" sh bin/rsh fedora "ssh-add -l"
run "新 rsh --sess fedora echo" sh bin/rsh --sess fedora "echo hi"
run "新 rsh -f fedora 小脚本" sh bin/rsh -f fedora .agent/t-f.sh
