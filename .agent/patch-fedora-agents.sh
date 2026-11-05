#!/bin/bash
# 就地给 fedora 的全局 AGENTS.md 打 wsh 补丁（不整文件覆盖）
set -eu
f="$HOME/.config/opencode/AGENTS.md"
mkdir -p "$HOME/.agent-oc"
cat > "$HOME/.agent-oc/agents-wsh-new.txt" <<'PAYLOAD'
- `wsh`（`~/.local/bin/wsh`）：Windows 侧默认跟随远端 `DefaultShell`（pwsh 7 / 5.1 / cmd 三种都支持，`wsh kind <host>` 查、`--shell pwsh|ps5|cmd` 切换），脚本本地 base64 后 `& ([scriptblock]::Create(...))` 执行，不嵌套子进程；输出统一强制 UTF-8。**坑**：Windows OpenSSH 下嵌套 `pwsh`/`cmd` 退出码一律被吞成 1 → 别写 `ssh win 'powershell -Command ...'`；命令长度上限 ~20KB。
- **硬规则：Windows 上禁止「写 .ps1 文件再用 `powershell.exe -File` 执行」**（用户 2026-11-05：会弹蓝窗被看到，烦人）。一律走 `wsh host -f - <<'PS' … PS`（stdin 内联）或 `wsh -f host ./x.ps1`（本地读、远端 session 0 执行、不落 Windows 文件、无窗口；`wsh` 本身就从不写 .ps1）。脚本 >20KB 才需要落文件：先 `scp` 上去，再 `wsh host '& C:\path\x.ps1'`（仍然无窗口）。只有**确实要在交互桌面里隐形执行**时才用 `Start-Process -WindowStyle Hidden` 或计划任务勾「不管用户是否登录都运行」（= session 0）。
PAYLOAD

python3 - "$f" "$HOME/.agent-oc/agents-wsh-new.txt" <<'PY'
import sys
f, payload_path = sys.argv[1], sys.argv[2]
lines = open(f, encoding='utf-8').read().split('\n')
new = open(payload_path, encoding='utf-8').read().rstrip('\n').split('\n')
out, done = [], False
for ln in lines:
    if (not done) and ln.startswith('- `wsh`（`~/.local/bin/wsh`）'):
        out.extend(new); done = True
    elif not done and ln.startswith('- **硬规则：Windows 上禁止「写 .ps1'):
        continue
    else:
        out.append(ln)
assert done, 'wsh bullet not found'
open(f, 'w', encoding='utf-8').write('\n'.join(out))
print('PATCHED')
PY
grep -c '禁止「写 .ps1' "$f"
grep -n 'wsh kind' "$f" | head -3
