# RestyTunnel 环境变量全解析

本文档完整收录了驱动 RestyTunnel 运行的所有环境变量、其功能说明、默认值以及它们在系统中的作用。

> 💡 **风格与命名空间统一声明**：为了使本项目（RestyTunnel）的环境变量规范且易于辨识，现在所有专属环境变量均以 **`RT_`** 前缀开头。同时，为了保障老版本部署的绝对兼容性，系统已内置了**自动向下平滑降级与平滑别名兼容机制**，老名称（无 `RT_` 前缀，如 `PROXY_DOMAIN`）在未提供新名称时仍会自动生效。

> 🛡️ **全新防缓存劫持机制声明**：由于伪装回落后端（如 Cloudreve 等现代 SPA 框架）会尝试在您公用的授权域名下注册 Service Worker 并强行劫持/缓存您的整个路由，导致控制台网页陷入死锁无法展示。RestyTunnel 继承了 RestyGuard 的顶级双态自注销 SW 引擎。即便您在未登录状态下不慎裸连访问了域名被种下了缓存毒素，系统会在后台微秒级拦截并注入反劫持 JS，促使您的浏览器自动执行物理级注销与无缓存刷新。

---

## 1. 代理核心配置 (Core Proxy Settings)

这些是运行代理服务最基础、最核心的参数。

| 变量名 (推荐) | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RT_PROXY_DOMAIN` | `localhost` | **【必需】您的主力正向代理域名**。必须直接解析到服务器公网 IP，切勿开启 Cloudflare 等 CDN 代理。兼容旧版 `PROXY_DOMAIN`。|
| `RT_PROXY_USERNAME` | `myuser` | **【必需】正向代理认证账号**。同时也是（如果开启）白名单管理面板的登录账号。兼容旧版 `PROXY_USERNAME`。|
| `RT_PROXY_PASSWORD` | `mypassword` | **【必需】正向代理认证密码**。同时也是（如果开启）白名单管理面板的登录密码。兼容旧版 `PROXY_PASSWORD`。|
| `RT_FALLBACK_BACKEND` | `https://cn.bing.com` | **高保真全局默认伪装回落后端**。当未分别指定 `PROXY_FALLBACK_BACKEND` 或 `AUTH_FALLBACK_BACKEND` 时，作为全局默认降级兜底端。兼容旧版 `FALLBACK_BACKEND`。|
| `RT_PROXY_FALLBACK_BACKEND` | (继承 `RT_FALLBACK_BACKEND`) | **主代理域名专属高防回落后端**。专门用于 `RT_PROXY_DOMAIN` 下，当遇到恶意探测、IP 未加白或凭证错漏时，流量无缝降维回落此站点（推荐使用 Bing 或高信誉静态学术站）。优先级高于 `RT_FALLBACK_BACKEND`。兼容旧版 `PROXY_FALLBACK_BACKEND`。|
| `RT_AUTH_FALLBACK_BACKEND` | (继承 `RT_FALLBACK_BACKEND`) | **白名单授权域名专属回落后端**。专门用于 `RT_AUTH_DOMAIN` 授权门户，即使输错子路径也会无缝反代至此（推荐设置为您的 AList / Cloudreve 真实云盘首页），直接掩护并充当您网盘的入口。优先级高于 `RT_FALLBACK_BACKEND`。兼容旧版 `AUTH_FALLBACK_BACKEND`。|
| `RT_NGINX_PORT` | `443` | **容器内部监听端口**。通常保持 `443` 即可。在 Fly.io 等特定 PaaS 平台部署时可能需要修改。兼容旧版 `NGINX_PORT`。|

---

## 2. 安全与白名单 (Security & Whitelist)

这些参数用于开启和配置 IP 白名单授权、多用户管理等高级安全功能。

| 变量名 (推荐) | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RT_ENABLE_IP_WHITELIST` | `false` | **IP 白名单总开关**。设为 `true` 时，只有已授权的 IP 才能使用代理服务。生产环境强烈建议开启。兼容旧版 `ENABLE_IP_WHITELIST`。|
| `RT_AUTH_DOMAIN` | `auth.localhost` | **白名单授权管理域名**。这是您的第二个域名，专门用于网页端自助添加 IP。推荐在 Cloudflare 开启 CDN 代理（小黄云）来隐藏真实源站 IP。兼容旧版 `AUTH_DOMAIN`。|
| `RT_AUTH_PATH_PREFIX` | `auth` | **授权管理页面的随机子路径前缀**，构成 `https://[RT_AUTH_DOMAIN]/[RT_AUTH_PATH_PREFIX]/[RT_SECRET_TOKEN]` 访问 URL 的一部分，作为第一重防扫描防线。兼容旧版 `AUTH_PATH_PREFIX`。|
| `RT_SECRET_TOKEN` | `mysecrettoken123` | **授权管理页面的安全随机密令**，构成访问 URL 的最后一部分，作为第二重防扫描防线。请务必修改为一个长且无规律的强密码。兼容旧版 `SECRET_TOKEN`。|
| `RT_WHITELIST_IP_TTL_DAYS` | `7` | **白名单 IP 授权有效期**（单位：天）。客户端 IP 被加入白名单后，在此天数内无需重新授权即可使用代理。此值会用于自动计算秒级 `RT_WHITELIST_IP_TTL_SECONDS`。兼容旧版 `WHITELIST_IP_TTL_DAYS`。|
| `RT_WHITELIST_IP_TTL_SECONDS` | (由 `RT_WHITELIST_IP_TTL_DAYS` 自动计算) | **白名单 IP 授权有效期**（单位：秒）。默认根据 `RT_WHITELIST_IP_TTL_DAYS` 自动计算（`天数 * 86400`）。如果设置此值，会覆盖自动计算结果。兼容旧版 `WHITELIST_IP_TTL_SECONDS`。|
| `RT_ENABLE_VIEW_WHITELIST` | `true` | **是否允许在网页端面板查看活跃白名单列表**（隐私安全开关）。设为 `false` 时，该板块将被安全屏蔽，在多用户共用时保障横向隔离隐私。兼容旧版 `ENABLE_VIEW_WHITELIST`。|
| `RT_ENABLE_VIEW_BLACKLIST` | `true` | **是否允许在网页端面板查看被阻断拦截日志**（隐私安全开关）。设为 `false` 时，该板块将被安全屏蔽。兼容旧版 `ENABLE_VIEW_BLACKLIST`。|
| `RT_ENABLE_CF_AOP` | `false` | **Cloudflare 双向 mTLS 强校验开关**。设为 `true` 后，`RT_AUTH_DOMAIN` 整个域名会受到密码学级别的客户端证书校验，只有通过 CF 边缘节点代理的请求才能进入。兼容旧版 `ENABLE_CF_AOP`。|
| `RT_USERS` | (由 `RT_PROXY_USERNAME` 和 `RT_PROXY_PASSWORD` 组成) | **多用户及 TOTP 认证配置**。格式如 `user1:pass1:totp_secret,user2:pass2`。若未配置，则自动降级为 `RT_PROXY_USERNAME:RT_PROXY_PASSWORD` 作为单个静态密码用户。|
| `RT_SESSION_TTL_SECONDS` | `2592000` | **Web 控制台登录会话 Cookie 保持生存时间**（秒）。在登录成功后 Cookie 维持的时长，默认 30 天。兼容 `RT_SESSION_TTL` (支持 `d`, `h`, `m`, `s` 单位)。|
| `RT_TOTP_VALID_WINDOW_SECONDS`| `300` | **TOTP 容差校验时间窗口大小**（秒）。默认 300 秒（前后各 150 秒均分容错），完美对齐 Google/Microsoft Authenticator 等手机端 APP 的时间步长。兼容 `RT_TOTP_VALID_WINDOW`。|

---

## 3. 通用真实 IP 与自定义 mTLS (高级定制)

这些高级参数用于将 RestyTunnel 与非 Cloudflare 的 CDN、自定义反向代理或私有 PKI 体系集成，实现极致的灵活性和通用性。

| 变量名 (推荐) | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RT_REAL_IP_HEADER` | `CF-Connecting-IP` | **【高级】指定用于获取真实客户端 IP 的 HTTP 请求头**。当您的 `RT_AUTH_DOMAIN` 前置了非 Cloudflare 的反代时，可将其设为 `X-Forwarded-For` 或 `X-Real-IP` 等。兼容旧版 `REAL_IP_HEADER`。|
| `RT_REAL_IP_FROM` | (空) | **【高级】设定您信任的前置反向代理 IP/CIDR 列表（空格分隔）**。Nginx 只会信任来自这些地址的 `RT_REAL_IP_HEADER`。当不使用 Cloudflare 时，必须设为您自己的前置代理 IP。兼容旧版 `REAL_IP_FROM`。|
| `RT_ENABLE_PROXY_PROTOCOL` | `false` | **启用 PROXY Protocol 接收和真实 IP 重写功能**。在将 TCP 直连代理（非卸载 TLS 盲直通）部署于 Fly.io 或 AWS ELB 四层负载均衡后端时，必须设为 `true`。兼容旧版 `ENABLE_PROXY_PROTOCOL`。|
| `RT_ENABLE_CUSTOM_MTLS` | `false` | **【高级】自定义 mTLS 客户端认证开关**。设为 `true` 时，系统将忽略 `RT_ENABLE_CF_AOP`，并使用您指定的私有 CA 证书对 `RT_AUTH_DOMAIN` 进行双向认证。兼容旧版 `ENABLE_CUSTOM_MTLS`。|
| `RT_CLIENT_CA_CERT_PATH` | `/etc/nginx/certs/my_ca.pem` | **【高级】您的私有客户端 CA 根证书在容器内的路径**。当 `RT_ENABLE_CUSTOM_MTLS` 开启时，您需要通过 `volumes` 将您的 CA 证书映射进来。兼容旧版 `CLIENT_CA_CERT_PATH`。|

---

## 4. 日志、限流与后台任务 (Logging, Rate-Limiting & Tasks)

这些参数用于控制容器内部的日志级别、安全策略和后台守护进程。

| 变量名 (推荐) | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RT_NGINX_LOG_LEVEL` | `notice` | **Nginx 核心错误日志级别**。可选值包括：`debug`, `info`, `notice`, `warn`, `error`, `crit`, `alert`, `emerg`。兼容旧版 `NGINX_LOG_LEVEL`。|
| `RT_TZ` | `Asia/Shanghai` | **运行容器所使用的系统时区（如北京时间）**。由于 alpine 容器默认采用 UTC 时间，此变量配置了日志记录和自动清理后台任务时间所对应的时区基准，默认设为中国标准时间。兼容旧版 `TZ`。|
| `RT_DNS_RESOLVER` | `1.1.1.1 8.8.8.8 ipv6=off` | **【优化】指定 Nginx 解析正向代理目标网站时所使用的 DNS 解析服务器**。如果部署在不同的网络区域（如中国大陆），请修改为低时延的受信任 DNS（如 `223.5.5.5 119.29.29.29 ipv6=off`）以获得极致的域名解析速度。兼容旧版 `DNS_RESOLVER`。|
| `RT_AUTH_RATE_LIMIT` | `5r/m` | **白名单面板防暴力破解速率限制**。`r/s` 代表每秒请求数, `r/m` 代表每分钟请求数。默认每分钟 5 次。兼容旧版 `AUTH_RATE_LIMIT`。|
| `RT_DISABLE_REJECT_LOG` | `false` | **是否禁用被拒 IP 的日志记录**。对于高度注重隐私或希望减少磁盘 I/O 的用户，可设为 `true` 禁用。兼容旧版 `DISABLE_REJECT_LOG`。|
| `RT_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS` | `3600` | **后台白名单过期自动清理周期**（单位：秒）。默认每 1 小时扫描并清理一次。兼容旧版 `TASK_CLEAN_WHITELIST_INTERVAL_SECONDS`。|
| `RT_TASK_CLEAN_LOG_RETAIN_LINES` | `30` | **被拒阻断日志在内存中的最大保留行数（流式精密控行）**。每当发生新的恶意阻断时，会在第一时间在 Lua 内存中进行自动原子裁剪，仅保留最新行。默认 30 行。兼容旧版 `TASK_CLEAN_LOG_RETAIN_LINES`。|
| `RT_WHITELIST_DB_PATH` | `/dev/shm/whitelist.db` | **【高级】自定义白名单数据文件的硬盘存储绝对路径**。默认存储于性能极致的纯物理内存 RAM 磁盘（`tmpfs: /dev/shm`）中以完全消灭文件磁盘 I/O 开销。兼容旧版 `WHITELIST_DB_PATH`。|
| `RT_REJECTED_LOG_PATH` | `/dev/shm/rejected_ips.log` | **【高级】自定义恶意探测与拦截日志文件的硬盘存储绝对路径**。默认存储于内存 RAM 磁盘。兼容旧版 `REJECTED_LOG_PATH`。|

---

## 5. 证书注入（可选）(Certificate Injection)

这两个变量用于在**运行时动态注入 SSL 证书**，常用于 CI/CD 或自动化部署场景，优先级高于卷挂载的 `./ssl` 目录。

| 变量名 (推荐) | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RT_SSL_CERT_BASE64` | (空) | **Base64 编码后的 `fullchain.pem` 证书内容**。如果设置了此变量，容器启动时会自动解码并写入证书文件。兼容旧版 `SSL_CERT_BASE64`。|
| `RT_SSL_KEY_BASE64` | (空) | **Base64 编码后的 `privkey.pem` 密钥内容**。如果设置了此变量，容器启动时会自动解码并写入密钥文件。兼容旧版 `SSL_KEY_BASE64`。|
