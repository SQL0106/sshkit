# rsh 容器直连（droidspaces）— 任务规格与实测记录

## 目标
`rsh <host>` 直接落进 droidspaces 容器执行，而不是停在 Android 宿主 shell。
容器自带 sshd 时首选它的 ssh 别名（`scp`/`sess` 全语义），droidspaces 包装是兜底。

## 规格（用户给定）
- 映射文件 `~/.config/sshkit/containers`：`<host><空白><容器名>[<TAB><droidspaces 路径>]`，
  `#` 注释、空行忽略；容器名可含空格（取到 TAB 或行尾）。
- **自动探测**（用户追加，原话：「支持自动探测，和 wsh 探测命令解释器一样，探测有没有
  droidspaces，有哪些容器」）：远端有 droidspaces 且只有一个容器 → 自动进入并缓存；
  多容器 → 列候选 exit 2；没有/连不上 → 宿主 shell。
- 命中时远端命令：
  - 普通命令：`<ds> -n '<容器>' run -- bash --noprofile --norc -c '<base64 eval 串>'`
  - `-f <file>` / `-f -`：`<ds> -n '<容器>' run -- bash --noprofile --norc -s`，脚本走 stdin
  - 交互（无参数）：`<ds> -n '<容器>' run -- bash -l`（`enter` 在管道 stdin 下会挂住，弃用）
- 逃生口：`-H` / `--host-shell` / `RSH_HOST_SHELL=1` → 直落 Android shell
- 容器模式跳过宿主 PATH / agent 前导（容器里没有那套东西，探测只会误报）
- `--sess` + 容器包装 → `exit 2` + 提示（keeper 在宿主；需要 sess 用容器 sshd 别名）
- 文档脱敏（`linux-host` / `debian-13`，不写真实别名/IP/用户名）

## 已知事实（已实测，勿重复调研）
- droidspaces v7.1.0，固定路径 `/data/local/Droidspaces/bin/droidspaces`（不在 PATH），
  **没有 `list`**；`show` 输出 UTF-8 制表框（NAME/PID 列），`awk -F'│'` 解析可靠。
- 容器名可带空格；`run` 靠全局 `-n NAME` 选容器，`run --` 只管命令。
- `run` 透传退出码；stdin 可穿透 `bash -s`；`droidspaces enter` + 管道 stdin 会挂住。

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
- 解析顺序：`-H`/env → 宿主；`-c`/`RSH_CONTAINER`；映射；缓存（`-R` 跳过）；
  现探（单容器自动缓存；0 容器/无 droidspaces 写 `none`；ssh 失败不缓存）。
- `rsh containers <host>`：强制现探并刷新缓存（无 droidspaces/连不上 exit 3）。
- `shq()`：单引号引用（值含 `'` 直接 exit 2）；`cprefix()`：`<ds> -n <名> run --`。
- 分支插入点：file / 交互 / 普通 exec 三处，均跳过 path/agent 前导。

## 实测记录（oneplus8 → realme，2026-11-06）

自动探测首次（`rsh containers realme`，空缓存）：**164 ms**
```
droidspaces: /data/local/Droidspaces/bin/droidspaces
  Debian 13                pid=624
已缓存：下次 rsh realme 自动进该容器（-R 刷新，-H 回宿主）
```

无映射、空缓存第一条命令（含探测）：**296 ms**
```
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
Debian-13
0
systemd
```
之后稳态 **88–101 ms**（宿主 `rsh server` 46–84 ms）。

`rsh -H realme 'getprop ro.build.version.release'` → `16` / `host=localhost`（宿主）**166 ms**
`rsh -f realme -`（中文/单双引号/反引号/管道）→ 原样输出，rc=0
`rsh -f realme <本地脚本>` → 容器内输出 + 退出码 3 透传
`rsh -s realme 'id -u'` → `0`；复合命令被 `-s` 规约拦下 rc=2
`rsh -c 'Debian 13' realme ...` / `rsh -n realme`（sh）/ `--sess` 冲突 rc=2 均通过
映射含 TAB 路径、宿主未命中（server → Linux/oneplus8 + `none` 缓存）通过
`RSH_AUTODETECT=0` 无映射 → 宿主 shell（Android 16）
多容器分支用本机 fake `droidspaces show`（`RSH_DROIDSPACES` 指向它）验证：
列候选 exit 2；`rsh containers` exit 3
交互（pty）：`$0=bash`、hostname `Debian-13`、PID1 `systemd`，正常 logout
`-R` 强制刷新 **234 ms**；`sh -n bin/rsh` OK

## 已知限制
- `--sess` 不可与容器包装同用（keeper 在宿主）；用容器 sshd 别名可解。
- 自动探测每台机首次多一次 ssh（之后走缓存）；`RSH_AUTODETECT=0` 可彻底关闭。
- 只处理 `run --`，未用 `enter`（管道 stdin 会挂）。
- 容器不存在时错误由 droidspaces 原样透出（不预检容器名）。
