# 续做：rsh 修复收尾 + wsh 同步有益改动

背景：上一个会话的子代理已在工作树改好 `bin/rsh`（**未 commit**）。设计与自检记录见 `.agent/rsh-fix.md`、`.agent/verify.sh`、`.agent/verify.log`，基线 `rsh.old`。子代理会话 ID `ses_e54162df8ffeQ3nfvjVd4T74Fv`（可用 subagent 工具带该 sessionID 追问，但不要让它重复改同一批文件）。

已确认方向正确、**不要推翻**的三处改动：
- **A** 远端 ssh-agent 陈旧 socket 自愈：探测与修复脚本和用户命令拼在**同一条**远端命令里（零额外 ssh 往返）；`ssh-add -l` rc=2 时 `rm -f` 陈旧 socket → `systemctl --user restart ssh-agent`（无 systemd 退 `ssh-agent -a`）→ 轮询等 agent 起来 → `ssh-unlock`，仍空再 `bash -ic 'ssh-unlock'`。开关 `RSH_AGENT=auto|always|off`（默认 auto），`RSH_NO_AGENT_FIX=1` 全关。
- **A'** 本地同故障也自愈；健康时 `ssh-add -l` 通过就跳过 `ssh-unlock`（省 ~25ms）。
- **B** 非 `-n` 模式把 `$HOME/.local/bin` 前置到 PATH。
- **C** `-s` 拒绝含未转义 `;` / `&&` / `|` / 换行的命令（`\;` 放行），提示改用 `-f`。

## 你的任务（按序）

1. 先读 `~/.config/opencode/AGENTS.md`、`~/sshkit/AGENTS.md`、`.agent/rsh-fix.md`；`git status` / `git diff` 确认现状。
2. 补完剩余回归，证据写进 `.agent/verify.log`：
   - fedora 演练：先 `bash bin/rsh fedora 'systemctl --user stop ssh-agent; rm -f ~/.ssh/agent.sock'`，随后**一次** `bash bin/rsh fedora 'ssh-add -l'` 应自愈并列出 ED25519 身份；再 `bash bin/rsh fedora 'git ls-remote git@github.com:SQL0106/sshkit.git HEAD'` 成功。
   - `-f`（带引号/管道的脚本）、`-f -`（stdin）、`--sess`、`--sess -f`、`-n`、健康态 stderr 为 0 字节。
   - 计时：`bash bin/rsh server 'echo hi'`、`bash bin/rsh fedora 'echo hi'` 各 ≥10 次取 min/median，确认无退化（判据 <500ms）。本机**没有 `/usr/bin/time`**，用 zsh 内建 `time` 或 `date +%s%N`。
   - realme 若仍离线（局域网 + Tailscale 都 No route/timeout），记录"跳过"，不要死磕。
3. 通过后 commit + push（`git add -A`，只提交本任务相关文件），并按仓库规矩把 `bin/rsh` 等装到 `~/.local/bin`（先比对差异，再 `install -m 755`）。
4. **wsh 同步有益改动**：通读 `bin/wsh`，只移植与平台无关的有益部分（本地 ssh-agent 探测+自愈 / 健康时跳过 `ssh-unlock`、故障时一行可诊断 stderr、开关命名用 `WSH_AGENT` 以保持一致）。**不要**把 `-s`、PATH 前导这类 Linux 专属逻辑塞进去；Windows 侧远端 agent 语义不同，别改协议/哨兵。改完实测 `wsh win 'echo hi'` 与 `wsh win '$PSVersionTable.PSVersion.ToString()'`（win 离线就记录）。
5. 同样 commit + push + 装到 `~/.local/bin`。
6. 最后回一段简短汇报：改了什么、验证证据路径、commit hash、性能数字、遗留风险。

## 硬约束
- `rsh` 用 POSIX sh（过 `dash -n`/`bash -n`），`wsh` 是 PowerShell。
- 禁止写 `/tmp`；禁止全盘搜索；README/脚本保持脱敏（示例主机写 `linux-host` / `win-host`）。
- 不打印任何口令/密钥（`SUDO_PASS`、`SSH_PASS` 只在 idiom 内用）。
