# RestyGuard 环境变量全解析

本文档完整收录了驱动 RestyGuard 运行的所有环境变量、其功能说明、默认值以及它们在系统中的作用。所有环境变量均以 **`RG_`** 前缀开头。

---

## 1. 核心认证与路径配置 (Core Authentication & Path)

| 变量名 | 默认值 | **必需** | 说明 |
| :--- | :--- | :---: | :--- |
| `RG_SECRET_TOKEN` | (无) | **是** | **【必需】白名单管理面板的安全密令**。如果未设置或使用默认值 `change-me-please`，容器将启动失败。用于构成管理 URL: `https://[RG_AUTH_DOMAIN]/[RG_AUTH_PATH_PREFIX]/[RG_SECRET_TOKEN]`。 |
| `RG_AUTH_PATH_PREFIX` | `auth` | 否 | **管理接口的子路径前缀**。用于抵御扫描器。 |
| `RG_AUTH_DOMAIN` | `localhost` | 否 | **白名单自助授权控制台域名**。推荐在 Cloudflare 开启 CDN (小黄云) 来隐藏源站 IP。 |
| `RG_FALLBACK_BACKEND` | `https://cn.bing.com` | 否 | **高保真伪装回落后端**。当访问的路径不是管理后台时，请求将被无缝反代到此地址，用于隐藏防火墙特征。 |
| `RG_AUTH_ALLOW_ANY_DOMAIN` | `false` | 否 | **是否允许通过任意域名访问管理控制台**。设为 `true` 时，`server_name` 将设为 `_`；否则，将严格匹配 `RG_AUTH_DOMAIN`。 |

---

## 2. 路由与规则配置 (Routing & Rules)

| 变量名 | 默认值 | **必需** | 说明 |
| :--- | :--- | :---: | :--- |
| `RG_STREAM_UPSTREAM_RULES`| (无) | 否 | **【推荐】新版路由映射表**。格式为 `domain=host:port`，每行一条规则，支持多行。**优先级高于** `RG_STREAM_UPSTREAM_MAP`。 |
| `RG_STREAM_UPSTREAM_MAP` | `*:translate.googleapis.com:443` | 否 | **旧版路由映射表**。格式为 `domain:host:port`，逗号分隔。用于向后兼容。 |
| `RG_UPSTREAM_RULES_FILE`| (空) | 否 | **静态路由规则配置文件在容器内的绝对路径**。如果留空，则默认使用 `/etc/nginx/rules/upstream_rules.conf`。 |

---

## 3. 安全与白名单配置 (Security & Whitelist)

| 变量名 | 默认值 | **必需** | 说明 |
| :--- | :--- | :---: | :--- |
| `RG_ENABLE_IP_WHITELIST`| `true` | 否 | **IP 白名单总开关**。设为 `true` 时，只有授权 IP 才能连接。设为 `false` 时，系统将转为纯粹的 SNI 代理，不进行任何 IP 限制。 |
| `RG_WHITELIST_IP_TTL_SECONDS`| `86400` | 否 | **IP 白名单授权的有效期（秒）**。默认 `86400` 秒，即 24 小时。 |
| `RG_NGINX_USERS` | (无) | 否 | **多用户及 TOTP 认证配置**。格式如 `user1:pass1:totp_secret,user2:pass2`。用于管理后台登录。 |
| `RG_NGINX_SESSION_TTL_SECONDS`| `2592000` | 否 | **Web 控制台登录会话 Cookie 的有效期（秒）**。默认 `2592000` 秒，即 30 天。 |
| `RG_TOTP_VALID_WINDOW_SECONDS`| `300` | 否 | **TOTP 容差校验时间窗口大小（秒）**。默认 300 秒，用于应对客户端与服务器的时间差。 |
| `RG_TOTP_SECRET` | (无) | 否 | **单用户 TOTP 密钥**。当 `RG_NGINX_USERS` 中未给用户单独指定密钥时，可使用此全局密钥。**建议在 `RG_NGINX_USERS` 中为每个用户配置独立的密钥**。 |
| `RG_NGINX_CDN_IP_HEADERS`| `CF-Connecting-IP:cf,True-Client-IP:cf` | 否 | **边缘 CDN 的真实 IP 请求头优先级链**。格式为 `Header:Alias`，逗号分隔，用于穿透 CDN 获取访客真实 IP。 |

---

## 4. 日志与后台任务配置 (Logging & Tasks)

| 变量名 | 默认值 | **必需** | 说明 |
| :--- | :--- | :---: | :--- |
| `RG_TZ` | `Asia/Shanghai` | 否 | **容器运行时区**。用于确保日志和定时任务时间计算的准确性。 |
| `RG_NGINX_LOG_LEVEL` | `notice` | 否 | **Nginx 核心错误日志级别**。可选值包括 `debug`, `info`, `notice`, `warn`, `error` 等。 |
| `RG_SHOW_REJECTED_LOG`| `false` | 否 | **是否允许在管理后台查看被拦截的 IP 日志**。设为 `true` 时，可通过特定 URL 查看。 |
| `RG_SHOW_WHITELIST_DB`| `false` | 否 | **是否允许在管理后台查看当前的白名单列表**。设为 `true` 时，可通过特定 URL 查看。 |
| `RG_WHITELIST_DB_FILENAME`| `whitelist.db` | 否 | **在管理后台查看白名单时使用的文件名**。可用于混淆 URL。 |
| `RG_NGINX_REJECT_LOG_FILENAME`| `rejected_ips.log`| 否 | **在管理后台查看拦截日志时使用的文件名**。可用于混淆 URL。 |
| `RG_TASK_CLEAN_LOG_INTERVAL_SECONDS`| `60` | 否 | **后台拦截日志清理任务的运行周期（秒）**。 |
| `RG_TASK_CLEAN_LOG_RETAIN_LINES`| `10` | 否 | **清理后保留的最新拦截日志行数**。 |
| `RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS`| `86400` | 否 | **后台白名单清理任务的运行周期（秒）**。 |

---

## 5. 高级传输层配置 (Advanced Transport Layer)

| 变量名 | 默认值 | **必需** | 说明 |
| :--- | :--- | :---: | :--- |
| `RG_NGINX_PROXY_PROTOCOL`| `off` | 否 | **是否在 443 端口开启 PROXY Protocol 支持**。当部署在 L4 负载均衡器 (如 Fly.io, AWS ELB) 之后时，需设为 `on` 以获取真实客户端 IP。 |
| `RG_NGINX_DNS_RESOLUTION_SECONDS`| `600` | 否 | **Nginx 内部 DNS 解析结果的缓存时间（秒）**。 |
| `RG_NGINX_TLS_MODE` | `https` | 否 | **管理后台内部通信的 TLS 模式**。可选：`https` (标准 HTTPS), `mtls` (双向 TLS 认证), `http` (明文，仅用于调试)。 |
| `RG_SSL_CERT_PATH` | `/etc/nginx/ssl/cert.pem` | 否 | **服务端 SSL 证书公钥（或 cert.pem）在容器内的绝对路径**。 |
| `RG_SSL_KEY_PATH` | `/etc/nginx/ssl/key.pem` | 否 | **服务端 SSL 证书私钥（或 key.pem）在容器内的绝对路径**。 |
| `RG_CLIENT_CA_CERT_PATH` | `/etc/nginx/ssl/ca.pem` | 否 | **双向 mTLS 校验客户端证书 CA 根证书在容器内的绝对路径**。 |
| `RG_ENABLE_CUSTOM_MTLS` | `false` | 否 | **自定义 mTLS 客户端认证开关**。设为 `true` 后，会自动将 `RG_NGINX_TLS_MODE` 强制切换为 `mtls`（强校验模式，无合规证书直接拦截）。 |
