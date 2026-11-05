# sshkit（rsh / wsh / sess / ssh-unlock）

> 上层：`~/.config/opencode/AGENTS.md` §SSH（选哪个工具）、`~/AGENTS.md` §二（主机别名与密钥）。

## 目录
- `bin/rsh`：Linux 目标单条命令直通。`rsh host` 交互（自动 `exec bash -l`）；`rsh host <cmd>`；`rsh -f host <file|->` 把本地脚本喂 `bash --noprofile --norc -s`；`rsh -s host <cmd>` 加 `sudo -n`（**只接受单条命令**，复合命令 exit 2）；`rsh -n` 用远端原生 shell；`rsh --sess` 走 sess。命令本地 base64 后远端解码，绕开引号地狱。非 `-n` 模式远端自动前置 `~/.local/bin` 到 PATH，并在命令涉及 git/ssh/scp/sftp/rsync 时自愈远端 ssh-agent（`RSH_AGENT=auto|always|off`，`RSH_NO_AGENT_FIX=1` 关闭）。
- `bin/wsh`：Windows 目标。默认 shell 已是 pwsh 7，脚本 base64 后 `& ([scriptblock]::Create(...))`，不嵌套子进程；`wsh -f host <file|->`；首次连接探壳结果缓存在 `~/.cache/wsh/<host>`；本地 ssh-agent 与 `rsh` 同套探测+自愈（`WSH_AGENT=auto|off`、`WSH_NO_AGENT_FIX=1`，健康时跳过 `ssh-unlock`）。
- `bin/sess`：每 host 一个 keeper 守护进程持 `ssh -T`，单条命令约 45ms（Windows 从 400ms 降下来），`cd`/env 跨命令保留。`sess run <host> [--new]`、`list`、`stop [host]`、`kind [--reset] <host>`。
- `bin/ssh-unlock`：幂等解锁 ssh-agent（未解锁时用 `$SSH_PASS` 自动 `ssh-add`，不落盘）。
- `systemd/ssh-agent.service`：user unit，`ExecStart=/usr/bin/ssh-agent -D -a %h/.ssh/agent.sock`。
- `install.sh`：`--agent` 装 agent unit。

## 约定
- **改这四个工具请在本仓库改，push 后再拷到 `~/.local/bin`**（不要直接改 `~/.local/bin`）。
- **`wsh` 默认走 sess 常驻会话**（实测 70-120 ms/条）。`--direct` 才是强制一次性 ssh（0.4 s～30 s 握手），只在需要干净会话时用。
- sess 唯一的故障模式是 **keeper 变陈旧**：现象是每条命令几十秒（实测 147 s）。修法固定三步：`sess run <host> 1` 两次看耗时 → `sess stop <host>` → 再测。**不要退回裸 ssh。**
- README 与脚本**保持脱敏**：示例主机写 `linux-host` / `win-host`，不写真实别名、IP、用户名。
- 一律显式落 bash（远端登录 shell 可能是 zsh）：`rsh`/`sess` 已内置 `bash --noprofile --norc`。
- `rsh` 远端跑 `bash --noprofile --norc`，但非 `-n` 模式会先做一段前导：PATH 前置 `~/.local/bin`（存在才加）+ 按需自愈远端 ssh-agent。这段前导和用户命令拼在**同一条**远端命令里（base64 同一个 payload），所以不增加 ssh 往返；`-n` 只跑 agent 前导，PATH 保持原生。

## 已知坑（改协议/改实现必读）
- **远端 agent 的死法**：`~/.ssh/agent.sock` 是陈旧 socket（`srw-------`）而 unit 已 failed —— `ssh-agent -D -a` 遇到已存在的 socket 会 exit 1，`~/.ssh/config` 的 `IdentityAgent` 指向它，于是所有 git/ssh 都 `Permission denied (publickey)`，报错完全不指向真因。`rsh` 已内置自愈（`ssh-add -l` rc=2 → `rm -f` socket → `systemctl --user restart ssh-agent` → 等 1s 内起来 → ssh-unlock）。远端 `SSH_PASS` 只在 `~/.bashrc`，非交互 shell 读不到，所以解锁要借 `bash -ic`。本地同一套故障也由 `rsh` 修（条件：socket 存在或本机有 `~/.config/systemd/user/ssh-agent.service`）。
- `rsh -s` 只给单条命令加 `sudo -n`：复合命令（`;` `&&` `|`）直接 exit 2（`sudo -n bash -c` 会被 sudoers 按路径拒掉，硬套只会换成另一种误导报错）。
- `sess` 哨兵必须在 stdout 和 stderr 各写一份 `__END__<tok>:<rc>`（单哨兵会导致 stderr 偶发丢失）。
- 本地 socket 帧格式 = `kind + 4 字节长度 + 数据`（`O`/`E`/`R`），socket 在 `~/.cache/sess/<host>.v3.sock`；改协议要改 `PROTO`。
- 改过 `sess` 源码后旧 keeper 自动退役：`~/.cache/sess/<host>.sig` 存源码 `mtime:size` 指纹。某 host 突然从 45ms 变几百 ms → `sess stop <host>`。
- 会话里执行 `exit` 会杀掉常驻 shell（rc=255），下次自动重建；两个 keeper 抢同一 socket 会导致 `cd`/env 莫名丢失，已用 pid 文件 + flock 互斥修掉（`live_keeper()`）。
- `sess kind` 类型缓存会中毒（`~/.cache/sess/<host>.kind` 被存成 `windows`）：表现为 rc=1 且**零输出**、日志 `write failed: BrokenPipeError`。修法 `sess kind --reset <host>` 或删缓存 + `sess stop <host>`。探测失败不再落缓存，写管道失败会自动 respawn 重试一次。
- Windows OpenSSH 下**嵌套 `pwsh`/`cmd` 的退出码一律被吞成 1**（只有本进程 `exit` 才透传）→ 别用 `ssh win 'powershell -Command ...'`；`-Command -` 读 stdin 也是 rc=1。`wsh` 已在脚本尾部显式 `exit` 并按需回传 `$LASTEXITCODE`，且设 `$PSStyle.OutputRendering='PlainText'`、强制 UTF-8。
- 命令长度上限约 20KB（base64 后），更大先 scp 上去再执行。

## 性能参考（本机实测）
- Linux：`ssh` 有 ControlMaster 时 16ms，`sess` 44ms → **单条命令直接 ssh/rsh，批处理/需要状态才用 sess**。
- Windows：`sess` 45ms vs 每次新连接 400ms（8.7 倍）。
- **2026-11-01 实测**：keeper 陈旧时 `wsh --sess host 1` 单条 **147 s**；`sess stop host` 重建后同一命令 **49～51 ms**，`wsh host 1` 70～120 ms。→ 慢不是 sess 的锅，是 keeper 陈旧，重置即可。
