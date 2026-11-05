# sshkit

> 让 agent 和人用 ssh 都不再别扭的四个单文件小工具。

远程执行有两个反复出现的痛点：**引号解析**和**进程启动开销**。`ssh host '<cmd>'` 要过两层 shell（本地一层、远端一层），每加一个引号都得猜一次远端是怎么解析的；Windows 更糟，默认 shell 是 PowerShell 时每条命令固定烧掉 ~400ms 在进程启动上，而且嵌套 `pwsh`/`cmd` 的退出码还会被吞掉。

sshkit 把这两件事一起解决了：

- **`rsh`** —— Linux/POSIX 目标：命令本地 base64，远端解码执行，引号/换行/中文零转义；强制落到 bash（远端登录 shell 是 zsh 也不怕）。
- **`wsh`** —— Windows 目标：脚本 base64 交给**远端默认解释器**（pwsh / 5.1 / cmd 均可，可 `--shell` 切换）执行，退出码如实透传。
- **`sess`** —— 常驻远端会话：`cd`、环境变量、函数跨命令保留，一条命令固定 ~45ms（Windows 从 400ms 降到 47ms）。
- **`ssh-unlock`** —— 幂等解锁常驻 ssh-agent，口令只经环境变量过一遍，不落盘。

零第三方依赖：三个 POSIX sh 脚本 + 一个 Python 3 标准库脚本。

```
bin/rsh           POSIX 目标外壳（bash 语义 + base64 传输）
bin/wsh           Windows 目标外壳（pwsh / 5.1 / cmd 三解释器 + base64 传输）
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
| **Windows 任何命令** | **`wsh host '<pwsh>'`**（默认走 sess 常驻会话） | **~70-120 ms** |
| Windows 强制一次性 ssh | `wsh --direct host '<pwsh>'` | 握手 0.4 s ～ 30 s |
| Windows 换解释器（5.1 / cmd） | `wsh --shell ps5 host '<ps>'` / `wsh --shell cmd host '<cmd>'` | ps5 ~370 ms / cmd ~90 ms |
| 需要保留 `cd`/env/函数（Linux） | `rsh --sess host '<cmd>'` | ~45 ms/条 |
| 整段本地脚本 | `rsh -f host ./script.sh` / `wsh -f host ./script.ps1` | 一条命令 |
| 交互登录 | `rsh host` / `wsh host` | — |
| 原生 shell（zsh/fish） | `rsh -n host '<cmd>'` | ~33 ms |

**硬规则（不要自行发挥）：**
1. 目标是 Windows → **只写 `wsh`**，不要手写 `ssh host 'powershell ...'`：嵌套子进程的退出码会被吞成 1。
2. 目标是 Linux → 单条 `rsh`；要保留状态或连续多条 → `rsh --sess`。
3. `wsh` 默认走 sess。**唯一的故障模式是 keeper 变陈旧**（现象：每条命令几十秒，实测过 147 s）。诊断只需两步：`sess run <host> 1` 连跑两次看第二次耗时 → 慢就 `sess stop <host>` 重建，之后再试一次。**不要因此退回裸 ssh。**
4. 觉得慢或行为怪 → `sess stop <host>` 让它重建，再测；不要退回裸 ssh。
5. 批量/长脚本优先 `-f <脚本>`，别把几十行塞进命令行（20 KB 上限）。

## rsh

```sh
rsh host 'uname -a'                   # 远端强制 bash --noprofile --norc 解析
rsh host                              # 交互，exec bash -l
rsh -f host ./script.sh               # 本地脚本喂远端 bash -s，零转义
printf 'ls -l' | rsh -f host -        # 同上，从 stdin 读
rsh -s host 'journalctl -n 20'        # 用户命令前加 sudo -n（只接受单条命令，配 NOPASSWD 子集）
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

所以**永远不存在「本地删一层引号、远端再删一层」的问题**，远端没有 bash 会自动退回 sh。

`-s` 是把 `sudo -n ` 直接贴在用户命令前面（不是 `sudo -n bash -c` —— sudoers 按命令路径授权，那样请求必然失败）。因此 `-s` 只接受**单条命令**：出现未转义的 `;`、`&&`、`|` 或换行会直接 `exit 2` 并提示改用 `rsh -f`（脚本里自己写 `sudo -n`）。旧版对复合命令只给第一段加 sudo，`sudo: a password is required` 会和后续输出混在一起，极易误判 —— 这个模糊行为已删除。`find ... \;` 里的转义分号仍放行。

> 守卫是**保守**的：本地不做 shell 解析，`grep 'a|b'` 这类引号内含有 `;`/`|`/`&&` 的单条命令也会被拦（exit 2），**属预期行为，不是 bug**。理由与被拦后的出路见 [已知限制](#已知限制)。

远端还有两件事在同一条远端命令里顺带处理（**不增加 ssh 往返**）：

- **PATH**：非 `-n` 模式把 `$HOME/.local/bin`（存在时）前置到 PATH，自己装的工具不再 `command not found`。`-n` 保持远端原生 shell 语义不动。
- **ssh-agent 自愈**：命令文本涉及 `git` / `ssh` / `scp` / `sftp` / `rsync` 时，先跑一次 `ssh-add -l`（约 +10 ms）：
  - rc=0：agent 已就绪，直接放行；
  - rc=1：agent 活着但没身份 → 调 `~/.local/bin/ssh-unlock`，必要时借 `bash -ic` 从登录环境取 `SSH_PASS` 再解锁；
  - rc=2：socket 陈旧 / agent 已死 → `rm -f` 陈旧 socket → `systemctl --user restart ssh-agent`（无 systemd 时 `ssh-agent -a`）→ 等 agent 起来再解锁。

  失败一律静默降级（命令照常执行），只在 stderr 打一行可诊断提示。开关：`RSH_AGENT=auto|always|off`（默认 `auto`；`off` 表示本地远端都不碰），`RSH_NO_AGENT_FIX=1` 彻底关闭。口令只存在于远端登录环境，从不进命令行、不落盘。指向转发 agent 的 `SSH_AUTH_SOCK` 绝不删除或重启。

  **自动探测有边界**（刻意取舍，不是缺陷）：只认命令文本里的 `git`/`ssh` 等字样，`rsh -f host -` 走 stdin 时不探测，远端解锁还依赖登录环境的 `SSH_PASS`。逐条说明与兜底（`RSH_AGENT=always`）见 [已知限制](#已知限制)。

这也是「远端 `git clone` 莫名其妙 `Permission denied (publickey)`」的真因：agent 死了但 `~/.ssh/agent.sock` 还在，`~/.ssh/config` 的 `IdentityAgent` 指向这个死 socket。

## wsh

前提：远端 OpenSSH Server 的默认 shell 可以是 **pwsh 7 / Windows PowerShell 5.1 / cmd.exe** 中的任意一种（注册表 `DefaultShell` 设置）。`wsh` 首次连接时自动探测并缓存，也可以显式切换解释器。

```sh
wsh win-host '$PSVersionTable.PSVersion.ToString()'   # 默认 shell（自动探测）
wsh win-host 'Get-ChildItem C:\ | Select-Object -First 3'
wsh -f win-host ./script.ps1
wsh -f win-host - < ./script.ps1
wsh --sess win-host '"cwd=" + (Get-Location).Path'

wsh kind win-host                 # 探测远端默认解释器：pwsh / ps5 / cmd
wsh kind --reset win-host         # 丢掉缓存重新探测
wsh --shell ps5 win-host 'Get-WmiObject Win32_OperatingSystem'
wsh --shell cmd win-host 'dir /b C:\'
wsh --cmd win-host 'echo %COMPUTERNAME%'     # 等价写法
```

远端收到的命令形如 `& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('<b64>'))))` —— 命令行里不含双引号，也不启动子进程。

> **不要写 `.ps1` 文件再用 `powershell.exe -File` 去执行。** `wsh` 本来就从不写文件，脚本全程内联：交互桌面里用 `powershell -File` 会弹一个蓝窗被人看到，而 `wsh` 走 ssh 的 session 0，没有任何窗口。需要多行就直接喂 stdin：
>
> ```sh
> wsh win-host -f - <<'PS'
> Get-ChildItem C:\ | Measure-Object
> "done"
> PS
> ```
>
> 只有脚本超过 ~20KB 命令行上限时才需要落文件（`scp` 到 Windows），执行仍走 `wsh host '& C:\path\x.ps1'` —— 依旧无窗口。

- **解释器**：`--shell auto|pwsh|ps5|cmd`（默认 auto = 跟随远端默认 shell）。别名：`--pwsh`/`--ps7`、`--ps5`/`--powershell`、`--cmd`。
  - 目标 == 默认 shell → 本进程执行，最快（pwsh 约 70ms/条）。
  - 跨解释器 → 起子进程：`pwsh.exe` / `powershell.exe -NoProfile -EncodedCommand <UTF-16LE base64>`，引号/换行/中文全免转义；代价是一次进程启动（ps5 约 +300ms，cmd 约 +20ms）。
  - cmd 在 PowerShell 默认 shell 下包成 `& cmd.exe /d /c '<text>'`；默认 shell 本身就是 cmd 时直接发原文（此时 sess 不支持，自动回落一次性 ssh）。
  - 子进程执行**不共享会话状态**（`cd`、`$env:` 不保留），要连续状态就整段写成 `-f` 脚本一次跑完。
- **多行 cmd**：`cmd /c` 只执行第一条命令行，`wsh` 会自动把多行折成 ` & ` 连接（因此 `goto`/label 不可用）。
- **退出码**：尾部显式 `exit`，先看 `$?` 再看 `$LASTEXITCODE`，非零就原样回传；cmd 走 `cmd /c` 的退出码。
- **编码**：输出统一强制 UTF-8，中文永远可读（中文 Windows `chcp 936` 下实测：`d6d0cec4` GBK 乱码 → `e4b8ad` UTF-8）。
  - pwsh 7：管道输出本来就是 UTF-8 no-BOM，只设 `$PSStyle.OutputRendering="PlainText"` 去 ANSI（再设一次 `Console::OutputEncoding` 要多花 ~280ms）。
  - PS 5.1：**所有路径**都会先注入 `[Console]::OutputEncoding` / `$OutputEncoding` = UTF-8（含默认 shell 就是 5.1 的快路径），所以脚本里不需要再自己写这两行。
  - cmd：命令含非 ASCII 时前置 `chcp 65001>nul`；个别完全无视控制台代码页的老程序仍会吐 GBK，用 `| iconv -f GBK -t UTF-8` 兜底。
  - 纯 ASCII 命令不触发任何额外动作，不付开销。
- **解释器探测**：`$PSVersionTable.PSVersion.Major` → `7*`=pwsh、`5*`（及更老）=ps5；不是 PowerShell 再试 `echo` → cmd。结果缓存在 `~/.cache/wsh/<host>.shell`，`wsh kind [--reset] <host>` 可查/重探。探测失败会打印两行诊断（含 `DefaultShell` 注册表修复命令）并 exit 3。
- **本地 ssh-agent**：与 `rsh` 同一套——先内联 `ssh-add -l`（约 6ms），健康就不再 fork `ssh-unlock`（省约 25ms）；`rc=2`（socket 陈旧 / agent 已死）就地 `rm -f` + 重启 + 解锁，仍失败只在 **stderr 打一行**诊断。`SSH_AUTH_SOCK` 指向别的（转发）agent 时绝不删/重启。控制：`WSH_AGENT=auto|off`（默认 auto）、`WSH_NO_AGENT_FIX=1`。
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

## 已知限制

以下六条都是**刻意的取舍或尚未验证的边界**，不是待修的 bug。若哪天看到"为什么不支持"，先回来读这一节。

### 1. 远端解锁依赖 `~/.bashrc` 导出的 `SSH_PASS`

`ssh-unlock` 用 `$SSH_PASS` 自动 `ssh-add`，而 `SSH_PASS` 通常只写在 `~/.bashrc`，非交互 shell 读不到，所以 `rsh` 的远端前导会退化到 `bash -ic 'ssh-unlock'`。

- **代价**：仅当 agent 真的缺身份时才付 0.5–0.9s（见第 2 条）。
- **口令源换成 keyring / secret 服务的机器**（`pass`、`secret-tool`、1Password CLI 等）：解锁会失败，`rsh` 只打一行提示，然后照常执行命令。
- 这是「口令不得进命令行、不得落盘」的直接后果 —— 不把口令塞进远端命令行就没有别的传法。
- 兜底：把 `SSH_PASS` 也导出到远端非交互环境（例如 `~/.profile`），或让该机的 ssh-agent 常驻并预先解锁。

### 2. `bash -ic` 慢，且依赖 `.bashrc` 可被非交互加载

- 只在**故障路径**（agent 死了/没身份）触发，健康时完全不走。
- `.bashrc` 极慢、或需要交互输入（如 `read -p`）时，解锁会超时/卡住，最终退化成"打一行提示、命令照常执行"。
- 想让 `bash -ic` 变快，就在 `.bashrc` 顶部加非交互早退守卫。

### 3. 触发探测靠命令文本正则

`(^|[^[:alnum:]_.-])(git|ssh|scp|sftp|rsync)([[:space:]]|$|-)` —— 写死的文本匹配。

- ✅ `/usr/bin/rsync …`、`sudo git clone …`、`git-lfs …` 都能中。
- ❌ 变量/别名间接调用不中：`R=git; $R clone`、`eval "$cmd"`、`sh -c 'git clone …'` 里的内层。
- 兜底：**`RSH_AGENT=always`** 无条件探测（每条命令固定 +10~15ms），或干脆常驻并预先解锁 agent。

### 4. `rsh -f host -`（stdin）默认不探测

脚本要先读进内存才能发包，读之前无法判定内容里有没有 `git`/`ssh`，所以 stdin 模式默认跳过探测。

- 兜底：`RSH_AGENT=always rsh -f host - < script.sh`。
- 有路径的 `-f host file` 和普通命令模式不受影响（照常按第 3 条判定）。

### 5. `-s` 会拦掉引号内含 `;` / `|` / `&&` 的单条命令

例：`rsh -s host "grep -E 'a|b' /var/log/x"` → exit 2。

- 原因：本地不做 shell 解析，分不清「操作符」和「引号内的字符」。放宽成"引号内放行"需要覆盖嵌套引号、`\` 转义、`awk '{print $1}'`、此处文档字符串等；一旦误判，就会把复合命令当单条命令塞给 `sudo -n`，那是真正危险的方向。
- 取舍：**宁可多拦，不可漏放**。误拦的代价只是"改用 `-f`"，漏放的代价是 sudo 语义错乱。
- 出路：`rsh -f host script.sh`（脚本里自己写 `sudo -n`），或把该模式拆成两条命令。

### 6. 平台覆盖：Linux 与 Android 实测，macOS / Windows 未实测

- **Linux（Debian 13，aarch64 主线内核 + fedora x86_64）**：已实测，`dash` / `bash` / `zsh` 语法检查通过。
- **Android（realme RMX5062，Android 16 + KernelSU，静态 OpenSSH 8022）**：已实测 —— 普通命令、`-f`（引号/管道脚本）、`-f -`、`--sess`（cwd 跨命令保留）、`-n` 全部正常；单条 69～173 ms。
  - 远端**没有 bash**，自动退到 `/system/bin/sh`（mksh 派生），`base64 -d` + `eval` 路径可用。
  - 没有 `systemctl --user`、没有 `sudo`：agent 前导只在 socket/unit 存在时才动手，此处两者都无 → 命中 `git` 等关键字时**静默跳过**；`rsh -s` 会得到 `sudo: inaccessible or not found`（rc 127），这是环境缺失，不是 `rsh` 的问题。
  - `$HOME/.local/bin` 一般不存在 → PATH 前导自然空转（该分支已用 `env -i` 隔离验证过）。
- **macOS**：未实测。前导只用 POSIX 内建 + `ssh-add` + `sleep`，不依赖 `/proc`，理论上可跑。
- **Windows（Windows 10 19044 + pwsh 7.6.9 + 5.1.19041）**：`wsh` 已实测 —— 默认（pwsh/sess）、`--shell ps5`、`--shell cmd`、`--pwsh`、`-f`/`-f -`、`--direct`、退出码透传（含 cmd `exit /b`）、引号与中文、`wsh kind` 探测/缓存/`--reset` 全部正常。
  - 单条耗时：默认 pwsh 66～96 ms，cmd 85～98 ms，ps5 332～408 ms（进程启动开销），`--direct` 约 0.7 s。
  - 已知限制：sess 模式下命令里 `exit` 会杀掉常驻 shell（rc=255，下次自动重建）；跨解释器执行不保留 `cd`/`$env:`；多行 cmd 会被折叠成 ` & `（`goto`/label 不可用）。

## 故障排查

| 症状 | 原因 / 处理 |
|---|---|
| `sess run` 返回 255 | 上一条命令里有 `exit`，会话已死；再执行一次即自动重建 |
| `sess run` 立刻 rc=1 且**零输出** | 类型缓存中毒（早期探测失败被存成 `windows`）→ `sess kind --reset <host>`；看 `~/.cache/sess/<host>.v3.log` 里的 `write failed: BrokenPipeError` |
| 某 host 突然从 45ms 变几百 ms | 改过 `sess` 源码但旧 keeper 还在；源码 `mtime:size` 指纹不符会自动退役，仍不生效就 `sess stop <host>` |
| `cd`/环境变量「莫名丢失」 | 曾有多个 keeper 抢同一 socket（已用 pid 文件 + `flock` 修掉）；确认 `sess list` 里同一 host 只有一个 pid |
| `sess run` 报 `No route to host` | 对端机器没开机/不在网，不是工具问题；`ping` 验证 |
| 中文乱码 | Windows 端确认 `$PSStyle.OutputRendering`/编码设置；Linux 端确认 `LANG` |
| `wsh` 报「无法判断 <host> 的默认 shell」 | 远端 `DefaultShell` 不可用或 OpenSSH 不通；`wsh kind --reset <host>` 重探，或直接 `wsh --shell cmd\|ps5\|pwsh` 指定解释器 |
| 远端 `sess: command not found` | 老版本的 PATH 不含 `~/.local/bin`；本版非 `-n` 模式已自动前置，仍找不到就确认远端确实存在 `~/.local/bin` |
| 远端 `git`/`ssh` 报 `Permission denied (publickey)` | 远端 ssh-agent 死了而 `~/.ssh/agent.sock` 仍是个陈旧 socket。`rsh` 在命令涉及 git/ssh 时会自动修（见上文）；被 `RSH_AGENT=off` / `RSH_NO_AGENT_FIX=1` 关掉时手工：`rm -f ~/.ssh/agent.sock && systemctl --user restart ssh-agent && ssh-unlock` |
| `rsh -s` 报「只支持单条命令」 | 复合命令（`;` `&&` `|`）改用 `rsh -f <host> <脚本>`，在脚本里自己写 `sudo -n` |

状态与缓存：

```
~/.cache/sess/<host>.v3.{sock,pid,kind,log}   keeper 的 socket / pid / 类型 / 日志
~/.cache/sess/<host>.{sig,lock}               源码指纹、启动互斥锁
~/.cache/wsh/<host>.shell                   wsh 探测到的远端默认解释器（pwsh|ps5|cmd）
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
