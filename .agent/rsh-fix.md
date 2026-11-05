# rsh 缺陷修复（A 远端 agent 自愈 / B 远端 PATH / C `-s` 语义）

状态：**完成**（改动已在工作树，未 commit/push；主会话统一提交）

## 0. 规格抄录（主会话任务书，2026-11-05）

- 缺陷 A（主因）：`bin/rsh` 只在**本地**调 `ssh-unlock`，从不检查远端 `~/.ssh/agent.sock`。
  远端 agent 死掉时 socket 是陈旧文件（`srw-------`，`Connection refused`），远端一切走密钥的操作
  （git/ssh/scp/rsync/嵌套 ssh）都 `Permission denied (publickey)`，报错不指向真因。手工修复三步：
  `rm -f ~/.ssh/agent.sock; systemctl --user restart ssh-agent; export SSH_AUTH_SOCK=$HOME/.ssh/agent.sock; ~/.local/bin/ssh-unlock`
- 缺陷 B：`rsh` 远端 `bash --noprofile --norc` → `PATH=/usr/local/bin:/usr/bin`，不含 `~/.local/bin`，
  自装工具（dsh 等）`command not found` 且无提示。
- 缺陷 C：`rsh -s host '<复合命令>'` 只给第一段加 `sudo -n`，报错混排，易误判。
- 硬约束：POSIX sh（Android busybox/mksh 可跑）、零额外 ssh 往返、失败静默降级 + stderr 一行诊断、
  `RSH_NO_AGENT_FIX=1` 可关、向后兼容 `rsh host` / `cmd` / `-f` / `-s` / `-n` / `--sess`、不动机密。

## 1. 勘察（2026-11-05，HEAD 8895c8c，工作树干净）

- 本机（Debian 13 / aarch64）：`ssh-unlock` **31 ms**；`ssh-add -l`（直连 socket）**5 ms**；
  `ssh server true`（ControlMaster 命中）**14~28 ms**；`rsh server 'echo hi'` **37~65 ms**。
  → 本地无条件 `ssh-unlock` 吃掉约一半耗时，可改为「内联 `ssh-add -l` 判定，失败才 fork」。
- `rsh fedora 'echo $PATH'` → `/usr/local/bin:/usr/bin`（实证 B）。
- **本机 agent 同样是坏的**：`~/.ssh/agent.sock` 陈旧、`ssh-agent.service` 状态 `failed`
  （socket-triggered unit：`ssh-agent -D -a` 撞上已存在 socket → exit 1）。所以本地也需要同一套自愈。
- fedora 的 `SSH_PASS` 只在 `~/.bashrc`；`bash --noprofile --norc` 和 `bash -l -c` 都读不到
  （非交互 login shell 不读 `.bashrc`）→ 远端解锁只能 `bash -ic 'ssh-unlock'`。
- ⚠️ 勘察时打印过远端 `.bashrc`，里面含真实口令/令牌；**未写入任何文件、之后不再回显**。

## 2. 方案（与理由）

**A. 远端 agent 自愈——拼进同一条远端命令，零额外 ssh 往返**
- 触发：`RSH_AGENT=always` 恒定；`auto`（默认）时命令文本命中 `git|ssh|scp|sftp|rsync`（本地正则，
  允许 `ssh-add` 这类带 `-` 的形式）；`off` / `RSH_NO_AGENT_FIX=1` 不探测。
- 探测：一次 `ssh-add -l`（rc 0 就绪 / 1 有 agent 无身份 / 2 无 agent 或陈旧 socket），约 +10~15 ms。
- 自愈：rc2 → `rm -f` 陈旧 socket → `systemctl --user restart ssh-agent`，无 systemd 则 `ssh-agent -a`
  → **轮询等 agent 起来（0.1s × 10，实测必须等，否则 `ssh-add` 撞 Connection refused）**
  → `~/.local/bin/ssh-unlock` → 仍无身份则 `bash -ic 'ssh-unlock'`（借 `.bashrc` 的 `SSH_PASS`）。
- 安全：只对「自己那台装了常驻 agent」的机器动手（socket 存在（含陈旧）或 `~/.config/systemd/user/ssh-agent.service`
  存在）；`SSH_AUTH_SOCK` 指向转发 agent 时**绝不**删/重启；口令只在远端环境，从不上命令行/落盘。
- 失败：命令继续执行，仅 stderr 一行提示（含三步手工修复命令）；健康态完全静默（stderr 0 字节）。

**A'. 本地同样自愈**：`ssh-add -l` rc2（socket 陈旧/unit 失败）→ `rm -f` + `systemctl --user restart`
+ 等起来 + `ssh-unlock`；健康时跳过 `ssh-unlock`（省 ~25 ms）。没有持久 agent 的机器（无 socket 且无 unit）不打扰。

**B. PATH**：前导把 `$HOME/.local/bin` 前置（目录存在才加，纯 `case`/`[ ]` 内建，零 fork），
`-n` 保持原生语义不动（只在非 native 模式加）。

**C. `-s`**：明确拒绝复合命令（未转义 `;`、`&&`、`|`、换行）→ `exit 2` + 提示改用 `-f`；
`\;`（`find -exec` 结尾）放行。理由：sudoers 按命令路径授权，`sudo -n bash -c '...'` 必然被拒，
硬套只会把「密码要求」换成「命令不允许」，仍是误导。原「只给第一段加 sudo」的模糊行为已删除。

## 3. 改动文件

- `bin/rsh`：新增本地/远端 agent 自愈、PATH 前导、`-s` 复合命令守卫；帮助文本同步。
- `README.md`：rsh 章节补 PATH/agent 自愈与开关；`-s` 语义改写；故障排查表更新 2 行、新增 2 行。
- `AGENTS.md`：bin/rsh 描述、PATH 约定、新增「远端 agent 的死法」与 `-s` 坑。
- `.agent/`：本文件、`verify.sh`（可复跑自检）、`verify.log`、`rsh.old`（改造前基线）、
  `bench5.sh`、`t-f.sh` / `t-git.sh`（回归夹具）、`*_prelude.sh`（前导段单独做 dash/bash/zsh 语法检查用）。

## 4. 自检结果（2026-11-05）

```
== 1. 语法：dash -n / bash -n bin/rsh 均 OK；两段前导另外单独过 dash/bash/zsh -n 均 OK
== 2. 本机耗时（server=本机，ControlMaster 命中）
   rsh server 'echo hi'  42 / 48 / 54 ms（改造前基线 37~65 ms；median 46 vs 47，无回归）
== 3. B：rsh fedora 'echo $PATH' → /home/SQL916/.local/bin:/usr/local/bin:/usr/bin
        rsh fedora 'command -v dsh' → /home/SQL916/.local/bin/dsh（旧版 command not found）
== 4. C：rsh -s server 'apt-cache policy bash' → rc=0（NOPASSWD 正常）
        rsh -s fedora 'echo ok' → sudo: a password is required（rc=1，单条、语义明确）
        rsh -s fedora 'echo a; echo b' → 拒绝，rc=2，提示改用 -f
        rsh -s fedora 'true \; echo x' → 放行（find -exec 写法）
== 5. -f：含引号/管道脚本 OK；-f -（stdin）OK；--sess OK；--sess -f OK；-n OK
== 6. A 远端自愈（从「stop + rm socket」真死状态，一次调用内）
        rsh fedora 'ssh-add -l'  → 直接列出 ED25519 身份，737 ms
        rsh fedora 'git ls-remote ... | head -1' → 8895c8c...，成功
        另测：陈旧普通文件占位 socket（: > agent.sock）→ 0.82 s 自愈
               agent 活着但空（restart 后未解锁）→ 0.53 s 自愈
               健康态再跑 → 静默（stderr 0 字节）
== 7. 开关：RSH_NO_AGENT_FIX=1 → 不修（unit=failed、无进程）；RSH_AGENT=off → 不修；
        RSH_AGENT=always → 连 'echo hi' 也探测并修复（0.83 s）
== 8. A' 本地自愈：stop+rm → 一次 rsh 后 agent active 且身份已载（220 ms）；空闲态 34 ms（只是探测）
== 9. realme（Android sh 路径）：局域网 192.168.1.100:8022 与 Tailscale 均 No route/timeout，
        设备不在线 → **跳过**（记录在案）。远端前导只用 POSIX sh 内建 + ssh-add/sleep，mksh/toybox 可跑，
        且已用 dash 单独验证语法。
```

探测量化：`rsh fedora 'ssh-add -l'`（触发探测）median **69 ms**，`rsh fedora 'echo hi'`（不触发）median **52 ms**
→ 探测开销 ≈ 15 ms，只在可能用 agent 的命令上付。

## 5. 已知取舍 / 风险

1. **远端解锁依赖 `~/.bashrc` 里导出的 `SSH_PASS`**（`bash -ic`）。若某机口令来源不同（secret 服务、keyring），
   自愈会失败并打一行提示，需人工 `ssh-unlock`。这是「不得把口令写进命令行/文件」的必然取舍。
2. `bash -ic` 会读该机 `.bashrc`（0.5~0.9 s，仅故障时）；若 `.bashrc` 很慢或需交互，最坏退化为提示。
3. 启发式靠命令文本正则，**不**看脚本运行时行为：`rsync` 写成绝对路径 `/usr/bin/rsync` 能匹配，
   但通过变量/别名间接调用不会触发。`RSH_AGENT=always` 可兜底。
4. `rsh -f host -`（stdin）无法预读脚本文本 → 默认不做 agent 探测，需 `RSH_AGENT=always`。
5. 本机自愈会 `systemctl --user restart ssh-agent`（可逆，无数据风险）；若该机 unit 并非本仓库提供，
   仅在有 `~/.config/systemd/user/ssh-agent.service` 时才动手。
6. `-s` 拒绝含 `|` 的单条命令（如 `grep 'a|b'`）；这是为了消除歧义，提示里已给出 `-f` 出路。
7. 未验证：Android（设备离线）、macOS。远端前导只用 POSIX 内建与 `ssh-add`/`sleep`，已 dash/zsh 语法验证。

## 6. 追加验证（同日晚）

- `--sess` 状态语义未受影响：`cd /tmp` → 下一条 `pwd` = `/tmp`；`cd ~` → `/home/SQL916`。
- 空命令 `rsh fedora ''` → rc=0（与旧版一致）；`-f` 指向不存在的文件 → rc=2 + 提示。
- `bin/rsh` 保持 0755；`.agent/verify.sh` 可复跑（会临时弄坏再修好对端 user agent，可逆）。
- 完整自检输出留档：`.agent/verify.log`。
