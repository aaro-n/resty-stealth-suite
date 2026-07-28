# RestyGuard — TLS 反向代理 + IP 白名单防火墙 (Stealth Edition)

[![Docker](https://img.shields.io/badge/Docker-OpenResty-blue)](https://openresty.org/)
![version](https://img.shields.io/badge/version-3.x-brightgreen)

**RestyGuard** 是一个基于 **OpenResty (Nginx + Lua)** 构建的 TLS 反向代理与 IP 白名单防火墙。它监听 443 端口，通过 SNI（服务器名称指示）将 TLS 流量路由到不同上游，并用 IP 白名单控制访问。在架构上采用了最顶级的**单端口全隐形（Stealth）**设计。所有系统环境变量现已全量对齐至具有 **`RG_`** 统一前缀的新版格式。

---

## 架构概览

```
                       ┌────────────────────────────────────────────────────────┐
                       │                  RestyGuard 容器                       │
                       │                                                        │
                       │  443 端口 (唯一对公网暴露入口)                          │
                       │     │                                                  │
                       │     ▼ (四层 Stream / SNI 预读 + TCP Fast Open)          │
                       │     ├─► [SNI = 业务域名] ─► 校验白名单 ─► 转发至上游     │
                       │     │                        (内存负防缓存加速拦截)     │
                       │     │                                                  │
                       │     └─► [SNI = 授权域名] ─► 无条件放行 (绕过白名单)      │
                       │                                │ (带 PROXY Protocol)   │
                       │                                ▼                       │
                       │                         127.0.0.1:18443                │
                       │                                │                       │
                       │                                ▼                       │
                       │                         127.0.0.1:8443                 │
                       │                         (HTTPS 环回管理 & IP 诊断服务)  │
                       │                            ├─► /auth/SECRET_TOKEN (授权)│
                       │                            └─► /ip (安全 TLS IP 诊断)   │
                       └────────────────────────────────────────────────────────┘
```

### 唯一外部物理端口：443

在公网上，本容器 **100% 仅暴露、仅监听 443 一个物理端口**。原本危险的 `8443` 管理端口和明文裸奔的 `8080` 调试端口完全被隐藏在容器内部的本地环回接口上，外界扫描器完全不可见。

当外部用户访问 `RG_AUTH_DOMAIN`（管理域名，如 `auth.yourdomain.com`）时，四层流网关通过 SNI 预读自动将其识别并放行，绕过白名单直接接力给内部的 `127.0.0.1:8443` 控制台，在保护业务安全的同时，实现了完美的单端口全隐形安全。

---

## 快速开始

### 前提条件

- Docker
- TLS 证书（推荐使用 Cloudflare 15年 Origin CA 证书与 mTLS 结合）

### 1. 生成开发保底证书（首次运行可由容器在后台自动生成并开箱即用）

```bash
# 也可手动使用项目提供的脚本生成：
./scripts/generate-dev-certs.sh
```

### 2. 构建 Docker 镜像

```bash
docker build -t restyguard .
```

### 3. 运行容器 (推荐使用单端口 443 极简配置)

```bash
docker run -d --name my-restyguard \
  -e RG_SECRET_TOKEN="your-strong-secret-here" \
  -e RG_AUTH_DOMAIN="auth.yourdomain.com" \
  -e RG_STREAM_UPSTREAM_RULES="translate.googleapis.com=translate.googleapis.com:443" \
  -p 443:443 \
  restyguard
```

> **⚠️ 安全警告：** `RG_SECRET_TOKEN` 必须设置一个复杂且唯一的密钥。不设置或使用默认值会导致容器拒绝启动。

---

## 环境变量参考

### 必需变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RG_SECRET_TOKEN` | **无（必须设置）** | 管理控制台的认证密钥。启动时强制检查，为空则报错退出。 |

### Stream 代理模块

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RG_STREAM_UPSTREAM_RULES` | **无** | **【推荐】等号多行对齐路由表**，格式：`domain=host:port`。支持多行、支持行首减号与引号脱壳清洗。 |
| `RG_STREAM_UPSTREAM_MAP` | `*:translate.googleapis.com:443` | **旧版兼容冒号路由表**，逗号分隔，优先级低于 `RG_STREAM_UPSTREAM_RULES`。 |
| `RG_NGINX_DNS_RESOLUTION_SECONDS` | `600` | DNS 解析结果在内存中的缓存时间（秒） |
| `RG_NGINX_PROXY_PROTOCOL` | `off` | 是否在 443 stream 入口开启 PROXY 协议接收支持。部署在 Fly.io 等前置有代理的负载均衡设备时设为 `on`。 |

### 自适应多用户与 TOTP 验证模块 (stealth)

网关激活**高隐蔽性 Lua 门禁防线（不弹出 401 浏览器对话框）**。
系统支持**多用户并行**，并且既支持普通的静态密码（通过 URL 洗刷直入），又支持扫码安装的**谷歌身份验证器 (Google Authenticator) 动态口令双向验证**：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RG_NGINX_USERS` | 无 | **多用户静态账密/TOTP 配置列表**。格式为 `username:password_or_TOTP[:optional_totp_secret]`，逗号分隔。如：`RG_NGINX_USERS="aaron:password,bob:TOTP:Base32种子"`。 |
| `RG_NGINX_SESSION_TTL_SECONDS` | `2592000` | 授权成功后颁发的 Cookie 锁在浏览器中的有效天数（秒，默认 30 天）。该 Cookie 锁采用**滑动过期 (Sliding Expiration)** 顺延机制，支持直观单位：如 `30d` (30天)、`24h` (24小时)、`60m` (60分钟)。 |
| `RG_TOTP_VALID_WINDOW_SECONDS` | `300` | 动态口令（TOTP）的有效偏差时间缓冲区。默认 300 秒（5分钟），支持直观单位如 `303s` 或 `5m`。系统会自适应将该时间均分给过去和未来，允许手机上刷新并失效的历史 code 及未来 code 在前后各 2.5 分钟内依旧合法，极大提高时钟容差。 |

### 定时任务与可观测性模块

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RG_NGINX_LOG_LEVEL` | `notice` | Nginx 错误日志打印等级。默认 `notice` 极致静音，可完美屏蔽本地高频环回 proxy connected 冗余日志；需要深度调试时可设为 `info`。 |
| `RG_TASK_CLEAN_LOG_INTERVAL_SECONDS` | `600` | 日志清理任务的执行周期（秒） |
| `RG_TASK_CLEAN_LOG_RETAIN_LINES` | `10` | 日志保留的行数，超出部分将被物理裁剪并触发 reopen 通知 |
| `RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS` | `86400` | 白名单清理任务的执行周期（秒），默认 24 小时 |
| `RG_SHOW_REJECTED_LOG` | `false` | 是否允许通过控制台查看拒绝日志 |
| `RG_SHOW_WHITELIST_DB` | `false` | 是否允许通过控制台查看白名单数据库 |

---

## 管理控制台与授权使用

所有管理接口通过公网唯一 443 端口访问，并且完全实现了 **“URL 参数自动清洗（302 洗刷）”**，100% 杜绝密码在浏览器地址栏和代理日志中泄漏的风险。

### 首次加白激活（使用 TOTP 动态口令示例）

直接在浏览器地址栏中，输入您手机 Google 验证器上的 6 位数字验证码：

```http
https://auth.yourdomain.com/auth/my-secure-token-12345?u=bob&code=123456
```

*   **洗刷与跳转**：页面加载成功的瞬间，Lua 会在您的浏览器中埋入 30 天滑动有效的安全 Cookie 锁，并**立刻执行 302 重定向**跳转到纯净短链接：
    `https://auth.yourdomain.com/auth/my-secure-token-12345`。
    明文参数在地址栏停留时间少于 0.1 秒，完美洗刷痕迹！
*   **黑客刺探**：不提供口令或口令过期试探 ➔ Nginx **绝对不弹出 401 对话框暴露大闸指纹**，而是静默、高保真地反代您的网盘后端，安全等级极高。

### 30 天内后续管理（免参、免密直入）

在此期间，您**不再需要**带上任何 `?u=` 或 `&code=` 参数，直接在书签里访问纯净短链接即可免密加白、免密管理：

```http
https://auth.yourdomain.com/auth/my-secure-token-12345
```

---

## 🖥️ 极客终极防空：使用浏览器“书签脚本 (Bookmarklet)”接管 100% 自动登录探测

由于我们的后端在密码学上追求 **“绝对的零指纹暴露（对外 100% 全隐形，不发送 401 标头刺激弹窗）”**。

为了免去您在首次或新设备登录时，需要手动去拼装 `?u=aaron&code=123456` 长网址的繁琐操作。系统支持并提供了一个**极度智能、可自适应探测 Cookie 锁状态的浏览器书签脚本（Bookmarklet）**：

#### ⚙️ 运行与探测原理：
1.  **安全抗拦截设计（CSP / Service Worker 免疫）**：由于新版网关不提供 401 信号且采用静默欺骗，访客在未授权时会直接被 Nginx 反代渲染您的真实网盘网站。因为网盘网站可能拥有极严格的 Content Security Policy (CSP) 标头或注册了 Service Worker 拦截器，这会直接导致在网盘页面上无法运行任何 `javascript:` 书签弹窗。
2.  **一键离线智能弹窗**：为了彻底绕过浏览器的同源安全锁，新版书签被设计为 **“在当前任意干净页面（如 google.com / 浏览器空白页）上直接点击一秒弹窗加白，已加白设备一键免密直入”** 的卓越交互机制：

#### ✍️ 浏览器一键添加书签脚本（Bookmarklet）：
请在您的电脑或手机浏览器书签栏中添加一个全新书签，在 **“网址 (URL)”** 栏中直接全量粘贴并保存以下一行经过高度压制的 JavaScript 书签代码：

```javascript
javascript:(function(){var domain="YOUR_AUTH_DOMAIN";var prefix="YOUR_PATH_PREFIX";var token="YOUR_SECRET_TOKEN";var username="YOUR_PROXY_USERNAME";var baseUrl="https://"+domain+"/"+prefix+"/"+token;if(window.location.href.indexOf(domain)!==-1){if(document.cookie.indexOf("gkp_active=1")!==-1){window.location.reload();}else{var code=prompt("🔑 [RestyGuard 双重验证]\n\n您的 30 天免密已过期。\n请输入您手机 App (Google Authenticator) 上的 6 位动态验证码：");if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}}else{var code=prompt("🔑 [RestyGuard 智能免密通道]\n\n若当前已处于 30 天免密期内，可直接不输入并点“确定/回车”直入后台。\n\n新设备请直接输入您手机上的 6 位动态验证码：");if(code===""){window.location.href=baseUrl;}else if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}})();
```
*(注：使用时请将上述的配置替换为您自己的真实控制台域名即可永久畅行！)*

---

## 调试与安全 IP 诊断

由于 8080 端口已被彻底废除并公网全隐形，IP 诊断服务已安全收拢。在已加白或 CF Bypass 后，只需访问：

```bash
curl https://auth.yourdomain.com/ip
```

即可得到高安全的客户端真实 IP 精准识别及 CDN 标头调试数据。

---

## 自适应 SNI 动态路由 (零配置，无限扩展)

RestyGuard 支持**自适应 SNI 动态路由**机制。当客户端发起 TLS 握手且携带 SNI（目标域名）时，如果该域名未匹配到任何显式定义的规则，RestyGuard 会自动将流量安全地以四层（TCP Stream）透明透传至 `[SNI域名]:443`。

### 核心优势
1. **零配置扩展**：你不再需要为每一个新增的代理服务修改 `RG_STREAM_UPSTREAM_MAP` 环境变量。
2. **无限代理**：只要你的客户端 IP 处于白名单中，你可以将任何 HTTPS 域名在本地 hosts 文件中指向 RestyGuard IP。RestyGuard 会智能地帮你代理并转发该流量。
3. **免证书维护**：由于采用四层透传（SSL Preread 提取 SNI），RestyGuard 不需要目标域名（如 `github.com`）的任何 SSL 证书和私钥。

### 示例用法
假设你想同时代理谷歌翻译、GitHub 以及 Docker Hub：
1. **运行 RestyGuard** (保持默认配置或不需要指定其他路由映射)：
   ```bash
   docker run -d --name restyguard \
     -e RG_SECRET_TOKEN="your_token" \
     -p 443:443 \
     restyguard
   ```
2. **在本地客户端 hosts 文件中指向 RestyGuard 的公网 IP**：
   ```hosts
   # 谷歌翻译
   <RestyGuard_IP> translate.googleapis.com
   <RestyGuard_IP> translate.google.com
   
   # GitHub 代理
   <RestyGuard_IP> github.com
   <RestyGuard_IP> api.github.com
   <RestyGuard_IP> github.global.ssl.fastly.net
   
   # Docker Hub 代理
   <RestyGuard_IP> registry-1.docker.io
   ```
3. **完成授权**：使用浏览器直接输入账密/TOTP 的 URL 完成自动清洗并加白。
4. **畅快体验**：此时在本地无论是打开网页翻译、拉取 Docker 镜像还是克隆 GitHub 仓库，都将全部在白名单的安全防护下通过 RestyGuard 进行平滑透传加速。

---

## 项目结构

```
├── Dockerfile                        # Docker 构建文件
├── docker-entrypoint.sh              # 容器入口脚本
├── .gitignore                        # Git 忽略规则
├── certs/                            # TLS 证书目录（不提交到仓库）
│   ├── README.md
│   ├── ca.pem
│   ├── cert.pem
│   └── key.pem
├── nginx/
│   ├── lua/
│   │   ├── core/
│   │   │   ├── scheduler.lua         # 定时任务调度器
│   │   │   └── tasks.lua             # 任务实现（极致静音日志裁剪、白名单清理）
│   │   ├── http/
│   │   │   ├── whitelist.lua         # 强写锁物理去重 IP 写入
│   │   │   ├── auth_handler.lua      # 终极自适应无弹窗/TOTP/多用户认证
│   │   │   └── auth_view.lua         # 移动端自适应控制台渲染
│   │   └── stream/
│   │       ├── check_whitelist.lua   # 负防缓存/并发限流物理熔断白名单检查
│   │       └── stream_handler.lua    # 443 L4 智能分流与防公开代理网关
│   └── templates/
│       ├── nginx.conf.template       # 主配置文件模板
│       ├── stream-main.conf.template # Stream 四层服务器模板
│       ├── ssl.conf.template         # TLS 极速加密套件配置
│       ├── mtls.conf.template        # 双向 TLS 校验大闸模板
│       └── ip-validation.conf.template # CDN 真实 IP 优先级识别链
└── scripts/
    └── generate-dev-certs.sh         # 100年长效自签名开发证书生成
```
