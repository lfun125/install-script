#!/usr/bin/env bash
# 彻底清理 Teleport 节点安装（deb 包 / 二进制安装 / teleport-update 托管更新）
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

echo "==> 停止并禁用相关 systemd 服务"
for unit in teleport.service teleport-upgrade.service teleport-upgrade.timer \
            teleport-update.service teleport-update.timer; do
  systemctl stop "$unit" 2>/dev/null
  systemctl disable "$unit" 2>/dev/null
done
pkill -x teleport 2>/dev/null

echo "==> 清除软件包（含 rc 残留状态）"
if command -v dpkg >/dev/null 2>&1; then
  for pkg in $(dpkg -l | awk '/teleport/ {print $2}'); do
    echo "    purge $pkg"
    dpkg --purge "$pkg" || apt-get purge -y "$pkg"
  done
fi
if command -v rpm >/dev/null 2>&1; then
  for pkg in $(rpm -qa | grep -i teleport); do
    echo "    erase $pkg"
    rpm -e "$pkg"
  done
fi

echo "==> 删除二进制文件"
for bin in teleport tctl tsh tbot fdpass-teleport teleport-update teleport-upgrade; do
  rm -f "/usr/local/bin/$bin" "/usr/bin/$bin"
done
rm -rf /opt/teleport

echo "==> 删除配置和数据目录"
rm -rf /etc/teleport.yaml /etc/teleport.d /etc/teleport-upgrade.d \
       /var/lib/teleport /run/teleport.pid /var/run/teleport.pid \
       /tmp/teleport-*

echo "==> 删除 systemd 单元文件"
rm -f /etc/systemd/system/teleport*.service /etc/systemd/system/teleport*.timer \
      /lib/systemd/system/teleport*.service /lib/systemd/system/teleport*.timer \
      /usr/lib/systemd/system/teleport*.service /usr/lib/systemd/system/teleport*.timer
rm -rf /etc/systemd/system/teleport*.service.d
systemctl daemon-reload
systemctl reset-failed 2>/dev/null

echo "==> 删除软件源（apt / yum）"
rm -f /etc/apt/sources.list.d/teleport*.list \
      /usr/share/keyrings/teleport-archive-keyring.asc \
      /etc/apt/keyrings/teleport*.asc \
      /etc/yum.repos.d/teleport*.repo

echo
echo "==> 检查残留"
dpkg -l 2>/dev/null | grep teleport && echo "!! 仍有包记录" || echo "    包记录：已清空"
command -v teleport >/dev/null && echo "!! 仍能找到 teleport: $(command -v teleport)" || echo "    二进制：已清空"
systemctl list-unit-files 2>/dev/null | grep -i teleport && echo "!! 仍有 systemd 单元" || echo "    systemd：已清空"
echo "完成。现在可以重新运行安装脚本了。"