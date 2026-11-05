#!/bin/bash
# rsh 修复——补充回归（2026-11-05 第二段：fedora/win/realme 全部离线，改用 server=本机 作远端）
# 可复跑；会停/重启本机 user ssh-agent（可逆）。证据追加到 .agent/verify.log
set -u
cd "$(dirname "$0")/.."
B=bin/rsh
OLD=.agent/rsh.old
out=.agent/verify2.out
: > "$out"

say() { echo "$@" | tee -a "$out"; }
ms() { echo $(( ($2 - $1) / 1000000 )); }

say "== 9. 目标可达性（复测时间 $(date '+%F %T')）"
for h in 192.168.1.200 192.168.1.199 192.168.1.100; do
    ping -c1 -W 0.5 -n "$h" >/dev/null 2>&1
    say "  ping $h -> rc=$?"
done
say "  fedora tailscale 100.83.106.80 -> $(ping -c1 -W 0.5 -n 100.83.106.80 >/dev/null 2>&1; echo rc=$?)"
say "  fedora/win/realme 均不可达 → 演练改在同机 server(192.168.1.190) 上做，远端前导代码路径相同"

say "== 10. 计时（12 次，取 min/median；判据 <500ms）"
bench() {
    local desc=$1; shift
    local t=()
    for _ in $(seq 12); do
        local s=$(date +%s%N)
        "$@" >/dev/null 2>&1
        local e=$(date +%s%N)
        t+=("$(ms "$s" "$e")")
    done
    local sorted=($(printf '%s\n' "${t[@]}" | sort -n))
    say "  $(printf '%-28s' "$desc") min=${sorted[0]}ms med=${sorted[$(( ${#sorted[@]} / 2 ))]}ms"
}
bench "旧 rsh server echo" sh "$OLD" server "echo hi"
bench "新 rsh server echo" sh "$B" server "echo hi"
bench "旧 rsh server \$(普通 git)" sh "$OLD" server "command -v git"
bench "新 rsh server \$(普通 git)" sh "$B" server "command -v git"

say "== 11. -f（含引号/管道）"
sh "$B" -f server .agent/t-f.sh 2>&1 | sed 's/^/  /' | tee -a "$out"
say "== 12. -f -（stdin）"
printf 'echo stdin-ok; x="a b"\necho "[$x]"\n' | sh "$B" -f server - 2>&1 | sed 's/^/  /' | tee -a "$out"
say "== 13. --sess（含状态保持）"
sh "$B" --sess server 'cd /usr; echo sess-pwd=$PWD' 2>&1 | sed 's/^/  /' | tee -a "$out"
sh "$B" --sess server 'echo next-pwd=$PWD' 2>&1 | sed 's/^/  /' | tee -a "$out"
say "== 14. --sess -f"
sh "$B" --sess -f server .agent/t-f.sh 2>&1 | tail -2 | sed 's/^/  /' | tee -a "$out"
say "== 15. -n（原生 shell，不加 PATH 前导）"
say "  ssh 裸连         : $(ssh -T server 'echo $0 $PATH' 2>/dev/null)"
say "  rsh -n           : $(sh "$B" -n server 'echo $0 $PATH' 2>/dev/null)"
say "  ssh + bash --norc: $(ssh -T server 'bash --noprofile --norc -c "echo \$0 \$PATH"' 2>/dev/null)"
say "  rsh（非 -n）     : $(sh "$B" server 'echo $0 $PATH' 2>/dev/null)"
say "  → -n 与裸 ssh 完全一致；非 -n 的 bash 只有 /usr/local/bin:/usr/bin，靠前导补上 ~/.local/bin"
say "== 16. 健康态 stderr 字节数（应为 0）"
for c in 'echo hi' 'ssh-add -l >/dev/null' 'git --version >/dev/null'; do
    err=$({ sh "$B" server "$c" >/dev/null; } 2>&1 >/dev/null | wc -c)
    say "  cmd=[$c] stderr=${err}B"
done

say "== 17. 远端 agent 真死 → 一次调用自愈（同机 server；本地块先修，等价于真实两端场景的端到端验收）"
systemctl --user stop ssh-agent >/dev/null 2>&1; rm -f "$HOME/.ssh/agent.sock"
s=$(date +%s%N); sh "$B" server 'ssh-add -l' 2>&1 | sed 's/^/  /' | tee -a "$out"; e=$(date +%s%N)
say "  heal: $(ms "$s" "$e") ms"
s=$(date +%s%N); sh "$B" server 'git ls-remote git@github.com:SQL0106/sshkit.git HEAD' 2>&1 | sed 's/^/  /' | tee -a "$out"; e=$(date +%s%N)
say "  git after heal: $(ms "$s" "$e") ms"

say "== 18. 远端前导独立演练（RSH_NO_AGENT_FIX=1 关掉内置修复，手工跑 bin/rsh 里那段前导）"
python3 - "$B" > .agent/_prelude_extract.sh <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"^agent_prelude='(.*?)'\n", s, re.S | re.M)
sys.stdout.write(m.group(1) + "\n")
PY
say "  抽取到的前导：$(wc -l < .agent/_prelude_extract.sh) 行，末行：$(tail -1 .agent/_prelude_extract.sh)"
systemctl --user stop ssh-agent >/dev/null 2>&1; rm -f "$HOME/.ssh/agent.sock"
say "  断开后 ssh-add -l（本地直连）= rc=$(SSH_AUTH_SOCK=$HOME/.ssh/agent.sock ssh-add -l >/dev/null 2>&1; echo $?)"
s=$(date +%s%N)
{ cat .agent/_prelude_extract.sh; echo 'ssh-add -l'; } | RSH_NO_AGENT_FIX=1 sh "$B" -f server - 2>&1 | sed 's/^/  /' | tee -a "$out"
e=$(date +%s%N); say "  远端前导自愈: $(ms "$s" "$e") ms"
say "  再看健康态（同一前导，应静默）:"
err=$({ { cat .agent/_prelude_extract.sh; echo 'echo quiet'; } | RSH_NO_AGENT_FIX=1 sh "$B" -f server - >/dev/null; } 2>&1 >/dev/null | wc -c)
say "    stderr=${err}B"

say "== 19. 开关"
systemctl --user stop ssh-agent >/dev/null 2>&1; rm -f "$HOME/.ssh/agent.sock"
RSH_NO_AGENT_FIX=1 sh "$B" server 'echo nofix-ok' >/dev/null 2>&1
say "  RSH_NO_AGENT_FIX=1 → unit=$(systemctl --user is-active ssh-agent 2>&1) ssh-add -l rc=$(SSH_AUTH_SOCK=$HOME/.ssh/agent.sock ssh-add -l >/dev/null 2>&1; echo $?)"
systemctl --user stop ssh-agent >/dev/null 2>&1; rm -f "$HOME/.ssh/agent.sock"
RSH_AGENT=off sh "$B" server 'echo off-ok' >/dev/null 2>&1
say "  RSH_AGENT=off      → unit=$(systemctl --user is-active ssh-agent 2>&1) ssh-add -l rc=$(SSH_AUTH_SOCK=$HOME/.ssh/agent.sock ssh-add -l >/dev/null 2>&1; echo $?)"
s=$(date +%s%N); RSH_AGENT=always sh "$B" server 'echo always-ok' >/dev/null 2>&1; e=$(date +%s%N)
say "  RSH_AGENT=always   → unit=$(systemctl --user is-active ssh-agent 2>&1) ssh-add -l rc=$(SSH_AUTH_SOCK=$HOME/.ssh/agent.sock ssh-add -l >/dev/null 2>&1; echo $?)，$(ms "$s" "$e") ms"
say "  恢复健康态后再测: $(sh "$B" server 'ssh-add -l' 2>&1)"

say "== 20. 空命令 / -f 不存在 / -s 语义"
sh "$B" server '' >/dev/null 2>&1; say "  空命令 rc=$?"
sh "$B" -f server .agent/__no_such_file 2>&1 | head -1 | sed 's/^/  /' | tee -a "$out"; say "  rc=${PIPESTATUS[0]}"
sh "$B" -s server 'apt-cache policy bash' >/dev/null 2>&1; say "  -s 单条 NOPASSWD rc=$?"
sh "$B" -s server 'echo a; echo b' >/dev/null 2>&1; say "  -s 复合 rc=$?"
sh "$B" -s server 'true \; echo x' >/dev/null 2>&1; rc=$?; say "  -s 转义分号 rc=$rc（非 2 = 未守卫拒绝；sudo 层是否允许另一回事）"

say "== 21. 跳过项"
say "  fedora 演练：LAN/Tailscale 均不可达（tailscale 显示 offline, last seen 1m ago）→ 跳过；同一代码路径已在 server 上验证"
say "  realme：LAN 192.168.1.100 FAILED、Tailscale offline 2d → 跳过"
say "  win：LAN 192.168.1.199 不可达（tailscale offline 21h）→ wsh 实测跳过"
echo "---- 输出结束 ----"
