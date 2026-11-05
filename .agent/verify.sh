#!/bin/bash
# rsh 修复自检（本机可复跑）。远端 agent 演练会重启对端 user agent（可逆）。
set -u
cd "$(dirname "$0")/.."
B=bin/rsh
echo "== 1. 语法"; dash -n $B && bash -n $B && echo "sh -n OK (dash/bash)"
echo "== 2. 本机耗时"; for i in 1 2 3; do s=$(date +%s%N); sh $B server 'echo hi >/dev/null'; e=$(date +%s%N); echo "  rsh server echo: $(( (e-s)/1000000 )) ms"; done
echo "== 3. B: 远端 PATH"; sh $B fedora 'echo "$PATH"' | head -1
echo "== 4. C: 单条（NOPASSWD 命令）"; sh $B -s server 'apt-cache policy bash' | head -1; echo "  rc=$?"
echo "  fedora 单条(需密码→明确报错):"; sh $B -s fedora 'echo ok' 2>&1 | head -1
echo "== 5. C: 复合（应 exit 2）"; sh $B -s fedora 'echo a; echo b' >/dev/null 2>&1; echo "  rc=$?"
echo "== 6. -f / -f - / --sess / -n"; sh $B -f fedora .agent/t-f.sh | tail -1; printf 'echo stdin-ok\n' | sh $B -f fedora -; sh $B --sess fedora 'echo sess-ok'; sh $B -n fedora 'echo native-ok'
echo "== 7. 远端 agent 真死 → 一次调用自愈"
sh $B fedora 'systemctl --user stop ssh-agent; rm -f ~/.ssh/agent.sock' >/dev/null 2>&1
s=$(date +%s%N); sh $B fedora 'ssh-add -l' ; e=$(date +%s%N); echo "  heal: $(( (e-s)/1000000 )) ms"
s=$(date +%s%N); sh $B fedora 'git ls-remote git@github.com:SQL0106/sshkit.git | head -1'; e=$(date +%s%N); echo "  git after heal: $(( (e-s)/1000000 )) ms"
echo "== 8. 本地 agent 自愈"
systemctl --user stop ssh-agent >/dev/null 2>&1; rm -f ~/.ssh/agent.sock
sh $B server 'echo hi' >/dev/null; SSH_AUTH_SOCK=$HOME/.ssh/agent.sock ssh-add -l
