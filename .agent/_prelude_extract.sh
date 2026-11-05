_rsh_sock=$HOME/.ssh/agent.sock
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "$_rsh_sock" ]; then SSH_AUTH_SOCK=$_rsh_sock; export SSH_AUTH_SOCK; fi
_rsh_broke=0
_rsh_rc=2
if [ -n "${SSH_AUTH_SOCK:-}" ]; then ssh-add -l >/dev/null 2>&1; _rsh_rc=$?; fi
# 只有「装了常驻 agent」的机器才修：socket 存在（含陈旧）或本机 unit 存在
_rsh_persist=0
if [ -e "$_rsh_sock" ] || [ -f "$HOME/.config/systemd/user/ssh-agent.service" ]; then _rsh_persist=1; fi
if [ "$_rsh_rc" -eq 2 ] && [ "$_rsh_persist" -eq 1 ] && { [ -z "${SSH_AUTH_SOCK:-}" ] || [ "${SSH_AUTH_SOCK}" = "$_rsh_sock" ]; }; then
    _rsh_broke=1
    rm -f "$_rsh_sock"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user restart ssh-agent >/dev/null 2>&1; then :
    elif command -v ssh-agent >/dev/null 2>&1; then ssh-agent -a "$_rsh_sock" >/dev/null 2>&1 || true
    fi
    SSH_AUTH_SOCK=$_rsh_sock; export SSH_AUTH_SOCK
    ssh-add -l >/dev/null 2>&1; _rsh_rc=$?
    _rsh_w=0
    while [ "$_rsh_rc" -eq 2 ] && [ "$_rsh_w" -lt 10 ]; do
        sleep 0.1
        ssh-add -l >/dev/null 2>&1; _rsh_rc=$?
        _rsh_w=$((_rsh_w + 1))
    done
fi
if [ "$_rsh_rc" -ne 0 ] && [ "$_rsh_persist" -eq 1 ] && [ -x "$HOME/.local/bin/ssh-unlock" ]; then
    "$HOME/.local/bin/ssh-unlock" >/dev/null 2>&1
    ssh-add -l >/dev/null 2>&1; _rsh_rc=$?
fi
if [ "$_rsh_rc" -ne 0 ] && [ "$_rsh_persist" -eq 1 ] && command -v bash >/dev/null 2>&1; then
    bash -ic "command -v ssh-unlock >/dev/null 2>&1 && ssh-unlock" </dev/null >/dev/null 2>&1
    ssh-add -l >/dev/null 2>&1; _rsh_rc=$?
fi
if [ "$_rsh_rc" -ne 0 ] && { [ "$_rsh_broke" -eq 1 ] || { [ "$_rsh_persist" -eq 1 ] && [ -S "$_rsh_sock" ]; }; }; then
    echo "rsh: 远端 ssh-agent 无可用身份（socket=${SSH_AUTH_SOCK:-未设置}），git/ssh 可能报 publickey 失败；在该机执行: rm -f ~/.ssh/agent.sock && systemctl --user restart ssh-agent && ssh-unlock" >&2
fi
unset _rsh_sock _rsh_rc _rsh_broke _rsh_w _rsh_persist
