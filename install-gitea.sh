#!/usr/bin/env bash
#
# ==============================================================================
#  Gitea 一键安装脚本（交互式）
#
#  直接从 GitHub 运行（推荐，进程替换不占用 stdin，菜单交互正常）：
#
#      sudo bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-gitea.sh)
#
#  或先下载再运行：
#
#      curl -fsSLO https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-gitea.sh
#      sudo bash install-gitea.sh
#
#  支持两种部署方式：
#    - 二进制 + systemd（推荐，依赖少、升级只换一个文件）
#    - Docker Compose（数据库一起拉起，环境隔离）
#
#  所有需要决策的地方都会弹菜单让你选，回车走默认值。
# ==============================================================================
#
# ------------------------------------------------------------------------------
#  端口说明（本脚本不配置防火墙，请照此自行配置）
# ------------------------------------------------------------------------------
#
#  <HTTP_PORT>/tcp   Web UI / HTTP(S) Git 克隆
#                    → 直接对外时开公网；前面接了 Nginx/Caddy 反代时只开本机。
#
#  <SSH_PORT>/tcp    Git over SSH
#                    → 用内置 SSH 服务时需要单独开放（默认 2222）。
#                    → 复用系统 sshd 时走 22，不需要额外开端口。
#
#  80/tcp            仅「内置 ACME 自动证书」模式需要，且必须对公网开放
#                    （Let's Encrypt HTTP-01 校验，无固定出口 IP，不能做白名单）。
#
#  出站              需放行 443（下载安装包、拉镜像、ACME 签发）。
#
# ------------------------------------------------------------------------------

set -euo pipefail

# ============================================================ 基础工具

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
c_cyn() { printf '\033[36m%s\033[0m\n' "$*"; }
c_bld() { printf '\033[1m%s\033[0m\n'  "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n'  "$*"; }

die() { c_red "错误: $*"; exit 1; }

# 管道执行（curl | bash）时 stdin 被占用，重新挂到终端上，否则所有菜单都读不到输入
if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
        exec 0</dev/tty
    else
        die "需要交互式终端。请改用：sudo bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/install-gitea.sh)"
    fi
fi

MENU_CHOICE=""

# menu "标题" 默认序号 "选项1" "选项2" ...
# 选中的序号写入全局 MENU_CHOICE
menu() {
    local title="$1"; shift
    local def="$1";   shift
    local opts=("$@")
    local i ans
    echo
    c_bld "$title"
    for i in "${!opts[@]}"; do
        if (( i + 1 == def )); then
            printf '  \033[36m%d)\033[0m %s \033[2m(默认)\033[0m\n' "$((i+1))" "${opts[$i]}"
        else
            printf '  \033[36m%d)\033[0m %s\n' "$((i+1))" "${opts[$i]}"
        fi
    done
    while true; do
        read -rp "请输入序号 [1-${#opts[@]}]，回车用默认 ${def}: " ans
        ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            MENU_CHOICE="$ans"
            return 0
        fi
        c_red "  无效输入，请重新选择"
    done
}

# ask 变量名 "提示" ["默认值"]
ask() {
    local __var="$1" prompt="$2" def="${3-}" val
    if [[ -n "$def" ]]; then
        read -rp "${prompt} [${def}]: " val
        val="${val:-$def}"
    else
        read -rp "${prompt}: " val
    fi
    printf -v "$__var" '%s' "$val"
}

# ask_secret 变量名 "提示"
ask_secret() {
    local __var="$1" prompt="$2" val
    read -rsp "${prompt}: " val; echo
    printf -v "$__var" '%s' "$val"
}

# confirm "问题" [Y|N]  默认值
confirm() {
    local prompt="$1" def="${2:-N}" ans hint
    [[ "$def" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "${prompt} ${hint} " ans
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" ]]
}

rand_pw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

# ============================================================ 前置检查

[[ $EUID -eq 0 ]] || die "需要 root 权限，请用 sudo 运行"
[[ "$(uname -s)" == "Linux" ]] || die "本脚本只支持 Linux"

for cmd in curl systemctl; do
    command -v "$cmd" >/dev/null || die "缺少命令: $cmd"
done

# 包管理器
if   command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf     >/dev/null; then PKG=dnf
elif command -v yum     >/dev/null; then PKG=yum
else die "未识别的包管理器（仅支持 apt / dnf / yum）"
fi

pkg_install() {
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
    esac
}
pkg_update() {
    case "$PKG" in
        apt) apt-get update -qq ;;
        *)   : ;;
    esac
}

# CPU 架构
case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm-6 ;;
    i386|i686)     ARCH=386   ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac

GITEA_USER="git"
GITEA_HOME="/home/git"
GITEA_BIN="/usr/local/bin/gitea"
GITEA_CONF_DIR="/etc/gitea"
GITEA_CONF="${GITEA_CONF_DIR}/app.ini"
DOCKER_DIR="/opt/gitea"

clear 2>/dev/null || true
c_bld "=============================================="
c_bld "            Gitea 一键安装脚本"
c_bld "=============================================="
c_dim "  架构: ${ARCH}    包管理器: ${PKG}"
echo

# ============================================================ 旧安装检测

EXISTING=""
if [[ -f "$GITEA_CONF" ]] || [[ -x "$GITEA_BIN" ]]; then
    EXISTING="binary"
elif [[ -f "${DOCKER_DIR}/docker-compose.yml" ]]; then
    EXISTING="docker"
fi

if [[ -n "$EXISTING" ]]; then
    c_ylw "检测到本机已有 Gitea 安装（${EXISTING} 方式）。"
    echo
    menu "如何处理？" 1 \
        "退出，不做任何改动" \
        "仅升级二进制/镜像，保留配置与数据" \
        "覆盖安装（重写配置，保留数据目录）"
    case "$MENU_CHOICE" in
        1) echo "已退出"; exit 0 ;;
        2) MODE_ACTION="upgrade" ;;
        3) MODE_ACTION="reinstall"
           c_ylw "配置文件会被覆盖（旧文件自动备份为 .bak.<时间戳>），仓库与数据库不动。"
           confirm "确认继续？" N || { echo "已取消"; exit 0; }
           ;;
    esac
else
    MODE_ACTION="install"
fi
echo

# ============================================================ 1. 部署方式

menu "【1/9】部署方式" 1 \
    "二进制 + systemd  —— 依赖少、启动快、升级只换一个文件（推荐）" \
    "Docker Compose    —— 数据库一起拉起，环境隔离，需要已装 Docker"

if [[ "$MENU_CHOICE" == "1" ]]; then
    DEPLOY="binary"
else
    DEPLOY="docker"
    command -v docker >/dev/null || die "未检测到 docker，请先安装 Docker 后重试"
    if docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null; then
        DC="docker-compose"
    else
        die "未检测到 docker compose 插件，请先安装"
    fi
fi

# ============================================================ 2. 版本

c_bld "【2/9】Gitea 版本"
echo -n "  正在查询最新版本… "
LATEST="$(curl -fsSL --max-time 10 \
    https://api.github.com/repos/go-gitea/gitea/releases/latest 2>/dev/null \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9.]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -n "$LATEST" ]]; then
    echo "${LATEST}"
    ask VERSION "  安装版本" "$LATEST"
else
    echo "查询失败"
    c_dim "  可在 https://dl.gitea.com/gitea/ 查看可用版本"
    ask VERSION "  安装版本 (如 1.24.3)"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z，例如 1.24.3"

# ============================================================ 3. 数据库

menu "【3/9】数据库" 1 \
    "SQLite3         —— 零维护，单机小团队（< 50 人）足够" \
    "PostgreSQL      —— 本机自动安装并建库（推荐用于中大型实例）" \
    "MySQL / MariaDB —— 本机自动安装并建库" \
    "使用已有的外部数据库（手动填写连接信息）"

DB_TYPE=""; DB_HOST=""; DB_NAME="gitea"; DB_USER="gitea"; DB_PASS=""
DB_LOCAL="no"          # 是否由本脚本安装数据库
DB_IN_DOCKER="no"      # docker 模式下是否起数据库容器

case "$MENU_CHOICE" in
    1)
        DB_TYPE="sqlite3"
        ;;
    2)
        DB_TYPE="postgres"
        [[ "$DEPLOY" == "docker" ]] && DB_IN_DOCKER="yes" || DB_LOCAL="yes"
        DB_HOST="127.0.0.1:5432"
        ;;
    3)
        DB_TYPE="mysql"
        [[ "$DEPLOY" == "docker" ]] && DB_IN_DOCKER="yes" || DB_LOCAL="yes"
        DB_HOST="127.0.0.1:3306"
        ;;
    4)
        menu "  外部数据库类型" 1 "PostgreSQL" "MySQL / MariaDB"
        [[ "$MENU_CHOICE" == "1" ]] && DB_TYPE="postgres" || DB_TYPE="mysql"
        local_def="127.0.0.1:5432"
        [[ "$DB_TYPE" == "mysql" ]] && local_def="127.0.0.1:3306"
        echo
        ask DB_HOST "  数据库地址 host:port" "$local_def"
        ask DB_NAME "  库名"   "gitea"
        ask DB_USER "  用户名" "gitea"
        ask_secret DB_PASS "  密码"
        [[ -n "$DB_PASS" ]] || die "外部数据库密码不能为空"
        ;;
esac

# 本地/容器数据库自动生成密码
if [[ "$DB_LOCAL" == "yes" || "$DB_IN_DOCKER" == "yes" ]]; then
    DB_PASS="$(rand_pw)"
    c_dim "  将自动创建库 ${DB_NAME} / 用户 ${DB_USER}，密码随机生成并写入配置"
fi

# ============================================================ 4. 访问地址与端口

echo
c_bld "【4/9】访问地址与端口"
c_dim "  域名会写进 ROOT_URL，决定页面上显示的克隆地址和各类回调链接。"
c_dim "  没有域名就填服务器公网 IP。"
ask DOMAIN "  访问域名或 IP" "$(hostname -f 2>/dev/null || hostname)"
[[ -n "$DOMAIN" ]] || die "域名不能为空"
[[ "$DOMAIN" != *:* ]] || die "只填域名/IP，不要带端口"
[[ "$DOMAIN" != *://* ]] || die "只填域名/IP，不要带 http:// 前缀"

ask HTTP_PORT "  Web 监听端口" "3000"
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字"

# ============================================================ 5. HTTPS

menu "【5/9】HTTPS" 1 \
    "不启用 —— 纯 HTTP。前面自己接 Nginx / Caddy 反代时选这个" \
    "内置 ACME 自动申请 Let's Encrypt 证书（需要 80 端口对公网开放）" \
    "使用已有证书文件"

HTTPS_MODE="$MENU_CHOICE"
PROTOCOL="http"; ACME_EMAIL=""; CERT_FILE=""; KEY_FILE=""; BEHIND_PROXY="no"

case "$HTTPS_MODE" in
    1)
        PROTOCOL="http"
        echo
        if confirm "  前面会接反向代理（Nginx / Caddy / Traefik）吗？" N; then
            BEHIND_PROXY="yes"
            c_dim "  将只监听 127.0.0.1，并按 https 生成 ROOT_URL"
        fi
        ;;
    2)
        PROTOCOL="https"
        echo
        [[ "$DOMAIN" =~ ^[0-9.]+$ ]] && die "ACME 需要真实域名，不能用 IP"
        ask ACME_EMAIL "  Let's Encrypt 邮箱"
        [[ "$ACME_EMAIL" == *@* ]] || die "邮箱格式不对"
        if [[ "$HTTP_PORT" != "443" ]]; then
            c_ylw "  ACME 签发要求服务监听标准 443 端口，当前填的是 ${HTTP_PORT}"
            if confirm "  改成 443？" Y; then HTTP_PORT=443; fi
        fi
        c_ylw "  注意：${DOMAIN} 的 A 记录必须已指向本机，且 80、443 端口对公网可达"
        ;;
    3)
        PROTOCOL="https"
        echo
        ask CERT_FILE "  证书链路径 (fullchain.pem)"
        ask KEY_FILE  "  私钥路径 (privkey.pem)"
        [[ -f "$CERT_FILE" ]] || die "证书不存在: $CERT_FILE"
        [[ -f "$KEY_FILE"  ]] || die "私钥不存在: $KEY_FILE"
        ;;
esac

# 拼 ROOT_URL
URL_SCHEME="$PROTOCOL"
[[ "$BEHIND_PROXY" == "yes" ]] && URL_SCHEME="https"
if { [[ "$URL_SCHEME" == "http"  ]] && [[ "$HTTP_PORT" == "80"  ]]; } \
|| { [[ "$URL_SCHEME" == "https" ]] && [[ "$HTTP_PORT" == "443" ]]; } \
|| [[ "$BEHIND_PROXY" == "yes" ]]; then
    ROOT_URL="${URL_SCHEME}://${DOMAIN}/"
else
    ROOT_URL="${URL_SCHEME}://${DOMAIN}:${HTTP_PORT}/"
fi
echo
ask ROOT_URL "  确认对外访问地址 ROOT_URL" "$ROOT_URL"
[[ "$ROOT_URL" == */ ]] || ROOT_URL="${ROOT_URL}/"

HTTP_ADDR="0.0.0.0"
[[ "$BEHIND_PROXY" == "yes" ]] && HTTP_ADDR="127.0.0.1"

# ============================================================ 6. Git over SSH

if [[ "$DEPLOY" == "binary" ]]; then
    menu "【6/9】Git over SSH" 1 \
        "Gitea 内置 SSH 服务 —— 独立端口，不碰系统 sshd（推荐）" \
        "复用系统 sshd      —— 走 22 端口，需要往 git 用户写 authorized_keys" \
        "关闭 SSH           —— 只允许 HTTP(S) 克隆"
    SSH_MODE="$MENU_CHOICE"
else
    # 容器内没有系统 sshd，只有内置服务或关闭两种
    menu "【6/9】Git over SSH" 1 \
        "Gitea 内置 SSH 服务（容器内置，映射到宿主机端口）" \
        "关闭 SSH —— 只允许 HTTP(S) 克隆"
    [[ "$MENU_CHOICE" == "1" ]] && SSH_MODE=1 || SSH_MODE=3
fi

DISABLE_SSH="false"; START_SSH_SERVER="true"; SSH_PORT="2222"; SSH_LISTEN_PORT="2222"
case "$SSH_MODE" in
    1)
        echo
        ask SSH_PORT "  内置 SSH 对外端口" "2222"
        [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字"
        SSH_LISTEN_PORT="$SSH_PORT"
        [[ "$DEPLOY" == "docker" ]] && SSH_LISTEN_PORT="22"
        ;;
    2)
        START_SSH_SERVER="false"
        echo
        ask SSH_PORT "  系统 sshd 端口" "22"
        SSH_LISTEN_PORT="$SSH_PORT"
        c_dim "  Gitea 会把公钥写入 ${GITEA_HOME}/.ssh/authorized_keys"
        ;;
    3)
        DISABLE_SSH="true"
        START_SSH_SERVER="false"
        ;;
esac

# ============================================================ 7. 注册与可见性策略

menu "【7/9】注册策略" 2 \
    "开放注册 —— 任何人都能自行注册账号" \
    "关闭注册 —— 只能由管理员创建账号（内网/团队实例推荐）"
[[ "$MENU_CHOICE" == "2" ]] && DISABLE_REGISTRATION="true" || DISABLE_REGISTRATION="false"

menu "【7/9】仓库可见性" 2 \
    "允许匿名浏览 —— 未登录也能看公开仓库" \
    "必须登录才能浏览任何页面（整站私有）"
[[ "$MENU_CHOICE" == "2" ]] && REQUIRE_SIGNIN="true" || REQUIRE_SIGNIN="false"

menu "【7/9】新建仓库默认可见性" 2 \
    "公开 (public)" \
    "私有 (private)"
[[ "$MENU_CHOICE" == "2" ]] && DEFAULT_PRIVATE="private" || DEFAULT_PRIVATE="public"

menu "【7/9】登录验证码" 2 \
    "不启用" \
    "Cloudflare Turnstile —— 登录与注册都需通过人机验证"
CF_TURNSTILE_SITEKEY=""; CF_TURNSTILE_SECRET=""
if [[ "$MENU_CHOICE" == "2" ]]; then
    ENABLE_CAPTCHA="true"
    c_dim "  在 https://dash.cloudflare.com/?to=/:account/turnstile 添加站点获取密钥，"
    c_dim "  Hostname 需包含 ${DOMAIN}（否则验证总是失败，导致无法登录）"
    while [[ -z "$CF_TURNSTILE_SITEKEY" ]]; do ask CF_TURNSTILE_SITEKEY "  Site Key"; done
    while [[ -z "$CF_TURNSTILE_SECRET"  ]]; do ask_secret CF_TURNSTILE_SECRET "  Secret Key"; done
else
    ENABLE_CAPTCHA="false"
fi

# ============================================================ 8. 数据目录

echo
c_bld "【8/9】数据目录"
if [[ "$DEPLOY" == "binary" ]]; then
    c_dim "  仓库、附件、头像、LFS 都放这里，是唯一需要备份的目录（外加数据库）。"
    ask DATA_ROOT "  数据目录" "/var/lib/gitea"
else
    c_dim "  会挂载进容器，是唯一需要备份的目录。"
    ask DATA_ROOT "  宿主机数据目录" "/opt/gitea/data"
fi
[[ "$DATA_ROOT" == /* ]] || die "必须是绝对路径"

# ============================================================ 9. 管理员账号

menu "【9/9】管理员账号" 1 \
    "现在就创建 —— 装完直接登录，跳过 Web 安装向导（推荐）" \
    "稍后在网页上创建"

ADMIN_CREATE="no"; ADMIN_USER=""; ADMIN_PASS=""; ADMIN_MAIL=""
if [[ "$MENU_CHOICE" == "1" ]]; then
    ADMIN_CREATE="yes"
    echo
    ask ADMIN_USER "  管理员用户名" "gitadmin"
    [[ "$ADMIN_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "用户名只能用字母数字和 . _ -"
    [[ "${ADMIN_USER,,}" != "admin" ]] || die "Gitea 保留了 admin 这个名字，请换一个"
    ask ADMIN_MAIL "  管理员邮箱" "${ADMIN_USER}@${DOMAIN}"
    while true; do
        ask_secret ADMIN_PASS "  管理员密码（至少 8 位，留空则随机生成）"
        if [[ -z "$ADMIN_PASS" ]]; then
            ADMIN_PASS="$(rand_pw)"
            c_ylw "  已随机生成密码，安装完成后会打印出来"
            break
        fi
        (( ${#ADMIN_PASS} >= 8 )) || { c_red "  密码太短"; continue; }
        ask_secret ADMIN_PASS2 "  再输一次"
        [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && break
        c_red "  两次不一致，请重输"
    done
fi

# ============================================================ 确认

DB_DESC="$DB_TYPE"
[[ "$DB_LOCAL"     == "yes" ]] && DB_DESC="${DB_TYPE} (本机自动安装)"
[[ "$DB_IN_DOCKER" == "yes" ]] && DB_DESC="${DB_TYPE} (容器)"
[[ "$DB_TYPE" != "sqlite3" && "$DB_LOCAL" == "no" && "$DB_IN_DOCKER" == "no" ]] \
    && DB_DESC="${DB_TYPE} (外部 ${DB_HOST})"

HTTPS_DESC=("" "不启用" "内置 ACME 自动证书" "已有证书文件")
SSH_DESC=("" "内置 SSH 服务 :${SSH_PORT}" "系统 sshd :${SSH_PORT}" "已关闭")

echo
c_bld "=============== 请确认 ==============="
printf '  部署方式     : %s\n' "$([[ "$DEPLOY" == "binary" ]] && echo '二进制 + systemd' || echo 'Docker Compose')"
printf '  Gitea 版本   : %s\n' "$VERSION"
printf '  数据库       : %s\n' "$DB_DESC"
printf '  访问地址     : %s\n' "$ROOT_URL"
printf '  Web 监听     : %s:%s\n' "$HTTP_ADDR" "$HTTP_PORT"
printf '  HTTPS        : %s\n' "${HTTPS_DESC[$HTTPS_MODE]}"
printf '  Git SSH      : %s\n' "${SSH_DESC[$SSH_MODE]}"
printf '  注册         : %s\n' "$([[ "$DISABLE_REGISTRATION" == "true" ]] && echo '已关闭' || echo '开放')"
printf '  匿名浏览     : %s\n' "$([[ "$REQUIRE_SIGNIN" == "true" ]] && echo '禁止（整站私有）' || echo '允许')"
printf '  新仓库默认   : %s\n' "$DEFAULT_PRIVATE"
printf '  登录验证码   : %s\n' "$([[ "$ENABLE_CAPTCHA" == "true" ]] && echo 'Cloudflare Turnstile' || echo '不启用')"
printf '  数据目录     : %s\n' "$DATA_ROOT"
printf '  管理员       : %s\n' "$([[ "$ADMIN_CREATE" == "yes" ]] && echo "$ADMIN_USER <$ADMIN_MAIL>" || echo '稍后在网页创建')"
c_bld "======================================"
echo
confirm "开始安装？" Y || { echo "已取消"; exit 0; }
echo

STEP=0
step() { STEP=$((STEP+1)); c_bld "[${STEP}] $*"; }

# ==============================================================================
#                              Docker Compose 部署
# ==============================================================================

if [[ "$DEPLOY" == "docker" ]]; then

step "准备目录…"
mkdir -p "$DOCKER_DIR" "$DATA_ROOT"
[[ "$DB_IN_DOCKER" == "yes" ]] && mkdir -p "${DATA_ROOT}-db"
c_grn "    ${DOCKER_DIR} / ${DATA_ROOT}"

step "生成 docker-compose.yml…"
[[ -f "${DOCKER_DIR}/docker-compose.yml" ]] && \
    cp "${DOCKER_DIR}/docker-compose.yml" "${DOCKER_DIR}/docker-compose.yml.bak.$(date +%s)"

{
cat <<EOF
services:
  gitea:
    image: gitea/gitea:${VERSION}
    container_name: gitea
    restart: always
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__PROTOCOL=${PROTOCOL}
      - GITEA__server__DOMAIN=${DOMAIN}
      - GITEA__server__ROOT_URL=${ROOT_URL}
      - GITEA__server__HTTP_PORT=3000
      - GITEA__server__DISABLE_SSH=${DISABLE_SSH}
      - GITEA__server__START_SSH_SERVER=${START_SSH_SERVER}
      - GITEA__server__SSH_PORT=${SSH_PORT}
      - GITEA__server__SSH_LISTEN_PORT=${SSH_LISTEN_PORT}
      - GITEA__server__LFS_START_SERVER=true
      - GITEA__server__LANDING_PAGE=login
      - GITEA__security__INSTALL_LOCK=true
      - GITEA__service__DISABLE_REGISTRATION=${DISABLE_REGISTRATION}
      - GITEA__service__REQUIRE_SIGNIN_VIEW=${REQUIRE_SIGNIN}
      - GITEA__repository__DEFAULT_PRIVATE=${DEFAULT_PRIVATE}
      - GITEA__service__ENABLE_CAPTCHA=${ENABLE_CAPTCHA}
      - GITEA__database__DB_TYPE=${DB_TYPE}
EOF

if [[ "$DB_TYPE" != "sqlite3" ]]; then
    if [[ "$DB_IN_DOCKER" == "yes" ]]; then
        [[ "$DB_TYPE" == "postgres" ]] && DBHOST_IN="db:5432" || DBHOST_IN="db:3306"
    else
        DBHOST_IN="$DB_HOST"
    fi
cat <<EOF
      - GITEA__database__HOST=${DBHOST_IN}
      - GITEA__database__NAME=${DB_NAME}
      - GITEA__database__USER=${DB_USER}
      - GITEA__database__PASSWD=${DB_PASS}
EOF
fi

if [[ "$ENABLE_CAPTCHA" == "true" ]]; then
cat <<EOF
      - GITEA__service__REQUIRE_CAPTCHA_FOR_LOGIN=true
      - GITEA__service__REQUIRE_EXTERNAL_REGISTRATION_CAPTCHA=true
      - GITEA__service__CAPTCHA_TYPE=cfturnstile
      - GITEA__service__CF_TURNSTILE_SITEKEY=${CF_TURNSTILE_SITEKEY}
      - GITEA__service__CF_TURNSTILE_SECRET=${CF_TURNSTILE_SECRET}
EOF
fi

if [[ "$HTTPS_MODE" == "2" ]]; then
cat <<EOF
      - GITEA__server__ENABLE_ACME=true
      - GITEA__server__ACME_ACCEPTTOS=true
      - GITEA__server__ACME_EMAIL=${ACME_EMAIL}
      - GITEA__server__ACME_DIRECTORY=https
      - GITEA__server__REDIRECT_OTHER_PORT=true
      - GITEA__server__PORT_TO_REDIRECT=80
EOF
elif [[ "$HTTPS_MODE" == "3" ]]; then
cat <<EOF
      - GITEA__server__CERT_FILE=/certs/fullchain.pem
      - GITEA__server__KEY_FILE=/certs/privkey.pem
EOF
fi

cat <<EOF
    volumes:
      - ${DATA_ROOT}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
EOF
[[ "$HTTPS_MODE" == "3" ]] && cat <<EOF
      - ${CERT_FILE}:/certs/fullchain.pem:ro
      - ${KEY_FILE}:/certs/privkey.pem:ro
EOF

cat <<EOF
    ports:
      - "${HTTP_ADDR}:${HTTP_PORT}:3000"
EOF
[[ "$SSH_MODE" == "1" ]] && printf '      - "%s:22"\n' "$SSH_PORT"
[[ "$HTTPS_MODE" == "2" ]] && printf '      - "80:80"\n'

if [[ "$DB_IN_DOCKER" == "yes" ]]; then
cat <<EOF
    depends_on:
      db:
        condition: service_healthy

  db:
EOF
    if [[ "$DB_TYPE" == "postgres" ]]; then
cat <<EOF
    image: postgres:16-alpine
    container_name: gitea-db
    restart: always
    environment:
      - POSTGRES_DB=${DB_NAME}
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD=${DB_PASS}
    volumes:
      - ${DATA_ROOT}-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 20
EOF
    else
cat <<EOF
    image: mariadb:11
    container_name: gitea-db
    restart: always
    environment:
      - MARIADB_DATABASE=${DB_NAME}
      - MARIADB_USER=${DB_USER}
      - MARIADB_PASSWORD=${DB_PASS}
      - MARIADB_RANDOM_ROOT_PASSWORD=yes
    volumes:
      - ${DATA_ROOT}-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 20
EOF
    fi
fi
} > "${DOCKER_DIR}/docker-compose.yml"

chmod 600 "${DOCKER_DIR}/docker-compose.yml"   # 里面有数据库密码
c_grn "    ${DOCKER_DIR}/docker-compose.yml"

step "拉取镜像并启动…"
cd "$DOCKER_DIR"
$DC pull
$DC up -d
c_grn "    容器已启动"

step "注册 systemd 服务（开机自启 / systemctl 统一管理）…"
DOCKER_BIN="$(command -v docker)"
if [[ "$DC" == "docker compose" ]]; then
    DC_START="${DOCKER_BIN} compose"
else
    DC_START="$(command -v docker-compose)"
fi
cat > /etc/systemd/system/gitea.service <<EOF
[Unit]
Description=Gitea (Docker Compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DOCKER_DIR}
ExecStart=${DC_START} up -d
ExecStop=${DC_START} down
ExecReload=${DC_START} up -d --force-recreate
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gitea >/dev/null 2>&1
c_grn "    /etc/systemd/system/gitea.service（已设为开机自启）"

step "等待 Gitea 就绪…"
READY="no"
for i in $(seq 1 60); do
    if curl -fsS -o /dev/null --max-time 3 -k "http://127.0.0.1:${HTTP_PORT}/api/healthz" 2>/dev/null \
    || curl -fsS -o /dev/null --max-time 3 -k "https://127.0.0.1:${HTTP_PORT}/api/healthz" 2>/dev/null; then
        READY="yes"; break
    fi
    sleep 2
done
if [[ "$READY" == "yes" ]]; then
    c_grn "    已就绪"
else
    c_ylw "    超时未就绪，请查看日志：cd ${DOCKER_DIR} && ${DC} logs -f gitea"
fi

if [[ "$ADMIN_CREATE" == "yes" ]]; then
    step "创建管理员 ${ADMIN_USER}…"
    if $DC exec -u git -T gitea gitea admin user create \
        --username "$ADMIN_USER" --password "$ADMIN_PASS" \
        --email "$ADMIN_MAIL" --admin --must-change-password=false 2>/dev/null; then
        c_grn "    已创建"
    else
        c_ylw "    创建失败（可能已存在同名用户），可稍后手动执行："
        c_dim  "    cd ${DOCKER_DIR} && ${DC} exec -u git gitea gitea admin user create --username X --password Y --email Z --admin"
        ADMIN_CREATE="failed"
    fi
fi

MANAGE_HINT="systemctl status|restart|stop gitea
  cd ${DOCKER_DIR} && ${DC} ps / logs -f gitea"

# ==============================================================================
#                            二进制 + systemd 部署
# ==============================================================================

else

step "安装依赖…"
pkg_update
case "$PKG" in
    apt) pkg_install git git-lfs curl ca-certificates openssl ;;
    *)   pkg_install git curl ca-certificates openssl || true
         pkg_install git-lfs 2>/dev/null || c_ylw "    git-lfs 未装上，可跳过（仅影响 LFS）" ;;
esac
c_grn "    git $(git --version | awk '{print $3}')"

step "创建 ${GITEA_USER} 用户与目录…"
if ! id -u "$GITEA_USER" >/dev/null 2>&1; then
    useradd --system --shell /bin/bash --comment 'Gitea' \
            --create-home --home-dir "$GITEA_HOME" "$GITEA_USER"
    c_grn "    已创建用户 ${GITEA_USER}"
else
    c_grn "    用户 ${GITEA_USER} 已存在"
fi

mkdir -p "${DATA_ROOT}"/{custom,data,log}
chown -R "${GITEA_USER}:${GITEA_USER}" "$DATA_ROOT"
chmod -R 750 "$DATA_ROOT"
mkdir -p "$GITEA_CONF_DIR"
chown root:"$GITEA_USER" "$GITEA_CONF_DIR"
chmod 770 "$GITEA_CONF_DIR"     # 装完收紧成 750
c_grn "    ${DATA_ROOT} / ${GITEA_CONF_DIR}"

# ---------- 数据库 ----------
if [[ "$DB_LOCAL" == "yes" ]]; then
    step "安装并初始化 ${DB_TYPE}…"
    if [[ "$DB_TYPE" == "postgres" ]]; then
        case "$PKG" in
            apt) pkg_install postgresql postgresql-client ;;
            *)   pkg_install postgresql-server postgresql
                 [[ -d /var/lib/pgsql/data/base ]] || postgresql-setup --initdb >/dev/null 2>&1 || true ;;
        esac
        systemctl enable --now postgresql
        for i in $(seq 1 30); do
            sudo -u postgres psql -c 'SELECT 1' >/dev/null 2>&1 && break
            sleep 1
        done
        if sudo -u postgres psql -tAc \
            "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
            sudo -u postgres psql -c \
                "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
            c_grn "    角色 ${DB_USER} 已存在，已重置密码"
        else
            sudo -u postgres psql -c \
                "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
        fi
        if ! sudo -u postgres psql -tAc \
            "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
            sudo -u postgres psql -c \
                "CREATE DATABASE ${DB_NAME} WITH OWNER ${DB_USER} TEMPLATE template0 ENCODING 'UTF8';" >/dev/null
        fi
        c_grn "    库 ${DB_NAME} 就绪"
    else
        case "$PKG" in
            apt) pkg_install mariadb-server mariadb-client ;;
            *)   pkg_install mariadb-server mariadb ;;
        esac
        systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld
        for i in $(seq 1 30); do
            mysql -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 1
        done
        mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
        c_grn "    库 ${DB_NAME} 就绪"
    fi
elif [[ "$DB_TYPE" != "sqlite3" ]]; then
    step "检查外部数据库连通性…"
    db_h="${DB_HOST%%:*}"; db_p="${DB_HOST##*:}"
    if (exec 3<>"/dev/tcp/${db_h}/${db_p}") 2>/dev/null; then
        c_grn "    ${DB_HOST} 可达"
    else
        c_ylw "    ${DB_HOST} 连不上，安装会继续，但 Gitea 起不来。请自行检查网络与库是否已建好。"
    fi
fi

# ---------- 下载二进制 ----------
step "下载 Gitea ${VERSION} (${ARCH})…"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
BASE="https://dl.gitea.com/gitea/${VERSION}"
FILE="gitea-${VERSION}-linux-${ARCH}"

curl -fL --progress-bar -o "${TMPD}/${FILE}" "${BASE}/${FILE}" \
    || die "下载失败: ${BASE}/${FILE}"

if curl -fsSL -o "${TMPD}/${FILE}.sha256" "${BASE}/${FILE}.sha256" 2>/dev/null; then
    ( cd "$TMPD" && sha256sum -c "${FILE}.sha256" >/dev/null 2>&1 ) \
        || die "SHA256 校验失败，文件可能损坏或被篡改"
    c_grn "    SHA256 校验通过"
else
    c_ylw "    未取到 SHA256 校验文件，跳过校验"
fi

if [[ -x "$GITEA_BIN" ]]; then
    cp "$GITEA_BIN" "${GITEA_BIN}.bak.$(date +%s)"
    systemctl stop gitea 2>/dev/null || true
fi
install -m 755 -o root -g root "${TMPD}/${FILE}" "$GITEA_BIN"
c_grn "    $("$GITEA_BIN" --version | head -1)"

# ---------- 写配置 ----------
if [[ "$MODE_ACTION" == "upgrade" && -f "$GITEA_CONF" ]]; then
    step "保留现有配置 ${GITEA_CONF}（升级模式）"
else
    step "写入 ${GITEA_CONF}…"
    [[ -f "$GITEA_CONF" ]] && cp "$GITEA_CONF" "${GITEA_CONF}.bak.$(date +%s)"

    gen_secret() { "$GITEA_BIN" generate secret "$1" 2>/dev/null || openssl rand -base64 32 | tr -d '\n'; }
    SECRET_KEY="$(gen_secret SECRET_KEY)"
    INTERNAL_TOKEN="$(gen_secret INTERNAL_TOKEN)"
    JWT_SECRET="$(gen_secret JWT_SECRET)"
    LFS_JWT_SECRET="$(gen_secret LFS_JWT_SECRET)"

    {
    cat <<EOF
APP_NAME = Gitea
RUN_USER = ${GITEA_USER}
RUN_MODE = prod
WORK_PATH = ${DATA_ROOT}

[server]
PROTOCOL         = ${PROTOCOL}
DOMAIN           = ${DOMAIN}
ROOT_URL         = ${ROOT_URL}
HTTP_ADDR        = ${HTTP_ADDR}
HTTP_PORT        = ${HTTP_PORT}
APP_DATA_PATH    = ${DATA_ROOT}/data
DISABLE_SSH      = ${DISABLE_SSH}
START_SSH_SERVER = ${START_SSH_SERVER}
SSH_PORT         = ${SSH_PORT}
SSH_LISTEN_PORT  = ${SSH_LISTEN_PORT}
SSH_DOMAIN       = ${DOMAIN}
LFS_START_SERVER = true
LFS_JWT_SECRET   = ${LFS_JWT_SECRET}
# 未登录访问首页时跳转到登录页（已登录用户照常进入个人面板）
LANDING_PAGE     = login
OFFLINE_MODE     = true
EOF

    if [[ "$HTTPS_MODE" == "2" ]]; then
    cat <<EOF
ENABLE_ACME       = true
ACME_ACCEPTTOS    = true
ACME_DIRECTORY    = https
ACME_EMAIL        = ${ACME_EMAIL}
REDIRECT_OTHER_PORT = true
PORT_TO_REDIRECT  = 80
EOF
    elif [[ "$HTTPS_MODE" == "3" ]]; then
    cat <<EOF
CERT_FILE = ${CERT_FILE}
KEY_FILE  = ${KEY_FILE}
EOF
    fi

    echo
    echo "[database]"
    if [[ "$DB_TYPE" == "sqlite3" ]]; then
    cat <<EOF
DB_TYPE = sqlite3
PATH    = ${DATA_ROOT}/data/gitea.db
SQLITE_JOURNAL_MODE = WAL
EOF
    else
    cat <<EOF
DB_TYPE  = ${DB_TYPE}
HOST     = ${DB_HOST}
NAME     = ${DB_NAME}
USER     = ${DB_USER}
PASSWD   = ${DB_PASS}
SSL_MODE = disable
EOF
    fi

    cat <<EOF

[repository]
ROOT            = ${DATA_ROOT}/data/gitea-repositories
DEFAULT_PRIVATE = ${DEFAULT_PRIVATE}
DEFAULT_BRANCH  = main

[security]
INSTALL_LOCK   = true
SECRET_KEY     = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}
PASSWORD_HASH_ALGO = pbkdf2

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[service]
DISABLE_REGISTRATION            = ${DISABLE_REGISTRATION}
REQUIRE_SIGNIN_VIEW             = ${REQUIRE_SIGNIN}
REGISTER_EMAIL_CONFIRM          = false
ENABLE_NOTIFY_MAIL              = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = false
ENABLE_CAPTCHA                  = ${ENABLE_CAPTCHA}
; 验证码同时作用于登录与第三方账号注册（Cloudflare Turnstile）
REQUIRE_CAPTCHA_FOR_LOGIN       = ${ENABLE_CAPTCHA}
REQUIRE_EXTERNAL_REGISTRATION_CAPTCHA = ${ENABLE_CAPTCHA}
CAPTCHA_TYPE                    = cfturnstile
CF_TURNSTILE_SITEKEY            = ${CF_TURNSTILE_SITEKEY}
CF_TURNSTILE_SECRET             = ${CF_TURNSTILE_SECRET}
DEFAULT_KEEP_EMAIL_PRIVATE      = true
DEFAULT_ALLOW_CREATE_ORGANIZATION = true
DEFAULT_ENABLE_TIMETRACKING     = true

[mailer]
ENABLED = false

[session]
PROVIDER      = file
COOKIE_SECURE = $([[ "$URL_SCHEME" == "https" ]] && echo true || echo false)

[log]
MODE      = console
LEVEL     = info
ROOT_PATH = ${DATA_ROOT}/log

[cron.update_checker]
ENABLED = false

[actions]
ENABLED = true
EOF
    } > "$GITEA_CONF"

    chown root:"$GITEA_USER" "$GITEA_CONF"
    chmod 640 "$GITEA_CONF"
    c_grn "    已写入（含随机密钥，权限 640 root:${GITEA_USER}）"
fi

# ---------- systemd ----------
step "配置 systemd 服务…"
UNIT_AFTER="network.target"
UNIT_WANTS=""
[[ "$DB_LOCAL" == "yes" && "$DB_TYPE" == "postgres" ]] && { UNIT_AFTER+=" postgresql.service"; UNIT_WANTS="postgresql.service"; }
[[ "$DB_LOCAL" == "yes" && "$DB_TYPE" == "mysql"    ]] && { UNIT_AFTER+=" mariadb.service";    UNIT_WANTS="mariadb.service"; }

CAPS=""
# 绑定 1024 以下端口需要这个能力（80 / 443 / 22）
if (( HTTP_PORT < 1024 )) || [[ "$HTTPS_MODE" == "2" ]] || { [[ "$SSH_MODE" == "1" ]] && (( SSH_LISTEN_PORT < 1024 )); }; then
    CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE"
fi

cat > /etc/systemd/system/gitea.service <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=${UNIT_AFTER}
${UNIT_WANTS:+Wants=${UNIT_WANTS}}

[Service]
Type=simple
User=${GITEA_USER}
Group=${GITEA_USER}
WorkingDirectory=${DATA_ROOT}
ExecStart=${GITEA_BIN} web --config ${GITEA_CONF}
Restart=always
RestartSec=2s
Environment=USER=${GITEA_USER} HOME=${GITEA_HOME} GITEA_WORK_DIR=${DATA_ROOT}
${CAPS}
LimitNOFILE=524288:524288
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_ROOT} ${GITEA_HOME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
c_grn "    /etc/systemd/system/gitea.service"

# ---------- 初始化数据库结构 + 管理员 ----------
if [[ "$ADMIN_CREATE" == "yes" ]]; then
    step "初始化数据库并创建管理员 ${ADMIN_USER}…"
    sudo -u "$GITEA_USER" env GITEA_WORK_DIR="$DATA_ROOT" HOME="$GITEA_HOME" \
        "$GITEA_BIN" migrate --config "$GITEA_CONF" >/dev/null \
        || die "数据库迁移失败，请检查数据库连接配置"
    if sudo -u "$GITEA_USER" env GITEA_WORK_DIR="$DATA_ROOT" HOME="$GITEA_HOME" \
        "$GITEA_BIN" admin user create --config "$GITEA_CONF" \
        --username "$ADMIN_USER" --password "$ADMIN_PASS" \
        --email "$ADMIN_MAIL" --admin --must-change-password=false >/dev/null 2>&1; then
        c_grn "    已创建"
    else
        c_ylw "    创建失败（可能已存在同名用户），可稍后手动执行："
        c_dim  "    sudo -u git ${GITEA_BIN} admin user create --config ${GITEA_CONF} --username X --password Y --email Z --admin"
        ADMIN_CREATE="failed"
    fi
fi

chmod 750 "$GITEA_CONF_DIR"

step "启动服务…"
systemctl enable gitea >/dev/null 2>&1
systemctl restart gitea
sleep 3
if systemctl is-active --quiet gitea; then
    c_grn "    gitea 运行中"
else
    c_red "    启动失败，最近日志："
    journalctl -u gitea -n 30 --no-pager || true
    die "请修正后执行 systemctl restart gitea"
fi

MANAGE_HINT="systemctl status|restart gitea    journalctl -u gitea -f"

fi

# ==============================================================================
#                                   收尾
# ==============================================================================

echo
c_grn "=============================================="
c_grn "                安装完成"
c_grn "=============================================="
echo
c_bld "访问地址"
printf '  %s\n' "$ROOT_URL"
echo

if [[ "$ADMIN_CREATE" == "yes" ]]; then
    c_bld "管理员账号"
    printf '  用户名: %s\n' "$ADMIN_USER"
    printf '  密码  : %s\n' "$ADMIN_PASS"
    printf '  邮箱  : %s\n' "$ADMIN_MAIL"
    c_ylw "  ↑ 请立刻记录并妥善保存，本脚本不会再次显示"
    echo
elif [[ "$ADMIN_CREATE" == "failed" ]]; then
    c_ylw "管理员未创建成功，请按上面的提示手动创建"
    echo
else
    c_ylw "首次访问会进入安装向导，请在网页上创建第一个账号（第一个注册的用户自动成为管理员）"
    echo
fi

if [[ "$SSH_MODE" == "1" ]]; then
    c_bld "Git over SSH"
    printf '  git clone ssh://git@%s:%s/<owner>/<repo>.git\n' "$DOMAIN" "$SSH_PORT"
    echo
elif [[ "$SSH_MODE" == "2" ]]; then
    c_bld "Git over SSH"
    printf '  git clone git@%s:<owner>/<repo>.git\n' "$DOMAIN"
    echo
fi

if [[ "$DB_LOCAL" == "yes" || "$DB_IN_DOCKER" == "yes" ]]; then
    c_bld "数据库"
    printf '  %s  库=%s  用户=%s  密码=%s\n' "$DB_TYPE" "$DB_NAME" "$DB_USER" "$DB_PASS"
    c_dim "  （已写入配置文件，备份时记得一并保存）"
    echo
fi

c_bld "需要放行的端口"
if [[ "$BEHIND_PROXY" == "yes" ]]; then
    printf '  %s/tcp  仅本机（已绑定 127.0.0.1，请在反代里 proxy_pass 到这里）\n' "$HTTP_PORT"
else
    printf '  %s/tcp  Web / HTTP(S) 克隆 → 需对访问者开放\n' "$HTTP_PORT"
fi
[[ "$SSH_MODE" == "1" ]] && printf '  %s/tcp  Git SSH → 需对访问者开放\n' "$SSH_PORT"
[[ "$HTTPS_MODE" == "2" ]] && printf '  80/tcp    ACME HTTP-01 校验 → 必须对公网开放，不能做 IP 白名单\n'
echo

c_bld "日常管理"
printf '  %s\n' "$MANAGE_HINT"
if [[ "$DEPLOY" == "binary" ]]; then
    printf '  配置文件: %s\n' "$GITEA_CONF"
    printf '  数据目录: %s\n' "$DATA_ROOT"
else
    printf '  编排文件: %s/docker-compose.yml\n' "$DOCKER_DIR"
    printf '  数据目录: %s\n' "$DATA_ROOT"
fi
echo

c_bld "备份（这两样缺一不可）"
printf '  1. 数据目录 %s\n' "$DATA_ROOT"
if [[ "$DB_TYPE" == "sqlite3" ]]; then
    printf '  2. 数据库已在数据目录内（gitea.db），停服后整目录打包即可\n'
elif [[ "$DB_TYPE" == "postgres" ]]; then
    printf '  2. 数据库: pg_dump -U %s %s > gitea.sql\n' "$DB_USER" "$DB_NAME"
else
    printf '  2. 数据库: mysqldump -u %s -p %s > gitea.sql\n' "$DB_USER" "$DB_NAME"
fi
echo

if [[ "$BEHIND_PROXY" == "yes" ]]; then
    c_bld "Nginx 反代参考配置"
    cat <<EOF
  server {
      listen 443 ssl http2;
      server_name ${DOMAIN};

      ssl_certificate     /path/fullchain.pem;
      ssl_certificate_key /path/privkey.pem;

      # Git 推送大仓库时必须放开，否则报 413
      client_max_body_size 512M;

      location / {
          proxy_pass http://127.0.0.1:${HTTP_PORT};
          proxy_set_header Host              \$host;
          proxy_set_header X-Real-IP         \$remote_addr;
          proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
          proxy_read_timeout 300s;
      }
  }
EOF
    echo
fi
