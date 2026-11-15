# POSIX wsh/sess 修 Windows 坑 — 进度

## 目标
把 `origin/windows-port` 分支上 PowerShell 原生 Windows 客户端（`win/`）在真 Windows 上实测出的三个坑，移植修回 POSIX 版的 `bin/wsh`（POSIX sh）与 `bin/sess`（Python 3）。

分支：`wsh-posix-fixes`（从 `origin/master` 开，不推 master）。
范围：只改 `bin/wsh`、`bin/sess`、`README.md`、`AGENTS.md`、新增 workflow。未改 `win/**`。

## TODO

### 修复 1：`bin/wsh` 远端输出编码无条件 UTF-8 —— 完成
- [x] PROLOGUE 无条件设 `[Console]::OutputEncoding` 与 `$OutputEncoding` = UTF-8（无 BOM）
- [x] `$PSStyle.OutputRendering = "PlainText"` 保留但 try/catch 且仅 ≥7 时设
- [x] 本机用本地 pwsh 7 跑 PROLOGUE 验证语法与 UTF-8 输出（`e4b8ad e69687` = 中文）

### 修复 2：`bin/sess` Windows 目标单哨兵 —— 完成
- [x] `PWSH_LOOP` 开头加 `try { [Console]::SetError([Console]::Out) } catch {}`
- [x] 用户代码执行行改成 `. ([scriptblock]::Create($src)) 2>&1`
- [x] 删掉写 stderr 哨兵的两行
- [x] `Keeper.reset()`：`pending` 只在 `self.kind == "posix"` 时加 `"err"`
- [x] `Keeper.run()` 收尾：stdout 哨兵到但 stderr 没来（0.3s 宽限）→ 用 stdout 的 rc、`self.dead = True` + kill 进程
- [x] PWSH_LOOP 加 `[Console]::OutputEncoding`（pwsh 7 管道同样按码页编码，不加中文变 `?`）
- [x] 文档写明代价：Windows 目标 sess 的 stderr 并到 stdout（README + AGENTS.md）

### 修复 3：`bin/sess` 就绪前不暴露 socket —— 完成
- [x] `Keeper.serve()`：spawn 成功后才 bind/chmod/listen/写 pid+sig；spawn 失败清残留并退出；bind 失败（被抢先）让位并 kill 自己的子进程
- [x] `spawn_keeper()` 返回 `(socket, Popen)`；`connect()` 改成截止时间重试（`READY_TIMEOUT + 15`），keeper 提前退出立刻返回

### 可选加固 —— 完成
- [x] `PWSH_LOOP` 读到的行先 `[regex]::Replace($line, '^[^0-9A-Fa-f]+', '')` 剥 BOM 前导

### 附带（为了 POSIX sess 能在 Windows 上跑）
- [x] `fcntl` 缺失时用 `msvcrt.locking` 兜底（`_lock_file` / `_unlock_file`）
- [x] `pid_alive()`：Windows 上 `os.kill(pid, 0)` 会 TerminateProcess，改用 OpenProcess/GetExitCodeProcess；`kill_pid()` 用 TerminateProcess
- [x] 去掉 `/proc/<pid>`、`signal.SIGKILL` 的硬依赖（`hard_stop` / `cmd_list`）
- [x] `main()` 把 stdout/stderr reconfigure 成 UTF-8（Windows 管道默认码页，中文诊断会 UnicodeEncodeError）
- [x] `bin/wsh` 探测用的 `timeout` 加退化（Git Bash 可能没有 coreutils timeout）
- [x] **Windows 没有 `socket.AF_UNIX`**（CI 实测 CPython 3.12：`hasattr(socket,"AF_UNIX") == False`，
      run 43717409653 里 `sess run` 直接 `AttributeError`）→ 本地传输分叉：
      `listen_sock()` 绑 `127.0.0.1:0`、`publish()` 把端口 + 一次性 token 写 `<host>.v3.port`（0600）、
      `dial()` 读该文件连回并发 token 行、`published()` 判文件存在；keeper 侧 `handle()` 在 Windows 先校验 token。
      `fcntl.flock` → `msvcrt.locking` 实例锁（`<host>.v3.lock`）同时补上，避免两 keeper 抢同一端口。
- [x] 文档同步：`bin/sess` 模块 docstring、README（sess 段）、AGENTS（socket 帧格式那条）都写了 TCP+token 兜底

## 验证

### 本机（Fedora，POSIX 路径不回归）—— 全部通过
- [x] `bin/sess run server 'cd /etc; pwd'` → `/etc`；再 `bin/sess run server 'pwd'` → `/etc`（状态保持）
- [x] `bin/sess run server 'echo out; echo err >&2; false'` → rc=1，out/err 分列；`2>/dev/null` 时只剩 `out`
- [x] 错位路径：`bin/sess run server 'exec 2>&1; echo merged; false'` → rc=1，下一条命令正常（会话重建）
- [x] `bin/sess list` / `bin/sess stop server` 正常
- [x] `bin/wsh --shell cmd fedora 'echo passthrough-ok'` → passthrough-ok（Linux 主机 cmd 透传路径不回归）
- [x] `bin/rsh server 'uname -s'` → Linux
- [x] 本地 pwsh 7 跑 `bin/wsh` 的 PROLOGUE + `"中文-" + (1+1)` → `中文-2`（UTF-8 字节 `e4b8ad...`）
- [ ] `bin/wsh --shell pwsh fedora` **不可用**：wsh 面向 Windows，`--shell pwsh` 会构造 `pwsh.exe`，
  Linux 上只有 `pwsh` → `bash: pwsh.exe: command not found`。这是既有行为（不是本次改动引入），
  所以改用上面的本地 pwsh + PROLOGUE 直测，真 Windows 路径交给 CI。

### Windows 目标（新 job，`.github/workflows/windows-posix.yml`，Git Bash 跑 POSIX `bin/wsh`/`bin/sess`）
- [x] 开 sshd（抄 `origin/windows-port:.github/workflows/windows.yml` 已验证步骤，DefaultShell=pwsh 7，Host 别名 `localhost win-host`）
- [x] 用例：`wsh kind`、`wsh --direct` 中文/退出码、`--shell ps5`/`--shell cmd`、默认 sess 路径中文与状态保持、sess 直接调用（状态/退出码/失败后仍可用）、stderr 并入 stdout、`sess list`/`stop`
- [x] 步骤内先 `sed -i 's/\r$//'` 防 CRLF；Python 探测 `python|python3|py`；给 wsh 放 `$HOME/.local/bin/sess` 包装器
- [ ] CI 实跑结果见下方「状态记录」

## 状态记录
- 2026-11-15 开工：worktree 在 `windows-port`，已切到 `wsh-posix-fixes`（基于 `origin/master`）。
- 2026-11-15 三条修复 + Windows 兼容垫片 + 文档 + 新 workflow 完成；本机 POSIX 验证全通过。
- 2026-11-15 首轮 CI：sshd 步骤因 `Host localhost win-host` 缺 `HostName` 失败（`Could not resolve hostname win-host`），已补 `HostName localhost` 并 push（67e9a56）。
- 2026-11-15 第二轮 CI（43717409653）：`bin/wsh` 四项（kind / --direct 中文 / 退出码 / ps5 / cmd）全部 PASS；
  `bin/sess` 在 `run` 处 `AttributeError: module 'socket' has no attribute 'AF_UNIX'` → 实现 TCP+token 兜底（见上）。
- 2026-11-15 第三轮 CI（43717707650，25fa448）：TCP 兜底生效（无 AttributeError，中文/退出码都对），
  但 **状态保持全挂**（第二次 `(Get-Location).Path` 回到 `C:\Users\runneradmin`），stderr 用例输出空，
  `sess stop` 后残留一个 keeper。
  定位：`read_line()` 一次 `recv(65536)` 再截到第一个换行 —— Windows TCP 回退上客户端连发
  「token 行 + 脚本行」，两行常落在同一个 recv 里，脚本那半截被当垃圾丢掉 ⇒ keeper 等不到第二行
  ⇒ `healthy()` 探活超时 ⇒ `hard_stop()` ⇒ 每条命令都重建会话（状态全丢、stop 与残留互踩）。
- 2026-11-15 修复：`read_line()` 改逐字节 `recv(1)`（永不越界），CI 里给会话测试加 `-v` 并打印 keeper 日志。
- 2026-11-15 第四轮 CI（43717977825，8d8adbd）：**全绿，失败数 0**。19 项 PASS，keeper 只 `keeper up` 一次
  （无 respawn / bad token / handle error），`sess stop` 后无残留。

## 最终状态
- 分支 `wsh-posix-fixes`，HEAD `8d8adbd`（后续只追加本文档与 PROGRESS 更新）。
- 三条修复 + Windows 兼容垫片 + 文档 + 新 workflow 全部完成，Windows CI 全绿。
- 既有 `windows.yml` / `windows-exe.yml` 只存在于 `origin/windows-port`，本分支自 master 开出、
  不含这两个文件，也未改 `win/**` ⇒ 与它们互不影响。
