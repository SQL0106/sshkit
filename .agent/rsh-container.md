# rsh 容器直连（droidspaces）— 任务规格与实测记录

## 目标
`rsh <host>` **默认停在宿主 shell（Android）**，不探测、不擅自进容器；
需要进 droidspaces 容器时用 `-C` / `-c <名>`，或直接连容器自己 sshd 的别名（首选）。

## 规格（用户给定）
- 映射文件 `~/.config/sshkit/containers`：`<host><空白><容器名>[<TAB><droidspaces 路径>]`，
  `#` 注释、空行忽略；容器名可含空格（取到 TAB 或行尾）。
- 进容器三选一（用户最终要求，原话：「rsh realme默认应该连接的是Android shell，
  需要加参数进container，或者搞别名专门进Container」）：
  1. 容器 sshd 独立别名（首选，`scp`/`sess` 全语义）；
  2. `rsh -C <host> ...`：有映射用映射，否则现探宿主 droidspaces；单容器自动进；
  3. `rsh -c '<容器名>' <host> ...`：优先于映射。
- 命中时远端命令：
  - 普通命令：`<ds> -n '<容器>' run -- bash --noprofile --norc -c '<base64 eval 串>'`
  - `-f <file>` / `-f -`：`<ds> -n '<容器>' run -- bash --noprofile --norc -s`，脚本走 stdin
  - 交互（无参数）：`<ds> -n '<容器>' run -- bash -l`（`enter` 在管道 stdin 下会挂住，弃用）
- 逃生口：`-H` / `--host-shell` / `RSH_HOST_SHELL=1` → 强制宿主 shell（默认已是宿主）。
- 旧自动行为（单容器自动进）保留在 `RSH_AUTODETECT=1`，默认关闭。
- 容器模式跳过宿主 PATH / agent 前导（容器里没有那套东西，探测只会误报）
- `--sess` + 容器包装 → `exit 2` + 提示（keeper 在宿主；需要 sess 用容器 sshd 别名）
- 文档脱敏（`linux-host` / `debian-13`，不写真实别名/IP/用户名）

## 已知事实（已实测，勿重复调研）
- droidspaces v7.1.0，固定路径 `/data/local/Droidspaces/bin/droidspaces`（不在 PATH），
  **没有 `list`**；`show` 输出 UTF-8 制表框（NAME/PID 列），`awk -F'│'` 解析可靠。
- 容器名可带空格；`run` 靠全局 `-n NAME` 选容器，`run --` 只管命令。
- `run` 透传退出码；stdin 可穿透 `bash -s`；`droidspaces enter` + 管道 stdin 会挂住。
- 容器自己跑 sshd 时，宿主 8022 / 容器 22，两者可同时存在，别名直连最快。

## 实现（bin/rsh）
- `usage()`：awk 提取头部连续 `#` 行（不再写死行号）。
- 变量：`CONTAINERS_FILE`（`SSHKIT_CONTAINERS`）、`DS`（`RSH_DROIDSPACES`，默认
  `/data/local/Droidspaces/bin/droidspaces`）、`CACHE_DIR`（`SSHKIT_CACHE_DIR`，
  默认 `~/.cache/sshkit`）、`CACHE_FILE=<cache>/<host 净化>.container`。
- `container_lookup host`：awk 跳过注释/空行，`$1==host` 时按**最后一个 TAB** 拆
  名字/路径（名字可含空格，tab 也可作 host 与名字的分隔）→ `名字\t路径`。
- `probe_remote()`：一次 `ssh -T` 拿回 droidspaces 路径 + `show` 的 base64；输出
  `@@none`（宿主没有）/ `@@bin\t<path>` + b64；rc 0/1/2。本地解析 `NAME/PID` 行。
- `cache_write()`：mkdir + 临时文件 + mv；内容 `名\t路径` 或 `none`。
- **容器块只在需要时执行**：`-c` / `RSH_CONTAINER` / `-C` / `RSH_AUTODETECT=1`
  任一成立且不是 `-H` / `containers` 子命令；否则完全走原来的宿主逻辑。
- 解析顺序：`-c`/`RSH_CONTAINER` → 映射 → 缓存（`-R` 跳过）→ 现探
  （单容器自动缓存并进；0 容器/无 droidspaces 写 `none`；ssh 失败不缓存）。
  `-C` 下探不到时直接 stderr 报错 `exit 2`，不会静默落回宿主。
- `rsh containers <host>`：强制现探并刷新缓存（无 droidspaces/连不上 exit 3）。
- `shq()`：单引号引用（值含 `'` 直接 exit 2）；`cprefix()`：`<ds> -n <名> run --`。
- 分支插入点：file / 交互 / 普通 exec 三处，均跳过 path/agent 前导。

## 实测记录（oneplus8 → realme，2026-11-06）

默认宿主（不探测）：
```
$ rsh realme 'getprop ro.build.version.release; echo HOSTNAME=$(hostname)'
16
HOSTNAME=localhost
```
显式进容器：
```
$ rsh -C realme 'head -1 /etc/os-release; hostname'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
Debian-13
```
`rsh containers realme`（首次探测 164 ms）：
```
droidspaces: /data/local/Droidspaces/bin/droidspaces
  Debian 13                pid=624
已缓存：下次 rsh -C realme ... 直接进该容器（-R 刷新）
```
耗时（`date +%s%N`）：`-C` 稳态 **90–92 ms**，首条 552 ms（冷连接）；
`rsh containers` 首次 164 ms、`-R` 234 ms；宿主基线 46–84 ms；容器 sshd 别名首条约 658 ms（冷）。

`-f -`（中文/单双引号/反引号/管道）→ 原样输出，rc=0
`-f <本地脚本>` → 容器内输出 + 退出码透传
`-s 'id -u'` → `0`；复合命令被 `-s` 规约拦下 rc=2
`-c '<名>'` 覆盖坏映射 → 容器；映射 + `-C` → 容器；映射不加 `-C` → 宿主
`-n` → 容器内 `$0=sh`；`--sess` + 容器 → rc=2
交互（pty）：`$0=bash`、hostname 容器名、PID1 `systemd`，正常 logout
多容器分支用本机 fake `droidspaces show`（`RSH_DROIDSPACES` 指向它）验证：
列候选 exit 2；`rsh containers` exit 3

## 已知限制
- `--sess` 不可与容器包装同用（keeper 在宿主）；用容器 sshd 别名可解。
- 包装模式每条命令多一层 `droidspaces run`，但仍 ~90 ms。
- 只处理 `run --`，未用 `enter`（管道 stdin 会挂）。
- 容器不存在时错误由 droidspaces 原样透出（不预检容器名）。
- 裸 `rsh host` 不探测；想恢复旧行为设 `RSH_AUTODETECT=1`。

## 容器 sshd、端口与开机自启

- 容器里的 sshd 是容器自带的 systemd `ssh.service`（enabled），**容器起来才有 22 端口**；
  Android 的 sshd 是另一套（实测 8022）。两者 `net_mode=host` 共享 netns，不能同占一个端口。
- 要重启后仍能直连：把容器 `container.config` 的 `run_at_boot` 改 `1`（改前备份；
  文件头注明可能被自动重写）。droidspaces 的 Magisk 服务会等 `sys.boot_completed` 和网络就绪后
  自启所有 `run_at_boot=1` 的容器，日志 `/data/local/Droidspaces/Logs/boot-module.log`。
- 若某台机 Android 先占了 22：给容器 sshd 换端口（如 2222）再配别名，或用 `rshc`（不依赖端口）。
