# sshkit（rsh / wsh / sess / ssh-unlock）

> 上层：`~/.config/opencode/AGENTS.md` §SSH（选哪个工具）、`~/AGENTS.md` §二（主机别名与密钥）。

## 目录
- `bin/rsh`：Linux 目标单条命令直通。`rsh host` 交互（自动 `exec bash -l`）；`rsh host <cmd>`；`rsh -f host <file|->` 把本地脚本喂 `bash --noprofile --norc -s`；`rsh -s host <cmd>` 加 `sudo -n`；`rsh -n` 用远端原生 shell；`rsh --sess` 走 sess。命令本地 base64 后远端解码，绕开引号地狱。
- `bin/wsh`：Windows 目标。默认 shell 已是 pwsh 7，脚本 base64 后 `& ([scriptblock]::Create(...))`，不嵌套子进程；`wsh -f host <file|->`；首次连接探壳结果缓存在 `~/.cache/wsh/<host>`。
- `bin/sess`：每 host 一个 keeper 守护进程持 `ssh -T`，单条命令约 45ms（Windows 从 400ms 降下来），`cd`/env 跨命令保留。`sess run <host> [--new]`、`list`、`stop [host]`、`kind [--reset] <host>`。
- `bin/ssh-unlock`：幂等解锁 ssh-agent（未解锁时用 `$SSH_PASS` 自动 `ssh-add`，不落盘）。
- `systemd/ssh-agent.service`：user unit，`ExecStart=/usr/bin/ssh-agent -D -a %h/.ssh/agent.sock`。
- `install.sh`：`--agent` 装 agent unit。

## 约定
- **改这四个工具请在本仓库改，push 后再拷到 `~/.local/bin`**（不要直接改 `~/.local/bin`）。
- README 与脚本**保持脱敏**：示例主机写 `linux-host` / `win-host`，不写真实别名、IP、用户名。
- 一律显式落 bash（远端登录 shell 可能是 zsh）：`rsh`/`sess` 已内置 `bash --noprofile --norc`。
- `rsh` 远端跑 `bash --noprofile --norc`，**PATH 不含 `~/.local/bin`**，调这些工具要用绝对路径。

## 已知坑（改协议/改实现必读）
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
