# sshkit

> 让 agent 和人用 ssh 都不再别扭的四个单文件小工具。

远程执行有两个反复出现的痛点：**引号解析**和**进程启动开销**。`ssh host '<cmd>'` 要过两层 shell（本地一层、远端一层），每加一个引号都得猜一次远端是怎么解析的；Windows 更糟，默认 shell 是 PowerShell 时每条命令固定烧掉 ~400ms 在进程启动上，而且嵌套 `pwsh`/`cmd` 的退出码还会被吞掉。

sshkit 把这两件事一起解决了：

- **`rsh`** —— Linux/POSIX 目标：命令本地 base64，远端解码执行，引号/换行/中文零转义；强制落到 bash（远端登录 shell 是 zsh 也不怕）。
- **`wsh`** —— Windows 目标：脚本 base64 交给**默认 shell 本进程**执行，不嵌套子进程，退出码如实透传。
- **`sess`** —— 常驻远端会话：`cd`、环境变量、函数跨命令保留，一条命令固定 ~45ms（Windows 从 400ms 降到 47ms）。
- **`ssh-unlock`** —— 幂等解锁常驻 ssh-agent，口令只经环境变量过一遍，不落盘。

零第三方依赖：三个 POSIX sh 脚本 + 一个 Python 3 标准库脚本。

```
bin/rsh           POSIX 目标外壳（bash 语义 + base64 传输）
bin/wsh           Windows 目标外壳（pwsh 语义 + base64 传输）
bin/sess          常驻会话守护（每 host 一个 keeper + unix socket）
bin/ssh-unlock    无交互解锁 ssh-agent
systemd/ssh-agent.service
install.sh
```

## 30 秒上手

```sh
git clone https://github.com/SQL0106/sshkit.git && cd sshkit
./install.sh --agent          # 装四个工具 + 启用常驻 ssh-agent

# 然后就可以：
rsh linux-host 'uname -a'
wsh win-host '$PSVersionTable.PSVersion.ToString()'
rsh --sess linux-host 'cd /var/log; pwd'   # 下一条命令仍在 /var/log
```

`install.sh` 装完会打印建议追加到 `~/.ssh/config` 的 `Host *` 配置块（开 ControlMaster 后单条 ssh 从 ~227ms 降到 ~15ms）和建 `~/.ssh/cm` 的提示。

## 选哪个

| 场景 | 用什么 | 典型耗时 |
|---|---|---|
| Linux 单条命令 | `rsh host '<cmd>'` | ~33 ms |
| Windows 单条命令 | `wsh host '<pwsh>'` | ~460 ms |
| 需要保留 `cd`/env/函数，或连续多条 | `rsh --sess host '<cmd>'` / `wsh --sess host '<pwsh>'` | ~45 ms/条 |
| 整段本地脚本 | `rsh -f host ./script.sh` | 一条 ssh |
| 交互登录 | `rsh host` | — |
| 原生 shell（zsh/fish） | `rsh -n host '<cmd>'` | ~33 ms |

一句话：**Windows 必用 `--sess`；Linux 单条命令用 `rsh`，批处理或需要状态才上 `--sess`。**

## rsh

```sh
rsh host 'uname -a'                   # 远端强制 bash --noprofile --norc 解析
rsh host                              # 交互，exec bash -l
rsh -f host ./script.sh               # 本地脚本喂远端 bash -s，零转义
printf 'ls -l' | rsh -f host -        # 同上，从 stdin 读
rsh -s host 'journalctl -n 20'        # 用户命令前加 sudo -n（配 NOPASSWD 子集）
rsh -n host 'echo $ZSH_VERSION'       # 不改 shell，用远端原生 zsh/sh
rsh --sess host 'cd /etc; pwd'        # 走常驻会话
rsh --sess -f host ./script.sh        # 整段脚本送进常驻会话
```

工作方式：命令在本地 `base64 -w0`，远端拿到的只是一个 base64 串：

```sh
if command -v bash >/dev/null 2>&1; then
    bash --noprofile --norc -c 'eval "$(printf %s <B64> | base64 -d 2>/dev/null || ... -D)"'
else
    sh -c '...'
fi
```

所以**永远不存在「本地删一层引号、远端再删一层」的问题**，远端没有 bash 会自动退回 sh。`-s` 是把 `sudo -n ` 直接贴在用户命令前面（不是 `sudo -n bash -c` —— sudoers 按命令路径授权，那样请求必然失败）。

## wsh

前提：远端 OpenSSH Server 的默认 shell 已经是 PowerShell（Windows 10/11 装了 pwsh 7 即如此，用注册表 `DefaultShell` 设置）。

```sh
wsh win-host '$PSVersionTable.PSVersion.ToString()'
wsh win-host 'Get-ChildItem C:\ | Select-Object -First 3'
wsh -f win-host ./script.ps1
wsh -f win-host - < ./script.ps1
wsh --sess win-host '"cwd=" + (Get-Location).Path'
```

远端收到的命令形如 `& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('<b64>'))))` —— 命令行里不含双引号，也不启动子进程。

- **退出码**：尾部显式 `exit`，先看 `$?` 再看 `$LASTEXITCODE`，非零就原样回传。
- **编码**：PS7 设 `$PSStyle.OutputRendering="PlainText"` 去掉 ANSI；5.1 才需要显式设 `[Console]::OutputEncoding`（PS7 本来就是 UTF-8，设一次要多花 ~280ms）。
- **首连探测**：执行一次 `exit 42`，rc==42 才认为「默认 shell 是 PowerShell 且退出码可透传」，结果缓存在 `~/.cache/wsh/<host>`。
- **上限**：base64 后约 20KB（Windows 命令行长度限制）。更大的脚本先 scp 上去。

Windows 端**不需要 Git Bash**，也**不要**用 `ssh win-host 'powershell -Command ...'`：嵌套子进程的退出码会被吞成 1。

## sess

每个 host 一个 keeper 守护进程，持一条 `ssh -T`；远端是个读 stdin 的循环，每行 `<token>:<base64 脚本>`，执行完在 **stdout 与 stderr 各写一份** `__END__<token>:<rc>` 哨兵。本地客户端通过 unix socket（`~/.cache/sess/<host>.v3.sock`）用带长度前缀的帧通信：`O`=stdout、`E`=stderr、`R`=4 字节退出码。

```sh
sess run host '<cmd>'          # 自动起会话
sess run --new host '<cmd>'    # 先重建会话
sess run -v host '<cmd>'       # 打印「启动会话 / 旧代码重建」等诊断
sess list                      # host / kind / pid / 是否运行
sess stop [host]               # 关闭（省略=全部）
sess kind [--reset] <host>     # 远端是 posix 还是 windows
```

状态保留的语义：命令在远端是 `eval` 在**顶层**执行的，所以 `cd`、`export`、函数定义都会留在会话里；`exit` 会杀掉远端 shell（返回 255），下次调用自动重建 —— 这是预期行为。

### 为什么是双哨兵

`stdout` 和 `stderr` 是两条独立管道，到达顺序没有保证。如果只在 stdout 上写一个结束标记，晚到的 stderr 就会被丢掉（早期版本确实偶发丢 stderr）。现在两条流各写一份，keeper 等两路都见到哨兵才收工，rc 以 stdout 为准；同时留了 0.3s 宽限，防止用户代码 `exec 2>&1` 导致 stderr 哨兵永远不出现时卡死。

### 为什么不用 mosh / ControlPersist

- ControlMaster 省的是**握手**（227ms → 15ms），但每条命令仍要在远端启动一个 shell：Windows 上就是那 380ms。
- mosh 面向交互 TUI，不适合「拿输出 + 拿退出码 + 无 tty」的批量场景，且 Windows 端基本没有。
- sess 是把 shell **留着不退出**，所以两边都省；代价是要自己管一个守护进程（抢 socket、源码更新、类型探测，这些坑下面都列了）。

## ssh-unlock

常驻 agent 的 socket 由 `systemd/ssh-agent.service` 提供（`ExecStart=/usr/bin/ssh-agent -D -a %h/.ssh/agent.sock`）。但**私钥有口令时，agent 重启后是空的**，每次都要手输。

`ssh-unlock` 是幂等的：socket 不存在就退出；`ssh-add -l` 通过就退出；否则用 `$SSH_PASS` + `~/.ssh/askpass.sh` 无交互 `ssh-add`（`setsid -w`，确保加载完才返回）。口令只经环境变量过一遍，不写任何文件。

挂进 shell 启动（`~/.bashrc` / `~/.zshrc` 末尾）：

```sh
export SSH_ASKPASS="$HOME/.ssh/askpass.sh"
export SSH_ASKPASS_REQUIRE=force
command -v ssh-unlock >/dev/null 2>&1 && ssh-unlock
```

`~/.ssh/askpass.sh` 就两行，权限 700：

```sh
#!/bin/sh
echo "$SSH_PASS"
```

## 性能

客户端 aarch64 / Debian 13（低功耗 ARM 主机），取 6~10 次最小值：

| 操作 | 耗时 |
|---|---|
| 本机 `bash -c true`（基线） | 2.9 ms |
| `ssh linux-host true`（ControlMaster 复用） | 14.9 ms |
| `ssh -o ControlMaster=no linux-host true` | 226.8 ms |
| `sess run linux-host true` | 43.9 ms |
| `rsh linux-host true` | 33.1 ms |
| `ssh win-host '1'`（裸 pwsh 启动） | 399 ms |
| `ssh win-host '1'`（profile 加非交互守卫前） | 1250 ms |
| `sess run win-host '1'` | **47.2 ms（8.7×）** |
| `wsh --sess win-host '1'` | 59.2 ms |

## 安装

```sh
./install.sh                     # 四个工具 → ${SSHKIT_BIN:-~/.local/bin}
./install.sh --agent             # 外加 systemd user unit 并 enable --now
SSHKIT_BIN=/usr/local/bin ./install.sh   # 换安装目录
```

配合的 `~/.ssh/config`（ControlMaster 是「单条命令 15ms」的关键）：

```
Host *
    IdentityAgent ~/.ssh/agent.sock
    AddKeysToAgent yes
    ControlMaster auto
    ControlPath ~/.ssh/cm/%C
    ControlPersist 30m
    ConnectTimeout 15
    StrictHostKeyChecking accept-new
```

第一次要 `mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm`。

卸载：删掉 `~/.local/bin/{rsh,wsh,sess,ssh-unlock}`，`systemctl --user disable --now ssh-agent`，再删 `~/.cache/sess`、`~/.cache/wsh`。

## 远端要求

| 目标 | 要求 |
|---|---|
| Linux / Android / macOS | OpenSSH Server；有 bash 最好（没有则退回 sh，`rsh -n` 直接用原生 shell） |
| Windows | OpenSSH Server（`Add-WindowsCapability -Online -Name OpenSSH.Server*`）；默认 shell 设为 PowerShell 7（`New-ItemProperty ... DefaultShell`）；不需要 Git Bash |

## 故障排查

| 症状 | 原因 / 处理 |
|---|---|
| `sess run` 返回 255 | 上一条命令里有 `exit`，会话已死；再执行一次即自动重建 |
| `sess run` 立刻 rc=1 且**零输出** | 类型缓存中毒（早期探测失败被存成 `windows`）→ `sess kind --reset <host>`；看 `~/.cache/sess/<host>.v3.log` 里的 `write failed: BrokenPipeError` |
| 某 host 突然从 45ms 变几百 ms | 改过 `sess` 源码但旧 keeper 还在；源码 `mtime:size` 指纹不符会自动退役，仍不生效就 `sess stop <host>` |
| `cd`/环境变量「莫名丢失」 | 曾有多个 keeper 抢同一 socket（已用 pid 文件 + `flock` 修掉）；确认 `sess list` 里同一 host 只有一个 pid |
| `sess run` 报 `No route to host` | 对端机器没开机/不在网，不是工具问题；`ping` 验证 |
| 中文乱码 | Windows 端确认 `$PSStyle.OutputRendering`/编码设置；Linux 端确认 `LANG` |
| `wsh` 首连报「默认 shell 不是 PowerShell」 | 远端 `DefaultShell` 指向 `cmd.exe` 或 5.1；改成 pwsh 7 的绝对路径后重试 |
| 远端 `sess: command not found` | `rsh` 远端跑 `bash --noprofile --norc`，PATH 不含 `~/.local/bin` → 用绝对路径，或装到 `/usr/local/bin` |

状态与缓存：

```
~/.cache/sess/<host>.v3.{sock,pid,kind,log}   keeper 的 socket / pid / 类型 / 日志
~/.cache/sess/<host>.{sig,lock}               源码指纹、启动互斥锁
~/.cache/wsh/<host>                           wsh 首连探测结果
~/.ssh/cm/<hash>                              ControlMaster 复用 socket
```

改 `sess` 的协议时把 `PROTO` 改一下（当前 `.v3`），旧 keeper 的 socket 名自然失效。

## 踩过的坑（都已在代码里处理）

- **远端登录 shell 可能是 zsh**，而模型/脚本的默认知识是 bash（`${a%%b}`、`[[ ]]`、数组、`set -e` 行为都有差异）→ `rsh`/`sess` 一律显式 `exec bash --noprofile --norc`；要原生 shell 才用 `rsh -n`。
- **Windows 下嵌套 `powershell`/`cmd` 的退出码一律被吞成 1**，只有本进程 `exit` 才透传；`powershell -Command -` 读 stdin 也是 rc=1 → `wsh` 只让默认 shell 本进程执行。
- **非交互 ssh 会话也会加载 Windows 的 `$PROFILE`**（oh-my-posh、Terminal-Icons 会把 `Get-Item`/`Get-ChildItem` 包成函数）：错误信息带 profile 行号、单条命令多花 ~500ms → 在 profile 里加守卫 `if ([Console]::IsOutputRedirected) { return }`。
- **PowerShell `$?` 陷阱**：点源嵌套 scriptblock 后 `$?` 恒为 True（只反映 dot-source 本身）→ `sess` 在用户代码后追加一行捕获 `$?`/`$LASTEXITCODE`，并在每条命令前重置 `$LASTEXITCODE`。
- **`exit` 会杀掉常驻 shell**（rc=255），下次自动重建。
- **keeper 抢同一 socket**：`serve()` 无条件 `unlink` 再 bind 时，第二个 keeper 抢走 socket，旧 keeper 退出时又把新 socket 删掉 → 已用 pid 文件 + `flock` + 校验 pid 后再删。
- **改了源码旧 keeper 还在服务**（45ms 突然变几百 ms）→ `<host>.sig` 存源码 `mtime:size` 指纹，不符则自动退役重建。
- **类型缓存会中毒**：探测失败曾被静默写成 `windows`，之后 Linux 机被按 pwsh 协议戳（rc=1 且零输出）→ 探测失败不再落缓存，并可 `sess kind --reset <host>`。
- **写管道失败不会直接吞掉**：远端已死时 `stdin.write` 抛 `BrokenPipeError`，`run()` 会 kill 后 respawn 重试一次，而不是把错误丢给调用方。
- **`sess stop` 曾要等 30s**：Linux 上其他线程 close 监听 socket 唤不醒阻塞的 `accept()` → 改成 `settimeout(0.25)` 轮询标志位，现在 0.13s。

## 许可

个人工具，WTFPL。
