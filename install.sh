#!/bin/sh
# 安装 sshkit 到 ~/.local/bin，并按需配置常驻 ssh-agent。
#
#   ./install.sh              # 只装四个工具（rsh / wsh / sess / ssh-unlock）
#   ./install.sh --agent      # 额外装并启用 systemd user unit ssh-agent.service
#
# 幂等：重复执行只会覆盖同名的 sshkit 工具。
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
DEST="${SSHKIT_BIN:-$HOME/.local/bin}"
AGENT=0
for a in "$@"; do
    case "$a" in
        --agent) AGENT=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

mkdir -p "$DEST"
for f in rsh wsh sess ssh-unlock; do
    install -m 0755 "$SRC/bin/$f" "$DEST/$f"
done
echo "已安装到 $DEST: rsh wsh sess ssh-unlock"

case ":$PATH:" in
    *":$DEST:"*) ;;
    *) echo "提示: $DEST 不在 PATH 里，请把它加进 shell 配置" ;;
esac

if [ "$AGENT" = 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "跳过 --agent：没有 systemd" >&2
        exit 0
    fi
    mkdir -p "$HOME/.config/systemd/user"
    install -m 0644 "$SRC/systemd/ssh-agent.service" "$HOME/.config/systemd/user/ssh-agent.service"
    systemctl --user daemon-reload
    systemctl --user enable --now ssh-agent
    echo "已启用 ssh-agent: socket = $HOME/.ssh/agent.sock"
    echo "若是新机器，还需在你的 shell 配置里设置（密钥有口令时需要）："
    echo "  export SSH_ASKPASS=\"\$HOME/.ssh/askpass.sh\""
    echo "  export SSH_ASKPASS_REQUIRE=force"
    echo "  ssh-unlock"
fi

cat <<'EOF'

建议同时在 ~/.ssh/config 里加（复用连接，单条 ssh 从 227ms 降到 15ms）：

Host *
    IdentityAgent ~/.ssh/agent.sock
    AddKeysToAgent yes
    ControlMaster auto
    ControlPath ~/.ssh/cm/%C
    ControlPersist 30m
    ConnectTimeout 15
    StrictHostKeyChecking accept-new

先建 socket 目录：mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm
EOF
