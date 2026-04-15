#!/bin/bash

# Debian 初始化脚本
# 需要以 root 权限运行

set -e

# 打印函数
print_info() {
    printf "\033[0;34m[INFO]\033[0m %s\n" "$1"
}

print_success() {
    printf "\033[0;32m[SUCCESS]\033[0m %s\n" "$1"
}

print_warning() {
    printf "\033[1;33m[WARNING]\033[0m %s\n" "$1"
}

print_error() {
    printf "\033[0;31m[ERROR]\033[0m %s\n" "$1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 1. 设置时区
set_timezone() {
    echo ""
    print_info "=== 设置时区 ==="
    echo "常用时区选项："
    echo "  1) Asia/Shanghai (北京/上海)"
    echo "  2) Asia/Hong_Kong (香港)"
    echo "  3) Asia/Tokyo (东京)"
    echo "  4) Asia/Singapore (新加坡)"
    echo "  5) America/New_York (纽约)"
    echo "  6) America/Los_Angeles (洛杉矶)"
    echo "  7) Europe/London (伦敦)"
    echo "  8) UTC"
    echo "  9) 自定义输入"
    echo ""
    read -p "请选择时区 [默认: 1]: " tz_choice
    tz_choice=${tz_choice:-1}

    case $tz_choice in
        1) timezone="Asia/Shanghai" ;;
        2) timezone="Asia/Hong_Kong" ;;
        3) timezone="Asia/Tokyo" ;;
        4) timezone="Asia/Singapore" ;;
        5) timezone="America/New_York" ;;
        6) timezone="America/Los_Angeles" ;;
        7) timezone="Europe/London" ;;
        8) timezone="UTC" ;;
        9)
            read -p "请输入时区 (如 Asia/Shanghai): " timezone
            ;;
        *) timezone="Asia/Shanghai" ;;
    esac

    timedatectl set-timezone "$timezone"
    print_success "时区已设置为: $timezone"
}

# 2. 修改主机名
set_hostname() {
    echo ""
    print_info "=== 设置主机名 ==="
    current_hostname=$(hostname)
    print_info "当前主机名: $current_hostname"
    
    while true; do
        read -p "是否修改主机名? (y/n) [默认: n]: " change_hostname
        change_hostname=${change_hostname:-n}
        
        if [ "$change_hostname" = "y" ] || [ "$change_hostname" = "Y" ]; then
            read -p "请输入新的主机名: " new_hostname
            if [ -n "$new_hostname" ]; then
                hostnamectl set-hostname "$new_hostname"
                sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
                if ! grep -q "127.0.1.1" /etc/hosts; then
                    echo "127.0.1.1	$new_hostname" >> /etc/hosts
                fi
                print_success "主机名已修改为: $new_hostname"
                break
            else
                print_warning "主机名不能为空，请重新输入"
            fi
        else
            print_info "跳过主机名修改"
            break
        fi
    done
}

# 3. 执行 apt update
run_apt_update() {
    echo ""
    print_info "=== 执行 apt update ==="
    apt update
    print_success "apt update 完成"
}

# 4. 安装 Docker
install_docker() {
    echo ""
    print_info "=== 安装 Docker ==="
    read -p "是否为国内机器? (y/n) [默认: y]: " is_china
    is_china=${is_china:-y}

    if [ "$is_china" = "y" ] || [ "$is_china" = "Y" ]; then
        print_info "使用阿里云源安装 Docker..."
        
        apt install -y gpg curl lsb-release ca-certificates
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        print_info "使用官方源安装 Docker..."
        curl -sSL https://get.docker.com/ | sh
    fi

    systemctl enable docker
    systemctl start docker
    
    print_success "Docker 安装完成"
    docker --version
}

# 5. 设置 vim
setup_vim() {
    echo ""
    print_info "=== 配置 vim ==="
    
    apt install -y vim
    
    if [ -f /etc/vim/vimrc ]; then
        cp /etc/vim/vimrc /etc/vim/vimrc.bak
    fi
    
    grep -q "encoding=utf-8" /etc/vim/vimrc 2>/dev/null || echo ":set encoding=utf-8" >> /etc/vim/vimrc
    grep -q "set ts=4 sw=4" /etc/vim/vimrc 2>/dev/null || echo "set ts=4 sw=4" >> /etc/vim/vimrc
    
    print_success "vim 配置完成"
}

# 6. 添加 apiuser 用户
add_apiuser() {
    echo ""
    print_info "=== 添加 apiuser 用户 ==="
    
    # 修复：使用兼容的重定向语法
    if id "apiuser" >/dev/null 2>&1; then
        print_warning "apiuser 用户已存在，跳过创建"
    else
        adduser --disabled-password --gecos "" apiuser
        print_success "apiuser 用户创建成功"
    fi
    
    gpasswd -a apiuser docker
    
    mkdir -p /home/apiuser/.ssh
    touch /home/apiuser/.ssh/authorized_keys
    
    chmod 755 /home/apiuser/
    chmod 700 /home/apiuser/.ssh
    chmod 600 /home/apiuser/.ssh/authorized_keys
    chown apiuser:apiuser -R /home/apiuser/
    
    print_success "apiuser 用户配置完成"
}

# 7. 设置 SSH 公钥
setup_ssh_key() {
    echo ""
    print_info "=== 设置 SSH 公钥 ==="
    read -p "是否为 apiuser 设置 SSH 公钥? (y/n) [默认: n]: " set_key
    set_key=${set_key:-n}
    
    if [ "$set_key" = "y" ] || [ "$set_key" = "Y" ]; then
        echo "请输入公钥内容 (以 ssh-rsa 或 ssh-ed25519 开头):"
        read -r pubkey
        
        if [ -n "$pubkey" ]; then
            echo "$pubkey" >> /home/apiuser/.ssh/authorized_keys
            chown apiuser:apiuser /home/apiuser/.ssh/authorized_keys
            print_success "SSH 公钥已添加"
        else
            print_warning "公钥内容为空，跳过设置"
        fi
    else
        print_info "跳过 SSH 公钥设置"
    fi
}

# 8. 配置 Docker 私有仓库
setup_docker_registry() {
    echo ""
    print_info "=== 配置 Docker 私有仓库 ==="
    read -p "是否添加支持 HTTP 的私有仓库? (y/n) [默认: n]: " add_registry
    add_registry=${add_registry:-n}
    
    if [ "$add_registry" = "y" ] || [ "$add_registry" = "Y" ]; then
        read -p "请输入私有仓库地址 (如 192.168.1.100:5000): " registry_addr
        
        if [ -n "$registry_addr" ]; then
            daemon_file="/etc/docker/daemon.json"
            
            if [ -f "$daemon_file" ]; then
                cp "$daemon_file" "${daemon_file}.bak"
                print_warning "已备份原配置到 ${daemon_file}.bak"
            fi
            
            # 直接创建新配置
            cat > "$daemon_file" << EOF
{
  "insecure-registries": ["$registry_addr"]
}
EOF
            
            systemctl daemon-reload
            systemctl restart docker
            
            print_success "私有仓库 $registry_addr 配置完成"
        else
            print_warning "仓库地址为空，跳过配置"
        fi
    else
        print_info "跳过私有仓库配置"
    fi
}

# 主函数
main() {
    echo ""
    echo "========================================"
    echo "       Debian 服务器初始化脚本"
    echo "========================================"
    echo ""
    
    check_root
    
    set_timezone
    set_hostname
    run_apt_update
    install_docker
    setup_vim
    add_apiuser
    setup_ssh_key
    setup_docker_registry
    
    echo ""
    echo "========================================"
    print_success "初始化完成!"
    echo "========================================"
    echo ""
    print_info "建议重新登录以使所有配置生效"
}

main
