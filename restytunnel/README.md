# RestyTunnel —— 双域名金盾防探测极速 HTTPS 代理系统

RestyTunnel 是专为应对深度包检测（DPI）、高强度主动探测（Active Probing）以及流量统计学分类而设计的终极代理解决方案。它基于最新发布的 **OpenResty 1.31**（内嵌 Nginx 1.31.1 稳定版内核）构建，完美实现了“公网是合法的双向加密 mTLS 管理站或博客，暗地里执行 C 语言级四层盲转发隧道”的终极防探测形态。

---

## ⚡ 3分钟极速上手指南 (Quick Start)

只需三步，即可零门槛拉起高防护、极速的安全传输代理服务：

### 1. 配置证书 (不配可直接跳过，系统会自动生成自签名保底)
将您的 SSL 证书文件放入项目根目录下的 `ssl/` 文件夹中：
* `ssl/fullchain.pem`
* `ssl/privkey.pem`

### 2. 配置并启动服务
编辑项目根目录下的 `docker-compose.yml`，根据注释修改您的域名及凭证：
* `PROXY_DOMAIN`: 您的主力代理域名（如 `agent.example.com`）
* `AUTH_DOMAIN`: 您的授权管理域名（如 `auth.example.com`）
* `PROXY_USERNAME` / `PROXY_PASSWORD`: 您的专属登录账号与密码
* `SECRET_TOKEN`: 您的安全访问密令

随后在项目根目录下，执行一键部署命令：
```bash
docker-compose up -d --build
```

### 3. 自助授权与连接使用
* **第一步：授权客户端 IP**
  在您的手机或电脑浏览器中访问您的专属授权链接：
  `https://YOUR_AUTH_DOMAIN/auth/YOUR_TOKEN`（如 `https://auth.example.com/auth/mysecrettoken123`）。
  输入您的账号密码登录，页面提示 **「白名单授权成功」** 即可。
* **第二步：客户端接入**
  在 Chrome 的 **SwitchyOmega** 插件中，新建 HTTPS 情景模式：
  * **协议**：选择 `HTTPS`
  * **服务器**：填写您的代理域名（`PROXY_DOMAIN`）
  * **端口**：`443`
  * **验证**：输入您的账号与密码。启用此情景模式即可开始安全极速的网络接入。

---

本项目的所有技术演进过程、协议设计逻辑与实操方案已高度结构化地拆分在不同的技术文档中，请查阅以下专有章节：

---

## 📂 技术文档指南

为了保持工程的严整度并深度沉淀技术细节，我们已将文档细致拆分为以下几个专有维度：

### 1. 🔬 [安全加固与防刺探测试复盘](./docs/security_hardening.md)
* **核心内容：** 详细记录我们在实测中测试的所有安全维度、发现的逻辑死穴与相应的安全加固逻辑。

### 2. 🎨 [系统架构设计与协议底层指南](./docs/architecture.md)
* **核心内容：** 拆解系统的内存流转拓扑、多协议解耦机制、以及如何实现高并发零时延。

### 3. 💻 [部署、指纹整形与实操指南](./docs/deployment_guide.md)
* **核心内容：** 提供开箱即用的运行配置，以及跨平台（Chrome / Python / Go）客户端的指纹整形与反探测接入方案。

---

## 🛡️ 双域名金融级防探测金盾架构

项目不再采用可能暴露特征的“单域名”或“强行装傻返回 200”模式，而是全面升级为 **“双域名 + 独立安全网关 + mTLS 客户端证书强校验”** 组合拳架构：

* **🌐 代理业务域名 (`PROXY_DOMAIN`)**：
  * 用于正向代理客户端建立数据隧道。为了规避 C 语言原生盲转（`tunnel_pass`）与多路复用 H2/H3 状态机的物理冲突，在公网上主动关闭 H2/H3，协商并跑在 100% 稳定的 **TLS 1.3 + HTTP/1.1** 加密大路。所有明文 `CONNECT` 指令均包裹在强加密隧道内部，对外部呈现为无可挑剔的标准高熵二进制噪声流量，完美融入全球 40% 的正常企业级 API 和长连接流量分布中。
  * **代理防线**：除“合法客户端（持正确账号密码 + 白名单 IP）”之外的任何探测、漏洞扫描、普通 H1 扫描流量，**一律静默、无反应地直通给后端工具**，所有错误全权由您的后端网盘/应用产生，绝不在网络层暴露一丝代理痕迹。
* **🔑 IP 授权域名 (`AUTH_DOMAIN`)**：
  * 用于客户端一键添加/更新白名单 IP 的管理端。
  * **mTLS 双向验证（Authenticated Origin Pulls）**：通过导入 Cloudflare 官方 Root CA，强制要求访问本域名的流量必须通过 Cloudflare 代理并携带客户端证书，**在 SSL 握手阶段即秒杀一切非 CF机房源的直连刺探请求**。
  * **Basic Auth 密码锁**：即使 Token 泄露，控制台首页也受代理账号密码保护，拒绝非法写入。
  * **黑白名单看板**：集成活跃白名单实时生命周期（TTL 倒计时）看板、手动移除、以及最新的十条被拒阻断探测黑名单实时拦截日志。

---

## ⚙️ 环境变量参数详解 (Environment Variables)

为了让您能够极致、灵活地掌控 RestyTunnel 的运行，我们对所有的环境变量参数进行了精细分类：

### 1. 🌐 代理核心层参数
| 环境变量 | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| **`PROXY_DOMAIN`** | `localhost` | **您的主力正向代理域名**。必须直接解析到服务器公网 IP，切勿开启 Cloudflare 小黄云代理（CF 不支持 H2/H3 盲隧道协议）。 |
| **`PROXY_USERNAME`** | `myuser` | **代理客户端连接账号**。同时也是您的白名单管理端登录账号。 |
| **`PROXY_PASSWORD`** | `mypassword` | **代理客户端连接密码**。同时也是您的白名单管理端登录密码。 |
| **`FALLBACK_BACKEND`** | `https://cn.bing.com` | **高保真欺骗回落后端**。检测失败的探测或普通流量会无痕反代至此，推荐设置为您的自建 VPS 网盘工具（如 AList / Cloudreve 等）。 |
| **`NGINX_PORT`** | `443` | **Nginx 运行监听端口**。在 Fly.io 部署时，请根据 TCP 透传需要将其修改为 `10443`。 |

### 2. 🔑 安全金盾 IP 白名单参数
| 环境变量 | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| **`ENABLE_IP_WHITELIST`**| `false` | **是否开启 IP 来源授权白名单功能**。开启后代理服务必须通过双重校验（IP在白名单内 + 密码正确）才允许建立通道。 |
| **`AUTH_DOMAIN`** | `auth.localhost` | **白名单授权管理端域名**。推荐在 Cloudflare 开启小黄云 CDN 代理保护，完美隐藏真实源站 IP。 |
| **`AUTH_PATH_PREFIX`** | `auth` | **第一层防御：自定义前缀子路径**。避免扫描器探测到后台接口。例如改为 `secure`。 |
| **`SECRET_TOKEN`** | `mysecrettoken123` | **第二层防御：随机高强度密令 Token**。授权访问的 URL 会组装为：`https://AUTH_DOMAIN/AUTH_PATH_PREFIX/SECRET_TOKEN`。 |
| **`WHITELIST_IP_TTL_SECONDS`**| `86400` | **单次 IP 白名单授权的有效期时长（秒）**。默认 `86400`（即 24 小时），超时后自动过期失效。 |

### 3. ⏰ 后台定时自动维护参数
| 环境变量 | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| **`RT_ENABLE_CUSTOM_MTLS`** | `false` | **自定义 mTLS 客户端证书强校验开关**。设为 `true` 开启，强制只有提供合法客户端证书（如 Cloudflare AOP 证书）的请求才能进入。 |
| **`TASK_CLEAN_WHITELIST_INTERVAL_SECONDS`**| `3600` | **后台自动扫描白名单过期数据库的运行周期（秒）**。默认每 1 小时后台默默运行清理。 |
| **`TASK_CLEAN_LOG_INTERVAL_SECONDS`**| `60` | **后台自动清理被拒探测日志的运行周期（秒）**。默认每分钟自动缩减日志大小。 |
| **`TASK_CLEAN_LOG_RETAIN_LINES`**| `100` | **被拒探测日志最多保留最新的行数**。默认保留最新的 100 行，防 RAM 临时文件系统占满。 |

---

## 🛠️ 生产环境极速部署实操指南

### 方案 A：常规 VPS 一键部署 (Docker-Compose)

#### 1. 证书放入项目目录
登录您的 Cloudflare 后台，下载对应域名的 **15 年免费源站证书（Origin CA Certificate）**，重命名并放入项目本地的 `ssl/` 目录中：
* `ssl/cert.pem`
* `ssl/key.pem`

#### 2. 配置 docker-compose.yml 
编辑 `docker-compose.yml` 中的环境变量配置（代理域名、授权域名、账号、密码及白名单路径，如上所述）。

#### 3. 启动容器
在项目根目录一键拉起并编译：
```bash
docker-compose up -d --build
```

#### 4. 在 Cloudflare 开启 AOP 双向证书防护 (推荐)
* 进入 Cloudflare 对应域名的后台 ➔ **SSL/TLS** ➔ **源站服务器 (Origin Server)**。
* 找到 **「验证源站拉取」 (Authenticated Origin Pulls)** 选项，点击 **开启 (ON)**。
* 此时在配置中设置环境变量 **`RT_ENABLE_CUSTOM_MTLS=true`** 和 **`RT_CLIENT_CA_CERT_PATH=/etc/nginx/certs/cloudflare-origin-pull-ca.pem`** 重启容器。您的管理域名将获得 100% 无法被源站扫描爆破的密码学级 mTLS 强盾牌！

---

### 方案 B：无状态 Fly.io 极速透传部署 (Flyctl)

本方案不仅支持纯净的 **IPv6 全免费** 运行，也完美契合无状态容器规范。

#### 1. 证书自动复制构建
依然提前把 Cloudflare 15 年源站证书放入本地的 `ssl/` 文件夹。通过我们在 `Dockerfile` 中为您量身定制的 `COPY` 指令，每次运行 `fly deploy` 时，最新的真实证书会自动被打入 Docker 镜像中，做到开箱即启动，无需在 Fly.io Volume 中持久化！

#### 2. 编写 `fly.toml`
在项目根目录创建 `fly.toml`（注意：请根据需要申请 **Dedicated IPv4** 约 $2/月 或直接使用免费的 **Dedicated IPv6**，不可使用 Shared IPv4）：

```toml
app = "your-restytunnel-app"
primary_region = "hkg" # 推荐香港、新加坡等近距离机房

[build]
  dockerfile = "Dockerfile"

# TCP 443 极速透传 (绑定 10443 端口并使用 PROXY 协议接收真实 IP)
[[services]]
  internal_port = 10443
  protocol = "tcp"

  [[services.ports]]
    port = 443
    handlers = ["proxy_proto"] # 🌟 核心：通知 Fly 网关将原始加密 TLS 流量和真实 IP 塞给容器

  [services.concurrency]
    type = "connections"
    hard_limit = 4000
    soft_limit = 3000
```

#### 3. 部署并注入运行时环境变量
一键完成首发部署：
```bash
fly deploy
```
并在 Fly.io 控制台或通过命令行注入您的正向代理密码和白名单 Token：
```bash
fly secrets set PROXY_DOMAIN="agent.yourdomain.com" \
                AUTH_DOMAIN="auth.yourdomain.com" \
                PROXY_USERNAME="myuser" \
                PROXY_PASSWORD="mypassword" \
                SECRET_TOKEN="mysecrettoken123" \
                ENABLE_IP_WHITELIST="true" \
                FALLBACK_BACKEND="https://cn.bing.com" \
                NGINX_PORT="10443"
```

---

## 📱 客户端自助授权使用方法

1. **自动一键授权本端**：
   客户端（例如您的手机或电脑）直接使用浏览器访问您的加密授权路径：
   `https://auth.yourdomain.com/auth/mysecrettoken123`
   * 浏览器会立刻弹出安全登录框，输入您的代理账号和密码；
   * 验证通过，系统会自动捕获并授权您当前的公网 IP，在网页显示 **「白名单授权成功」**！

2. **多端手动精准管理**：
   如果需要为没有浏览器（或尚未获得代理连接授权）的特定软路由、服务器代写 IP：
   * 在控制台首页中间的输入框内，手动输入特定设备 IP 地址（如 `1.2.3.4`），点击 **「提交授权」** 即可完成秒级授权！
   * 活跃的白名单、被拒阻断探测黑名单日志一并实时可视，掌控全局！

*“越简单，往往越坚固。” 这是 RestyTunnel 的信条，也是您值得信赖的网络安全防护网！*
