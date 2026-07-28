# RestyGuard 安全网关全量运行环境变量参考手册 (Environment Variables Specifications)

为了让您能够极致、精细地掌控 RestyGuard 的运行，我们对全量支持的环境变量参数进行了高度分类。本手册详尽整理了所有必需、核心、安全及高级调优的环境变量及其作用、默认值和最佳实战推荐。所有系统环境变量现已全量对齐至具有 **`RG_`** 统一前缀的新版格式。

---

## 🌐 1. 核心认证与路径防线配置

| 环境变量 | 默认值 | 必需 | 作用与机制说明 |
| :--- | :--- | :---: | :--- |
| **`RG_SECRET_TOKEN`** | **无（必须设置）** | **是** | **白名单管理面板的安全密令**。用于生成唯一的管理 URL：`https://<RG_AUTH_DOMAIN>/auth/<RG_SECRET_TOKEN>`。启动时强制安全自审，不配置或使用 `change-me-please` 会强制报错退出。 |
| **`RG_AUTH_PATH_PREFIX`**| `auth` | 否 | **管理接口的第一层自定义子路径前缀**。例如改为 `secure`，此时控制台 URL 变为 `https://<RG_AUTH_DOMAIN>/secure/<RG_SECRET_TOKEN>`。可有效抵御外部扫描器扫描后台接口。 |
| **`RG_AUTH_DOMAIN`** | `localhost` | 否 | **白名单自助授权控制台域名**。极力推荐在 Cloudflare 开启小黄云代理（CDN），借助 CF 完美的隐藏源站物理 IP，防止源站被 DDOS 或刺探。 |
| **`RG_FALLBACK_BACKEND`**| `https://cn.bing.com` | 否 | **高保真欺骗回落后端**。当攻击者或普通探针未输入精准的管理子路径尝试探测时（如访问主根路径 `/` 试探），Nginx 会在协议层**高保真无缝反代回落到该地址**。在外界扫描器看来这是一个合法的外部网站，彻底抹除了本 RestyGuard 防火墙的后台指纹。 |

---

## 🛡️ 2. 白名单网关防火墙配置

| 环境变量 | 默认值 | 必需 | 作用与机制说明 |
| :--- | :--- | :---: | :--- |
| **`RG_ENABLE_IP_WHITELIST`**| `true` | 否 | **是否开启 IP 白名单防火墙**。默认为 `true`。开启后连接网关必须在白名单内。**若设为 `false`，则系统秒级化身、退化为极致高性能、通透的纯 SNI 盲转发代理**。 |
| **`RG_WHITELIST_IP_TTL_SECONDS`**| `86400` | 否 | **单次 IP 白名单授权的生存有效期时间（秒）**。默认 `86400` 秒（即 24 小时）。超时后，后台定时任务会自动执行物理清空，该 IP 失去代理放行权限。 |
| **`RG_NGINX_CDN_IP_HEADERS`**| `CF-Connecting-IP:cf,True-Client-IP:cf` | 否 | **边缘 CDN 真实用户 IP 获取标头优先级链**。格式为 `Header:Alias`，逗号分隔。管理页面会根据此链，自动逆向、穿透 CDN 代理获取到访客的最真实客户端公网 IP。 |

---

## 🗺️ 3. 路由与规则表管理配置

| 环境变量 | 默认值 | 必需 | 作用与机制说明 |
| :--- | :--- | :---: | :--- |
| **`RG_STREAM_UPSTREAM_RULES`**| **无** | 否 | **【极力推荐】新版等号语法多行路由映射表**。格式：`domain=host:port`，一行一个。支持 YAML 的多行 `|` 或 `>-` 语法，支持行首 `-` 减号，支持中英文、角/半角单双引号自动脱壳清洗，维护极度优雅护眼。 |
| **`RG_STREAM_UPSTREAM_MAP`**| `*:translate.googleapis.com:443` | 否 | **旧版冒号语法多行路由映射表**。格式为 `domain:host:port`，逗号分隔。作为旧版本兼容保留，优先级低于 `RG_STREAM_UPSTREAM_RULES`。 |
| **`RG_UPSTREAM_RULES_FILE`**| `/etc/nginx/rules/upstream_rules.conf` | 否 | **静态路由规则配置文件路径**。允许大规模域名转发配置落盘，通过 Git 进行协同管理。默认值为空时系统采用默认路径。支持通过 Volume 进行宿主机同步挂载。 |

---

## ⏱️ 4. 后台自动维护定时任务配置

| 环境变量 | 默认值 | 必需 | 作用与机制说明 |
| :--- | :--- | :---: | :--- |
| **`RG_TASK_CLEAN_LOG_INTERVAL_SECONDS`**| `600` | 否 | **黑名单拦截日志后台自动清理周期频率（秒）**。默认每 10 分钟自动执行一次日志裁剪。 |
| **`RG_TASK_CLEAN_LOG_RETAIN_LINES`**| `10` | 否 | **黑名单物理拦截日志文件留存的最大行数**。为了防止日志爆盘，系统会自动流式精准截断多余行，物理抛弃最旧的历史拦截，保留最新 10 条展示。 |
| **`RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS`**| `86400` | 否 | **白名单数据库自动清扫周期频率（秒）**。默认每 24 小时全量清扫一次物理内存盘中的过期 IP。 |

---

## ⚡ 5. 传输层高级性能与安全调优

| 环境变量 | 默认值 | 必需 | 作用与机制说明 |
| :--- | :--- | :---: | :--- |
| **`RG_TZ`** | `Asia/Shanghai` | 否 | **容器系统的绝对时区配置**。保底设为北京时间，确保审计日志、白名单剩余生存时间 TTL 的计算在时序上完美无错位。 |
| **`RG_NGINX_PROXY_PROTOCOL`**| `off` | 否 | **是否在主 443 Stream 入口开启 PROXY 协议接收支持**。部署在 Fly.io 盲直通、或前置有负载均衡设备，需要穿透获取物理真实连接 IP 时设为 `on`。 |
| **`RG_NGINX_DNS_RESOLUTION_SECONDS`**| `600` | 否 | **Nginx 内部域名解析（DNS）结果在内存中的缓存有效时间（秒）**。防止频繁请求 DNS 阻塞。 |
| **`RG_NGINX_LOG_LEVEL`** | `notice` | 否 | **Nginx 核心错误日志输出等级**。支持 `debug`, `info`, `notice`, `warn`, `error`。默认设为 `notice` 极致静音，可完美屏蔽本地高频环回 proxy connected 冗余日志，需要详细排查调试时可设为 `info`。 |
| **`RG_NGINX_TLS_MODE`**| `https` | 否 | **管理控制台 8443 环回链路的传输协议安全等级**。可选项：`https` (HTTPS 传输保底)、`mtls` (mTLS双向证书强校验，需在 `certs/` 目录下放置 `cert.pem` / `key.pem` / `ca.pem`)、`http` (纯明文 HTTP，调试备用)。 |
| **`RG_NGINX_USERS`** | **无** | 否 | **多用户静态账密/TOTP 配置列表**。格式为 `username:password_or_TOTP[:optional_totp_secret]`，逗号分隔。如：`RG_NGINX_USERS="aaron:password,bob:TOTP:Base32种子"`。系统默认且恒定以自适应、极致安全不弹窗的隐形 Lua 校验模式运行（100% 抹除原生弹窗指纹），直接支持在 URL 中通过 `?u=bob&code=6位数字` 进行加白。 |
| **`RG_NGINX_SESSION_TTL_SECONDS`**| `2592000` | 否 | **控制台授权成功后 Session Cookie 锁的有效期**。默认为 `30d` (30 天)。该 Cookie 锁采用**滑动过期（Sliding Expiration）**顺延机制，只要在此周期内有任意访问，自动向后无限期顺延。支持直观单位，如 `30d` (30天)、`24h` (24小时)、`60m` (60分钟)。 |
| **`RG_TOTP_VALID_WINDOW_SECONDS`**| `300` | 否 | **动态口令（TOTP）可校验的时间偏差窗口大小**。默认为 `5m` (5分钟)，支持直观单位如 `303s` 或 `5m`。系统会自适应将该时间均分给过去和未来，允许手机上刷新并失效的历史口令及未来口令在前后各半的时间段内依旧合法。 |
| **`RG_TOTP_SECRET`** | **无** | 否 | **动态口令的自定义十六进制/Base32 种子密钥（单用户备用，建议在 RG_NGINX_USERS 中统一配置）**。 |
| **`RG_AUTH_ALLOW_ANY_DOMAIN`**| `false` | 否 | **是否允许客户端通过任意域名头访问管理控制台 8443 端口**。设为 `false` 触发严密主机头（Host Header）校验，防止直接 IP 刺探。 |
| **`RG_SHOW_REJECTED_LOG`**| `false` | 否 | **安全可见性：是否允许管理员在管理控制台卡片中直接阅读最新拦截阻断实况**。设为 `true` 激活前 10 条黑名单看板。 |
| **`RG_SHOW_WHITELIST_DB`**| `false` | 否 | **安全可见性：是否允许管理员在管理控制台卡片中阅读活跃白名单 IP 列表**。设为 `true` 激活白名单看板。 |
| **`RG_WHITELIST_DB_FILENAME`**| `whitelist.db` | 否 | **控制台卡片在线查阅白名单时的动态映射文件名**。支持通过此变量混淆文件名。 |
| **`RG_NGINX_REJECT_LOG_FILENAME`**| `rejected_ips.log` | 否 | **控制台卡片在线查阅拦截阻断日志时的动态映射文件名**。支持通过此变量混淆文件名。 |
