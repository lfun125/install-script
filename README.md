# Webhook 一键部署脚本

用于生产环境的 [adnanh/webhook](https://github.com/adnanh/webhook) 一键安装/卸载脚本，配合 docker-compose 实现通过 HTTP 请求触发自动部署，并返回部署结果和详细日志。

## 功能

- 自动下载安装最新版 webhook
- 生成 deploy token 用于鉴权
- 支持部署单个服务或全部服务
- 服务白名单校验，防止非法调用
- 部署结果通过 HTTP 响应直接返回（包含容器状态、镜像信息）
- 自动配置 systemd 服务，开机自启
- 支持 GitHub 镜像加速（国内环境）

## 前置条件

- Linux 系统（支持 amd64 / arm64 / armhf）
- root 权限
- 已安装 Docker 和 docker-compose
- 已安装 curl、openssl

## 快速开始

```bash
# 下载脚本
chmod +x install-webhook.sh

# 使用默认配置安装
sudo ./install-webhook.sh install

# 国内环境使用镜像加速
sudo ./install-webhook.sh install --mirror https://ghfast.top
```

## 用法

```
./install-webhook.sh install [选项]    安装 webhook
./install-webhook.sh uninstall         卸载 webhook
./install-webhook.sh status            查看状态
./install-webhook.sh help              显示帮助
```

### 安装选项

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-u, --user USER` | 运行用户 | `apiuser` |
| `-p, --port PORT` | 监听端口 | `9000` |
| `-t, --token TOKEN` | 部署密钥 | 自动生成 |
| `-d, --dir DIR` | docker-compose 目录 | `/home/USER` |
| `-s, --services SERVICES` | 允许的服务名，逗号分隔 | `api,web,worker,gateway` |
| `-m, --mirror URL` | GitHub 镜像加速前缀 | 无（直连 GitHub） |

### 安装示例

```bash
# 自定义用户和端口
sudo ./install-webhook.sh install -u deploy -p 8080

# 自定义允许的服务列表
sudo ./install-webhook.sh install -s "api,web,im-server"

# 国内镜像 + 自定义配置
sudo ./install-webhook.sh install --mirror https://ghfast.top -u deploy -p 8080

# 指定所有参数
sudo ./install-webhook.sh install \
  --user apiuser \
  --port 9000 \
  --token mytoken123 \
  --dir /opt/app \
  --services "api,web"
```

## API 接口

安装完成后，脚本会输出部署密钥和调用地址。

### 部署单个服务

```bash
curl "http://YOUR_SERVER_IP:9000/hooks/deploy?token=YOUR_TOKEN&service=api"
```

返回示例：

```
开始部署: api
时间: 2025-01-01 12:00:00
----------------------------------------
SUCCESS: api 部署成功

容器状态:
NAME        STATUS
app-api-1   Up 3 seconds
----------------------------------------
镜像信息:
registry.example.com/api   latest
```

### 部署所有服务

```bash
curl "http://YOUR_SERVER_IP:9000/hooks/deploy-all?token=YOUR_TOKEN"
```

## 安装后的文件结构

```
/usr/local/bin/webhook                  # webhook 二进制文件
/etc/systemd/system/webhook.service     # systemd 服务文件
/home/<USER>/webhook/
  ├── hooks.json                        # webhook 路由配置
  ├── deploy.sh                         # 单服务部署脚本
  ├── deploy-all.sh                     # 全量部署脚本
  └── deploy.log                        # 部署日志
```

## 管理命令

```bash
# 查看服务状态
systemctl status webhook

# 重启服务
systemctl restart webhook

# 查看 webhook 运行日志
journalctl -u webhook -f

# 查看部署日志
tail -f /home/<USER>/webhook/deploy.log
```

## 卸载

```bash
sudo ./install-webhook.sh uninstall
```

卸载会删除二进制文件和 systemd 服务，但保留配置目录（`/home/<USER>/webhook`），如需清理请手动删除。

## 国内镜像说明

国内服务器无法直接访问 GitHub 时，使用 `--mirror` 参数指定镜像加速前缀：

```bash
sudo ./install-webhook.sh install --mirror https://ghfast.top
```

常用镜像站：

| 镜像 | 地址 |
|------|------|
| ghfast | `https://ghfast.top` |
| ghproxy | `https://mirror.ghproxy.com` |
| gh-proxy | `https://gh-proxy.com` |

> 镜像站可用性可能随时变化，如遇下载失败请尝试更换。
