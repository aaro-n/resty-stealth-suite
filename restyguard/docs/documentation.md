# RestyGuard — TLS 反向代理与动态 IP 白名单防火墙技术文档

## 1. 项目愿景与设计初衷
在现代网络环境中，许多高频实用的网络服务（如 Chrome 的 **Google 网页翻译插件**）由于某些特定域名的连接干扰，经常会出现连接超时、无法加载等现象。开启全局代理虽能解决，但对国内网站的访问会造成额外的延迟和不便。

**RestyGuard** 正是为了解决该痛点而诞生的。它是一个基于 **OpenResty (Nginx + Lua)** 架构的 **TLS 反向代理 (SNI-Proxy) 与动态 IP 白名单防火墙**。

### 1.1 核心工作流程
1. **客户端劫持**：将本地的特定域名（如 `translate.googleapis.com`）通过 `hosts` 文件或本地 DNS 服务指向 RestyGuard 的公网 IP。
2. **四层 TLS 透传 (SNI-Proxy)**：当客户端发起 TLS 握手时，RestyGuard 监听 443 端口，利用 Nginx 的 `ssl_preread` 模块提前读取 TLS Client Hello 中的 **SNI (Server Name Indication)**，从而获取目标域名。之后，它在**不解密、不需要目标域名证书和私钥**的情况下，将 TCP 流量透明透传至目标网站。
3. **防火墙安全拦截**：为防止公网 443 端口被扫描器探测到并滥用，所有经过 443 端口的代理请求在接入前，都会经过 Lua 编写的 **IP 白名单防火墙**。只有已被授权的公网 IP 才能建立隧道，其他任何未授权连接都将被强行断开（Empty Reply）并记录日志，安全级别极高。
4. **一键授权（动态 IP 白名单）**：用户只需要通过浏览器或快捷脚本访问一次管理接口：`https://<IP>:8443/auth/<RG_SECRET_TOKEN>`，系统即可自动抓取用户的最新公网 IP，将其加入白名单并设置 TTL 过期时间，实现无感安全代理。

---

## 2. 核心架构与功能模块

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
                       │                            ├─► /auth/RG_SECRET_TOKEN (授权)│
                       │                            └─► /ip (安全 TLS IP 诊断)   │
                       └────────────────────────────────────────────────────────┘
```

### 2.1 极简单端口架构 (对公网 100% 隐藏 8443/8080 调试端口)
*   **443 端口 (唯一外部物理入口)**：
    *   通过 `preread_by_lua_file` 激活白名单安全校验和动态路由转发。
    *   **四层自适应 Bypass**：如果请求的 SNI 匹配配置的 `RG_AUTH_DOMAIN`（管理域名），系统将无条件放行（绕过拦截），并将其高速路由至本地环回代理接口 `127.0.0.1:18443`。
    *   **自适应 SNI 动态路由 (全新升级)**：如果请求的域名未在显式规则中定义，RestyGuard 会自动将请求透明转发至其原本对应的 `[SNI域名]:443`。
*   **127.0.0.1:8443 (本地回环管理/HTTPS)**：
    *   默认启用单向 TLS，确保管理链接不被泄露和嗅探。
    *   核心路由 `/<RG_AUTH_PATH_PREFIX>/<RG_SECRET_TOKEN>`：访问即可自动添加/更新客户端 IP 白名单，并返回具有良好移动端适配的手动管理表单页面。
    *   安全内置 `/ip` 诊断接口：免去原本公网暴露 8080 端口产生的指纹泄露，只需访问 `https://<RG_AUTH_DOMAIN>/ip` 即可进行安全的客户端真实 IP 精准识别和提供 CDN 标头数据。

---

## 3. 技术设计细节与避坑实践

在项目的研发迭代中，我们对一系列 Nginx 变量传递、Lua 语法边界及环境兼容性做出了关键修复与深度打磨。

### 3.1 变量返回机制的 Lua counts 陷阱（经典修复）
在早期的 HTML 模板替换引擎中，我们自定义了 `escape_gsub_replacement(str)` 函数对用户提交的 IP 参数进行转义：
```lua
local function escape_gsub_replacement(str)
    return string.gsub(tostring(str), "%%", "%%%%")
end
```
**问题原因**：
Lua 的 `string.gsub` 默认返回**两个**值：`(replaced_string, substitution_count)`。当我们在外层嵌套调用 `string.gsub(final_html, "@@IP_ADDED@@", escape_gsub_replacement(ip))` 时，Lua 会把 `escape_gsub_replacement` 的两个返回值合并到外层 `gsub` 的实参列表中：
```lua
string.gsub(final_html, "@@IP_ADDED@@", replaced_string, substitution_count)
```
这导致外层 `string.gsub` 的第四个可选参数 `n` (最大替换次数) 被意外赋值为了 `0`（因为 `ip` 中通常没有 `%` 字符，因此 count 返回 `0`），导致页面里的占位符 `@@IP_ADDED@@` 完全没有被替换！

**最终解决方案**：
我们采用括号强制限制返回值个数，仅返回第一个被替换后的字符串：
```lua
local function escape_gsub_replacement(str)
    return (string.gsub(tostring(str), "%%", "%%%%"))
end
```

### 3.2 `server_name` 参数缺失缺陷（致命启动 Bug 修复）
在 `23-generate-auth-server.sh` 脚本中，如果用户启动容器时没有传入 `RG_AUTH_DOMAIN`，并且 `RG_AUTH_ALLOW_ANY_DOMAIN` 为默认的 `false`，生成脚本会直接输出：
```nginx
server_name ;
```
这会导致 Nginx 提示 `invalid number of arguments in "server_name" directive` 并在容器启动时瞬间崩溃。

**解决方案**：
在 `00-set-defaults.sh` 默认环境变量配置中，增加了对 `RG_AUTH_DOMAIN` 的缺省容错设置：
```bash
export RG_AUTH_DOMAIN=${RG_AUTH_DOMAIN:-localhost}
```
保证了即使不传入该参数，Nginx 也能够通过 `localhost` 域名完美、稳定地启动运行。

### 3.3 优雅的自动去重写入与后台清理任务
*   **去重追加**：在将 IP 追加进 `whitelist.db` 时，如果 IP 已存在，Lua 会先过滤掉旧的条目，将最新的 IP 替换或更新 TTL 时间追加写入，防止数据库无限膨胀。
*   **Worker 定时器**：基于 OpenResty 的 `ngx.timer.at` 在后台运行轻量级 Worker。无需借助外部系统的 `crontab`，即能自给自足地在容器内自动清理超期的白名单条目和裁剪庞大的拒绝日志文件，确保系统长时间无维护运行。

### 3.4 mTLS 模式下自签名客户端 CA 证书自动生成保底 (v3.8.1)
*   **启动崩溃痛点**：在开启极速网关的 mTLS（双向认证，即 `RG_NGINX_TLS_MODE="mtls"`）时，如果宿主机未外挂或未在 `/etc/nginx/certs/` 目录下放置客户端验证所需的 `ca.pem`，Nginx 启动时会因为找不到客户端 CA 文件报出致命错误 `cannot load certificate "/etc/nginx/certs/ca.pem": BIO_new_file() failed`，导致容器陷入无限崩溃与重启循环中。
*   **解决方案**：我们在启动引导脚本 `bootstrap.sh` 中对证书保底逻辑进行了升级调优。在原本自动生成自签名 TLS 服务端证书（`cert.pem` / `key.pem`）的基础上，新增了针对 `ca.pem` 的自适应缺失检测与自签名 CA 证书（包含 3650 天超长有效期）后台自动保底生成机制：
    ```bash
    if [ ! -s "$ca_file" ]; then
        echo "   - [证书保底] 未检测到合规的客户端 CA 证书，正在生成开发保底自签名 CA 证书..."
        openssl genrsa -out "${cert_dir}/ca.key" 2048 2>/dev/null
        openssl req -x509 -new -nodes -key "${cert_dir}/ca.key" \
            -sha256 -days 3650 \
            -subj "/C=CN/O=RestyGuard-Dev-CA/CN=RestyGuard Dev CA" \
            -out "$ca_file" 2>/dev/null
        rm -f "${cert_dir}/ca.key"
    fi
    ```
    本机制保证了即使云端无状态环境（如 `fly.io`）或本地直接全新运行，在缺省配置证书下也能 100% 优雅冷启动开箱即用。

### 3.5 极速一键加白：智能书签（Bookmarklet）配置参考 (v4.0.0)

为了给用户和运维提供极其顺滑、点击即入的“无感级”白名单授权与免密登录体验，本项目设计了**一键智能授权书签**（无需打开 App，浏览器点击书签即可瞬间对当前设备的最新公网 IP 完成安全授权）。

此脚本是紧凑直观型书签。用户只需在使用前，将脚本中声明的 `YOUR_AUTH_DOMAIN`（验证域名）、`YOUR_PATH_PREFIX`（安全路径）以及 `YOUR_SECRET_TOKEN`（认证密钥）修改为自己部署时的真实参数即可。代码内部已完全抹去一切隐私与具体域名，其他人可将下述通用模板作为参考并进行微调：

#### 📝 书签 URL 代码：
```javascript
javascript:(function(){var baseUrl="https://YOUR_AUTH_DOMAIN/YOUR_PATH_PREFIX/YOUR_SECRET_TOKEN";if(window.location.href.indexOf("YOUR_AUTH_DOMAIN")!==-1){if(document.cookie.indexOf("gkp_active=1")!==-1){window.location.reload();}else{var code=prompt("🔑 [RestyGuard 双重验证]\n\n您的 30 天免密已过期。\n请输入您手机 App (Google Authenticator) 上的 6 位动态验证码：");if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u=YOUR_PROXY_USERNAME&code="+code;}}}else{var code=prompt("🔑 [RestyGuard 智能免密通道]\n\n若当前已处于 30 天免密期内，可直接不输入并点“确定/回车”直入后台。\n\n新设备请直接输入您手机上的 6 位动态验证码：");if(code===""){window.location.href=baseUrl;}else if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u=YOUR_PROXY_USERNAME&code="+code;}}})();
```

---

## 4. 部署与验证指南

### 4.1 环境准备
确认您的服务器已安装 Docker。

### 4.2 极简一键启动（自适应 SNI 动态路由模式）
这是最强大的部署模式。运行此容器后，您不仅可以代理谷歌翻译，只要客户端 IP 在白名单中，您可以在本地 hosts 绑定任何外部域名至该服务器，系统都会自适应代理。

```bash
docker run -d --name restyguard \
  -e RG_SECRET_TOKEN="your-strong-secret-token" \
  -e RG_SHOW_REJECTED_LOG=true \
  -e RG_SHOW_WHITELIST_DB=true \
  -p 443:443 -p 8443:8443 -p 8080:8080 \
  restyguard
```

### 4.3 白名单一键授权
打开浏览器，访问您的授权链接：
```
https://<您的服务器IP>:8443/auth/your-strong-secret-token
```
界面将提示 `添加成功`，并且将您的当前公网 IP 精确记录进白名单。

### 4.4 本地 Hosts 绑定配置
在您的客户端电脑（Windows/macOS/Linux）上，编辑 `hosts` 文件，将想要代理和加速的服务域名强行解析到您的 RestyGuard 服务器：
```hosts
# Google 翻译代理（包含浏览器翻译插件所需的常用域名）
<您的服务器公网IP> translate.googleapis.com
<您的服务器公网IP> translate.google.com

# 极速扩展 - GitHub 代理（示例）
<您的服务器公网IP> github.com
<您的服务器公网IP> api.github.com
<您的服务器公网IP> github.global.ssl.fastly.net

# 极速扩展 - Docker Hub 镜像加速（示例）
<您的服务器公网IP> registry-1.docker.io
```

### 4.5 测试连接
*   **白名单内访问 (通过)**：
    使用您的客户端机器执行 TLS 握手连接测试：
    ```bash
    curl -k -v --resolve github.com:443:<您的服务器公网IP> https://github.com/
    ```
    您将看到来自 GitHub 真实的证书链握手信息（例如 `CN=github.com`）并收到成功的 301/200 响应。
*   **非白名单访问 (拒绝)**：
    尝试从一台未授权的机器或环境连接：
    ```bash
    curl -v http://<您的服务器公网IP>:443/
    ```
    连接将被服务器强行切断，返回 `Empty reply from server`。
*   **查看拦截记录**：
    访问：
    ```
    https://<您的服务器IP>:8443/auth/your-strong-secret-token/rejected_ips.log
    ```
    您能看到刚才由于未加白而被防火墙拦截的扫描记录，格式如下：
    ```
    [17/Jun/2026:17:39:39 +0000] <未授权IP>
    ```

---

## 🔒 5. Cloudflare 级源站安全防护配置：Authenticated Origin Pulls (AOP)

为了保护部署在公网的 Fly.io 网关不被黑客直接通过扫描 IP 绕过 Cloudflare 刺探，推荐启用 Cloudflare 的 **Authenticated Origin Pulls (AOP)** 双向证书拦截技术。这样可以省去繁杂且需要高频更新的 IP 白名单维护，在密码学层面锁死源站只能由 Cloudflare 访问。

### 5.1 方案 A：全局共享证书（高安全、最省心）
Cloudflare 官方提供了一张全局共享的客户端验证证书。所有 Cloudflare 域名的回源拉取都会出示该证书。
1. **下载官方 CA 文件**：
   在容器运行环境或 Git 代码库的 `certs/` 目录下放置 `ca.pem`（使用 2026 年最新重命名链接）：
   ```bash
   wget https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem -O certs/ca.pem
   ```
2. **在 Cloudflare 网页端开启**：
   * 登录 Cloudflare 控制台 ➔ 进域名 ➔ **SSL/TLS** ➔ **Origin Server**。
   * 下拉找到 **Authenticated Origin Pulls**，将 **Global** 的开关切换为 **On**。

---

### 5.2 方案 B：区域级私有证书（极致安全、防跨账号刺探）
如果您需要极致的安全隔离，确保**不仅只有 Cloudflare 能访问，且只允许您指定的这一个 Cloudflare 账号下的特定域名能拉取您的源站**，可以自定义您独占的 AOP 证书：

#### 1. 在本地机器一键生成证书链：
```bash
# 生成私有 CA 根证书（用于 Nginx 端的 ca.pem 校验）
openssl genrsa -out private-ca.key 2048
openssl req -x509 -new -nodes -key private-ca.key -sha256 -days 3650 \
  -subj "/C=CN/O=MyPrivateAOP/CN=My Private AOP CA" -out certs/ca.pem

# 生成 Cloudflare 专用客户端私钥与证书签名请求 (CSR)
openssl genrsa -out cf-client.key 2048
openssl req -new -key cf-client.key \
  -subj "/C=CN/O=MyPrivateAOP/CN=auth.yourdomain.com" -out cf-client.csr

# 用您生成的私有 CA 签名生成 Cloudflare 专用客户端证书
openssl x509 -req -in cf-client.csr -CA certs/ca.pem -CAkey private-ca.key \
  -CAcreateserial -out cf-client.pem -days 3650 -sha256
```

#### 2. 将证书上传给 Cloudflare 账号：
使用 Cloudflare API 将刚生成的客户端证书上传（请替换 `<YOUR_ZONE_ID>` 和 `<YOUR_API_TOKEN>`）：
```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/<YOUR_ZONE_ID>/client_certificates" \
     -H "Authorization: Bearer <YOUR_API_TOKEN>" \
     -H "Content-Type: application/json" \
     --data '\''{
       "certificate": "'\''$(awk '\''{printf "%s\\n", $0}'\'' cf-client.pem)'\''",
       "private_key": "'\''$(awk '\''{printf "%s\\n", $0}'\'' cf-client.key)'\''"
     }'\''
```

#### 3. 在 Cloudflare 网页端开启：
* 上传成功后，刷新 Cloudflare 的 **SSL/TLS** ➔ **Origin Server** ➔ **Authenticated Origin Pulls** 页面。
* 您会在 **区域级（Zone-level）** 列表中看到您上传的自定义 AOP 证书。将该证书的开关切换为 **On**。

---

### 5.3 方案 C：按主机名私有证书（极致安全、细粒度业务隔离）
如果您需要极致的安全隔离，**只想对网关授权域名 `auth.yourdomain.com` 开启双向验证，而让其他子域名（如网盘 `api.example.com`）保持通用且不受任何阻断干扰**，可以使用该级别证书。

#### 1. 在本地机器一键生成专属主机名证书链：
```bash
# 生成私有 CA 根证书（用于 Nginx 端的 ca.pem 校验）
openssl genrsa -out private-ca.key 2048
openssl req -x509 -new -nodes -key private-ca.key -sha256 -days 3650 \
  -subj "/C=CN/O=MyHostnameAOP/CN=My Private Hostname CA" -out certs/ca.pem

# 生成 Cloudflare 专用客户端私钥与证书签名请求 (CSR)，通用名称锁定为子域名
openssl genrsa -out hostname-cf-client.key 2048
openssl req -new -key hostname-cf-client.key \
  -subj "/C=CN/O=MyHostnameAOP/CN=auth.yourdomain.com" -out hostname-cf-client.csr

# 用您生成的私有 CA 签名生成 Cloudflare 专属客户端证书
openssl x509 -req -in hostname-cf-client.csr -CA certs/ca.pem -CAkey private-ca.key \
  -CAcreateserial -out hostname-cf-client.pem -days 3650 -sha256
```

#### 2. 将证书上传给 Cloudflare 账号：
使用 Cloudflare API 将刚签发的主机名专属客户端证书上传（请替换 `<YOUR_ZONE_ID>` 和 `<YOUR_API_TOKEN>`）：
```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/<YOUR_ZONE_ID>/client_certificates" \
     -H "Authorization: Bearer <YOUR_API_TOKEN>" \
     -H "Content-Type: application/json" \
     --data '{
       "certificate": "'$(awk '{printf "%s\\n", $0}' hostname-cf-client.pem)'",
       "private_key": "'$(awk '{printf "%s\\n", $0}' hostname-cf-client.key)'"
     }'
```

#### 3. 在 Cloudflare 网页端激活与绑定：
* 刷新 Cloudflare 的 **SSL/TLS** ➔ **Origin Server** ➔ **Authenticated Origin Pulls** 页面。
* 在页面最底部的 **按主机名（Per-hostname）** 卡片中，找到刚上传的主机名证书，勾选关联 **`auth.yourdomain.com`**，并将开关切换为 **On**。

---

### 5.4 🌐 全局、区域级、按主机名的金字塔优先级与共存防雷避坑规则

当您在 Cloudflare 网页控制面板中同时遇到 **全局（Global）**、**区域级（Zone-level）**、**按主机名（Per-hostname）** 的选项时，请务必了解它们之间极其严格的**覆盖覆盖及优先级规则**，以防在混合部署（如既有门禁、又有公共网盘）时发生服务瘫痪：

#### 1. 边缘引擎优先级金字塔

在 Cloudflare 边缘节点向源站服务器发起回源连接时，AOP 证书的选择遵循 **“越精准，优先级越高”** 的原则：

$$\text{按主机名 (Per-Hostname)} > \text{区域级 (Zone-Level)} > \text{全局 (Global)}$$

*   **访问已绑定“按主机名”的子域名（如 `auth.yourdomain.com`）**：Cloudflare 优先选择出示该主机名专属的特制 AOP 客户端证书。
*   **访问未绑定“按主机名”的普通子域名（如网盘 `api.example.com`）**：Cloudflare 自动退避，选择出示 **区域级（Zone-level）** 证书（若区域级未配置，则出示 **全局共享证书**）。

#### 2. ⚠️ 个人多业务混合场景下的“全域瘫痪”防雷避坑警告

如果您将所有这些服务部署在**同一台 Fly.io 实例、同一个物理端口（如 443 统一入口）**上：

*   **致命错误配置**：您在 Cloudflare 网页上**同时**开启了“全局/区域级”和“按主机名”，但您只在 Fly.io 服务器 Nginx 的 `certs/ca.pem` 中配置了专门为 `auth` 签发的私有 CA 证书。
*   **后果**：由于 Nginx 不支持根据 SNI 动态在 TLS 握手层切换 `ssl_client_certificate` 的 CA（除非使用复杂的握手动态解析），当访客访问您的网盘 `api.example.com` 时，CF 只能出示“全局/区域级”证书回源，Nginx 会拿着 `auth` 的 CA 去对齐它，直接导致 **密码学验证失败并强行断连**，您的网盘将直接瘫痪！

#### 3. 🎯 终极完美配置实战方案（仅让 auth 开启 mTLS，网盘完全不受影响）

如果您希望**只有 `auth` 启用高强度 mTLS 锁死，而其他二级子域名保持通用，且互不干扰**：

1.  **Cloudflare 端**：
    *   **彻底关闭** 全局（Global）和 区域级（Zone-level）开关。
    *   **仅在** 按主机名（Per-hostname）列表中，为子域名 `auth.yourdomain.com` 上传并单独绑定您私有的 AOP 客户端证书。
2.  **服务端 Nginx 端配合（条件式双向校验）**：
    在 Nginx 的主配置文件中，配置证书双向校验模式为 **可选（optional）**，从而支持不带证书的握手（防止网盘访客被瞬间拒绝），随后在具体的 server {} 块里对特定域名执行强拦截：

    ```nginx
    # 1. 允许客户端不带证书完成握手（建立连接保底）
    ssl_verify_client optional;
    ssl_client_certificate /etc/nginx/certs/ca.pem;

    # 2. 在门禁/授权管理虚拟主机块里，对未通过证书校验的请求强制阻断
    server {
        server_name auth.yourdomain.com;
        
        location / {
            if ($ssl_client_verify != SUCCESS) {
                return 403; # 无特制 AOP 私有证书者，直接当场拦截！
            }
            # 正常网关逻辑
        }
    }

    # 3. 在网盘等公共虚拟主机块里，不设置阻断，正常放行
    server {
        server_name api.example.com;
        
        location / {
            proxy_pass http://your-cloud-backend; # 正常反代网盘
        }
    }
    ```

---

## 🔒 5.5 极致安全防探测：TOTP 动态口令与 302 重定向洗刷加白

为了在“无状态、不引入外部数据库”的前提下彻底杜绝管理控制台因弹窗引发指纹扫描，系统升级了最先进的 **TOTP 动态口令与滑动 Session 锁合一防线**：

### 1. 为什么采用这套方案？（技术前因后果总结）
*   **攻防背景**：传统的 HTTP Basic Auth 存在严重的“401 WWW-Authenticate”劫持硬伤。如果服务器向不带密码的浏览器返回 401 信号，会强制触发浏览器的弹窗，这给扫描器指明了“此处存在密码大门”的破绽。
*   **传统方案硬伤**：若为了隐形直接让不满足校验的请求返回 200 并反代网盘，浏览器由于没有收到 401 挑战信号，其内部的 `https://user:pass@domain` 自动重试机制永远不会被唤醒。导致合法的用户点击链接也被无限卡死在网盘中（经典浏览器-服务器死锁）。
*   **降维级破局**：我们彻底移除了 Nginx 原生的 Basic Auth 配置。改由 Lua 进程在内层执行 **`预签名 URL Token (?u=user&code=6位TOTP)`** 的纯无状态数学计算。当外部恶意流量未带此口令试探时，系统**绝对不返回 401 弹窗，而是静默、高保真重定向到您的网盘（返回 200）**。
*   **302 洗刷与滑动 Cookie 顺延**：
    1.  **302 地址清洗**：当您首次使用包含 `?u=aaron&code=123456` 的完整长链接访问时，Lua 极速验证成功，自动为您的设备种下一枚长效 Cookie，并**立刻执行 302 临时重定向，跳转到纯净无参的控制台短链接**。明文验证码在浏览器地址栏停留时间少于 0.1 秒，完美洗刷历史痕迹防泄漏！
    2.  **滑动过期免密**：在随后的 30 天内（由 `RG_NGINX_SESSION_TTL_SECONDS` 控制），您的浏览器会自动携带 `gkp_session` Cookie。只要您在此期间刷新、点击过控制台，该 Cookie 的**有效存活时间会自动顺延 30 天**。您不再需要带上多余参数，免密、直入管理后台！

### 2. 本地一键生成 TOTP 动态验证码（5分钟有效）

因为系统默认的时间步长被对齐配置为了极度充裕的 **5 分钟（300 秒）**，极大地缓解了传统 Google Authenticator 30 秒倒计时的局促体验。

您可以在本地电脑的控制台（如 MacOS / Linux 终端）中，运行以下极简的 Bash 一键命令，获取您当前的 6 位动态验证码：

```bash
# [Bash 一键生成 5分钟有效验证码]
# 原理：根据当前 Unix 时间戳除以 300秒，结合种子密钥生成
luajit -e '
local bit = require("bit")
local totp_secret = "YOUR_NGINX_USER_PASSWORD_OR_BASE32_SECRET" -- 替换为您的 NGINX_USER_PASSWORD 或 Base32 秘钥
local interval = 300
local current_time = os.time()

local time_step = math.floor(current_time / interval)
local T_bytes = string.char(
    bit.band(bit.rshift(time_step, 56), 0xFF),
    bit.band(bit.rshift(time_step, 48), 0xFF),
    bit.band(bit.rshift(time_step, 40), 0xFF),
    bit.band(bit.rshift(time_step, 32), 0xFF),
    bit.band(bit.rshift(time_step, 24), 0xFF),
    bit.band(bit.rshift(time_step, 16), 0xFF),
    bit.band(bit.rshift(time_step, 8), 0xFF),
    bit.band(time_step, 0xFF)
)

local hash = ngx and ngx.hmac_sha1(totp_secret, T_bytes) or require("crypto").hmac("sha1", totp_secret, T_bytes) -- 自适应
local offset_byte = bit.band(hash:byte(#hash), 0x0F) + 1
local binary = bit.bor(
    bit.lshift(bit.band(hash:byte(offset_byte), 0x7F), 24),
    bit.lshift(hash:byte(offset_byte+1), 16),
    bit.lshift(hash:byte(offset_byte+2), 8),
    hash:byte(offset_byte+3)
)

print(string.format("您当前的 5分钟 专属动态加白验证码为: %06d", binary % 1000000))
'
```

## 🔒 5.5 极致安全防探测：多用户自适应 TOTP 动态口令与 302 洗刷

为了在“无状态、不引入外部数据库（零 Redis/DB）”的前提下彻底杜绝管理控制台因弹窗引发扫描器提取指纹，系统重构并升级了行业顶尖的 **“自适应多用户账密/标准 30秒 TOTP + 均分时间滑动缓冲区”** 验证机制。

### 1. 为什么采用这套方案？（技术前因后果总结）

*   **攻防背景**：传统的 HTTP Basic Auth 存在严重的“401 弹窗挑战”指纹破绽。只要扫描器试探不合规路径，服务器若返回 401 信号会强行要求浏览器弹出登录对话框，这暴露了该路径是一个验证后台的指纹特征，导致暴力破解威胁。
*   **传统方案硬伤**：若为了隐形在首包直接返回 200 并反代网盘，浏览器由于其内置安全机制，在全新 clean 会话下**首次 GET 访问默认绝不主动发送 Authorization 头**。这会导致正常的加白长链直接被阻断并卡死在网盘中，陷入死锁。
*   **降维级破局**：我们彻底移除了 Nginx 原生的 Basic Auth 401 弹窗模块。完全改由 Lua 进程在内层执行 **`预签名 URL 动态口令 (?u=user&code=6位TOTP)`** 的纯无状态数学计算。
*   **100% 拒绝弹窗并保持无痕回落**：当外部恶意探测未提供口令（或口令错误）时，系统**绝对不发送任何 401 或 WWW-Authenticate 标头**，而是直接运行 `ngx.exec("@fallback")` 返回 `200` 并高保真反代您的网盘。对扫描器而言这只是网盘的一个普通无害接口，实现极致隐形。
*   **302 洗刷与滑动 Cookie 顺延**：
    1.  **302 地址清洗**：当您首次使用包含 `?u=bob&code=123456` 的完整长链接访问成功时，Lua 验证通过，自动写入 Session Cookie，并**立刻执行 302 临时重定向，跳转到纯净无参的控制台短链接**。明文验证码在浏览器地址栏停留时间少于 0.1 秒，完美洗刷历史痕迹防泄漏！
    2.  **滑动过期免密**：在随后的 30 天内（由 `RG_NGINX_SESSION_TTL_SECONDS` 控制），您的浏览器会自动携带 `gkp_session` Cookie。只要您在此期间刷新、点击过控制台，该 Cookie 的**有效存活时间会自动顺延 30 天**。您不再需要带上多余参数，免密、直入管理后台！

---

### 🖥️ 5.6 极客终极防空：使用浏览器“书签脚本 (Bookmarklet)”接管 100% 自动登录探测

由于我们的后端在密码学上追求 **“绝对的零指纹暴露（对外 100% 全隐形，不发送 401 标头刺激弹窗）”**。

为了免去您在首次或新设备登录时，需要手动去拼装 `?u=aaron&code=123456` 长网址的繁琐操作。系统支持并提供了一个**极度智能、可自适应探测 Cookie 锁状态的浏览器书签脚本（Bookmarklet）**：

#### ⚙️ 运行与探测原理：
1.  **已登录（30 天内活跃设备）**：
    您直接在任何网页上，点击此书签 ➔ 浏览器检测到您有有效的 `gkp_active` 登录凭证 ➔ **0.1 秒内秒速直入控制台，完全免密码、免 TOTP 弹出！**
2.  **未登录 / Cookie 已过期（处于被静默反代的网盘页面下）**：
    您点击该书签 ➔ 脚本探测到本地缺少 `gkp_active` 指纹 ➔ **自动在您浏览器上弹出本地原生 Prompt 对话框**，要求输入 6 位验证码 ➔ 输入正确 ➔ **自动在后台为您拼接好带参长链发送激活 ➔ 302 洗刷掉地址栏 code 参数痕迹 ➔ 成功入驻 30 天免密！**

#### ✍️ 浏览器一键添加书签脚本（Bookmarklet）：
请在您的电脑或手机浏览器书签栏中添加一个全新书签，在 **“网址 (URL)”** 栏中直接全量粘贴并保存以下一行经过高度压制的 JavaScript 书签代码：

```javascript
javascript:(function(){var domain="YOUR_AUTH_DOMAIN";var prefix="YOUR_PATH_PREFIX";var token="YOUR_SECRET_TOKEN";var username="YOUR_PROXY_USERNAME";var baseUrl="https://"+domain+"/"+prefix+"/"+token;if(window.location.href.indexOf(domain)!==-1){if(document.cookie.indexOf("gkp_active=1")!==-1){window.location.reload();}else{var code=prompt("🔑 [RestyGuard 双重验证]\n\n您的 30 天免密已过期。\n请输入您手机 App (Google Authenticator) 上的 6 位动态验证码：");if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}}else{var code=prompt("🔑 [RestyGuard 智能免密通道]\n\n若当前已处于 30 天免密期内，可直接不输入并点“确定/回车”直入后台。\n\n新设备请直接输入您手机上的 6 位动态验证码：");if(code===""){window.location.href=baseUrl;}else if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}})();
```
*(注：使用时请将上述的 `domain`、`prefix`、`token` 和 `username` 参数脑补替换为您自己的真实控制台配置即可永久畅行！)*

---

### 3.4 [2026 深度打磨] 完美消灭隐私模式「回落套娃劫持」与 SW 幽灵霸占

在 v3.9.0 迭代中，我们解决了一个极其硬核、隐蔽的**现代浏览器隐私保护与 Service Worker (SW) 叠加引发的控制台失效 Bug**。

#### 💣 致命 Bug 复现链条
1.  **高保真回落引火上身**：用户由于直接访问根目录或未授权，请求被 Nginx 静默 `ngx.exec("@fallback")` 转发给真实业务系统。因为真实业务是带有 PWA 缓存机制的单页应用 (SPA)，浏览器瞬间在本地注册了管理域名 `auth.yourdomain.com` 下的作用域为 `/` 的 Service Worker。
2.  **302 跨站丢弃 Cookie**：用户随后通过书签跨站进行 TOTP 验证，Nginx 校验成功下发带有 `SameSite=Strict` 属性的 Cookie 并 302 重定向。但在**隐私模式**下，现代浏览器防弹跳追踪保护机制（Bounce Tracking Mitigation）会强制在跨站重定向链路中**清洗并丢弃**该 Cookie。
3.  **SW 幽灵劫持**：浏览器在干净 URL 下因为缺少 Cookie，再次被 Nginx 静默转至 `@fallback`（即真实业务 SPA）。此时，已经被注册的 Service Worker 被激活，它强制将所有的非静态资源导航请求**用本地缓存的 index.html 覆盖**。最终，导致控制台永远无法呈现，而是反复套娃渲染出真实业务的主页，并在 2 秒内疯狂发起 API 以及 locales 多语言拉取请求。

#### 🛠️ 终极密码学与协议层加固方案
我们通过在 `auth_handler.lua`、`auth_view.lua` 中进行以下三维一体重构，完美修复了此问题：

1.  **废弃 302 重定向，改用 HTML/JS 落地页强跳**：
    将原本的 `return ngx.redirect(..., 302)` 替换为直接返回 `200` 并附带一小段自刷新 HTML。这样，浏览器在当前 `auth` 域名下完成了真实的第一方页面落地，**完美破解了隐私模式下防弹跳追踪保护强制丢弃 Cookie 的限制**，使凭证 Cookie 能够稳稳写入！
2.  **响应头注入 `Clear-Site-Data: "storage"` 头物理杀毒**：
    在验证成功和首次写入 Cookie 时，下发：
    ```nginx
    Clear-Site-Data: "storage"
    ```
    这一记协议层重锤，会命令浏览器在一瞬间**强制卸载并注销**当前授权域名下的所有 Service Worker 并清空缓存，却不会删除刚刚下发的合法 Cookie 凭证，从物理层面彻底扼杀了“SW 幽灵劫持”。
3.  **OpenResty Cookie 获取安全加固（Table 崩溃防御）**：
    在 Lua 脚本中引入多 Cookie 安全合并函数，防止在浏览器带入多个 Cookie 时，`headers["Cookie"]` 在 OpenResty 中自动变成 Lua Table（数组）而引发 Lua 虚拟机崩溃：
    ```lua
    local function get_cookie_string(cookie_header_val)
        if type(cookie_header_val) == "table" then
            return table.concat(cookie_header_val, "; ")
        end
        return cookie_header_val or ""
    end
    ```
4.  **Cookie 属性降维**：将控制台认证 Cookie 升级为 `SameSite=Lax; Secure`，兼顾跨站书签导航体验与防 CSRF 攻击安全性。
5.  **前端页面级 Service Worker 强行自毁清洗**：在控制台页面及重定向 HTML 落地页中，注入前置 `navigator.serviceWorker.getRegistrations()` 循环卸载代码，即便曾经被大范围污染，用户点开书签的一瞬间也能将其自动治愈。

---

### 2. 标准 30 秒周期与自适应时间偏差均分缓冲区（TOTP 防超时机制）

大部分手机身份验证器（如 Google Authenticator, Microsoft Authenticator, Authy）默认且强制采用 **30 秒一变** 的步长。

为了让您能够直接使用手机扫码生成的标准一次性验证码，同时又彻底解决“30秒太急促、手速慢、或者客户端服务器微小时钟偏差导致输入失败”的极差体验，我们对验证机制进行了密码学对齐：

#### ⚙️ 核心机制：
1.  **口令一律 30 秒一变**：保证 100% 完美无缝兼容所有的手机身份验证器 App。
2.  **自适应均分校验滑动窗口**：通过配置环境变量 **`RG_TOTP_VALID_WINDOW_SECONDS`**（默认 300 秒，即 5 分钟）来控制可校验的时间偏差范围。
    *   **计算公式**：系统会自动将有效时间的一半均分给过去和未来，计算可校验的 steps 跨度：
        $$\text{max\_offset\_steps} = \lceil \frac{\text{TOTP\_VALID\_WINDOW\_SECONDS}}{2 \times 30} \rceil$$
    *   **均分效果**：若设为 300秒（5分钟），则在您发起验证时，服务器会以当前秒级时间为基准，**自动向前追加比对 5 步（过去 2.5 分钟内手机上刷新过并失效的 5 个历史口令依旧可以通过验证）**；并**向后追加比对 5 步（未来 2.5 分钟内手机即将刷新的 5 个口令提前通过验证）**。
    *   **总结**：在当前时间**前后各 2.5 分钟（合起来整整 5 分钟）内，手机上的所有 11 个验证码对服务器而言全部判为有效**。这为您提供了极其充裕、优雅且时钟容差度极高的一流使用体验！

---

### 3. 多用户配置与手机扫码绑定指南 (Google Authenticator)

#### ① 多用户环境配置格式
您可以直接在 `fly.toml` 的环境变量中，通过 **`RG_NGINX_USERS`**（用逗号分隔）进行多用户及静态密码与动态 TOTP 强度的混合配置（无状态，Stateless）：

```toml
[env]
# 支持多用户逗号分隔，格式为 username:password_or_TOTP[:optional_totp_secret]
RG_NGINX_USERS = "admin:password_here,bob:TOTP:YOUR_BASE32_SECRET,charles:5678"
```
*   **静态密码用户 (`admin`/`charles`)**：密码为非 `TOTP` 的普通静态字符串。使用带参长链直入：`...?u=charles&p=5678`。
*   **动态 TOTP 用户 (`bob`)**：密码配置为 **`TOTP`**，并在第三段中提供其专属的 **Base32 种子密钥**（如 `YOUR_BASE32_SECRET`）。使用手机 6 位口令直入：`...?u=bob&code=123456`。

#### ② 手机扫码或手动绑定指南
在将多用户 TOTP 密钥录入到您的手机身份验证器（如 Google 验证器）中时：

1.  **手动添加**：
    *   在 Google Authenticator 手机 App 中点击右下角 **“+”** ➔ **输入设置密钥（Enter a setup key）**。
    *   **信息填写**：
        *   **账号名称**：如 `auth.yourdomain.com`
        *   **您的密钥**：填入您在 `RG_NGINX_USERS` 中为该用户配置的 **Base32 种子密钥**（即上例中 bob 的 `MZXW6YTBOI2G64TE`）。*注意：种子密钥必须完全符合 Base32 标准，只包含大写字母 A-Z 和数字 2-7*。
        *   **类型**：保持默认的 **“基于时间（Time-based）”**（无需修改，步长保持标准的 30s）。
2.  **扫码添加 (自制二维码)**：
    为了能让您或您的副卡用户直接一键扫码绑定，您还可以利用任何二维码生成工具，将以下标准的 **OTPAuth 协议链接**生成二维码，用手机直接扫码绑定：
    ```text
    otpauth://totp/RestyGuard:bob?secret=MZXW6YTBOI2G64TE&issuer=RestyGuard
    ```

### 4. 如何生成符合 RFC 3548 标准的 Base32 种子密钥？

为了保证 Google 验证器能 100% 成功识别，您的自定义 TOTP 种子密钥（Secret）必须符合标准的 Base32 规范。

您可以使用以下几种极其便捷的方式，快速在本地生成安全、高强度的标准 Base32 种子：

#### 💡 方式 A：使用极简的 Python 一键生成（最推荐，全平台通用）
在您的本地电脑终端（支持 Python 3）中运行以下极简的一键命令：
```bash
python3 -c '
import os, base64
# 1. 随机生成 10 字节的高强度二进制强密码
random_bytes = os.urandom(10)
# 2. 对其执行 RFC 3548 标准的 Base32 编码并解码为干净的字符串
base32_secret = base64.b32encode(random_bytes).decode("utf-8")
print(f"您的标准 Base32 种子密钥为: {base32_secret}")
'
```
*(该命令会为您吐出一串纯净的大写英数、长度为 16 位的标准种子密钥，如 `MZXW6YTBOI2G64TE`)*。

#### 💡 方式 B：使用 OpenSSL + tr 命令生成（适合纯 Linux 环境）
如果您的环境只有 Shell，直接运行以下命令：
```bash
openssl rand -hex 10 | tr '0189' 'ABCDE' | tr 'a-z' 'A-Z' | cut -c 1-16
```
*(该命令通过随机生成 10 字节的 Hex，随后智能地将非法 Base32 字符 `0,1,8,9` 替换为合法字母并截取前 16 位，快速生成完美对齐的种子。)*

---

## 6. 项目 future 展望
1. **多重安全检测 (WAF)**：在四层上利用 Lua 对 TLS Client Hello 的特征码（如 JA3 指纹）进行分析，阻断恶意的扫描工具。
2. **可视化控制台**：在 8443 端口的管理界面提供一个极简的白名单列表页面，支持在前端网页一键删除已加白的 IP 或延长特定 IP 的 TTL 租约。
