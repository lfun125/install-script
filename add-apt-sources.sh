#!/usr/bin/env bash
#
# 根据当前系统（Ubuntu / Debian + 发行代号）添加官方 APT 源：
#
#   nginx    nginx.org 官方源                 → nginx
#   mysql    repo.mysql.com 官方源            → mysql-server / mysql-client / mysql-shell 等
#   mongodb  repo.mongodb.org 官方源          → mongodb-org（服务端）、mongodb-mongosh（命令行）、
#                                              mongodb-database-tools（mongodump / mongorestore /
#                                              mongoimport / mongoexport 等导入导出工具）
#
# 用法：
#   sudo bash add-apt-sources.sh                    # 交互选择要添加的源
#   sudo bash add-apt-sources.sh nginx mysql        # 只添加指定的源
#   sudo bash add-apt-sources.sh all                # 全部添加
#
# 从 GitHub 执行：
#   bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/add-apt-sources.sh) all
#
# 可选环境变量：
#   NGINX_BRANCH=stable|mainline     nginx 分支，默认 stable
#   MYSQL_SERIES=8.4-lts             MySQL 系列（对应源组件 mysql-<系列>），如 8.0 / 8.4-lts / 9.7-lts / innovation
#   MONGODB_VERSION=8.0              MongoDB 大版本，如 7.0 / 8.0
#   INSTALL=y                        添加源后直接安装对应软件包（默认会询问）
#
# 如果官方源尚未支持当前发行代号（例如刚发布的新版本系统），
# 脚本会自动回退到该发行版已被支持的最近代号，并给出提示。
#

set -euo pipefail

NGINX_BRANCH="${NGINX_BRANCH:-stable}"
MYSQL_SERIES="${MYSQL_SERIES:-8.4-lts}"
MONGODB_VERSION="${MONGODB_VERSION:-8.0}"
INSTALL="${INSTALL:-}"

KEYRING_DIR="/usr/share/keyrings"
SOURCES_DIR="/etc/apt/sources.list.d"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_bld()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { c_red "错误: $*"; exit 1; }

# ---------------------------------------------------------------- 前置检查

[[ $EUID -eq 0 ]] || die "需要 root 权限，请用 sudo 运行"
command -v apt-get >/dev/null || die "仅支持基于 APT 的系统（Ubuntu / Debian）"
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) DISTRO="$ID" ;;
    *)
        # 衍生发行版（Linux Mint、Pop!_OS 等）按 ID_LIKE 归类
        if [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
            DISTRO="ubuntu"
            CODENAME_OVERRIDE="${UBUNTU_CODENAME:-}"
        elif [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
            DISTRO="debian"
        else
            die "不支持的系统: ${PRETTY_NAME:-未知}"
        fi
        ;;
esac

CODENAME="${CODENAME_OVERRIDE:-${VERSION_CODENAME:-}}"
[[ -n "$CODENAME" ]] || die "无法识别发行代号（VERSION_CODENAME 为空）"
ARCH="$(dpkg --print-architecture)"

# 各官方源回退用的已知代号（新 → 旧）
if [[ "$DISTRO" == "ubuntu" ]]; then
    FALLBACK_CODENAMES=(noble jammy focal)
else
    FALLBACK_CODENAMES=(trixie bookworm bullseye)
fi

# ---------------------------------------------------------------- 选择要添加的源

ALL_REPOS=(nginx mysql mongodb)
SELECTED=()

if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
        case "${arg,,}" in
            all)                SELECTED=("${ALL_REPOS[@]}") ;;
            nginx|mysql|mongodb) SELECTED+=("${arg,,}") ;;
            -h|--help)          sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *)                  die "未知参数: ${arg}（可选 nginx / mysql / mongodb / all）" ;;
        esac
    done
else
    c_bld "=== 添加 APT 源 ==="
    echo "系统: ${PRETTY_NAME:-$DISTRO} (${DISTRO} ${CODENAME}, ${ARCH})"
    echo
    for r in "${ALL_REPOS[@]}"; do
        read -rp "添加 ${r} 源？[Y/n] " ans
        [[ "${ans,,}" == "n" ]] || SELECTED+=("$r")
    done
fi

[[ ${#SELECTED[@]} -gt 0 ]] || { echo "未选择任何源，退出"; exit 0; }

# ---------------------------------------------------------------- 依赖

c_bld "[准备] 安装依赖 curl / gnupg / ca-certificates…"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg ca-certificates >/dev/null
install -d -m 0755 "$KEYRING_DIR"

# ---------------------------------------------------------------- 工具函数

# 下载 ASCII 公钥并转为 keyring：fetch_key <url> <keyring 文件>
fetch_key() {
    local url="$1" out="$2" tmp
    tmp="$(mktemp)"
    curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; die "下载公钥失败: ${url}"; }
    gpg --dearmor --yes -o "$out" "$tmp"
    rm -f "$tmp"
    chmod 0644 "$out"
}

# 找到源实际支持的代号：pick_codename <Release 文件 URL 模板，{C} 代表代号>
# 优先当前系统代号，否则按 FALLBACK_CODENAMES 依次尝试
pick_codename() {
    local tpl="$1" c
    for c in "$CODENAME" "${FALLBACK_CODENAMES[@]}"; do
        if curl -fsIL -o /dev/null "${tpl//\{C\}/$c}"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

note_fallback() {
    local name="$1" used="$2"
    if [[ "$used" != "$CODENAME" ]]; then
        c_ylw "      ${name} 官方源暂不支持 ${CODENAME}，已回退使用 ${used}"
    fi
}

INSTALL_PKGS=()

# ---------------------------------------------------------------- nginx

add_nginx() {
    c_bld "[nginx] 添加 nginx.org 源（${NGINX_BRANCH}）…"
    local path base keyring="${KEYRING_DIR}/nginx-archive-keyring.gpg" c
    case "$NGINX_BRANCH" in
        stable)   path="packages" ;;
        mainline) path="packages/mainline" ;;
        *)        die "NGINX_BRANCH 只能是 stable 或 mainline" ;;
    esac
    base="https://nginx.org/${path}/${DISTRO}"

    c="$(pick_codename "${base}/dists/{C}/Release")" || die "nginx 源不支持当前系统"
    note_fallback nginx "$c"

    fetch_key "https://nginx.org/keys/nginx_signing.key" "$keyring"

    echo "deb [arch=${ARCH} signed-by=${keyring}] ${base} ${c} nginx" \
        > "${SOURCES_DIR}/nginx.list"

    # 让 nginx.org 的包优先于系统自带的 nginx
    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

    INSTALL_PKGS+=(nginx)
    c_grn "      已写入 ${SOURCES_DIR}/nginx.list"
}

# ---------------------------------------------------------------- MySQL

add_mysql() {
    c_bld "[mysql] 添加 repo.mysql.com 源（mysql-${MYSQL_SERIES}）…"
    local base="http://repo.mysql.com/apt/${DISTRO}" keyring="${KEYRING_DIR}/mysql-archive-keyring.gpg" c

    c="$(pick_codename "${base}/dists/{C}/Release")" || die "MySQL 源不支持当前系统"
    note_fallback MySQL "$c"

    # 注意：RPM-GPG-KEY-mysql-2023 已于 2025-10 过期；2025 文件是同一把钥匙续期到 2027-10
    fetch_key "https://repo.mysql.com/RPM-GPG-KEY-mysql-2025" "$keyring"

    # mysql-<系列>：服务端 / 客户端；mysql-tools：mysql-shell、mysql-router 等工具
    echo "deb [arch=${ARCH} signed-by=${keyring}] ${base} ${c} mysql-${MYSQL_SERIES} mysql-tools" \
        > "${SOURCES_DIR}/mysql.list"

    INSTALL_PKGS+=(mysql-server mysql-client)
    c_grn "      已写入 ${SOURCES_DIR}/mysql.list"
}

# ---------------------------------------------------------------- MongoDB

add_mongodb() {
    c_bld "[mongodb] 添加 repo.mongodb.org 源（${MONGODB_VERSION}）…"
    local base="https://repo.mongodb.org/apt/${DISTRO}" comp c
    local keyring="${KEYRING_DIR}/mongodb-server-${MONGODB_VERSION}.gpg"

    case "$ARCH" in
        amd64|arm64) ;;
        *) die "MongoDB 官方源仅提供 amd64 / arm64，当前为 ${ARCH}" ;;
    esac
    [[ "$DISTRO" == "ubuntu" ]] && comp="multiverse" || comp="main"

    c="$(pick_codename "${base}/dists/{C}/mongodb-org/${MONGODB_VERSION}/Release")" \
        || die "MongoDB ${MONGODB_VERSION} 源不支持当前系统"
    note_fallback MongoDB "$c"

    fetch_key "https://pgp.mongodb.com/server-${MONGODB_VERSION}.asc" "$keyring"

    # 清理其他版本的旧 list，避免多个版本源并存
    rm -f "${SOURCES_DIR}"/mongodb-org-*.list
    echo "deb [arch=${ARCH} signed-by=${keyring}] ${base} ${c}/mongodb-org/${MONGODB_VERSION} ${comp}" \
        > "${SOURCES_DIR}/mongodb-org-${MONGODB_VERSION}.list"

    # mongodb-org 元包已包含 mongod、mongos、mongosh 和 database-tools，
    # 这里显式列出，方便只想装工具的人按需裁剪
    INSTALL_PKGS+=(mongodb-org mongodb-mongosh mongodb-database-tools)
    c_grn "      已写入 ${SOURCES_DIR}/mongodb-org-${MONGODB_VERSION}.list"
}

# ---------------------------------------------------------------- 执行

echo
for r in "${SELECTED[@]}"; do
    "add_${r}"
done

echo
c_bld "[更新] apt-get update…"
if ! apt-get update; then
    die "apt-get update 失败，请检查上方输出（常见原因：公钥过期、网络不通）"
fi

echo
c_grn "=== 源添加完成 ==="
echo
echo "安装命令参考："
for r in "${SELECTED[@]}"; do
    case "$r" in
        nginx)   echo "  apt-get install -y nginx" ;;
        mysql)   echo "  apt-get install -y mysql-server        # 服务端（自带客户端）"
                 echo "  apt-get install -y mysql-client        # 仅客户端"
                 echo "  apt-get install -y mysql-shell         # MySQL Shell (mysqlsh)" ;;
        mongodb) echo "  apt-get install -y mongodb-org         # 服务端 + mongosh + 导入导出工具"
                 echo "  apt-get install -y mongodb-mongosh     # 仅命令行 mongosh"
                 echo "  apt-get install -y mongodb-database-tools  # 仅 mongodump/mongorestore/mongoimport/mongoexport" ;;
    esac
done
echo

if [[ -z "$INSTALL" ]]; then
    read -rp "现在安装以上默认软件包（${INSTALL_PKGS[*]}）？[y/N] " INSTALL
fi
if [[ "${INSTALL,,}" == "y" ]]; then
    # 不设 noninteractive：mysql-server 安装时需要交互设置 root 密码
    apt-get install -y "${INSTALL_PKGS[@]}"
    c_grn "安装完成"
    for r in "${SELECTED[@]}"; do
        case "$r" in
            nginx)   echo "  nginx:   $(nginx -v 2>&1)" ;;
            mysql)   echo "  mysql:   $(mysql --version)" ;;
            mongodb) echo "  mongod:  $(mongod --version | head -1)"
                     echo "  mongosh: $(mongosh --version)"
                     echo "  tools:   $(mongodump --version | head -1)" ;;
        esac
    done
    echo
    c_ylw "提示：服务默认可能未启动，可执行 systemctl enable --now nginx / mysql / mongod"
fi
