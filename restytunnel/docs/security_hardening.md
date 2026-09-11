# RestyTunnel 安全加固与恶意探测防范技术复盘

在 RestyTunnel 的研发与方案推演过程中，我们围绕**恶意扫描（Malicious Scanning）、主动探测（Active Probing）、时序/行为特征分析**以及**宽带网络运营商（ISP）的流量管理策略**，进行了极其深入的底层协议剖析与实测验证。

以下是我们在此次交谈与测试中发现的核心安全隐患、测试维度及最终技术决策背后的底层逻辑。

---

## 🔬 一、 测试维度与核心问题发现

### 1. 纯原生 Nginx 1.31 `tunnel_pass` 裸奔测试
* **测试场景：** 
  不引入任何 Lua 脚本，直接在最外层（公网 443 端口）通过原生的 Nginx 1.31 开启 `tunnel_pass` 代理。
* **发现问题：**
  1. **协议死锁：** Nginx 1.31 开源版的 `tunnel_pass` 状态机在底层被硬编码为**只认识 HTTP/1.1 的文本格式 `CONNECT` 报文**。如果最外层开启了 HTTP/2 多路复用（`http2 on;`），Chrome 插件（如 SwitchyOmega）会发送标准的 H2 代理数据帧。原生 1.31 核心无法在没有外部解耦的情况下自行将 H2 帧解码并降维翻译为 1.1，从而在协议握手阶段就抛出 `400 Bad Request` 报错，导致连接直接断开。
  2. **指纹裸奔：** 为了让原生 Nginx 1.31 认出 `CONNECT`，我们必须强迫客户端退回 HTTP/1.1。这导致客户端与 Nginx 之间在公网上直接传输裸奔的 HTTP/1.1 `CONNECT` 指令。在现代全流量深度审计面前，高带宽、长周期的 1.1 `CONNECT` 长连接就是最显眼且容易被识别的指纹，极易在短时间内被扫描和识别并进行阻断。

### 2. 主动探测（Active Probing）中的“密码学测谎仪”漏洞
* **测试场景：** 
  当公网上的自动化探测器监听到某个海外 IP 的 443 端口产生大流量疑似代理/隧道特征时，会派出探测机器，模拟成普通客户端去连接该 443 端口。它会发送两种探测包：不带密码的代理包，或者乱填密码的错误代理包。
* **发现的问题（Lie-Detector Trap）：**
  我们对传统的代理及不同的分流重写方案进行了模拟，发现它们在探测器面前全部存在逻辑死穴：
  * **传统正向代理（老实人方案）➔ 暴露特征**：
    传统的 Nginx 补丁或 Squid 在遇到错误的密码时，会非常敬业地返回 `401 Unauthorized` 或 `407 Proxy Authentication Required` 并在 Header 中吐出 Proxy 认证挑战头。然而，一个纯正的静态个人博客/门户网站**绝对不可能对一个畸形的 `CONNECT` 协议返回代理密码框**。探测机一摸出 401 响应，直接判定为代理/隧道节点，将其进行封锁或标记。
  * **过度重写 200 OK（自作聪明方案）➔ 暴露痕迹**：
    如果我们写 Lua 脚本，规定“不管怎么探测，只要密码不对，一律返回 200 OK 博客首页”。
    这看似安全，实则留下了严重的**行为学特征差**。
    因为对于一个完全没有代理能力的普通 Nginx 服务器，当它收到一个 HTTP/1.1 `CONNECT` 请求时，因为不认识这个方法，它在协议层**必然且雷打不动地返回 `400 Bad Request`**。当它在 H2 管道内收到 H2 `CONNECT` 时，**必然会发送 `RST_STREAM` 错误帧或返回 `405 Method Not Allowed`**。
    如果我们的服务器不报错，反而高高兴兴地返回了 200 OK 和静态源码，探测器的分类器模型在对正常网站进行特征比对时，就会瞬间触发行为异常报警：“全世界的正常 Nginx 都在冷酷地报错，为什么唯独你这个 IP 脾气这么好、居然返回了 200 静态网页？你一定是在内存里挂载了重写脚本进行伪装！”。

### 3. 套用商业 CDN（Cloudflare等）的反噬效应与隐私危机
* **测试场景：** 
  在服务器前置挂载一层 CDN（如 Cloudflare 免费版）来隐藏源站真实 IP。
* **发现的问题：**
  1. **七层阻断：** 传统的免费 CDN 是标准的**七层反向代理**（话多、干预深），根本不支持纯粹的正向代理 `CONNECT` 盲隧道。当它在边缘节点解析到 `CONNECT` 命令时，会直接将其拦截并扔回 400 错误，导致代理直接瘫痪。若要跑通，必须强行改用 WebSocket 升级头（WSS）进行数据的额外包装。
  2. **隐私泄露：** CDN 会在边缘节点当场强制拆包并解密你的 TLS 传输。你的代理密码、访问的目标网站、传输的敏感数据在 CDN 内部**完全以明文形式暴露**。对于商业 CDN 的流量审计机制而言，这严重违反了服务条款（TOS），会导致域名被封，且存在巨大的隐私安全危机。
  3. **破坏正常网站指纹：** 流量审计系统往往对公共 CDN 边缘 IP 予以高度关注。一个无人问津、流量断续的个人小破站，突然套上了跨国巨头的高级反 D 盾，且里面唯一的流量是一条持续几小时、数据吞吐巨大的双向加密长连接，这在统计学合理性上极不相称，极易引来重点关注。

### 4. 传统 WebSocket over SSL/TLS (WSS) 伪装的特征退化
* **测试场景：** 
  使用通用代理服务挂载经典的 WSS（WebSocket 伪装）模式通过 Nginx 反代。
* **发现的问题：**
  1. **握手指纹极其明显：** 客户端建立连接时，必须发送特征明显的 HTTP 头部：`Upgrade: websocket` 与 `Connection: Upgrade`。在现代全流量深度审计面前，WSS 已经从“通用混淆”退化为了“极易被识别的标准代理指纹”。
  2. **协议重叠与性能抖动（Jitter）：** 数据包经历了：`数据 ➔ WS 帧 ➔ TLS 1.3 ➔ TCP` 的层层封包拆包。在多线程大流量下载时，不仅 CPU 占用率飙升，数据包由于脚本频繁执行垃圾回收（GC）还会产生微秒级的**非原生时延抖动**，流量分析算法很容易通过包间隔（IANA）算法嗅探出后端挂载了转发脚本。

### 5. 部分宽带运营商对 HTTP/3 (UDP 443) 的策略性劣化
* **测试场景：** 
  强制客户端与服务器只通过 HTTP/3 (QUIC) 代理协议，利用 QUIC 的 0-RTT 和连接迁移对抗丢包。
* **发现的问题：**
  部分宽带运营商（ISP）在技术上支持 HTTP/3，但**对于未备案的自定义 IP，实行了较严厉的“UDP QoS 限制”与“瞬时阻断”策略。**
  由于部分运营商会在网络高峰期（如 20:00 - 23:00）无差别对本地 UDP 443 端口流量实行较严格的 QoS 限制与限速，如果死守 HTTP/3，网络吞吐量会遭遇毁灭性打击。

### 🛡️ 6. 容器内集成测试发现的重大缺陷与技术妥协 (想当然预防实录)
在将配置模型放入 `openresty/openresty:1.31-alpine` 官方镜像进行最终集成测试时，我们发现了以下两处与预期截然不符的重大技术断层：
1. **实验性 C 模块 `ngx_http_acme_module` 不存在：**
   * **发现问题：** 尽管 Nginx 1.31.1 核心自带了原生盲转隧道，但 OpenResty 在编译其 1.31 官方 alpine 镜像时，**并未编译和打入 ACME 证书管理模块**（该模块在开源版依然属于实验性或第三方非标组件）。在 Nginx 启动加载此模块时会因 unknown directive 直接崩溃。
   * **决策修正：** 为了不破坏官方 OpenResty 的 alpine light-weight 镜像纯净度，我们重构为**基于 OpenSSL 本地极速自建开发/测试自签名证书保底的机制**。
2. **Sourcing 机制下的 `$0` 相对路径解析 Bug：**
   * **发现问题：** 当 entrypoint 启动并通过 sourcing 方式（`. 20-generate-config.sh`）引入 Nginx 渲染脚本时，Sourced 脚本中的 `$0` 会被 Shell 解释器强制解析为父级调用脚本（即 `/usr/local/bin/docker-entrypoint.sh`），而非当前脚本所在目录。这导致相对路径全部失效，Nginx 寻找模板路径崩溃。
   * **决策修正：** 我们重新设计了脚本中的模板文件定位，设置优先级机制（容器内 `/app` 标准绝对路径 ➔ 宿主机相对回落路径），成功消除了路径断层。

---

## 🛠️ 二、 RestyTunnel 的安全设计（为什么这样做？）

针对上述测试中暴露出的核心隐患，RestyTunnel 采取了**最符合协议底层美学、极简且具备卓越防探测能力**的安全设计：

### 1. 内存协议降维欺骗：代理域强制 HTTP/1.1 / 内部 1.1 CONNECT
* **为什么这样做：**
  我们既要在公网上隐藏 `CONNECT` 特征（防止被公开扫描审计），又要在服务器内部保留 1.31 纯 C 的 `tunnel_pass`（无参数）原生盲转性能。
  代理域名在公网显式关闭 H2/H3（`http2 off; http3 off;`），客户端在 **TLS 1.3 加密隧道内**发送标准的 **HTTP/1.1 `CONNECT`**（公网仅可见标准 TLS 1.3 密文，`CONNECT` 明文永不落地公网）。Lua 仅仅在连接建立的第一微秒介入一次做鉴权（双模式 + 错密黑名单，见 §三定稿小节），成功后控制权移交 C 内核 `tunnel_pass` 盲转，后续流量零 Lua 介入，彻底消除了频繁 TLS 握手的特征差异。

### 2. “大智若愚”的原生错误回落
* **为什么这样做：**
  为了解决“错密返回 401 暴露代理”和“错密强回 200 暴露 Lua 脚本特征”的双重死锁，我们采用了最绝妙的**“无招胜有招”放行机制**：
  ```lua
  -- 🔒 只有暗号完全正确的，才暗中送往本地原生 tunnel 核心
  if proxy_auth == expected_auth then
      ngx.exec("@native_tunnel")
      return
  end
  -- ❌ 密码错误、没带密码、或者第三方的恶意 CONNECT 盲扫探测
  -- 我们什么也不管，直接结束 Lua 阶段，把流量往后丢给静态站点
  return 
  ```
  当 Lua 选择“放行”之后，拒绝未知探测的行为完全交由 **Nginx 官方原生的 C 语言内核**或我们定义的**伪装后端**处理。由于没有触发代理 location：
  * 探测器用 HTTP/1.1 探测 CONNECT ➔ 穿过 Lua，被视为普通流量 ➔ 鉴权未通过（错密 / 未加白 / 黑名单内无凭证 / 普通访客）一律经 `ngx.exec("@backend")` **转发至伪装后端**，其响应（如后端对 CONNECT 返回 400/405，对普通浏览返回 200）由后端服务产生。网关自身不伪造响应。
  * 探测器用 HTTP/2 探测 CONNECT ➔ 逻辑同上，最终响应由伪装后端或 Nginx 原生 H2 状态机产生（如 `405` 或 `RST_STREAM`）。
  * 正常访客、搜索引擎蜘蛛盲扫 ➔ 穿过 Lua，触发正常的伪装后端路由 ➔ **正常返回静态站点 `200 OK`**。
  
  这在网络对抗中达到了极高的防线：**我们不需要去专门伪装报错信息。无论是让 Nginx 原生内核去报错，还是让伪装后端去响应，其指纹、字节大小、行为特征，都与全世界几百万台没有配置过代理的正常服务器 100% 吻合，毫无偏差。**

### 3. TLS 1.3 极速强加密与 HTTP/1.1 CONNECT 强制分离
* **核心痛点：**
  在 Nginx 核心中，原生的 `tunnel_pass` 盲转引擎被硬编码为读取传统的 HTTP/1.1 标准 `CONNECT` 请求报文。如果最外层开启了 HTTP/2 多路复用，客户端在代理连接时可能会发送标准的 H2 代理 CONNECT 数据帧，而原生 1.31 核心无法直接解析此类协议，会导致连接抛出语法错误当场断开。
* **为什么这样做：**
  我们通过在代理专属虚拟主机中显式地配置了 `http2 off;` 与 `http3 off;`。
  这在协议和 ALPN 协商层面，温柔且强势地迫使浏览器在握手阶段退回并协商采用标准的 HTTP/1.1 协议发送 `CONNECT` 命令，从而 **100% 保障了与底层的 Nginx 官方 C 级原生 blind tunnel 转发模块的完美兼容与极速转发**。
  请注意，虽然客户端与 Nginx 之间进行的是 HTTP/1.1 CONNECT 数据交换，但因为该交换发生在 **最外层 TLS 1.3（安全保密信道）** 的层层包裹内，公网外部的主动探测和包审计无法窥探到任何 `CONNECT` 明文字符，依然具有顶级的指纹整形安全性能。

### 4. 伪装后端反代接驳（`@backend`）
* **为什么这样做：**
  鉴权未通过的流量（错密 / 未加白 / 黑名单内无凭证 / 普通访客）经 `ngx.exec("@backend")` 反代至伪装后端（`nginx/conf.d/backend.conf`，`proxy_pass $fallback_backend`，按代理域/授权域隔离 `Host` 与 `SNI`：`$fallback_backend`/`$fallback_host` 在 `nginx.conf.template` 中按 `PROXY_FALLBACK_BACKEND`/`AUTH_FALLBACK_BACKEND` 分别注入）。后端对非标 `CONNECT` 自然返回 `400/405`，对普通浏览返回正常页面——所有错误均由真实后端产生，网关自身不伪造任何响应，行为指纹与正常网站 100% 吻合。

### 5. 自签名自愈保底机制（无 80 端口监听）
* **为什么这样做：**
  为了在极其干净、不包含额外 C 模块的 Alpine 镜像中完美闭环：
  我们通过证书路径（`RT_SSL_CERT_PATH` / `RT_SSL_KEY_PATH`，默认 `/etc/nginx/ssl/cert.pem` 与 `/etc/nginx/ssl/key.pem`）加载证书：
  * **保底自签：** 容器启动时，`bootstrap.sh` 会自动检测证书，如空则通过本地 `openssl` 自动极速生成保底证书，彻底解决由于证书不存在导致 Nginx 初始化失败崩溃的死锁。
  * **无 80 监听：** 当前 `nginx.conf.template` 与 `Dockerfile` 仅监听 `NGINX_PORT`（默认 443，含 TCP+QUIC），未监听 80 端口；明文 HTTP 访问 443 端口触发的 `497` 错误由 `error_page 497 =301 https://$host$request_uri;` 重定向至 HTTPS，而非 80→443 跳转。

### 6. H2/H3 混合自适应自愈（仅授权域）
* **为什么这样做：**
  面对部分网络运营商在网络拥挤时段对 UDP 443 (HTTP/3) 较严格的 QoS 限制：
  授权域（`AUTH_DOMAIN`）通过 `Alt-Svc` 建立 **TCP (HTTP/2) + UDP (HTTP/3) 双轨托底通道**（`nginx.conf.template` 授权 server 块：`listen ... quic` + `http3 on;` + `add_header Alt-Svc`）。在弱网、移动切换时，利用 HTTP/3 的 QUIC 特性保障连接 0 毫秒重建不断连；在大流量下载、运营商限制 UDP 时，客户端会在几毫秒内自动无缝降级回 **HTTP/2 (TCP)** 通道，利用对 TCP 相对充足的带宽预算，获得极其稳定的吞吐量。代理域（`PROXY_DOMAIN`）显式 `http2 off; http3 off;`，不参与该双轨。

---

## 🔒 三、 终极全隐形（Stealth）安全防线与 407 挑战零暴露机制

在常规的 HTTPS 正向代理架构中，当客户端发起连接但未提供身份凭证时，服务器按惯例会返回 `407 Proxy Authentication Required` 状态码，并附带 `Proxy-Authenticate` 挑战头。然而，在面对网络审查和主动探测的主动博弈中，**无脑发送 407 挑战无异于自杀**：
1. **主动特征泄露**：全网漏洞和协议扫描器（如 GFW 的主动探测机）只要探测到该端口对非标 `CONNECT` 请求返回了 407，即可 100% 判定其为 HTTPS 代理节点，当场予以封锁。
2. **局域网/共享 IP 惊扰**：在办公室或公共 Wi-Fi 场景下，若某个 IP 已被加白（已认证授权），同 IP 下的其他设备由于没有证书或凭证，访问该域名时可能会被触发 407 弹窗，不仅会惊扰其他网民，还会直接暴露该网关的存在。

为了实现抗主动探测的理论极限，我们重构了整个网关层，推出了**“双模式鉴权 + 定向 407 智能挑战 + 错密黑名单”**机制（定稿实现见本章末尾「🏁 定稿」小节）：
* **模式 1（主动式，密码即通行证）**：任何时候、任何 IP，只要第一包请求中携带合法的 `Proxy-Authorization` 凭证，**直接建隧道，不看白名单、不看黑名单**。curl / Clash / Safari 首包带密即通，换网络零 TOTP 漫游。
* **模式 2（浏览器冷启动）**：Chrome / Edge / Firefox 搭配 SwitchyOmega / ZeroOmega 时，**冷启动第一次 `CONNECT` 不会携带代理凭据**（原因见下文，不是 TLS/HTTPS 协议硬性要求）。仅当 IP 已加白时，网关才对其返回一次 `407 Proxy Authentication Required`，触发插件的 `onAuthRequired` 自动填密并重发，从而实现无缝直通。未加白 IP 绝不回 407，一律静默反代至伪装后端。
* **错密黑名单（防爆破减速带）**：携带错误凭证的请求按源 IP 计数，达阈值（默认 5 次）拉黑 24 小时。黑名单内「正确密码照常放行」，只拦无凭证/错密请求——合法用户永不被连坐。

> ⚠️ **不要把「浏览器插件冷启动需要 407」说成「Chrome 网络引擎物理上必须先 407」。** 两者不是一回事。407 也不是 HTTPS 代理的协议前置条件。详见下一小节。

### 3.1 Chromium 网络栈确实有两套代理认证机制

Chromium 的 HTTP 认证控制器（`net/http/http_auth_controller.*`）对代理（`AUTH_PROXY`）和源站（`AUTH_SERVER`）共用同一套状态机，存在两条完全合法的路径：

| 机制 | 源码入口 | 首包 `CONNECT` 是否带 `Proxy-Authorization` |
|---|---|---|
| **响应式（挑战）** | `HandleAuthChallenge()` 处理 407 | 否。盲发 → 等 `Proxy-Authenticate` → 再带密重发 |
| **主动式（预认证）** | `MaybeGenerateAuthToken()` → `SelectPreemptiveAuth()` | 是。`HttpAuthCache` 命中后，**第一个** `CONNECT` 就带头 |

主动式对应 RFC 7617 §2.2（Reusing Credentials）以及源码里的 `IDENT_SRC_PATH_LOOKUP`（path-based / preemptive authorization）。代理没有 URL path 的概念，cache 条目的 path 为空，但 **只要 cache 里已经有这条代理的成功凭据，后续 CONNECT 就会主动带头**，代理可以直接回 `200 Connection Established`，不必再 407。

因此下面两句话都是错的：

* 「Chrome 网络引擎硬性规定第一次 CONNECT 绝不能带 `Proxy-Authorization`」
* 「HTTPS 代理在协议层必须先弹出 407，否则认证无法工作」

407 发生在 **已经和代理建好 TLS 之后** 的 HTTP `CONNECT` 上，跟外层是 HTTP 明文代理还是 HTTPS 代理无关。curl / Clash / Xray / `curl_cffi` 等独立网络栈会在**第一个** CONNECT 就写 `Proxy-Authorization: Basic ...`，RestyTunnel 对它们本来就不需要 407。

### 3.2 那为什么 Chrome + 插件仍然几乎总是先走 407？

因为 Chrome **故意不把「代理设置里的账密」预置进网络栈**。主动式认证的前提是 `HttpAuthCache` 里已经有凭据；而 Chrome 拒绝从下列来源把账密写进 cache：

1. **命令行 / 手动代理 URL 中的 user:pass 会被丢掉。**  
   Chromium 官方 `net/docs/proxy.md` 写明：*Chrome does not implement this, and will not use any credentials embedded in the proxy settings. Proxy authentication will instead go through the ordinary flow to find credentials.*  
   所以 `--proxy-server=https://user:pass@host:443` 里的 `user:pass` **不会**让首包 CONNECT 带密。
2. **`chrome.proxy` API 的 `ProxyServer` 对象没有 username / password 字段。**  
   SwitchyOmega / ZeroOmega 只能设置 scheme / host / port（以及 PAC），不能把账密交给网络栈做预认证。
3. **系统代理设置里的明文账密，Chrome 同样不用。**
4. **密码管理器保存过的代理密码，也不会在冷启动首包就带上。** 流程仍是：盲发 CONNECT → 407 → 密码箱 / 插件自动填 → 写入 `HttpAuthCache` → **同一次浏览器进程内的后续 CONNECT 才真正变成主动式。**

企业 SSO（Negotiate / NTLM）可以走环境票据，有时能更早带头；这和 RestyTunnel 使用的 HTTP Basic 代理密码无关。

所以对 RestyTunnel 要兼容的 **Chrome + SwitchyOmega / ZeroOmega 冷启动路径**：不是引擎不会主动认证，是 **Chrome 不让你把代理密码预置进网络栈**。第一次 CONNECT 必然是盲发。同一次 Chrome 进程里认证成功之后，后续 CONNECT 会主动带密，网关直接 `200` 即可。

### 3.3 SwitchyOmega / ZeroOmega 能否在首次请求注入特殊标头？Chrome 允不允许？

**结论：不允许。插件既改不了发往代理的 `CONNECT` 头，也注入不了 `Proxy-Authorization`；自定义头就算能加到目标站请求上，RestyTunnel 也看不见。** 因此不存在「用一个秘密请求头绕过 407」的浏览器方案。

原因分四层，全部是 Chrome 的产品限制，不是 SwitchyOmega 没实现：

#### （0）「赋予修改网页权限」也救不了：那是目标站权限，不是代理 CONNECT 权限

Chrome 安装提示里的 **「读取和更改您在访问的网站上的所有数据」**，对应的是清单里的 `host_permissions`（ZeroOmega 已经声明了 `"<all_urls>"`）。它允许扩展：

* 在匹配的网页里注入内容脚本、读 DOM
* 用 `tabs` 读该站 URL / 标题
* 对该站发 `fetch()`、读 Cookie
* 在 **发往该站的 HTTP(S) 请求** 上，配合 `webRequest` / `declarativeNetRequest` 观察或改头

它 **不** 允许：

* 改浏览器内部发往代理的 `CONNECT`
* 写 `Proxy-Authorization` / 任何 `Proxy-*`
* 把自定义头挂到隧道建立这一跳上

ZeroOmega 3.5.1 的实际权限是：

```json
"permissions": [
  "proxy", "tabs", "alarms", "storage", "unlimitedStorage",
  "webRequest", "webRequestAuthProvider", "contextMenus"
],
"host_permissions": ["<all_urls>"]
```

也就是说：**网页权限它已经有了**，而且是最宽的 `<all_urls>`。缺的不是「再勾一次修改网页」，而是：

1. **没有 `webRequestBlocking`**（MV3 商店扩展本来就不能有，除非企业策略强制安装）
2. **没有 `declarativeNetRequest`**，UI 里也没有「给某某网站加请求头」的开关
3. 仓库里名为 custom headers 的功能（PR #260）只用于 **拉取切换规则列表**（例如带 `Authorization` 去拉私有 gist），**不会**给用户浏览的网页请求加头

即便将来 ZeroOmega 加上 DNR，给 `https://www.google.com/*` 注入 `X-Resty-Token`，这条头也只出现在 **CONNECT 已经 200、隧道已经建成之后** 的内层 TLS 里。RestyTunnel 在 CONNECT 阶段鉴权，成功后 `tunnel_pass` 盲转，**内层头一律看不见**。没有 407，CONNECT 过不去，后面的「给特定网页加头」根本不会发生。

所以：再给 SwitchyOmega / ZeroOmega 开一遍网页权限、或换一个「能改特定网站请求头」的扩展，都 **绕不开冷启动 407**。能改的是目标站那一跳；RestyTunnel 要看的是代理那一跳。

#### （1）插件根本碰不到 `CONNECT` 这一跳

RestyTunnel 只在 **外层 `CONNECT`（及其请求头）** 上做鉴权。认证成功后 `tunnel_pass` 把套接字降成四层盲转，**内层 HTTPS 的请求头（Host / Cookie / 自定义 `X-*`）网关完全不解析。**

Chrome 扩展看到的 `webRequest` / `declarativeNetRequest` 事件，对应的是 **用户要访问的目标 URL**（例如 `https://www.google.com/`），不是浏览器内部向代理发出的那条 `CONNECT www.google.com:443 HTTP/1.1`。CONNECT 是网络栈的隧道建立动作，不对普通扩展开放。

所以：在目标站请求上加 `X-Resty-Auth: ...`，对 RestyTunnel **毫无意义**——那条头出现在隧道 *里面*，出现时鉴权窗口早已关闭。

#### （2）`Proxy-Authorization` 以及所有 `Proxy-*` 都是禁改标头

即使退一步，想在「能改的请求」上动手脚，Chrome 也不让改代理认证头：

* Fetch / XHR / 页面 JS：所有 `Proxy-*` 都是 [Forbidden request header](https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header)，脚本设置会被静默丢弃。
* `chrome.webRequest.onBeforeSendHeaders`：文档写明 **默认不向扩展提供** `Proxy-Authorization`、`Authorization`、`Host`、`Connection` 等头；即便加上 `extraHeaders`，`Proxy-Authorization` 仍按禁改头处理，扩展不能可靠地读、改、写它。
* `chrome.declarativeNetRequest` 的 `modifyHeaders`：`append` 只允许白名单里的少数头（`user-agent`、`cookie`、`accept-language` 等）。**没有 `Proxy-Authorization`，也没有任意 `X-*` 往 CONNECT 上塞的通道。**

SwitchyOmega / ZeroOmega 提供账密的唯一官方入口是 **`chrome.webRequest.onAuthRequired`**：它 **只在收到 401/407 之后** 才会触发。没有 407，回调不会跑，锁图标里存的密码永远送不出去。

#### （3）`chrome.proxy` 只能改「走哪台代理」，不能改「请求长什么样」

`chrome.proxy.settings.set` 只能提交 `mode` / `rules` / `pacScript`。`ProxyServer` 只有 `scheme`、`host`、`port`。没有：

* 用户名 / 密码
* 自定义请求头
* 「首包 CONNECT 预带 Basic」开关

这是 Chrome 扩展模型的硬边界。ZeroOmega 是 SwitchyOmega 的维护分支，代理认证路径相同，并不多出一套「首包注入头」的 API。

#### （4）Manifest V3 把「拦截改头」收得更死

自 MV3 起，商店分发的扩展失去 `webRequestBlocking`（政策强制安装的企业扩展除外）。SwitchyOmega / ZeroOmega 即便想在 `onBeforeSendHeaders` 里同步改头，普通用户侧的 Chrome 也不再允许。认证只能继续走 `webRequestAuthProvider` + `onAuthRequired` 这条 **407 之后** 的路。

| 想做的事 | Chrome 是否允许 | SwitchyOmega / ZeroOmega 能否做到 |
|---|---|---|
| 把账密写进 `chrome.proxy` 配置，让网络栈首包带密 | 否（API 无此字段；嵌入凭据会被丢掉） | 否 |
| 在首次 `CONNECT` 上写 `Proxy-Authorization` | 否（禁改头 + CONNECT 不对扩展暴露） | 否 |
| 在首次 `CONNECT` 上写自定义头（如 `X-Resty-Token`） | 否（扩展改不到 CONNECT） | 否 |
| 再授予「读取和更改网站数据」(`host_permissions`) | 可以（ZeroOmega 已有 `<all_urls>`） | 已有；仍改不到 CONNECT |
| 给特定网页（如 google.com）加 `X-*` 请求头 | 理论上可以（需 DNR / 阻塞式 webRequest） | ZeroOmega **没做**；即便做了也在隧道内，网关看不见 |
| 给拉取 PAC / 规则列表的请求加头 | 可以 | ZeroOmega 仅此用途（PR #260），与代理鉴权无关 |
| 收到 407 后再提供账密 | 是（`onAuthRequired`） | 是（锁图标 / 已存密码） |
| 同进程内第二次及以后的 CONNECT 主动带密 | 是（`HttpAuthCache` 预认证） | 是（浏览器自己做，插件不用再插手） |

**工程推论：** 不存在「给 SwitchyOmega 加一个秘密头、RestyTunnel 认头即可免 407」的兼容方案。要对浏览器插件保持无感登录，**已加白 IP 的定向 407 仍然是唯一合规通道**。独立客户端（Clash、curl、自研 `curl_cffi`）继续走主动式，首包带 `Proxy-Authorization` 即可，与 407 无关。

### 3.4 「先认一个秘密头，再决定要不要 407」——设计是对的，但头必须加在 CONNECT 上

保留 407、同时希望「只有带着特殊标头的请求才提供代理，否则一律伪装成普通网页」，这个分层是对的，而且正是为了压共享 IP 上的 407 指纹：同一公网出口里，只有「我的浏览器」才该看到 407，邻居设备、扫描器、普通网民访问同一域名时必须看到普通站。

但头加在哪一层，决定了它是身份令牌还是隐私事故。

```
浏览器
  │
  │  ① 外层：CONNECT + （可选）自定义头     ← 只有 RestyTunnel 看得到
  ▼
RestyTunnel 网关（鉴权 / 407 / 伪装发生在这里）
  │
  │  ② 内层：目标站 HTTPS 请求头            ← Google / 银行 / 任意网站都看得到
  ▼
目标网站
```

#### 头加在 ① CONNECT 上：不会泄漏给目标站

`CONNECT www.google.com:443 HTTP/1.1` 及其请求头只发给代理。隧道 `200` 之后，内层是另一套 TLS，目标站收不到外层任何头。

所以下面这种头 **不会** 泄漏给「被代理的网站」：

```http
CONNECT www.google.com:443 HTTP/1.1
Host: www.google.com:443
X-Resty-Gate: <只给你自己网关看的令牌>
```

网关逻辑可以是：

* 无此头、无 `Proxy-Authorization` → 直接伪装成普通网页（**连 407 都不回**）
* 有此头、无账密 → 才回 407，让 Chrome 插件填密
* 有合法 `Proxy-Authorization` → 直接 `200`（Clash / curl 的主动式）

共享 IP 上的邻居即使用 CONNECT 来扫，没有这个头也摸不到 407。这比「已加白 IP 就对整段 IP 回 407」更精确。

RestyTunnel **今天已经在用这个模型的一半**：`Proxy-Authorization` 本身就是「特殊标头」。Clash / curl 首包带它 → 直接代理；不带 → 伪装。缺的只是 Chrome 冷启动那一跳：它既带不了 `Proxy-Authorization`，也带不了第二个自定义头。

#### 头加在 ②「整个浏览器 / 特定网页」上：会泄漏，而且网关用不上

用扩展给「所有网站」或「google.com」加 `X-Resty-Gate`，这条头走的是内层 HTTPS：

* RestyTunnel 在 CONNECT 阶段鉴权，此时这条头 **还不存在**
* CONNECT 成功后 `tunnel_pass` 盲转，网关 **不解析** 内层头
* 目标站（Google、银行、任意 HTTPS 站点）会在自己的访问日志里看到这个头

这就是「感觉会泄露给代理的网站」——判断完全正确。把身份令牌焊进整浏览器的请求头，等于向每一个被访问的网站声明「我在用 RestyTunnel」。不要这样做。

Chrome 扩展（含 SwitchyOmega / ZeroOmega、以及任何「修改网页请求头」的插件）只能动 ②，动不了 ①。所以：

| 做法 | 网关能否用来决定「要不要 407」 | 会不会泄漏给目标站 |
|---|---|---|
| CONNECT 上的自定义头 / `Proxy-Authorization` | 能 | 否 |
| 给整个浏览器所有网页请求加头 | 不能（来太晚，且在隧道内） | **会** |
| 只给特定网页加头 | 不能（同上） | 会泄漏给那些网页 |
| Chrome + SwitchyOmega 冷启动 CONNECT 加头 | Chrome 不允许 | — |

#### Chrome 插件路径上，这个秘密头加不上去

要让「先认头再 407」在浏览器里生效，第一个 CONNECT 就必须带上头。Chrome 不允许扩展改 CONNECT，SwitchyOmega / ZeroOmega 做不到。因此：

* **不要指望改 SwitchyOmega、再开网页权限、或给全浏览器加头来实现这套门禁。**
* 407 对 Chrome 插件冷启动 **仍然要保留**；当前「仅已加白 IP 才 407、外人一律伪装」已经是 Chrome 约束下能做的最接近形态。
* 共享 IP 上 407 仍可能被同出口的邻居看到——这是白名单粒度（IP）粗于设备粒度的固有代价，不是再加一个网页头能修的。

#### 独立客户端可以，而且不必新发明一个头

Clash / Xray / curl / `curl_cffi` 能在 **第一个 CONNECT** 上写任意头。对它们来说：

* 继续用 `Proxy-Authorization` 当那张「特殊标头」即可，不必再叠一个 `X-Resty-*`
* 首包带密 → 直接代理，**根本不会触发 407**
* 扫描器盲发 CONNECT → 伪装成普通网页

若一定要和第二条头做门禁（例如只对带 `X-Resty-Gate` 的 CONNECT 才进入鉴权，连错误密码也不走 407），只应加在 CONNECT 上，并且只给这些独立客户端用。浏览器插件享受不到。

#### 若坚持让 Chrome 也「先亮令牌再 407」

唯一现实的办法是在本机再垫一层 **能改 CONNECT 的转发器**（本机 Clash mixed 端口、Privoxy、自写 tiny proxy）：

```
Chrome（无头 CONNECT，指向 127.0.0.1）
  → 本机转发器补上 X-Resty-Gate 或 Proxy-Authorization
  → RestyTunnel
```

令牌加在本机到网关的 CONNECT 上，目标站仍然看不见。这已不是「给 SwitchyOmega 加个标头」，而是换客户端形态。代价是本机多一个进程，Chrome 直连 HTTPS 代理的路径用不上。

**结论：** 用 CONNECT 上的特殊头做身份、没有头就伪装、有头才 407——协议设计成立，也不会泄漏给被代理的网站。Chrome 插件加不了这张头；给整个浏览器加头则会泄漏给所有目标站，且网关看不见。407 对 SwitchyOmega / ZeroOmega 继续保留；独立客户端继续靠 `Proxy-Authorization` 当那张头，不必 407。

### 3.5 Chrome 本身（设置 / `chrome://flags` / DevTools）能不能加特殊标头？

**短答案：日常设置和实验功能都不能。** Chrome 没有「给所有请求 / 给 CONNECT 加一个自定义头」的开关。能改头的入口全是调试器，而且改的是 **网页请求**，不是发往代理的 CONNECT。

| 入口 | 能不能加自定义请求头 | 加在哪一层 | 日常代理能不能用 |
|---|---|---|---|
| `chrome://settings`（含系统 / 代理） | 否。只能设代理主机、端口、PAC，不能设账密，更不能设头 | — | 否 |
| `chrome://flags` | 否。上千个实验开关里没有「extra request headers」这类项 | — | 否 |
| 命令行 | 只能改少数内置头，例如 `--user-agent`、`--accept-lang`。**没有** `--extra-headers` / `--add-header` | 网页请求（UA / Accept-Language） | 否（改不到 CONNECT，也不是任意头） |
| DevTools → Network → 本地替换 | 能改 **响应头**（Chrome 113+）；部分版本也能改单条请求的请求头，供本地调试 | 当前标签页的目标站请求 | 否。关 DevTools / 换标签即失效；不进 CONNECT |
| DevTools → Network 条件 | 只能模拟 `Save-Data`、自定义 UA 等有限项 | 网页请求 | 否 |
| CDP `Network.setExtraHTTPHeaders` | 能。对「这个页面发出的请求」附加额外 HTTP 头 | **页面请求**，不是 CONNECT | 否。要开远程调试；头会泄漏给目标站；RestyTunnel 在 CONNECT 上看不见 |
| 企业策略 | 可管代理、PAC、部分安全策略；**没有**「全局自定义请求头」策略 | — | 否 |

补充：

* **`chrome://flags` 不是藏着的请求头面板。** 它只开关 Chromium 功能（GPU、站点隔离、各种 UI）。没有「给每个请求塞 `X-Resty-Gate`」这种 flag。
* **DevTools 的改头是调试器，不是产品能力。** `Network.setExtraHTTPHeaders` 的文档写的是 *requests from this page*。CONNECT 由网络栈在页面请求之前发出，不走这套「页面额外头」。就算误把身份令牌加到页面请求上，也是上一节说的第 ② 层：目标站看得到，网关在鉴权窗口看不到。
* **命令行里的 `--proxy-server` 同样不带头。** 前面已引用官方文档：嵌入在代理设置里的 user:pass 会被丢掉。

所以：不要去设置或 flags 里找「全浏览器加一个身份头」。Chrome 故意不提供这条产品开关。身份只能放在 CONNECT 上；Chrome 自己加不上去，407 对插件冷启动继续保留。

### 3.6 复盘：本对话遗漏了什么？有没有更好的方案？

#### 遗漏 1：407 其实只有「主动探测者」看得到

407 是在 TLS 握手 **之后** 的 CONNECT 上返回的，被 TLS 完全包裹。被动监听流量的人看不到 407，只能看到一段高熵密文。能摸到 407 的只有「自己主动建 TLS、自己发 CONNECT」的探测者——而这已经被 IP 白名单解决。所以「首次 407 特征太明显」这个担忧，实际暴露面比直觉小得多：它不是被动指纹，而是主动探测信号。当前架构对此的处理（仅加白 IP 才 407）已经把暴露面压到接近零。

#### 遗漏 2（核心）：TLS 客户端证书（mTLS）——Chromium 官方支持的「第三条路」

前面所有讨论都困在 HTTP 层（CONNECT 头 / `Proxy-Authorization`），漏掉了 Chromium `net/docs/proxy.md` 的明确一句：

> In addition to the usual HTTP authentication methods, HTTPS proxies also support **client certificates**.

这意味着存在一条浏览器原生、第一次连接就带身份、彻底免 407 的路径：

* **Chrome 会在 TLS 握手阶段主动出示客户端证书**（首次弹一次选择框，选中后浏览器按代理 origin 记住；可用企业策略 `AutoSelectCertificateForUrls` 全自动）
* 证书只交给代理的 TLS 终端（Nginx），**目标站永远看不到**——不存在「泄漏给被代理网站」的问题
* 对网关而言，证书就是那张「特殊标头」：无证书 → 伪装；有证书 → 提供代理（可继续叠加密码）

落地方式（Nginx 原生支持，本项目 AUTH_DOMAIN 的 Cloudflare Authenticated Origin Pulls 用的就是同款技术）：

```nginx
# 代理 vhost
ssl_verify_client optional_no_ca;   # 请求但不强制，无证访客照常进入
```

```lua
-- access_by_lua 里在账密校验之前加一层
if ngx.var.ssl_client_verify == "SUCCESS" then
    -- 指纹在白名单 → 视同已认证，直接 @native_tunnel（或继续要求密码做双因子）
else
    -- 无证书 → 走现有伪装/407 逻辑
end
```

#### mTLS 方案的真实代价（必须诚实列出）

1. **TLS 层新增指纹：`CertificateRequest`。** 开启 `ssl_verify_client` 后，每次握手 Nginx 都会向客户端请求证书。主动探测者在 TLS 层能看到「这个服务器要求客户端证书」。缓解因素：银行、企业门户要求客户端证书并不罕见，属于低置信信号；且普通访客没有你的 CA 签发的证书时，Chrome/Firefox 会静默继续（不弹窗、不报错）。
2. **指纹形态的取舍，不是免费的。** 三个方案各有暴露面，选其一：
   * **现状（白名单 + HTTP 407）**：407 仅暴露给已加白 IP 上的主动探测者
   * **mTLS**：`CertificateRequest` 暴露给所有 TLS 握手者，但 HTTP 层 407 可以完全删掉
   * **本地转发器**：无新增服务端指纹，代价是客户端多一个进程
3. **证书分发与吊销**：CA 私钥、给多设备签发、过期轮换，比一个密码麻烦。
4. **第三方客户端兼容性需实测**：curl 支持代理客户端证书；Clash/mihomo 对 HTTPS 代理的 client cert 支持要验证，不行就让它们继续走 `Proxy-Authorization` 主动式。

#### 建议的最终形态（组合拳）

* **浏览器（Chrome + 插件）**：mTLS 为主——TLS 层直接带身份，冷启动零 407，共享 IP 邻居连 407 都摸不到；`ssl_verify_client optional_no_ca` 保证无证访客无感。
* **独立客户端（Clash / curl）**：继续首包 `Proxy-Authorization` 主动式，或同样签发证书。
* **HTTP 407 分支**：降级为兜底（证书校验失败但 IP 已加白时才回），未来可彻底移除。
* 若不想动 TLS 层：维持现状即可——它是 Chrome 约束下、不改客户端形态的最优解，本对话其余结论（扩展改不了 CONNECT、全浏览器加头会泄漏、flags 没有开关）仍然全部成立。

#### mTLS 在移动端怎么用？（现实比桌面受限得多）

证书文件准备（桌面生成后传手机）：

```bash
# 自建 CA + 用户证书（已有 CA 则直接签发用户证书）
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ca.key -out ca.crt -subj "/CN=RestyTunnel CA"
openssl req -newkey rsa:2048 -nodes \
  -keyout phone.key -out phone.csr -subj "/CN=phone"
openssl x509 -req -in phone.csr -CA ca.crt -CAkey ca.key \
  -days 365 -out phone.crt
# 打包成手机可导入的 PKCS#12（含私钥，设导入密码）
openssl pkcs12 -export -inkey phone.key -in phone.crt \
  -certfile ca.crt -out phone.p12
```

**Android：**
1. 把 `phone.p12` 和 `ca.crt` 传到手机，`设置 → 安全 → 更多安全设置 → 加密与凭据 → 安装证书`：
   * **VPN 和应用用户证书** ← 装 `phone.p12`（这是客户端证书，Chrome 从系统 KeyChain 读取）
   * **CA 证书** ← 装 `ca.crt`（Android 7+ 应用默认不信任用户 CA，需信任才能完成校验链）
2. Chrome Android 会自动把系统用户证书出示给请求客户端证书的服务器，无需额外配置。

**但 Android 有一个硬限制：** 系统代理（Wi-Fi 设置里手动配的代理）**只支持 HTTP 代理**，填不了 HTTPS 代理、也配不了客户端证书。也就是说「Chrome Android 直连你的 HTTPS 代理」这条路本身就走不通，mTLS 证书装了也没有直连场景可出示。Android 上现实的用法只剩 **本地转发 App**（Clash for Android / NekoBox / SagerNet 等）：App 自己向 RestyTunnel 发起 HTTPS CONNECT。这类内核（mihomo 等）目前普遍 **不支持** HTTPS 代理出站的客户端证书字段，只能走 `Proxy-Authorization` 主动式——好在这本来就是免 407 的。

**iOS：**
1. `.p12` 通过 AirDrop / Safari 下载后，`设置 → 已下载的描述文件 → 安装`，安装时输入导出密码。
2. Safari 支持客户端证书，会弹选择框。但 iOS 的 Wi-Fi 手动代理同样 **只有 HTTP 代理**，没有 HTTPS 代理字段——与 Android 同样的死结。
3. Chrome iOS 基于 WKWebView，客户端证书支持历来不完整，需实测。

**结论：移动端 mTLS 目前是「理论可行、系统代理卡死」。** 但移动端恰好不需要它——手机用户本来就用 Shadowrocket / Stash / Clash 等本地 App 当客户端，App 自己的 TLS 栈在第一个 CONNECT 就带 `Proxy-Authorization` 主动式，**天然免 407、天然不泄漏**。mTLS 的价值场景集中在桌面 Chrome；移动端维持「本地 App + 账密主动式」即可，这等于 §3.4「本机转发器」方案在手机上的自然形态。若某天所用内核支持了 client cert（如 Shadowrocket/Stash 的证书配置项），再签发证书接入即可。

**补充（重要）：带扩展的移动端浏览器是例外——插件路径在手机上其实走得通。**

上面说的「系统代理只有 HTTP 代理」只卡 **OS 层** 的 Wi-Fi 手动代理。如果手机上装的是 **支持扩展的浏览器**，代理配置走的是扩展的 `proxy` API，不经过系统代理设置：

* **Firefox for Android**（ZeroOmega 官方上架了 Firefox Addon）：`browser.proxy` API 支持 `scheme: "https"`，扩展可直接配置 HTTPS 代理
* **Kiwi Browser / Edge Canary Android / Quetta 等 Chromium 系**：可安装 Chrome 商店扩展，`chrome.proxy` 同样支持 `scheme: "https"`

在这些浏览器里装上 ZeroOmega 并配置 HTTPS 代理后，行为与桌面 **完全一致**：

1. 冷启动第一个 `CONNECT` 盲发（扩展改不了 CONNECT 的限制不变）
2. 网关（若 IP 已加白）回一次 407
3. 插件 `onAuthRequired` 自动填密重发
4. 之后同进程内走 `HttpAuthCache` 预认证

也就是说：**§3.2 / §3.3 的全部桌面结论原封不动搬到这些移动浏览器上**——冷启动仍需 407，秘密头加不上去，mTLS 与否取决于该浏览器内核的客户端证书支持（Firefox Android 的 client cert 支持历史上一向不完整，需实测；Kiwi 这类项目维护状态要留意，Kiwi 已停更）。

实际取舍：

* **手机日常**：本地代理 App（Shadowrocket / Stash / Clash）+ 账密主动式仍然是最顺滑方案，免 407、全局生效
* **需要浏览器级精细分流**（某个站直连、某个站走代理）：Firefox Android + ZeroOmega 是唯一正式路径，代价是冷启动那一次 407（已加白 IP 才有，共享 IP 上的暴露面同桌面）
* **注意共享 IP**：手机在移动基站/公共 Wi-Fi 下的公网出口本就是共享 IP，此时 407 恰好会被同出口邻居设备看到——这是白名单按 IP 粒度的固有代价，与桌面一致

#### 能不能避免冷启动 407？纯插件路径不能，但手机上有两条出路

**纯「浏览器 + ZeroOmega」路径：躲不掉。** Firefox 的 `browser.proxy` `ProxyConfig` 同样只有 `host` / `port` / `type` / `proxyDNS`，没有账密字段；PAC 里写 `user:pass@host` Firefox 也不认；`onAuthRequired` 同样只在收到 407 后触发。这是引擎层的产品决策（所有主流内核一致：不把设置/扩展里的代理账密预置进网络栈，防恶意扩展静默借道），与手机无关。§3.3 的结论对 Firefox Android 原样成立。

**出路 1：mTLS。** Firefox 对客户端证书的支持历来比 Chrome 好得多，近年 Firefox Android 已能从系统凭据库读取用户证书并出示（具体版本需实测）。证书装进系统后，Firefox Android + ZeroOmega 即可实现冷启动零 407。Chromium 系手机浏览器（Kiwi 等）的 client cert 支持不确定，需逐个验证。

**出路 2：手机版本地转发器（最实用，无需装扩展）。** 在 Termux 跑一个十几行的转发脚本，监听 `127.0.0.1:8888`：

```
浏览器（代理指向 127.0.0.1:8888）
  → 本地转发器：收到裸 CONNECT，自己向 RestyTunnel 发起带账密的主动式 HTTPS CONNECT
  → RestyTunnel（首包带 Proxy-Authorization，直接 200，零 407）
```

* 浏览器侧用系统 Wi-Fi 代理填 `127.0.0.1:8888` 即可（**系统代理只支持 HTTP 的死结在这里反而消失**——本地一跳是环回上的明文 HTTP，无所谓；出网那一跳由转发器做 TLS），连扩展都不用装
* 这就是 §3.4「本机转发器」方案的字面手机版；若手机上本来就有 Clash App，也可以把 RestyTunnel 配成 Clash 的 HTTPS 出站（带账密），浏览器走 Clash 本地 mixed 端口——但分流就归 Clash 管，不再是浏览器级分流
* 代价同桌面转发器：多一个常驻进程（Termux 后台 / 或一个 root-less 的小工具）

**追问：mTLS 证书能不能只装给浏览器、不装进系统？**

* **桌面 Firefox：可以，且是唯一真·浏览器级方案。** `设置 → 隐私与安全 → 证书 → 查看证书 → 您的证书 → 导入` 直接装 `.p12`，私钥只进 Firefox 自己的 NSS 数据库（`cert9.db`），系统和其他浏览器完全感知不到。
* **Firefox Android：没有证书导入 UI，只能曲线实现。** Android 版砍掉了证书管理器，但稳定版保留 `about:config`：把 `security.osclientcerts.autoload` 设为 `true`，Firefox 就会按需从 Android 系统 KeyChain 加载用户客户端证书。流程：系统设置装 `.p12` → 开该预项 → Firefox 出示证书。
* **隔离性疑虑其实不大：** Android KeyChain 里的客户端证书 **不会** 被其他 App 自动使用——每个 App 必须显式调用 `KeyChain.choosePrivateKeyAlias()` 主动请求且用户会看到选择器；Chrome 也只在服务器真发 `CertificateRequest` 时才会用到。所以「装进系统」≠「泄漏给其他 App」，只是做不到桌面那种「证书物理上只存在于浏览器内」。
* **Chromium 系桌面（Chrome/Edge）：** 只有系统级/KeyChain 级安装，没有浏览器内部证书库；可配合企业策略 `AutoSelectCertificateForUrls` 免弹窗。

**再追问：证书是客户端主动提交还是服务端要求的？服务端要求本身是不是暴露点？**

* **机制上只能服务端发起。** TLS 客户端认证是服务器驱动的：握手中服务器先发 `CertificateRequest`，客户端持有匹配证书才回 `Certificate`。没有「客户端先塞证书」的消息类型（TLS 1.3 post-handshake auth 同样是服务器发起）。因此一旦开启 `ssl_verify_client`，**每一次**与代理域名的握手都会收到这个要求——包括探测者的。
* **但暴露面比直觉小，TLS 1.3 的加密结构帮了忙：** 服务端第二段飞行（EncryptedExtensions / CertificateRequest / Certificate）全在密钥交换之后**加密发送**。被动监听者（IPS、流量分析）和只做端口扫描的人**完全看不到**「要求证书」这件事；只有**主动完成完整 TLS 握手**的探测者才能看到。
* **真正独特的暴露点是 CA DN 清单：** Nginx 配了 `ssl_client_certificate` 后，握手时会把可接受 CA 的名字发给客户端。自签 CA 叫 `RestyTunnel CA` 这类高度定制名字，等于把家门牌号递给探测者。
* **缓解：CA 名伪装成大众名字。** 签发 CA 时 CN 故意用 `DigiCert Global Root G2`、`Sectigo` 等常见值——`CertificateRequest` 里的 DN 看起来就和银行/企业门户在用的一样（它们也要求客户端证书，属低置信信号）。名字相同不影响链校验：浏览器只验服务端指定的 CA 链，不联网查名。
* **与现有 407 暴露面的精确对比：**

| | 现状（白名单 + 407） | mTLS |
|---|---|---|
| 被动监听 | 不可见 | 不可见 |
| 主动探测者 | 仅**已加白 IP** 上的能摸到 407 | **任何 IP** 的主动握手者都能看到 `CertificateRequest` |
| HTTP 层行为差异 | 407 挑战（对加白 IP） | **零差异**——匿名访客握手照常完成，CONNECT 走伪装回落 |
| TLS 层行为差异 | 零 | 新增 `CertificateRequest`（CA 名可伪装） |

* **决策准则：** mTLS 是把「加白 IP 内的主动探测者可见的 HTTP 407」置换成「全球主动握手者可见的低置信 TLS 信号」。若威胁模型更怕前者（共享 IP 邻居惊扰、需要设备级漫游白名单）→ 开启并伪装 CA 名；若更怕后者（全网高频主动握手探测）→ 维持现状。`optional_no_ca` 保证无论选哪边，匿名访客在 HTTP 层都 100% 无感。

**补充：有没有「原生支持任意代理（首包带密、免 407）」的浏览器？**

有，但都不在 Chromium / Gecko 双寡头里。Chromium 和 Gecko 缺的不是「连 HTTPS 代理」（都能连），而是**「把账密预置进网络栈、首包主动带 `Proxy-Authorization`」**这一个能力：

* **Safari（macOS）——最典型的正面例子。** macOS 系统设置的网络代理里有「安全网页代理（HTTPS）」字段（支持 HTTPS 代理），账密保存进钥匙串后，底层 CFNetwork 会**主动把 `Proxy-Authorization` 放进第一个 CONNECT**，不需要等 407——这正是 Chrome 拒绝做的事，Apple 的网络栈做了。把 RestyTunnel 填进 macOS 系统代理，Safari 即全免 407，**网关侧零改动**（主动式本来就是 Clash/curl 同款既有路径）。
* **GNOME Web / Epiphany（Linux）。** 代理走 GLib 的 `GProxy`，GNOME 系统代理账密存钥匙环（keyring），libsoup 同样首包主动带密。
* **为什么 Chrome / Firefox 刻意不做：** 威胁模型是**防恶意扩展/网站静默借道系统代理凭据**。CFNetwork / GLib 是操作系统级网络栈，凭据由 OS 保管、应用无法编程注入；Chromium/Gecko 的网络栈在浏览器进程内、暴露给扩展 API 面，允许预置账密等于任何拿到 `proxy` 权限的扩展都能静默消耗用户凭据。这是架构位置决定的差异，不是能力差距。
* **Firefox `about:config` 也翻不了身：** Gecko 可调性最强，但没有「代理 Basic 预认证」开关；`browser.proxy` / PAC / 首选项全部只收 host/port/scheme。Gecko 与 Blink 在此决策一致。
* **对 RestyTunnel 的意义：** Safari / Epiphany 用户今天就能零 407 使用，服务端无需任何改动；Chromium / Gecko 路径继续按「白名单定向 407 或 mTLS」处理。

**再进一步：能不能分支（fork）浏览器源代码，自己把预置账密做进去？**

技术上完全可行，这正是唯一能「从根上改掉引擎行为」的路线：

* **Chromium 补丁点很小**：① `net/http/http_auth_cache.cc` —— 正常就有 `HttpAuthCache::Add()`，只是没有代码路径从代理设置调用它；② proxy config 解析处（`--proxy-server=https://user:pass@host` 或扩展配置）—— 让账密**不再被丢弃**，代理选定后预写进 cache。之后 `SelectPreemptiveAuth()` 自然命中，第一个 CONNECT 主动带头，认证状态机一行都不用改。先例：Bromite / Cromite 就是靠几十个自定义补丁长期维护 Chromium 分支的。
* **Firefox 分支同理**：补丁点在 `netwerk/`（`nsHttpAuthCache` 预写），Gecko 构建也轻得多。
* **真实代价不在代码，在运维**：Chrome 每 4 周发安全版本，补丁要持续 rebase、安全补丁不能停；自建版没有 Google API key（无同步/安全浏览实时列表）、无 Widevine、自己签名分发 + 搭更新服务器。
* **性价比账（关键）**：fork 买到的功能只有「免 407、首包带密、无额外进程」。但免 407 + 首包带密，**本地转发器 30 行脚本就能做到**，Safari 原生就有，mTLS 是引擎原生支持——净增量收益只剩「不跑额外进程 + 必须是 Chromium + 不动 TLS 层」这个极窄交集。值得 fork 的只有两种情形：① 你本来就像 Bromite 维护者那样长期维护分支；② 要分发给非技术用户、不能要求装转发器/证书，需要「开箱即用免 407」的定制浏览器。
* **若真做，推荐钉版本而非跟随上游**：fork **CEF / Electron**（内核钉在某个版本，补丁只打网络栈，UI 用 Electron 包），安全更新走 cherry-pick 必要 CVE 的 backport，运维量比全量 Chrome 分支低一个数量级。

#### 🏆 协议层最终推荐方案

**核心判断：现有协议骨架（白名单定向 407 + `Proxy-Authorization` 主动式 + 伪装回落）已是理论最优，不需要动。所有新能力（mTLS、秘密头、fork）一律作为旁路插入现有鉴权链，不做替换。**

理由三条：

1. 407 的暴露面已被压到「仅已加白 IP 的主动探测者」（本节遗漏 1）——为此引入新的 TLS 层指纹（`CertificateRequest`）未必是净赚，所以 mTLS 做**可选开关**而非默认
2. 所有免 407 的浏览器路径都有现成出口（Safari 原生 / mTLS / 本地转发器 / fork），服务端全部天然兼容
3. 探测者能看到的行为永远只有「普通网站」或「400/405」，协议层面不存在可区分信号——这正是当前设计的目标态

**分三层落地：**

| 层级 | 内容 | 改动量 |
|---|---|---|
| **保持不变** | 白名单定向 407、错密静默回落、H2 外壳 + 内部 1.1 降维、UDS 零拷贝 | 0 |
| **推荐新增（可选开关）** | mTLS 旁路：`ssl_verify_client optional_no_ca` + Lua 指纹白名单 + **账密双因子**；证书分支无视 IP 白名单 | 约半天 |
| **明确不做** | 给特定网页加头（泄漏 + 网关看不见）、CDP 注头（调试器行为）、fork 浏览器（运维远超收益） | — |

**mTLS 旁路的三个硬性规范：**

1. **必须双因子**：证书 SUCCESS + 指纹在允许列表 + 密码正确，三者全过才放行——单因子证书一旦泄漏即全网可连，双因子后泄漏证书无害、泄漏密码也无害
2. **CA 名必须伪装**：签发脚本 `-subj` 用 `DigiCert Global Root G2` 等大众名，禁止出现 `RestyTunnel CA` 字样
3. **指纹必须可吊销**：指纹列表走环境变量（`RT_MTLS_CLIENT_FINGERPRINTS`，逗号分隔）或管理面板，设备丢失立即移除

**鉴权链最终形态（伪代码）：**

```lua
-- ① mTLS 旁路（可选，env 未配置则整段跳过，行为与现状 100% 一致）
if mtls_enabled
   and ngx.var.ssl_client_verify == "SUCCESS"
   and fingerprint_in_allowlist(ngx.var.ssl_client_fingerprint)
   and proxy_auth == expected_auth then
    return ngx.exec("@native_tunnel")          -- 证书+指纹+密码三因子，无视 IP 白名单
end

-- ② 现有白名单逻辑（不变）：加白 IP 才定向 407，未加白直接伪装
-- ③ 现有密码校验（不变）：主动式带密直接 200，错密静默回落
```

**环境变量开关（向后兼容）：** `RT_MTLS_CLIENT_CA` 不设置 → 功能完全关闭，现有部署零影响；设置后鉴权链按上面 ①②③ 顺序走。老用户不迁移、新用户按需开启，协议本身永远不变。

**追问：ISO / 互联网协议标准是怎么规定的？自己做个 App 能实现吗？**

**标准根本不强制 407 流程。** 相关 RFC 只有四个，且都只定义「报文格式」，把「客户端何时发凭证」完全留给实现：

| RFC | 内容 | 关键点 |
|---|---|---|
| RFC 9110 §11（原 7235） | HTTP 认证框架（407、`Proxy-Authorization`/`Proxy-Authenticate`） | 定义了 407 这个**机制**，没说客户端必须等挑战 |
| RFC 7617 §2.2（Basic） | Basic 方案 | 原文明文允许：凭据确立后客户端 **MAY 预先发送**（preemptive）——主动式首包带密完全合规 |
| RFC 9110 §9.3.6 | `CONNECT` 方法 | 定义隧道建立，只字未提「必须先 407」 |
| RFC 8446（TLS 1.3） | 客户端证书 | `CertificateRequest` 服务器发起，客户端出示 |

因此再次确认：Chrome 的「冷启动盲发→等 407」是产品策略不是 RFC 要求；主动式首包带 `Proxy-Authorization` 是标准明文许可。ISO/OSI 没有管到 HTTP 应用层认证，互联网权威就是 IETF RFC。

**自研 App：不受任何浏览器产品策略约束，是所有客户端形态里最自由的。**

```text
TLS 握手（可选：同时出示客户端证书 → mTLS）
  ↓
CONNECT target:443 HTTP/1.1
Proxy-Authorization: Basic xxx    ← 首包带密（RFC 7617 允许），零 407
X-Resty-Gate: <自定义令牌>         ← 任意自定义头，§3.4 的门禁 App 一行代码实现
  ↓
RestyTunnel 三因子齐全 → 直接 200 Connection Established
```

App 拥有浏览器/扩展/插件全部做不到的自由度：① 首包带密零 407；② CONNECT 上加任意自定义头（秘密标头门禁）；③ mTLS 客户端证书（BoringSSL/mbedTLS/OkHttp 全支持，证书直接打进 App）；④ 证书+密码+令牌任意组合多因子；⑤ **iOS 上反成最优路径**——App 自己出网完全绕开系统代理 HTTP-only 死结（Shadowrocket/Stash 即此形态）。服务端零改动：现有代码对带合法凭证的 CONNECT 本就直接放行。

代价只剩 App 常规成本：开发、签名分发、更新、移动端保活——不存在任何协议障碍。

#### 🏁 定稿：双模式鉴权链 + 错密黑名单（已实现）

经多轮推演拍板的最终鉴权链（mTLS 方案暂不启用，作为未来可选旁路保留在上方分析中）。核心变化两处：**① 正确密码本身即通行证，无视白名单（主动式客户端换网络零 TOTP 漫游）；② 错密计数达阈值拉黑 24h（防爆破减速带）**。

```text
CONNECT 进来
  ① 携带凭证且密码正确 → 直接建隧道（不看白名单、不看黑名单）
       —— curl / Clash / Safari 首包带密即通；浏览器同会话预认证同此路径
  ② 携带凭证但密码错误 → 错密计数（按真实 TCP 源 IP，不采信 XFF）
       → 达阈值（默认 5 次）→ 拉黑 24h（shared dict，TTL 自动过期）
       → 回落伪装
  ③ 无凭证：
       a. IP 在黑名单内 → 回落（黑名单只拦无凭证/错密）
       b. IP 已加白 → 定向 407（浏览器 onAuthRequired 填密的唯一触发口）
       c. IP 未加白 → 静默回落（绝不 407、不计数、不入黑名单）
```

**方案 3 关键语义：黑名单内「正确密码照常放行」。** 理由：20 位随机密码被 5 次/天 的爆破命中的概率是天文数字级的零，「猜中但被黑名单拦住」的场景几乎不存在；而「密码正确也被拦」会带来共享 IP 连坐问题（邻居错密把你的 IP 拉黑、你拿着正确密码也被拦），迫使引入复杂的解除机制。改为「密码即身份」后：合法用户永不被连坐、解除机制整个不需要（保留 TOTP 加白时顺手清除黑名单记录作为 B 兜底）、邻居爆破速率被锁死在 N 次/24h 且你不干预就是 0。

**浏览器全生命周期流程（Chrome + ZeroOmega 为例）：**

| 场景 | 流程 | 需要人工吗 |
|---|---|---|
| 首次使用 / 换新网络后冷启动 | 盲发 → 未加白 → 回落 → 管理界面 TOTP 加白 → 407 → 自动填密 → 通 | ✅ TOTP 一次 |
| 同会话内切基站 / 换网络 | TCP 断了自动重连，`HttpAuthCache` 凭据还在 → 首包带密 → ① 直接通 | ❌ 零介入 |
| 浏览器重启（IP 白名单 TTL 内） | 盲发 → 已加白 → 407 → 自动填密 → 通 | ❌ 无感 |
| 白名单 7 天过期 | 回到首次使用流程 | ✅ TOTP 重新授权 |
| 自己/邻居错密把 IP 拉黑 | 你的正确密码照常过（①）；仅无凭证的浏览器路径需等 24h 或 TOTP 加白清除 | ❌（对持密用户） |

**防探测与防爆破的双重闭环：**

* **防探测**：407 依然只对已加白 IP 回——扫描器/未加白 IP 永远只能看到伪装回落，与旧版行为 100% 一致
* **防爆破**：错密反馈始终是伪装回落（无渐进信号）；每 IP 每 24h 只有 N 次尝试机会；即使碰巧猜中，隧道建立的成功信号也无法与「正常代理用户」区分——爆破在数学上不可行（前提：强密码）

**配置开关（向后兼容）：** `RT_BLACKLIST_ENABLED=false` 时黑名单整段关闭，行为退回纯双模式；`RT_BLACKLIST_THRESHOLD` / `RT_BLACKLIST_TTL_HOURS` 可调。详见 `environment_variables.md` §2.1。实现落点：`nginx/lua/blacklist.lua`（新模块）+ `gateway.conf`（鉴权链重排）+ `whitelist.lua`（加白清黑名单兜底）+ `nginx.conf.template`（`blacklist_dict` 共享字典）。

---

## 👥 四、 共享 IP (局域网/基站) 穿透与防密码爆破博弈技术

在复杂的宽带网络环境中，用户往往与成百上千个第三方设备共享同一个公网出口 IP（如：大型办公室的出口、咖啡厅 Wi-Fi、移动基站下的 4G/5G 蜂窝网络）。

### 🚨 1. 为什么平时测试可以不开启白名单，但正常使用时“必须”开启 IP 白名单？

为了在安全性与灵活性之间取得完美平衡，RestyTunnel 允许通过 `RT_ENABLE_IP_WHITELIST` 开关来控制是否启用白名单：

#### 🔍 1. 测试时可以不开启白名单的原因（开发、诊断环境）
在初始部署、联调测试或排查客户端（如 Clash、Shadowrocket、SwitchyOmega）连接障碍时，您可以临时将 `RT_ENABLE_IP_WHITELIST` 设置为 `false`。
* **原因**：这可以绕过控制台的 TOTP 授权流程，直接验证“证书是否生效”、“端口是否打通”、“代理密码是否输入正确”。
* **注意**：测试完毕后，应立即开启白名单，避免长时间暴露。

#### 🛡️ 2. 正常使用时“必须”开启白名单的原因（生产、持久环境）
在日常正常运行中，**强烈建议且必须**将 `RT_ENABLE_IP_WHITELIST` 设置为 `true`。其原因在于防范两个最致命的安全漏洞：

1. **防御“未授权外部 IP 扫描”与“主动探测”的终极防火墙**
   * **安全威胁**：公网上有大量探测机、审查防火墙与端口漏洞扫描器（如 Censys、Shodan 以及防火墙主动探测机）。
   * **白名单防御效果**：
     * **若开启白名单（`true`）**：无凭证的浏览器冷启动请求仅对已加白 IP 回 `407`；未加白 IP 的无凭证请求一律静默反代至伪装后端，系统永远不向它们暴露任何 407 挑战或 401 报错，对外界呈现 100% 完美的普通网站行为。携带正确密码的请求则直接建隧道（不看白名单），携带错误密码的请求按源 IP 计数、达阈值拉黑。
     * **若不开启白名单（`false`）**：无凭证请求一律静默回落（绝不 407）；携带正确密码的请求直接建隧道，错密请求同样计数拉黑。

2. **抵御共享 IP (如公共 Wi-Fi、办公室、基站) 穿透与密码爆破阻断**
   * **安全威胁**：当您处于办公室局域网、咖啡厅公共 Wi-Fi 或移动 4G/5G 基站下时，您会与成百上千人共享同一个公网出口 IP。一旦您完成了 TOTP 认证，同一公网出口下的所有恶意邻居设备都会顺理成章地穿透第一层 IP 白名单屏障，直接接触到您的第二关“密码校验层”。
   * **防爆破防御效果**：
     * 如果恶意邻居或探测器在白名单内试图用密码字典强行碰撞爆破您的代理密码：
       在 Lua 校验层中，一旦他们提供的 `Proxy-Authorization` 凭证错误，系统绝对不会向其返回任何“凭证错误 / 401 / 407”等具有明显代理特征的异常，而是**直接、静默地将其反代至伪装后端**。
     * 由于后端网站（如 Cloudreve / Bing）不接受 `CONNECT` 请求，攻击者收到的只有 100% 符合正常网站报错规范的 `HTTP 405 Method Not Allowed`。攻击者在黑暗中完全摸瞎，根本无法判定这个端口到底是一个普通镜像站，还是一个密码错误的代理大门。

---

### 2. “IP 共享穿透”的必然与退化
如果该共享 IP 下的恶意邻居，或者探测器携带密码字典对您的端口发起高频代理密码碰撞：
* **“凭证错误静默反代”防御闭环**：
  在 Lua 校验层中，一旦对齐的 `Proxy-Authorization` 密码不正确（且未达拉黑阈值）：
  ```lua
  -- 错密：计数 + 达阈值拉黑，然后一律静默回落
  blacklist.record_failure(client_ip)
  ngx.exec("@backend")
  return
  ```
  网关绝对不会向其返回“凭证错误 / 401 / 407”等具有明显代理特征的异常信息，而是**直接、静默地在内存中反代至您配置的 `FALLBACK_BACKEND`（如 Bing 首页）**。
* **伪装反馈分析**：
  由于攻击者发起的是 `CONNECT` 代理请求，而被反代的 Bing 等公开站点不接受此类非标 HTTP CONNECT 请求，因此会向攻击者返回标准的 **`HTTP 405 Method Not Allowed`** 或 **`HTTP 400 Bad Request`** 响应。
  这一响应特征与攻击者去尝试用 `CONNECT` 强连全球任何一个普通静态网站（如微软官网、百度）收到的报错 **100% 毫无偏差**。
* **博弈结论**：
  哪怕黑客是在已被加白的共享 IP 内发起高频爆破，他拿到的反馈也仅仅是“正常的静态网站不接受代理方法”这一常规报错；且每 IP 每 24h 仅有 N 次（默认 5 次）尝试机会，达阈值即被拉黑。攻击者在黑暗中完全摸瞎，**根本无法判明该 443 端口后面是一个普通的 Bing 镜像站，还是一个密码错误的代理大门**。这在概率统计学和特征行为学上彻底消灭了密码爆破的可能性。

