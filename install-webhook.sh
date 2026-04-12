#!/bin/bash
set -e

#===============================================
# Webhook 一键安装/卸载脚本
# 用于生产环境 docker-compose 自动部署
# 支持返回部署结果和详细日志
#===============================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#===============================================
# 默认配置
#===============================================
WEBHOOK_USER="apiuser"
WEBHOOK_PORT="9000"
DEPLOY_TOKEN=""
COMPOSE_DIR=""
ALLOWED_SERVICES="api,web,worker,gateway"
GITHUB_MIRROR=""
ACTION=""

#===============================================
# 帮助信息
#===============================================
show_help() {
    cat << EOF
${GREEN}Webhook 一键安装/卸载脚本${NC}

用法:
    $0 install [选项]    安装 webhook
    $0 uninstall         卸载 webhook
    $0 status            查看状态
    $0 help              显示帮助

安装选项:
    -u, --user USER           运行用户 (默认: apiuser)
    -p, --port PORT           监听端口 (默认: 9000)
    -t, --token TOKEN         部署密钥 (默认: 自动生成)
    -d, --dir DIR             docker-compose 目录 (默认: /home/USER)
    -s, --services SERVICES   允许的服务名，逗号分隔 (默认: api,web,worker,gateway)
    -m, --mirror URL          GitHub 镜像加速前缀，国内推荐 https://ghfast.top

示例:
    # 使用默认配置安装
    $0 install

    # 自定义配置安装
    $0 install -u deploy -p 8080 -s "api,web,im-server"

    # 国内使用镜像加速安装
    $0 install --mirror https://ghfast.top

    # 指定所有参数
    $0 install --user apiuser --port 9000 --token mytoken123 --dir /opt/app --services "api,web"

    # 卸载
    $0 uninstall

EOF
}

#===============================================
# 解析参数
#===============================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            install|uninstall|status|help)
                ACTION="$1"
                shift
                ;;
            -u|--user)
                WEBHOOK_USER="$2"
                shift 2
                ;;
            -p|--port)
                WEBHOOK_PORT="$2"
                shift 2
                ;;
            -t|--token)
                DEPLOY_TOKEN="$2"
                shift 2
                ;;
            -d|--dir)
                COMPOSE_DIR="$2"
                shift 2
                ;;
            -s|--services)
                ALLOWED_SERVICES="$2"
                shift 2
                ;;
            -m|--mirror)
                GITHUB_MIRROR="${2%/}"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知参数: $1\n使用 '$0 help' 查看帮助"
                ;;
        esac
    done

    # 设置默认值
    if [[ -z "$COMPOSE_DIR" ]]; then
        COMPOSE_DIR="/home/${WEBHOOK_USER}"
    fi

    if [[ -z "$DEPLOY_TOKEN" ]]; then
        DEPLOY_TOKEN="$(openssl rand -hex 16)"
    fi
}

#===============================================
# 检查 root 权限
#===============================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本"
    fi
}

#===============================================
# 查看状态
#===============================================
do_status() {
    echo ""
    echo -e "${BLUE}=== Webhook 状态 ===${NC}"
    echo ""
    
    # 检查是否安装
    if command -v webhook &> /dev/null; then
        info "webhook 已安装: $(webhook -version 2>&1)"
    else
        warn "webhook 未安装"
    fi
    
    # 检查服务状态
    if systemctl is-active --quiet webhook 2>/dev/null; then
        info "服务状态: 运行中"
        echo ""
        systemctl status webhook --no-pager -l | head -15
    else
        warn "服务状态: 未运行"
    fi
    
    # 检查配置文件
    echo ""
    for user_home in /home/*; do
        if [[ -f "${user_home}/webhook/hooks.json" ]]; then
            info "配置目录: ${user_home}/webhook"
        fi
    done
    
    echo ""
}

#===============================================
# 卸载
#===============================================
do_uninstall() {
    check_root
    
    echo ""
    warn "即将卸载 webhook，这将删除:"
    echo "  - /usr/local/bin/webhook"
    echo "  - /etc/systemd/system/webhook.service"
    echo ""
    read -p "是否继续？[y/N] " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "取消卸载"
        exit 0
    fi
    
    # 停止服务
    if systemctl is-active --quiet webhook 2>/dev/null; then
        info "停止 webhook 服务..."
        systemctl stop webhook
    fi
    
    # 禁用服务
    if systemctl is-enabled --quiet webhook 2>/dev/null; then
        info "禁用 webhook 服务..."
        systemctl disable webhook
    fi
    
    # 删除服务文件
    if [[ -f /etc/systemd/system/webhook.service ]]; then
        info "删除 systemd 服务文件..."
        rm -f /etc/systemd/system/webhook.service
        systemctl daemon-reload
    fi
    
    # 删除二进制文件
    if [[ -f /usr/local/bin/webhook ]]; then
        info "删除 webhook 二进制文件..."
        rm -f /usr/local/bin/webhook
    fi
    
    echo ""
    info "webhook 已卸载"
    echo ""
    warn "配置目录未删除，如需删除请手动执行:"
    echo "  rm -rf /home/${WEBHOOK_USER}/webhook"
    echo ""
}

#===============================================
# 安装
#===============================================
do_install() {
    check_root
    
    # 显示配置
    echo ""
    echo -e "${BLUE}=== 安装配置 ===${NC}"
    echo "  用户: ${WEBHOOK_USER}"
    echo "  端口: ${WEBHOOK_PORT}"
    echo "  Compose目录: ${COMPOSE_DIR}"
    echo "  允许的服务: ${ALLOWED_SERVICES}"
    echo ""
    
    # 检查用户是否存在
    if ! id "$WEBHOOK_USER" &>/dev/null; then
        error "用户 $WEBHOOK_USER 不存在"
    fi
    
    # 检查 compose 目录
    if [[ ! -d "$COMPOSE_DIR" ]]; then
        warn "目录 $COMPOSE_DIR 不存在，是否创建？[Y/n]"
        read -r CREATE_DIR
        if [[ "$CREATE_DIR" =~ ^[Nn]$ ]]; then
            error "取消安装"
        fi
        mkdir -p "$COMPOSE_DIR"
        chown "${WEBHOOK_USER}:${WEBHOOK_USER}" "$COMPOSE_DIR"
    fi
    
    # 获取最新版本
    info "检查 webhook 最新版本..."
    if [[ -n "$GITHUB_MIRROR" ]]; then
        info "使用镜像加速: $GITHUB_MIRROR"
    fi
    LATEST_VERSION=$(curl -s ${GITHUB_MIRROR:+${GITHUB_MIRROR}/}https://api.github.com/repos/adnanh/webhook/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_VERSION" ]]; then
        error "无法获取最新版本信息"
    fi
    
    info "最新版本: $LATEST_VERSION"
    
    # 检查是否已安装
    if command -v webhook &> /dev/null; then
        CURRENT_VERSION=$(webhook -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        info "当前已安装版本: $CURRENT_VERSION"
        
        if [[ "$CURRENT_VERSION" == "${LATEST_VERSION#v}" ]]; then
            warn "已是最新版本，是否继续重新安装？[y/N]"
            read -r CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                info "取消安装"
                exit 0
            fi
        fi
    fi
    
    # 下载安装
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armhf" ;;
        *)       error "不支持的架构: $ARCH" ;;
    esac
    
    DOWNLOAD_URL="${GITHUB_MIRROR:+${GITHUB_MIRROR}/}https://github.com/adnanh/webhook/releases/download/${LATEST_VERSION}/webhook-linux-${ARCH}.tar.gz"
    TMP_DIR=$(mktemp -d)
    
    info "下载 webhook..."
    curl -L -o "${TMP_DIR}/webhook.tar.gz" "$DOWNLOAD_URL" || error "下载失败"
    
    info "解压安装..."
    tar -xzf "${TMP_DIR}/webhook.tar.gz" -C "${TMP_DIR}"
    mv "${TMP_DIR}/webhook-linux-${ARCH}/webhook" /usr/local/bin/webhook
    chmod +x /usr/local/bin/webhook
    
    rm -rf "${TMP_DIR}"
    
    info "安装完成: $(webhook -version 2>&1)"
    
    # 创建配置目录
    WEBHOOK_DIR="/home/${WEBHOOK_USER}/webhook"
    info "创建配置目录: $WEBHOOK_DIR"
    mkdir -p "$WEBHOOK_DIR"
    
    # 创建 hooks.json（添加输出返回配置）
    info "创建 hooks.json..."
    cat > "${WEBHOOK_DIR}/hooks.json" << EOF
[
  {
    "id": "deploy",
    "execute-command": "${WEBHOOK_DIR}/deploy.sh",
    "command-working-directory": "${COMPOSE_DIR}",
    "include-command-output-in-response": true,
    "include-command-output-in-response-on-error": true,
    "pass-arguments-to-command": [
      {
        "source": "url",
        "name": "service"
      }
    ],
    "trigger-rule": {
      "match": {
        "type": "value",
        "value": "${DEPLOY_TOKEN}",
        "parameter": {
          "source": "url",
          "name": "token"
        }
      }
    }
  },
  {
    "id": "deploy-all",
    "execute-command": "${WEBHOOK_DIR}/deploy-all.sh",
    "command-working-directory": "${COMPOSE_DIR}",
    "include-command-output-in-response": true,
    "include-command-output-in-response-on-error": true,
    "trigger-rule": {
      "match": {
        "type": "value",
        "value": "${DEPLOY_TOKEN}",
        "parameter": {
          "source": "url",
          "name": "token"
        }
      }
    }
  }
]
EOF

    # 创建部署脚本（单服务）- 详细版本
    info "创建 deploy.sh..."
    cat > "${WEBHOOK_DIR}/deploy.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash

SERVICE_NAME=$1
LOG_FILE="WEBHOOK_DIR_PLACEHOLDER/deploy.log"
COMPOSE_DIR="COMPOSE_DIR_PLACEHOLDER"

# 允许的服务白名单
IFS=',' read -ra ALLOWED_SERVICES <<< "ALLOWED_SERVICES_PLACEHOLDER"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 校验服务名
if [[ -z "$SERVICE_NAME" ]]; then
    log "ERROR: 未指定服务名"
    echo "ERROR: 未指定服务名"
    exit 1
fi

VALID=false
for svc in "${ALLOWED_SERVICES[@]}"; do
    if [[ "$svc" == "$SERVICE_NAME" ]]; then
        VALID=true
        break
    fi
done

if [[ "$VALID" != "true" ]]; then
    log "ERROR: 无效的服务名: $SERVICE_NAME (允许: ${ALLOWED_SERVICES[*]})"
    echo "ERROR: 无效的服务名: $SERVICE_NAME"
    echo "允许的服务: ${ALLOWED_SERVICES[*]}"
    exit 1
fi

log "========== 开始部署: $SERVICE_NAME =========="
echo "开始部署: $SERVICE_NAME"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------"

cd "$COMPOSE_DIR"

# 执行部署并捕获输出
echo "拉取镜像并启动服务..."
OUTPUT=$(docker compose up -d --pull always "$SERVICE_NAME" 2>&1)
EXIT_CODE=$?

# 记录输出到日志
log "$OUTPUT"

if [[ $EXIT_CODE -eq 0 ]]; then
    # 等待容器启动
    sleep 3
    
    # 检查容器状态
    CONTAINER_STATUS=$(docker compose ps "$SERVICE_NAME" --format "table {{.Name}}\t{{.Status}}" 2>&1)
    
    if echo "$CONTAINER_STATUS" | grep -q "Up"; then
        log "SUCCESS: $SERVICE_NAME 部署成功"
        echo "----------------------------------------"
        echo "SUCCESS: $SERVICE_NAME 部署成功"
        echo ""
        echo "容器状态:"
        echo "$CONTAINER_STATUS"
        echo "----------------------------------------"
        
        # 显示镜像信息
        IMAGE_INFO=$(docker compose images "$SERVICE_NAME" --format "table {{.Repository}}\t{{.Tag}}" 2>&1 | tail -n +2)
        if [[ -n "$IMAGE_INFO" ]]; then
            echo "镜像信息:"
            echo "$IMAGE_INFO"
        fi
    else
        log "WARNING: $SERVICE_NAME 部署完成但状态异常"
        echo "----------------------------------------"
        echo "WARNING: 部署完成但容器状态异常"
        echo ""
        echo "容器状态:"
        echo "$CONTAINER_STATUS"
        echo ""
        echo "最近日志:"
        docker compose logs --tail=10 "$SERVICE_NAME" 2>&1
        exit 1
    fi
else
    log "FAILED: $SERVICE_NAME 部署失败 (退出码: $EXIT_CODE)"
    echo "----------------------------------------"
    echo "FAILED: $SERVICE_NAME 部署失败"
    echo ""
    echo "错误信息:"
    echo "$OUTPUT"
    exit 1
fi

log "========== 部署结束 =========="
DEPLOY_SCRIPT

    # 替换占位符
    sed -i "s|WEBHOOK_DIR_PLACEHOLDER|${WEBHOOK_DIR}|g" "${WEBHOOK_DIR}/deploy.sh"
    sed -i "s|COMPOSE_DIR_PLACEHOLDER|${COMPOSE_DIR}|g" "${WEBHOOK_DIR}/deploy.sh"
    sed -i "s|ALLOWED_SERVICES_PLACEHOLDER|${ALLOWED_SERVICES}|g" "${WEBHOOK_DIR}/deploy.sh"

    # 创建部署脚本（全部服务）- 详细版本
    info "创建 deploy-all.sh..."
    cat > "${WEBHOOK_DIR}/deploy-all.sh" << DEPLOY_ALL_SCRIPT
#!/bin/bash

LOG_FILE="${WEBHOOK_DIR}/deploy.log"
COMPOSE_DIR="${COMPOSE_DIR}"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a "\$LOG_FILE"
}

log "========== 开始部署所有服务 =========="
echo "开始部署所有服务"
echo "时间: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------"

cd "\$COMPOSE_DIR"

# 拉取所有镜像
echo "拉取镜像..."
PULL_OUTPUT=\$(docker compose pull 2>&1)
PULL_CODE=\$?
log "\$PULL_OUTPUT"

if [[ \$PULL_CODE -ne 0 ]]; then
    echo "WARNING: 部分镜像拉取失败"
    echo "\$PULL_OUTPUT"
fi

# 启动服务
echo "启动服务..."
UP_OUTPUT=\$(docker compose up -d 2>&1)
UP_CODE=\$?
log "\$UP_OUTPUT"

if [[ \$UP_CODE -ne 0 ]]; then
    log "FAILED: 服务启动失败"
    echo "----------------------------------------"
    echo "FAILED: 服务启动失败"
    echo "\$UP_OUTPUT"
    exit 1
fi

# 等待容器启动
sleep 3

# 显示所有容器状态
echo "----------------------------------------"
echo "容器状态:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>&1

# 清理旧镜像
echo ""
echo "清理旧镜像..."
PRUNE_OUTPUT=\$(docker image prune -f 2>&1)
if [[ -n "\$PRUNE_OUTPUT" && "\$PRUNE_OUTPUT" != "Total reclaimed space: 0B" ]]; then
    echo "\$PRUNE_OUTPUT"
fi

log "SUCCESS: 所有服务部署完成"
echo "----------------------------------------"
echo "SUCCESS: 所有服务部署完成"

log "========== 部署结束 =========="
DEPLOY_ALL_SCRIPT

    chmod +x "${WEBHOOK_DIR}/deploy.sh"
    chmod +x "${WEBHOOK_DIR}/deploy-all.sh"
    
    # 设置权限
    chown -R "${WEBHOOK_USER}:${WEBHOOK_USER}" "$WEBHOOK_DIR"
    
    # 创建 systemd 服务
    info "配置 systemd 服务..."
    cat > /etc/systemd/system/webhook.service << EOF
[Unit]
Description=Webhook Server
After=network.target docker.service

[Service]
Type=simple
User=${WEBHOOK_USER}
Group=${WEBHOOK_USER}
WorkingDirectory=/home/${WEBHOOK_USER}
ExecStart=/usr/local/bin/webhook -hooks ${WEBHOOK_DIR}/hooks.json -verbose -port ${WEBHOOK_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable webhook
    systemctl restart webhook
    
    # 等待服务启动
    sleep 2
    if systemctl is-active --quiet webhook; then
        info "webhook 服务启动成功"
    else
        error "webhook 服务启动失败，请检查: journalctl -u webhook"
    fi
    
    # 输出信息
    echo ""
    echo "=============================================="
    echo -e "${GREEN}安装完成！${NC}"
    echo "=============================================="
    echo ""
    echo "配置信息:"
    echo "  - 版本: ${LATEST_VERSION}"
    echo "  - 端口: ${WEBHOOK_PORT}"
    echo "  - 用户: ${WEBHOOK_USER}"
    echo "  - 配置目录: ${WEBHOOK_DIR}"
    echo "  - Compose目录: ${COMPOSE_DIR}"
    echo ""
    echo -e "${YELLOW}部署密钥 (请妥善保存):${NC}"
    echo "  ${DEPLOY_TOKEN}"
    echo ""
    echo "调用示例:"
    echo "  # 部署单个服务"
    echo "  curl \"http://YOUR_SERVER_IP:${WEBHOOK_PORT}/hooks/deploy?token=${DEPLOY_TOKEN}&service=api\""
    echo ""
    echo "  # 部署所有服务"
    echo "  curl \"http://YOUR_SERVER_IP:${WEBHOOK_PORT}/hooks/deploy-all?token=${DEPLOY_TOKEN}\""
    echo ""
    echo "返回示例:"
    echo "  SUCCESS: api 部署成功"
    echo "  容器状态: Up 3 seconds"
    echo ""
    echo "允许的服务: ${ALLOWED_SERVICES}"
    echo ""
    echo "管理命令:"
    echo "  systemctl status webhook   # 查看状态"
    echo "  systemctl restart webhook  # 重启服务"
    echo "  journalctl -u webhook -f   # 查看日志"
    echo "  tail -f ${WEBHOOK_DIR}/deploy.log  # 部署日志"
    echo ""
    echo "=============================================="
}

#===============================================
# 主程序
#===============================================
main() {
    # 无参数显示帮助
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    parse_args "$@"
    
    case $ACTION in
        install)
            do_install
            ;;
        uninstall)
            do_uninstall
            ;;
        status)
            do_status
            ;;
        help)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

main "$@"
