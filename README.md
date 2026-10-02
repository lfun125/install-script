# Webhook 一键部署脚本

用于生产环境的 [adnanh/webhook](https://github.com/adnanh/webhook) 一键安装/卸载脚本，配合 docker-compose 实现通过 HTTP 请求触发自动部署，并返回部署结果和详细日志。

## 功能

- 自动下载安装最新版 webhook
- 生成 deploy token 用于鉴权
- 支持部署单个服务或全部服务
- 服务白名单校验，支持设置 `*` 允许任意服务
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
| `-s, --services SERVICES` | 允许的服务名，逗号分隔；`*` 表示允许全部 | `api,web,worker,gateway` |
| `-m, --mirror URL` | GitHub 镜像加速前缀 | 无（直连 GitHub） |

### 安装示例

```bash
# 自定义用户和端口
sudo ./install-webhook.sh install -u deploy -p 8080

# 自定义允许的服务列表
sudo ./install-webhook.sh install -s "api,web,im-server"

# 允许更新指定 Compose 目录中的任意服务
sudo ./install-webhook.sh install --dir /opt/app --services "*"

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

交互式安装时，“允许的服务名”可直接输入 `*`；命令行参数中的 `*` 必须加引号，避免被 Shell 展开为文件名。该设置取消单服务部署接口的白名单限制，范围仍为 `--dir` 指定的 Compose 项目。调用单服务接口时仍需传入具体的 `service` 名称；一次更新全部服务请使用 `deploy-all` 接口，该接口本身不受单服务白名单限制。

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

---

# APT 源添加脚本（nginx / MySQL / MongoDB）

`add-apt-sources.sh` 根据当前系统（Ubuntu / Debian 及其衍生版）自动识别发行代号和架构，添加以下官方 APT 源：

| 源 | 地址 | 可安装的包 |
|----|------|-----------|
| nginx | nginx.org（默认 stable） | `nginx` |
| MySQL | repo.mysql.com（`mysql-8.4-lts` + `mysql-tools`） | `mysql-server`、`mysql-client`、`mysql-shell` |
| MongoDB | repo.mongodb.org（默认 8.0） | `mongodb-org`（服务端）、`mongodb-mongosh`（命令行）、`mongodb-database-tools`（mongodump / mongorestore / mongoimport / mongoexport） |

## 用法

```bash
sudo bash add-apt-sources.sh              # 交互选择要添加的源
sudo bash add-apt-sources.sh nginx mysql  # 只添加指定的源
sudo bash add-apt-sources.sh all          # 全部添加

# 从 GitHub 执行
bash <(curl -fsSL https://raw.githubusercontent.com/lfun125/install-script/refs/heads/main/add-apt-sources.sh) all
```

添加完成后会执行 `apt-get update`，列出安装命令参考，并询问是否直接安装。

## 可选环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `NGINX_BRANCH` | nginx 分支：`stable` / `mainline` | `stable` |
| `MYSQL_SERIES` | MySQL 系列：`8.0` / `8.4-lts` / `9.7-lts` / `innovation` | `8.4-lts` |
| `MONGODB_VERSION` | MongoDB 大版本，如 `7.0` / `8.0` | `8.0` |
| `INSTALL` | 设为 `y` 时添加源后直接安装，不再询问 | 空（询问） |

```bash
sudo NGINX_BRANCH=mainline MYSQL_SERIES=9.7-lts INSTALL=y bash add-apt-sources.sh all
```

## 说明

- 公钥存放在 `/usr/share/keyrings/`，通过 `signed-by` 绑定到对应源，不使用已废弃的 `apt-key`。
- 源文件写入 `/etc/apt/sources.list.d/`：`nginx.list`、`mysql.list`、`mongodb-org-<版本>.list`。
- nginx 额外写入 `/etc/apt/preferences.d/99nginx`（Pin-Priority 900），确保优先使用 nginx.org 的包而非系统自带版本。
- 官方源尚未支持当前发行代号时（如新发布的系统），自动回退到该发行版已支持的最近代号并提示。
- MongoDB 官方源仅提供 amd64 / arm64。
- MySQL 公钥使用 `RPM-GPG-KEY-mysql-2025`（有效期至 2027-10）。网上常见的 `RPM-GPG-KEY-mysql-2023` 已于 2025-10 过期，会导致 `apt-get update` 签名校验失败。
