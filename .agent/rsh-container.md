# rsh 容器直连（droidspaces）— 任务规格与实测记录

## 目标
宿主（Android）没有容器 sshd 时，`rsh <host>` 也能自动落进 droidspaces 容器执行。
范围最小：只认显式映射文件，不做自动探测/缓存。

## 规格（用户给定，勿扩大）
- 映射文件 `~/.config/sshkit/containers`：每行 `<host><空白><容器名>`，允许 TAB，`#` 注释。
  host 未命中 → 行为与今天完全一致（向后兼容）。
- 命中时远端命令：
  - 普通命令：`<ds> -n '<容器>' run -- bash --noprofile --norc -c '<base64 eval 串>'`（复用 wrap() 的本地 base64）
  - `-f <file>` / `-f -`：`<ds> -n '<容器>' run -- bash -s`，脚本走 stdin
  - 交互（无参数）：`<ds> -n '<容器>' run -- bash -l`
- 逃生口：`-H` / `--host-shell` / `RSH_HOST_SHELL=1` → 直落 Android shell
- 容器模式跳过宿主 PATH / agent 前导
- `--sess` + 容器 → `exit 2` + 提示改用非 sess
- 同步更新 bin/rsh 头部注释与 README 对应段落；文档脱敏（`linux-host` / `debian-13`）

## 已知事实（已实测，勿重复调研）
- realme 宿主 root@192.168.1.100（`rsh realme`），PATH 仅 `/system/bin:/system/xbin`
- droidspaces 固定路径 `/data/local/Droidspaces/bin/droidspaces`（v7.1.0），无 `list`；`show` 列容器
- 容器名 `Debian 13`（带空格）；`run -- bash -s` stdin 可用，`run -- bash -c` 可用
- 已有 `realme-c` 别名直连容器 sshd（约 92ms），本任务只做兜底路径
- 工作区曾有一版 553 行草稿（自动探测 + `~/.cache/sshkit/<host>.container` 缓存 + `-c/-R/containers` 子命令），
  **违反验收第 5 条**（删映射后仍会进容器），已废弃，备份在 `~/.cache/rsh-container-draft.sh`

## 实现（bin/rsh，355 行）
- `usage()`：awk 提取头部注释块（原来 `sed -n '2,26p'` 写死行号，头部一长就截断）
- `CONTAINERS_FILE=${SSHKIT_CONTAINERS:-$HOME/.config/sshkit/containers}`、`DS=${RSH_DROIDSPACES:-/data/local/Droidspaces/bin/droidspaces}`
- `container_lookup host`：awk 跳过注释/空行，`$1==host` 时取**行内剩余全部**（容器名可含空格）→ 未命中 rc=1
- `shq()`：单引号引用，值里含 `'` 直接 exit 2
- `b64_eval()`：抽出原 wrap() 的 base64 串（无单引号）；`wrap()` 改为调用它（行为不变）
- `cprefix()`：`<shq ds> -n <shq 容器> run --`
- 分支插入点：选项解析加 `-H/--host-shell`；解析完 host 立即查映射（`host_shell` 或 `RSH_HOST_SHELL=1` 时跳过），sess 组合 exit 2；
  `mode=file` / 交互 / 普通 exec 三处各加容器分支，均在 `use_sess` 之前、在 path/agent 前导之外
- 选带 `-n '<容器>'` 的形式（不带也能跑，但多容器时歧义）

## TODO
- [x] 1. 从 HEAD 恢复 bin/rsh，去掉未提交的超范围实现
- [x] 2. 最小实现：映射解析、-H、容器 exec/-f/交互、sess 守卫
- [x] 3. bin/rsh 头部注释 + README 段落（脱敏）
- [x] 4. 写 ~/.config/sshkit/containers（realme → Debian 13）
- [x] 5. 真机验收 1-5 + `sh -n` + 耗时
- [x] 6. commit + push + install

## 实测记录

### 本地（stub ssh 拦参数，验证生成串与转义）
映射样例 `linux-host debian-13` / `android-host<TAB>Debian 13`：
- 普通命令：`ssh -T android-host "'/data/local/.../droidspaces' -n 'Debian 13' run -- bash --noprofile --norc -c 'eval \"$(printf %s ZWNoby... | base64 -d ...)\"'"`，无宿主前导 ✓
- `-f -`：`... run -- bash --noprofile --norc -s`，stdin 直通（stub 报 18 bytes）✓
- 未映射 host：只有原来的 path/agent 前导，无 droidspaces ✓
- `-H` / `RSH_HOST_SHELL=1`：走原路径，含 `~/.local/bin` 前导 ✓
- `-n` + 容器：`... run -- sh -c '...'` ✓；`-s` + 容器：`sudo -n` 贴进 base64 体 ✓
- 映射文件不存在：等同未映射 ✓
- `--sess` + 容器：`rsh: --sess 与容器模式不兼容…` rc=2 ✓

### 真机（oneplus8 → realme，`/home/SQL916/sshkit/bin/rsh`）
映射 `~/.config/sshkit/containers`：`realme Debian 13`

1) `rsh realme 'head -4 /etc/os-release'`
```
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
```
**0.216s** → 确实在容器里。

2) `rsh -H realme 'echo $PATH'`
```
/system/bin:/system/xbin
```
**0.291s** → 逃生口回到 Android 宿主。

3) `printf 'a=6\nb=7\necho "A=$((a*b))"\necho \'q="x y z"\'\n' | rsh -f realme -`
```
A=42
q="x y z"
```
**0.154s**。再补一版证明跑在容器内（`. /etc/os-release`）：
```
echo "A=$((6*7))"
. /etc/os-release; echo "$PRETTY_NAME"
A=42
Debian GNU/Linux 13 (trixie)
```
**0.166s** → 引号/算术/管道 stdin 全部原样到达，且落在容器。

4) `rsh --sess realme foo`
```
rsh: --sess 与容器模式不兼容（sess keeper 在宿主 shell 上）。
      去掉 --sess（普通 ssh），或加 -H 留在宿主 shell。
rc=2
```

5) `mv ~/.config/sshkit/containers` 后 `rsh realme 'echo $PATH'`
```
/system/bin:/system/xbin
```
**0.068s** → 回宿主 shell（向后兼容）。恢复文件后再测 `head -1 /etc/os-release` → `PRETTY_NAME="Debian GNU/Linux 13 (trixie)"`（仅 0.216s 那次含容器启动开销）。

### 语法
`sh -n bin/rsh` → OK（355 行）。

## 已知限制
- 只认显式映射：新增设备/改容器名要手改文件（刻意，避免"删了映射还进容器"）。
- `--sess` 不可与容器同用（keeper 在宿主）。
- 容器已自带 sshd 时（如 `realme-c`）应优先直连：92ms vs ~200ms，且 `scp`/`--sess` 语义完整。
- 未处理 `droidspaces enter`（需要 PID / 交互 tty 行为不同），只用 `run --`。
- 容器不存在时错误由 droidspaces 原样透出（不预设容器名可用性检查）。
