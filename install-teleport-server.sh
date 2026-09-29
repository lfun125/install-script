#!/usr/bin/env bash
#
# ==============================================================================
#  Teleport 服务端安装脚本（Auth + Proxy + 本机 Node 三合一）
#
#      sudo bash install-teleport-server.sh
#
#  安装时可选两种监听模式：
#    separate  : 客户端流量与 agent 隧道流量走不同端口（443/3023/3024），
#                便于对「人」做 IP 白名单、同时放行动态 IP 的资源节点。
#    multiplex : Teleport 默认方式，所有流量经 TLS 多路复用走同一个端口（443），
#                部署简单，但该端口需对公网开放（agent 也走它），无法按人做白名单。
#
#  下方端口说明针对 separate 模式；multiplex 模式只需对外开放 443 与 22。
#
#  可选：由 nginx 接管 443（与本机其他 HTTPS 网站共用 443）
#    nginx stream 在四层按 SNI 分流，不解密 TLS：
#      <域名> / *.<域名> / *.teleport.cluster.local → Teleport 127.0.0.1:3080
#      其他域名                                     → nginx 自身 HTTPS 站点 127.0.0.1:8443
#    separate 模式下 3023/3024 也由 nginx 转发到 127.0.0.1:13023/13024。
#    nginx 以 PROXY 协议把真实客户端 IP 传给 Teleport（proxy_protocol: on），
#    Teleport 只监听 127.0.0.1，外部无法直连伪造 PROXY 头。
#    443 需对公网开放（其他网站要用），开发者白名单改由 nginx 按域名执行，
#    名单文件 /etc/nginx/teleport-allow.conf，改完 nginx -s reload 生效。
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

# nginx 接管模式下的内部地址
NGX_STREAM_DIR="/etc/nginx/stream.d"
NGX_STREAM_CONF="${NGX_STREAM_DIR}/teleport.conf"
NGX_ALLOW_FILE="/etc/nginx/teleport-allow.conf"
NGX_REALIP_CONF="/etc/nginx/conf.d/00-teleport-stream-realip.conf"
INNER_WEB="127.0.0.1:3080"
INNER_SSH="127.0.0.1:13023"
INNER_TUN="127.0.0.1:13024"
INNER_HTTPS="127.0.0.1:8443"     # nginx 自身 HTTPS 站点改监听到这里
INNER_DENY="127.0.0.1:10999"     # 白名单外的连接转到这里直接断开

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
echo "  1) separate  分端口：Web/登录、tsh SSH、agent 隧道各用一个端口"
echo "               （可对开发者做 IP 白名单，同时对公网放行 agent 隧道）"
echo "  2) multiplex 单端口：全部流量走同一个端口（Teleport 默认配置）"
echo "               （简单，但该端口需对公网开放，无法按人做白名单）"
read -rp "选择 [1]: " LISTEN_MODE; LISTEN_MODE="${LISTEN_MODE:-1}"
case "$LISTEN_MODE" in
    1) LISTEN_MODE="separate" ;;
    2) LISTEN_MODE="multiplex" ;;
    *) die "无效选择" ;;
esac

if [[ "$LISTEN_MODE" == "separate" ]]; then
    read -rp "Web / 登录端口 [443]: "       WEB_PORT;    WEB_PORT="${WEB_PORT:-443}"
    read -rp "tsh SSH 会话端口 [3023]: "    SSH_PORT;    SSH_PORT="${SSH_PORT:-3023}"
    read -rp "agent 隧道端口 [3024]: "      TUN_PORT;    TUN_PORT="${TUN_PORT:-3024}"
else
    read -rp "统一端口 [443]: "             WEB_PORT;    WEB_PORT="${WEB_PORT:-443}"
    SSH_PORT="$WEB_PORT"; TUN_PORT="$WEB_PORT"
fi

echo
c_bld "--- nginx 前置 ---"
echo "由 nginx 接管 ${WEB_PORT} 端口，按 SNI 把 Teleport 域名转给 Teleport，"
echo "其他域名交给 nginx 自身的 HTTPS 站点（适合本机还跑着其他网站）。"
read -rp "使用 nginx 接管 ${WEB_PORT}？[y/N] " USE_NGINX
USE_NGINX="${USE_NGINX,,}"; [[ "$USE_NGINX" == "y" ]] || USE_NGINX="n"

ALLOW_RAW=""; REWRITE_HTTPS="n"; NGX_HTTPS_FILES=()
if [[ "$USE_NGINX" == "y" ]]; then
    if [[ "$LISTEN_MODE" == "separate" ]]; then
        echo
        echo "${WEB_PORT} 要给其他网站用，只能对公网开放，开发者白名单改由 nginx 执行"
        echo "（只拦 Teleport 域名与 ${SSH_PORT} 端口，不影响其他网站）。"
        echo "格式: IP 或 CIDR，多个用英文逗号分隔，例如 1.2.3.4,10.0.0.0/8"
        read -rp "开发者白名单 (留空不限制): " ALLOW_RAW
        IFS=',' read -ra ARR <<< "$ALLOW_RAW"
        for ip in "${ARR[@]}"; do
            ip="$(echo "$ip" | xargs)"; [[ -z "$ip" ]] && continue
            [[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]] || die "白名单格式错误: '${ip}'"
        done
    fi

    # 端口被非 nginx / teleport 的进程占用则无法接管
    for p in "$WEB_PORT" "$SSH_PORT" "$TUN_PORT"; do
        holder="$(ss -tlnpH "sport = :${p}" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' | sort -u \
            | grep -vE '^(nginx|teleport)$' || true)"
        [[ -z "$holder" ]] || die "端口 ${p} 已被 ${holder//$'\n'/,} 占用，请先停掉"
    done

    if command -v nginx >/dev/null; then
        nginx -V 2>&1 | grep -q 'stream_ssl_preread' \
            || die "当前 nginx 不带 stream_ssl_preread 模块。可先用 add-apt-sources.sh nginx 换成 nginx.org 官方版本"
        if grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf \
            && ! grep -qF "${NGX_STREAM_DIR}/*.conf" /etc/nginx/nginx.conf; then
            die "nginx.conf 已有 stream 块，请在其中加入: include ${NGX_STREAM_DIR}/*.conf; 后重跑"
        fi

        # http 块里监听 ${WEB_PORT} 的站点要挪到 ${INNER_HTTPS}，否则和 stream 抢端口
        mapfile -t NGX_HTTPS_FILES < <(
            nginx -T 2>/dev/null | awk -v port="$WEB_PORT" '
                /^# configuration file .*:$/ { f = $4; sub(/:$/, "", f); next }
                f !~ /stream\.d/ && $0 !~ /quic/ &&
                $0 ~ "^[[:space:]]*listen[[:space:]]+([0-9.]+:|\\*:|\\[::\\]:)?" port "([^0-9]|$)" { print f }
            ' | sort -u)
        if [[ ${#NGX_HTTPS_FILES[@]} -gt 0 ]]; then
            echo
            c_ylw "以下 nginx 配置在 http 中监听 ${WEB_PORT}，需改为 ${INNER_HTTPS}（并加 proxy_protocol）："
            printf '    %s\n' "${NGX_HTTPS_FILES[@]}"
            echo "自动改写会先把 /etc/nginx 整体备份，nginx -t 不通过则自动还原。"
            read -rp "自动改写？[y/N] " REWRITE_HTTPS
            [[ "${REWRITE_HTTPS,,}" == "y" ]] || die "请手动改为 listen ${INNER_HTTPS} ssl proxy_protocol; 后重跑"
            REWRITE_HTTPS="y"
        fi
    fi
fi

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
        [[ "$LISTEN_MODE" == "separate" ]] \
            && c_ylw "内置 ACME 需要 ${WEB_PORT} 对公网开放，无法与 IP 白名单共存"
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

echo
c_bld "--- 版本 ---"
LATEST=""
if command -v teleport >/dev/null; then
    LATEST="$(teleport version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    [[ -n "$LATEST" ]] && echo "当前已安装: ${LATEST}"
fi
if [[ -z "$LATEST" ]]; then
    echo -n "正在查询最新版本… "
    LATEST="$(curl -fsSL --max-time 10 \
        https://api.github.com/repos/gravitational/teleport/releases/latest 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9.]+"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -n "$LATEST" ]]; then echo "${LATEST}"; else echo "查询失败"; fi
fi
if [[ -n "$LATEST" ]]; then
    read -rp "安装版本 [${LATEST}]: " VERSION; VERSION="${VERSION:-$LATEST}"
else
    echo "请手动指定，可在 https://goteleport.com/download/ 查看"
    read -rp "安装版本 (如 18.11.0): " VERSION
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z，例如 18.10.0"

# ============================================================ 确认

echo
c_bld "--- 请确认 ---"
printf '  域名         : %s\n' "$DOMAIN"
printf '  集群名       : %s  (不可更改)\n' "$CLUSTER_NAME"
printf '  rp_id        : %s  (不可更改)\n' "$RP_ID"
printf '  监听模式     : %s\n' "$LISTEN_MODE"
if [[ "$LISTEN_MODE" == "separate" ]]; then
    printf '  Web 端口     : %s  → 开发者白名单\n' "$WEB_PORT"
    printf '  tsh 端口     : %s  → 开发者白名单\n' "$SSH_PORT"
    printf '  隧道端口     : %s  → 公网开放\n' "$TUN_PORT"
else
    printf '  统一端口     : %s  → 公网开放（Web / tsh / agent 隧道共用）\n' "$WEB_PORT"
fi
printf '  Auth 端口    : 3025 → 仅本机\n'
if [[ "$USE_NGINX" == "y" ]]; then
    printf '  nginx 接管   : 是（Teleport 改听 %s，其他 HTTPS 站点改听 %s）\n' "$INNER_WEB" "$INNER_HTTPS"
    [[ "$LISTEN_MODE" == "separate" ]] \
        && printf '  nginx 白名单 : %s\n' "${ALLOW_RAW:-（不限制）}"
fi
printf '  证书方式     : %s\n' "$CERT_MODE"
printf '  证书有效期   : %s\n' "$SESSION_TTL"
printf '  Teleport 版本: %s\n' "$VERSION"
echo
read -rp "开始安装？[y/N] " go
[[ "${go,,}" == "y" ]] || { echo "已取消"; exit 0; }
echo

STEPS=5; [[ "$USE_NGINX" == "y" ]] && STEPS=6

# ============================================================ 安装 Teleport

if command -v teleport >/dev/null; then
    c_grn "[1/${STEPS}] Teleport 已安装: $(teleport version | head -1)"
else
    c_bld "[1/${STEPS}] 安装 Teleport ${VERSION}…"
    curl -fsSL https://cdn.teleport.dev/install.sh | bash -s "$VERSION"
    command -v teleport >/dev/null || die "安装失败"
    c_grn "      $(teleport version | head -1)"
fi

if [[ "$USE_NGINX" == "y" ]] && ! command -v nginx >/dev/null; then
    c_bld "      安装 nginx…"
    apt-get update -qq
    apt-get install -y -qq nginx
fi
if [[ "$USE_NGINX" == "y" ]]; then
    # 发行版自带 nginx 的 stream 是动态模块，需单独安装
    if nginx -V 2>&1 | grep -q 'with-stream=dynamic'; then
        apt-get install -y -qq libnginx-mod-stream
    fi
    nginx -V 2>&1 | grep -q 'stream_ssl_preread' \
        || die "nginx 不带 stream_ssl_preread 模块。可先用 add-apt-sources.sh nginx 换成 nginx.org 官方版本"
fi

# ============================================================ 证书

c_bld "[2/${STEPS}] 准备证书…"
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

c_bld "[3/${STEPS}] 写入 ${CONFIG}…"
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
EOF

if [[ "$LISTEN_MODE" == "separate" ]]; then
cat <<EOF
  # separate: 关闭 TLS 多路复用，是端口分离的前提
  proxy_listener_mode: separate
EOF
else
cat <<EOF
  # multiplex: TLS 多路复用，Web / tsh / agent 隧道共用 ${WEB_PORT}（Teleport 默认）
  proxy_listener_mode: multiplex
EOF
fi

cat <<EOF
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
EOF

if [[ "$USE_NGINX" == "y" ]]; then
cat <<EOF
  # on: 必须带 PROXY 头。前置 nginx 以 PROXY 协议传递真实客户端 IP；
  #     下面各监听只绑 127.0.0.1，外部无法直连伪造 PROXY 头
  proxy_protocol: on

EOF
else
cat <<EOF
  proxy_protocol: off

EOF
fi

if [[ "$USE_NGINX" == "y" && "$LISTEN_MODE" == "separate" ]]; then
cat <<EOF
  # 以下监听均由 nginx 从公网端口转发过来（见 ${NGX_STREAM_CONF}）
  # ${WEB_PORT} → ${INNER_WEB}: Web UI / tsh login（白名单由 nginx 执行）
  web_listen_addr: ${INNER_WEB}
  # ${SSH_PORT} → ${INNER_SSH}: tsh SSH 会话（白名单由 nginx 执行）
  listen_addr: ${INNER_SSH}
  # ${TUN_PORT} → ${INNER_TUN}: agent 反向隧道（公网开放）
  tunnel_listen_addr: ${INNER_TUN}

  public_addr: ${DOMAIN}:${WEB_PORT}
  # 不设 ssh_public_addr 会退回机器 hostname，导致「登录成功但连不上节点」
  ssh_public_addr: ${DOMAIN}:${SSH_PORT}
  # 告知 agent 隧道入口，使其全程不经 ${WEB_PORT}
  tunnel_public_addr: ${DOMAIN}:${TUN_PORT}
EOF
elif [[ "$USE_NGINX" == "y" ]]; then
cat <<EOF
  # ${WEB_PORT} → ${INNER_WEB}: 由 nginx 按 SNI 转发，Web / tsh / agent 隧道全部复用
  web_listen_addr: ${INNER_WEB}
  public_addr: ${DOMAIN}:${WEB_PORT}
EOF
elif [[ "$LISTEN_MODE" == "separate" ]]; then
cat <<EOF
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
else
cat <<EOF
  # ${WEB_PORT}: Web UI / tsh login / tsh SSH / agent 隧道全部复用 → 防火墙对公网开放
  web_listen_addr: 0.0.0.0:${WEB_PORT}
  public_addr: ${DOMAIN}:${WEB_PORT}
EOF
fi

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

c_bld "[4/${STEPS}] 启动服务…"
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

# ============================================================ nginx

if [[ "$USE_NGINX" == "y" ]]; then
    c_bld "[5/${STEPS}] 配置 nginx…"

    NGX_BACKUP="/root/nginx-backup-$(date +%s).tar.gz"
    tar -czf "$NGX_BACKUP" -C / etc/nginx
    c_grn "      已备份 /etc/nginx → ${NGX_BACKUP}"

    ngx_restore() {
        rm -rf /etc/nginx && tar -xzf "$NGX_BACKUP" -C /
        c_red "      nginx 配置有误，已还原备份"
        die "$1"
    }

    # 其他 HTTPS 站点挪到 ${INNER_HTTPS}，由 stream 以 PROXY 协议转入
    if [[ "$REWRITE_HTTPS" == "y" ]]; then
        for f in "${NGX_HTTPS_FILES[@]}"; do
            sed -i -E \
                -e "/quic/!s/^([[:space:]]*)(listen[[:space:]]+\[::\]:${WEB_PORT}([^0-9;][^;]*)?;)/\1# 已由 nginx stream 接管: \2/" \
                -e "/quic/!s/^([[:space:]]*)listen[[:space:]]+([0-9.]+:|\*:)?${WEB_PORT}([^0-9;][^;]*)?;/\1listen ${INNER_HTTPS}\3 proxy_protocol;/" \
                "$f"
            c_grn "      已改写 ${f}"
        done
    fi

    # 让 HTTPS 站点从 PROXY 头取真实 IP（只信任本机 stream 转入的连接）
    cat > "$NGX_REALIP_CONF" <<'EOF'
# 由 install-teleport-server.sh 生成：443 经 nginx stream 以 PROXY 协议转入，
# 从 PROXY 头恢复真实客户端 IP。只对来自本机的连接生效，不影响 80 端口站点。
set_real_ip_from 127.0.0.1;
real_ip_header proxy_protocol;
EOF

    # 白名单（geo 格式）
    {
        echo "# Teleport 开发者白名单，由 install-teleport-server.sh 生成"
        echo "# 格式: <IP 或 CIDR> 1;   修改后执行 nginx -t && nginx -s reload"
        echo "# default 1 = 不限制；default 0 = 仅放行下方列出的地址"
        if [[ -z "$ALLOW_RAW" ]]; then
            echo "default 1;"
        else
            echo "default 0;"
            IFS=',' read -ra ARR <<< "$ALLOW_RAW"
            for ip in "${ARR[@]}"; do
                ip="$(echo "$ip" | xargs)"; [[ -z "$ip" ]] && continue
                echo "${ip} 1;"
            done
        fi
    } > "$NGX_ALLOW_FILE"

    # 本机开启了 IPv6 才监听 [::]，否则 nginx 启动报错
    listen_v6() { [[ -f /proc/net/if_inet6 ]] && echo "    listen [::]:$1;"; true; }

    mkdir -p "$NGX_STREAM_DIR"
    {
    cat <<EOF
# 由 install-teleport-server.sh 生成（被 nginx.conf 中的 stream 块 include）
# 四层转发，不解密 TLS；向后端发送 PROXY 协议头以传递真实客户端 IP

# Teleport 的 SNI：自身域名、子域名（应用访问）、集群内部名
map \$ssl_preread_server_name \$teleport_sni {
    hostnames;
    .${DOMAIN}  1;
    .teleport.cluster.local   1;
    default                   0;
}

# default 与名单都在 include 文件里
geo \$teleport_allow {
    include ${NGX_ALLOW_FILE};
}

map "\$teleport_sni\$teleport_allow" \$teleport_web_upstream {
    "11"    ${INNER_WEB};     # Teleport 且在白名单
    "10"    ${INNER_DENY};    # Teleport 但不在白名单 → 断开
    default ${INNER_HTTPS};   # 其他域名 → nginx 自身 HTTPS 站点
}

server {
    listen ${WEB_PORT};
$(listen_v6 "$WEB_PORT")
    ssl_preread    on;
    proxy_pass     \$teleport_web_upstream;
    proxy_protocol on;
    # 默认 10m 空闲即断，SSH 会话与 agent 隧道需要更长
    proxy_timeout  1h;
}

# 白名单外的连接：直接关闭
server {
    listen ${INNER_DENY};
    return "";
}
EOF

    if [[ "$LISTEN_MODE" == "separate" ]]; then
    cat <<EOF

map \$teleport_allow \$teleport_ssh_upstream {
    1       ${INNER_SSH};
    default ${INNER_DENY};
}

# tsh SSH 会话（白名单）
server {
    listen ${SSH_PORT};
$(listen_v6 "$SSH_PORT")
    proxy_pass     \$teleport_ssh_upstream;
    proxy_protocol on;
    proxy_timeout  1h;
}

# agent 反向隧道（公网开放）
server {
    listen ${TUN_PORT};
$(listen_v6 "$TUN_PORT")
    proxy_pass     ${INNER_TUN};
    proxy_protocol on;
    proxy_timeout  1h;
}
EOF
    fi
    } > "$NGX_STREAM_CONF"

    # stream 块必须在 http 块之外，追加到 nginx.conf 末尾
    if ! grep -qF "${NGX_STREAM_DIR}/*.conf" /etc/nginx/nginx.conf; then
        cat >> /etc/nginx/nginx.conf <<EOF

# Teleport：四层 SNI 分流（由 install-teleport-server.sh 添加）
stream {
    include ${NGX_STREAM_DIR}/*.conf;
}
EOF
    fi

    nginx -t 2>&1 | sed 's/^/      /' || true
    nginx -t >/dev/null 2>&1 || ngx_restore "nginx -t 未通过，见上方输出"

    # 端口归属在 http / stream 之间转移，reload 可能抢不到端口，直接 restart
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    sleep 2
    systemctl is-active --quiet nginx || die "nginx 启动失败，查看: journalctl -u nginx -n 40"
    c_grn "      完成"
fi

# ============================================================ 验证

c_bld "[${STEPS}/${STEPS}] 端口自检…"
echo
sleep 3
PORT_RE=":${WEB_PORT}|:${SSH_PORT}|:${TUN_PORT}|:3025"
[[ "$USE_NGINX" == "y" ]] && PORT_RE+="|${INNER_WEB}|${INNER_SSH}|${INNER_TUN}|${INNER_HTTPS}"
ss -tlnp 2>/dev/null | grep -E "$PORT_RE" \
    | sed 's/^/      /' || c_ylw "      未检测到监听，稍后用 ss -tlnp 手动确认"

# ============================================================ 收尾

if [[ "$USE_NGINX" == "y" ]]; then
    FW_WEB="公网                "
    FW_SSH="公网                "
    FW_NOTE="   ${WEB_PORT} 与其他网站共用，只能对公网开放。开发者白名单由 nginx 执行，
   同时作用于 Teleport 域名（${WEB_PORT}）与 ${SSH_PORT}，名单在 ${NGX_ALLOW_FILE}，
   修改后执行 nginx -t && nginx -s reload。"
else
    FW_WEB="开发者白名单        "
    FW_SSH="开发者白名单        "
    FW_NOTE="   ${WEB_PORT} 与 ${SSH_PORT} 必须成对限制：只锁 ${WEB_PORT} 的话，持有效证书者
   可绕过登录入口直接从 ${SSH_PORT} 建立会话。"
fi

if [[ "$LISTEN_MODE" == "multiplex" ]]; then
cat <<EOF

$(c_bld "=== 安装完成 ===")

$(c_bld "1. 创建管理员")

   tctl users add admin --roles=editor,access --logins=root,ubuntu

$(c_bld "2. 防火墙（本脚本不配置，请自行处理）")

   端口          开放给              说明
   ----------    ----------------    --------------------------------
   22/tcp        管理员 IP           先放行，否则会锁死自己
   ${WEB_PORT}/tcp       公网                Web / tsh / agent 隧道全部复用
   3025/tcp      不开放              已绑 127.0.0.1
   3022/tcp      不开放              本机节点，经 Proxy 转发

   multiplex 模式下 agent 也走 ${WEB_PORT}，因此无法对该端口做开发者 IP 白名单；
   如需白名单，请重新运行脚本选择 separate 模式。

$(c_bld "3. 加资源节点")

   tctl tokens add --type=node --ttl=1h

   节点端 proxy_server 填 ${DOMAIN}:${WEB_PORT}，
   Teleport 版本装 ${VERSION}（agent 版本不得高于服务端）。

$(c_bld "4. 客户端")

   tsh login --proxy=${DOMAIN}:${WEB_PORT} --user=<用户名>

   验收请做到 tsh ssh，确认会话能建立。

$(c_bld "5. 升级纪律")

   ${WEB_PORT} 对公网开放，安全性依赖版本跟进：
   - 订阅 gravitational/teleport 的 Release 通知
   - 补丁版本（x.y.z）不涉及数据迁移，出了就升
   - 大版本不能跨级跳，须逐个大版本升级

EOF
else
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
   ${WEB_PORT}/tcp       ${FW_WEB}Web UI / tsh login
   ${SSH_PORT}/tcp      ${FW_SSH}tsh SSH 会话，漏放会「登录成功但连不上」
   ${TUN_PORT}/tcp      公网                agent 隧道，动态 IP 无法枚举
   3025/tcp      不开放              已绑 127.0.0.1
   3022/tcp      不开放              本机节点，经 Proxy 转发

${FW_NOTE}

$(c_bld "3. 加资源节点")

   tctl tokens add --type=node --ttl=1h

   节点端 proxy_server 填 ${DOMAIN}:${TUN_PORT}（不是 ${WEB_PORT}），
   Teleport 版本装 ${VERSION}（agent 版本不得高于服务端）。
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
fi

if [[ "$USE_NGINX" == "y" ]]; then
    c_bld "nginx 前置说明"
    echo
    echo "   stream 配置 : ${NGX_STREAM_CONF}"
    echo "   白名单      : ${NGX_ALLOW_FILE}"
    echo "   配置备份    : ${NGX_BACKUP}"
    echo "   其他 HTTPS 站点须监听 ${INNER_HTTPS} ssl proxy_protocol，新增站点照此配置，"
    echo "   不要再直接 listen ${WEB_PORT}，否则会与 stream 抢端口。"
    echo "   Teleport 只接受带 PROXY 头的连接，本机直连 ${INNER_WEB} 做健康检查会失败，属正常。"
    echo
fi

if [[ "$CERT_MODE" == "1" ]]; then
    c_ylw "证书续期自检： certbot renew --dry-run"
    echo
fi

# bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-teleport-server.sh)