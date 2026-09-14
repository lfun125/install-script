#!/usr/bin/env bash
#
# Teleport Agent 交互式安装脚本
#
#   sudo bash install-teleport-agent.sh
#   sudo env DEFAULT_PROXY="teleport.example.com:3024" DEFAULT_TOKEN="your-token" bash install-teleport-agent.sh
#
# 从 GitHub 执行（在 root 用户的 Bash 中运行）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-teleport-agent.sh)
#
# 从 GitHub 执行并设置默认值（Proxy 和令牌提示处回车使用，也可输入新值覆盖）：
#   DEFAULT_PROXY='teleport.example.com:3024' DEFAULT_TOKEN='your-token' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-teleport-agent.sh)
#
# 会依次询问 proxy_server / token / labels / nodename / 版本，
# 然后安装 Teleport、写配置、加入集群并验证。
#

set -euo pipefail

DEFAULT_PROXY="${DEFAULT_PROXY:-teleport.example.com:3024}"
DEFAULT_TOKEN="${DEFAULT_TOKEN:-}"
CONFIG="/etc/teleport.yaml"
DATA_DIR="/var/lib/teleport"
TOKEN_FILE="${DATA_DIR}/tokenjoin"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_bld()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { c_red "错误: $*"; exit 1; }

# ---------------------------------------------------------------- 前置检查

[[ $EUID -eq 0 ]] || die "需要 root 权限，请用 sudo 运行"

for cmd in curl systemctl; do
    command -v "$cmd" >/dev/null || die "缺少命令: $cmd"
done

c_bld "=== Teleport Agent 安装 ==="
echo

# ---------------------------------------------------------------- 旧状态检测

if [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    c_ylw "检测到 ${DATA_DIR} 已有数据。"
    echo
    echo "如果这台机器曾加入过其他集群（或集群被重建过），"
    echo "残留的旧身份会导致 'ssh: no authorities for hostname' 错误。"
    echo
    read -rp "清空 ${DATA_DIR} 重新加入？[y/N] " wipe
    if [[ "${wipe,,}" == "y" ]]; then
        systemctl stop teleport 2>/dev/null || true
        rm -rf "${DATA_DIR:?}"
        c_grn "已清空"
    else
        c_ylw "保留旧数据，若加入失败请重跑本脚本并选择清空"
    fi
    echo
fi

# ---------------------------------------------------------------- 交互输入

read -rp "Proxy 地址 [${DEFAULT_PROXY}]: " PROXY_SERVER
PROXY_SERVER="${PROXY_SERVER:-$DEFAULT_PROXY}"
[[ "$PROXY_SERVER" == *:* ]] || die "Proxy 地址必须包含端口，例如 ${DEFAULT_PROXY}"

if [[ -n "$DEFAULT_TOKEN" ]]; then
    read -rp "加入令牌 (已设置默认值，回车使用): " TOKEN
else
    read -rp "加入令牌 (tctl tokens add --type=node --ttl=1h): " TOKEN
fi
TOKEN="${TOKEN:-$DEFAULT_TOKEN}"
[[ -n "$TOKEN" ]] || die "令牌不能为空"

echo
echo "标签格式: key=value，多个用英文逗号分隔"
echo "例如:     env=prod,team=backend"
read -rp "标签: " LABELS_RAW
[[ -n "$LABELS_RAW" ]] || die "标签不能为空（没有标签的节点在 RBAC 里谁都看不到）"

DEFAULT_NODENAME="$(hostname -s)"
read -rp "节点名 [${DEFAULT_NODENAME}]: " NODENAME
NODENAME="${NODENAME:-$DEFAULT_NODENAME}"

echo
echo "版本需与服务端一致，服务端上执行 'teleport version' 查看"
read -rp "Teleport 版本 (留空装最新): " VERSION

read -rp "CA pin (可选，sha256:... 留空跳过): " CA_PIN

# ---------------------------------------------------------------- 解析标签

LABEL_YAML=""
IFS=',' read -ra LABEL_ARR <<< "$LABELS_RAW"
for pair in "${LABEL_ARR[@]}"; do
    pair="$(echo "$pair" | xargs)"          # 去首尾空格
    [[ -z "$pair" ]] && continue
    [[ "$pair" == *=* ]] || die "标签格式错误: '${pair}'，应为 key=value"
    key="${pair%%=*}"
    val="${pair#*=}"
    key="$(echo "$key" | xargs)"
    val="$(echo "$val" | xargs)"
    [[ -n "$key" && -n "$val" ]] || die "标签格式错误: '${pair}'"
    LABEL_YAML+="    ${key}: \"${val}\""$'\n'
done
[[ -n "$LABEL_YAML" ]] || die "没有解析出有效标签"

# ---------------------------------------------------------------- 确认

echo
c_bld "--- 请确认 ---"
printf '  Proxy    : %s\n' "$PROXY_SERVER"
printf '  节点名   : %s\n' "$NODENAME"
printf '  令牌     : %s…%s\n' "${TOKEN:0:6}" "${TOKEN: -4}"
printf '  版本     : %s\n' "${VERSION:-最新}"
printf '  CA pin   : %s\n' "${CA_PIN:-（未设置）}"
echo   '  标签     :'
printf '%s' "$LABEL_YAML" | sed 's/^    /             /'
echo
read -rp "开始安装？[y/N] " go
[[ "${go,,}" == "y" ]] || { echo "已取消"; exit 0; }
echo

# ---------------------------------------------------------------- 安装

if command -v teleport >/dev/null; then
    c_grn "Teleport 已安装: $(teleport version | head -1)"
else
    c_bld "[1/4] 安装 Teleport…"
    if [[ -n "$VERSION" ]]; then
        curl -fsSL https://cdn.teleport.dev/install.sh | bash -s "$VERSION"
    else
        curl -fsSL https://cdn.teleport.dev/install.sh | bash -s
    fi
    command -v teleport >/dev/null || die "安装失败"
    c_grn "      $(teleport version | head -1)"
fi

# ---------------------------------------------------------------- 写配置

c_bld "[2/4] 写入 ${CONFIG}…"

[[ -f "$CONFIG" ]] && cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

{
    echo "version: v3"
    echo
    echo "teleport:"
    echo "  nodename: ${NODENAME}"
    echo "  data_dir: ${DATA_DIR}"
    echo "  proxy_server: ${PROXY_SERVER}"
    [[ -n "$CA_PIN" ]] && echo "  ca_pin: \"${CA_PIN}\""
    echo "  join_params:"
    echo "    method: token"
    echo "    token_name: ${TOKEN_FILE}"
    echo "  log:"
    echo "    output: stderr"
    echo "    severity: INFO"
    echo
    echo "ssh_service:"
    echo "  enabled: true"
    echo "  labels:"
    printf '%s' "$LABEL_YAML"
    echo
    echo "auth_service:"
    echo "  enabled: false"
    echo
    echo "proxy_service:"
    echo "  enabled: false"
} > "$CONFIG"

chmod 600 "$CONFIG"
c_grn "      完成"

# ---------------------------------------------------------------- 启动

c_bld "[3/4] 启动服务…"
systemctl daemon-reload
systemctl enable teleport >/dev/null 2>&1
systemctl restart teleport

for i in {1..30}; do
    sleep 1
    systemctl is-active --quiet teleport || {
        echo
        c_red "Teleport 启动失败，最近日志："
        journalctl -u teleport -n 30 --no-pager
        exit 1
    }
    printf '.'
done
echo
c_grn "      服务运行中"

# ---------------------------------------------------------------- 验证

c_bld "[4/4] 验证连接…"
echo

PROXY_PORT="${PROXY_SERVER##*:}"
CONNS="$(ss -tnp 2>/dev/null | grep teleport || true)"

if [[ -z "$CONNS" ]]; then
    c_ylw "      未检测到出站连接，可能仍在重试。查看日志："
    echo "      journalctl -u teleport -f"
else
    echo "$CONNS" | sed 's/^/      /'
    echo
    if echo "$CONNS" | grep -q ":443[[:space:]]"; then
        c_red "      警告: 检测到到 :443 的连接"
        c_red "      该节点依赖 443，一旦 443 被白名单限制，重启后将永久掉线"
    else
        c_grn "      仅使用 :${PROXY_PORT}，未依赖 443"
    fi
fi

# ---------------------------------------------------------------- 收尾

echo
c_bld "=== 完成 ==="
echo
echo "在 Teleport 服务器上确认节点已上线："
echo "    tctl nodes ls"
echo
c_ylw "确认上线后，删除本机残留的令牌文件："
echo "    rm -f ${TOKEN_FILE}"
echo
echo "常用命令："
echo "    journalctl -u teleport -f      # 看日志"
echo "    systemctl restart teleport     # 重启"
echo "    ss -tnp | grep teleport        # 看连接端口"
