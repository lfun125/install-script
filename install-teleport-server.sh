#!/usr/bin/env bash
#
# ==============================================================================
#  Teleport 服务端安装脚本（Auth + Proxy + 本机 Node 三合一）
#
#      sudo bash install-teleport-server.sh
#
#  采用 separate 监听模式：客户端流量与 agent 隧道流量走不同端口，
#  便于对「人」做 IP 白名单、同时放行动态 IP 的资源节点。
# ==============================================================================
#
# ------------------------------------------------------------------------------
#  端口开放策略（本脚本不配置防火墙，请照此自行配置）
# ------------------------------------------------------------------------------
#
#  22/tcp    系统 SSH
#            → 仅管理员 IP。配防火墙前务必先放行，否则会把自己锁在外面。
#
#  443/tcp   Web UI / tsh login / tsh ls
#            → 仅开发者白名单 IP。
#            → 控制「谁能拿到证书」，是登录入口。
#            → 注意：内置 ACME 走 TLS-ALPN-01，需要本端口对 Let's Encrypt
#              公网可达。LE 无固定出口 IP，因此启用白名单后必须改用 DNS-01
#              签发证书（本脚本的证书方式 1）。
#
#  3023/tcp  tsh SSH 会话通道
#            → 仅开发者白名单 IP。
#            → 控制「证书只能在哪些 IP 上使用」。
#            → 漏放会导致「登录成功但连不上任何节点」，容易误判成权限问题。
#            → 只放 443 不放 3023 等于白名单形同虚设：持有效证书者可绕过
#              443 直接从 3023 建立会话。
#
#  3024/tcp  agent 反向隧道
#            → 对公网开放（资源节点 IP 动态，无法枚举）。
#            → 这是本方案唯一的对外攻击面。它以集群 CA 做双向 TLS，
#              无集群签发的主机证书无法握手，是 Teleport 标准公网部署端口，
#              但仍可被扫描。务必跟紧版本更新。
#            → agent 端 proxy_server 应填 <域名>:3024，全程不经 443。
#
#  3025/tcp  Auth 服务
#            → 绑 127.0.0.1，不对外。
#            → 三合一部署下 Proxy 与 Auth 同进程；远程 agent 的 auth 流量
#              经 Proxy 隧道转发，无需直连。
#
#  3022/tcp  本机 ssh_service
#            → 不对外。会话经 Proxy 转发，无需直连。
#
#  出站      需放行 443（下载安装包、Let's Encrypt ACME、Cloudflare API）。
#
#  nftables 参考规则：
#
#      tcp dport 22   ip saddr @admin_ips  accept
#      tcp dport { 443, 3023 } ip saddr @dev_clients accept
#      tcp dport 3024 accept
#      # 其余由 policy drop 兜底
#
# ------------------------------------------------------------------------------

set -euo pipefail

CONFIG="/etc/teleport.yaml"
DATA_DIR="/var/lib/teleport"

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_bld() { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { c_red "错误: $*"; exit 1; }

# ============================================================ 前置检查

[[ $EUID -eq 0 ]] || die "需要 root 权限，请用 sudo 运行"
for cmd in curl systemctl; do
    command -v "$cmd" >/dev/null || die "缺少命令: $cmd"
done

c_bld "=== Teleport 服务端安装 ==="
echo

# ============================================================ 旧数据检测

if [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    c_ylw "检测到 ${DATA_DIR} 已有数据。"
    echo
    echo "继续将复用现有集群。注意 cluster_name 已固化在 CA 签名中，"
    echo "改配置无效——若要更换集群名，必须清空重建。"
    echo
    c_red "清空会销毁集群 CA：所有节点需重新加入、所有用户与 MFA 需重建、"
    c_red "历史会话录像与审计日志全部丢失。"
    echo
    read -rp "清空 ${DATA_DIR} 全新部署？[y/N] " wipe
    if [[ "${wipe,,}" == "y" ]]; then
        read -rp "再次确认，输入 DESTROY 继续: " confirm
        [[ "$confirm" == "DESTROY" ]] || { echo "已取消"; exit 0; }
        systemctl stop teleport 2>/dev/null || true
        rm -rf "${DATA_DIR:?}"
        c_grn "已清空"
    fi
    echo
fi

# ============================================================ 交互输入

c_bld "--- 集群标识（首次启动后不可更改）---"
echo

DEFAULT_DOMAIN=""
read -rp "对外域名 (如 teleport.example.com): " DOMAIN
[[ -n "$DOMAIN" ]] || die "域名不能为空"
[[ "$DOMAIN" != *:* ]] || die "只填域名，不要带端口"

echo
echo "集群名是集群的永久身份，写入 CA 签名，之后无法修改。"
echo "留空会退回机器 hostname ($(hostname -s))，通常不是你想要的。"
read -rp "集群名 [${DOMAIN}]: " CLUSTER_NAME
CLUSTER_NAME="${CLUSTER_NAME:-$DOMAIN}"

echo
echo "WebAuthn rp_id 必须是用户浏览器实际访问的域名。"
c_ylw "该值在集群生命周期内绝不能变，改动会使所有已注册 MFA 设备失效。"
read -rp "rp_id [${DOMAIN}]: " RP_ID
RP_ID="${RP_ID:-$DOMAIN}"

echo
c_bld "--- 端口 ---"
read -rp "Web / 登录端口 [443]: "       WEB_PORT;    WEB_PORT="${WEB_PORT:-443}"
read -rp "tsh SSH 会话端口 [3023]: "    SSH_PORT;    SSH_PORT="${SSH_PORT:-3023}"
read -rp "agent 隧道端口 [3024]: "      TUN_PORT;    TUN_PORT="${TUN_PORT:-3024}"

echo
c_bld "--- 证书 ---"
echo "  1) Cloudflare DNS-01 自动申请（推荐，不要求 443 对公网开放）"
echo "  2) 使用已有证书文件"
echo "  3) Teleport 内置 ACME（要求 443 对公网开放，与 IP 白名单冲突）"
read -rp "选择 [1]: " CERT_MODE; CERT_MODE="${CERT_MODE:-1}"

CF_TOKEN=""; ACME_EMAIL=""; KEY_FILE=""; CERT_FILE=""
case "$CERT_MODE" in
    1)
        read -rp  "Let's Encrypt 邮箱: " ACME_EMAIL
        [[ -n "$ACME_EMAIL" ]] || die "邮箱不能为空"
        echo "Cloudflare API Token 权限需为 Zone → DNS → Edit"
        read -rsp "Cloudflare API Token: " CF_TOKEN; echo
        [[ -n "$CF_TOKEN" ]] || die "Token 不能为空"
        KEY_FILE="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        ;;
    2)
        read -rp "私钥路径: "  KEY_FILE
        read -rp "证书链路径: " CERT_FILE
        [[ -f "$KEY_FILE"  ]] || die "私钥不存在: $KEY_FILE"
        [[ -f "$CERT_FILE" ]] || die "证书不存在: $CERT_FILE"
        ;;
    3)
        read -rp "Let's Encrypt 邮箱: " ACME_EMAIL
        [[ -n "$ACME_EMAIL" ]] || die "邮箱不能为空"
        c_ylw "内置 ACME 需要 ${WEB_PORT} 对公网开放，无法与 IP 白名单共存"
        ;;
    *) die "无效选择" ;;
esac

echo
c_bld "--- 本机 SSH 节点 ---"
read -rp "把本机也作为可访问资源？[Y/n] " LOCAL_NODE
LOCAL_NODE="${LOCAL_NODE:-y}"
LOCAL_LABELS=""
if [[ "${LOCAL_NODE,,}" == "y" ]]; then
    read -rp "本机标签 [env=prod,team=infra]: " LOCAL_LABELS_RAW
    LOCAL_LABELS_RAW="${LOCAL_LABELS_RAW:-env=prod,team=infra}"
    IFS=',' read -ra ARR <<< "$LOCAL_LABELS_RAW"
    for pair in "${ARR[@]}"; do
        pair="$(echo "$pair" | xargs)"; [[ -z "$pair" ]] && continue
        [[ "$pair" == *=* ]] || die "标签格式错误: '${pair}'"
        k="$(echo "${pair%%=*}" | xargs)"; v="$(echo "${pair#*=}" | xargs)"
        LOCAL_LABELS+="    ${k}: \"${v}\""$'\n'
    done
fi

echo
c_bld "--- 会话策略 ---"
read -rp "用户证书默认有效期 [8h]: " SESSION_TTL; SESSION_TTL="${SESSION_TTL:-8h}"

# ============================================================ 确认

echo
c_bld "--- 请确认 ---"
printf '  域名         : %s\n' "$DOMAIN"
printf '  集群名       : %s  (不可更改)\n' "$CLUSTER_NAME"
printf '  rp_id        : %s  (不可更改)\n' "$RP_ID"
printf '  Web 端口     : %s  → 开发者白名单\n' "$WEB_PORT"
printf '  tsh 端口     : %s  → 开发者白名单\n' "$SSH_PORT"
printf '  隧道端口     : %s  → 公网开放\n' "$TUN_PORT"
printf '  Auth 端口    : 3025 → 仅本机\n'
printf '  证书方式     : %s\n' "$CERT_MODE"
printf '  证书有效期   : %s\n' "$SESSION_TTL"
echo
read -rp "开始安装？[y/N] " go
[[ "${go,,}" == "y" ]] || { echo "已取消"; exit 0; }
echo

# ============================================================ 安装 Teleport

if command -v teleport >/dev/null; then
    c_grn "[1/5] Teleport 已安装: $(teleport version | head -1)"
else
    c_bld "[1/5] 安装 Teleport…"
    curl -fsSL https://cdn.teleport.dev/install.sh | bash -s
    command -v teleport >/dev/null || die "安装失败"
    c_grn "      $(teleport version | head -1)"
fi

# ============================================================ 证书

c_bld "[2/5] 准备证书…"
if [[ "$CERT_MODE" == "1" ]]; then
    if [[ -f "$CERT_FILE" ]]; then
        c_grn "      证书已存在，跳过申请"
    else
        apt-get update -qq
        apt-get install -y -qq certbot python3-certbot-dns-cloudflare

        mkdir -p /root/.secrets
        printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /root/.secrets/cloudflare.ini
        chmod 600 /root/.secrets/cloudflare.ini

        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
            -d "$DOMAIN" -d "*.${DOMAIN}" \
            --email "$ACME_EMAIL" --agree-tos --non-interactive

        [[ -f "$CERT_FILE" ]] || die "证书申请失败"
        c_grn "      已签发"
    fi
else
    c_grn "      跳过（方式 ${CERT_MODE}）"
fi

# ============================================================ 写配置

c_bld "[3/5] 写入 ${CONFIG}…"
[[ -f "$CONFIG" ]] && cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"

{
cat <<EOF
version: v3

teleport:
  nodename: $(hostname -s)
  data_dir: ${DATA_DIR}
  log:
    output: stderr
    severity: INFO
    format:
      output: text

auth_service:
  enabled: true
  # 仅本机可达：Proxy 与 Auth 同进程，远程 agent 的 auth 流量经 Proxy 转发
  listen_addr: 127.0.0.1:3025
  cluster_name: ${CLUSTER_NAME}
  # separate: 关闭 TLS 多路复用，是端口分离的前提
  proxy_listener_mode: separate
  # off: 禁止 PROXY 协议头，防止源 IP 伪造（无四层负载均衡时必须关闭）
  proxy_protocol: off
  disconnect_expired_cert: true

  authentication:
    type: local
    second_factors: ["webauthn", "otp"]
    locking_mode: strict
    default_session_ttl: ${SESSION_TTL}
    webauthn:
      rp_id: ${RP_ID}

  session_recording_config:
    mode: node-sync

proxy_service:
  enabled: true
  proxy_protocol: off

  # ${WEB_PORT}: Web UI / tsh login   → 防火墙仅放行开发者白名单 IP
  web_listen_addr: 0.0.0.0:${WEB_PORT}
  # ${SSH_PORT}: tsh SSH 会话         → 防火墙仅放行开发者白名单 IP
  listen_addr: 0.0.0.0:${SSH_PORT}
  # ${TUN_PORT}: agent 反向隧道       → 防火墙对公网开放
  tunnel_listen_addr: 0.0.0.0:${TUN_PORT}

  public_addr: ${DOMAIN}:${WEB_PORT}
  # 不设 ssh_public_addr 会退回机器 hostname，导致「登录成功但连不上节点」
  ssh_public_addr: ${DOMAIN}:${SSH_PORT}
  # 告知 agent 隧道入口，使其全程不经 ${WEB_PORT}
  tunnel_public_addr: ${DOMAIN}:${TUN_PORT}
EOF

if [[ "$CERT_MODE" == "3" ]]; then
cat <<EOF
  acme:
    enabled: "yes"
    email: ${ACME_EMAIL}
EOF
else
cat <<EOF
  https_keypairs:
    - key_file: ${KEY_FILE}
      cert_file: ${CERT_FILE}
  # 证书续期后自动重载，无需重启
  https_keypairs_reload_interval: 12h
EOF
fi

echo
if [[ "${LOCAL_NODE,,}" == "y" ]]; then
    echo "ssh_service:"
    echo "  enabled: true"
    echo "  labels:"
    printf '%s' "$LOCAL_LABELS"
else
    echo "ssh_service:"
    echo "  enabled: false"
fi
} > "$CONFIG"

chmod 600 "$CONFIG"
c_grn "      完成"

# ============================================================ 启动

c_bld "[4/5] 启动服务…"
systemctl daemon-reload
systemctl enable teleport >/dev/null 2>&1
systemctl restart teleport

sleep 5
if ! systemctl is-active --quiet teleport; then
    echo
    c_red "启动失败，最近日志："
    journalctl -u teleport -n 40 --no-pager
    echo
    c_ylw "提示：配置有误时 Teleport 只报第一个未知字段，需反复修正重启"
    exit 1
fi
c_grn "      运行中"

# ============================================================ 验证

c_bld "[5/5] 端口自检…"
echo
sleep 3
ss -tlnp 2>/dev/null | grep -E ":${WEB_PORT}|:${SSH_PORT}|:${TUN_PORT}|:3025" \
    | sed 's/^/      /' || c_ylw "      未检测到监听，稍后用 ss -tlnp 手动确认"

# ============================================================ 收尾

cat <<EOF

$(c_bld "=== 安装完成 ===")

$(c_bld "1. 创建管理员")

   tctl users add admin --roles=editor,access --logins=root,ubuntu

   输出的注册链接需从「白名单 IP」的浏览器打开。防火墙生效后其他 IP 会
   超时，容易误判成服务未启动。

$(c_bld "2. 防火墙（本脚本不配置，请自行处理）")

   端口          开放给              说明
   ----------    ----------------    --------------------------------
   22/tcp        管理员 IP           先放行，否则会锁死自己
   ${WEB_PORT}/tcp       开发者白名单        Web UI / tsh login
   ${SSH_PORT}/tcp      开发者白名单        tsh SSH 会话，漏放会「登录成功但连不上」
   ${TUN_PORT}/tcp      公网                agent 隧道，动态 IP 无法枚举
   3025/tcp      不开放              已绑 127.0.0.1
   3022/tcp      不开放              本机节点，经 Proxy 转发

   ${WEB_PORT} 与 ${SSH_PORT} 必须成对限制：只锁 ${WEB_PORT} 的话，持有效证书者
   可绕过登录入口直接从 ${SSH_PORT} 建立会话。

$(c_bld "3. 加资源节点")

   tctl tokens add --type=node --ttl=1h

   节点端 proxy_server 填 ${DOMAIN}:${TUN_PORT}（不是 ${WEB_PORT}）。
   加完务必在节点上执行 ss -tnp | grep teleport 确认没有到 :${WEB_PORT} 的连接——
   否则该节点在 ${WEB_PORT} 收紧后，下次重启将永久掉线。

$(c_bld "4. 客户端")

   tsh login --proxy=${DOMAIN}:${WEB_PORT} --user=<用户名>

   验收必须做到 tsh ssh，只做 tsh ls 不会经过 ${SSH_PORT}。

$(c_bld "5. 升级纪律")

   ${TUN_PORT} 是本方案唯一对外攻击面，安全性依赖版本跟进：
   - 订阅 gravitational/teleport 的 Release 通知
   - 补丁版本（x.y.z）不涉及数据迁移，出了就升
   - 大版本不能跨级跳，须逐个大版本升级

EOF

if [[ "$CERT_MODE" == "1" ]]; then
    c_ylw "证书续期自检： certbot renew --dry-run"
    echo
fi

# bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-teleport-server.sh)