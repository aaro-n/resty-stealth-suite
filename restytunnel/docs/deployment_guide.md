# RestyTunnel 部署与实操指南

本文档提供 RestyTunnel 系统的快速启动、客户端（Chrome + 开发语言）深度配置、以及容器的日常运维指南。

---

## 🚀 一、 服务端快速启动

### 1. 前提条件
* 准备一台便宜的海外 VPS（推荐使用 Debian 11/12 或 Ubuntu 20.04/22.04/24.04 系统）。
* 一个解析到该服务器公网 IP 的合法域名（若启用 ACME 自动管理）。
* 安装好 Docker 和 Docker Compose。

### 2. 部署 RestyTunnel 容器
1. 将 RestyTunnel 项目文件夹拷贝或克隆至服务器 `/opt/restytunnel` 目录下。
2. 编辑 `docker-compose.yml` 文件，将环境变量和证书选项修改为你自己的配置。
3. **针对 Fly.io (PaaS 平台) 的极速部署指南**：
   如果您希望将 RestyTunnel 部署在 Fly.io 容器平台上，通过 **443 端口原生 TLS 盲传直通**（不经过 Fly.io 的 TLS 卸载来保持极真底层 TLS指纹）来获得超高性能和完美伪装，您可以使用项目配套的 `fly.toml` 文件：
   * 在 `fly.toml` 的 `[env]` 环境变量块中将 **`ENABLE_PROXY_PROTOCOL`** 设为 `"true"`。
   * 为确保四层 TCP 边缘负载均衡能够透传访问者的真实客户端 IP（消灭 `172.16.xx` 局域网回源），在 `fly.toml` 的 **`[[services]]` (TCP)** 块中的 `[[services.ports]]` 下加入：
     ```toml
     handlers = [ "proxy_proto" ]
     ```
   * 接着直接运行 `fly deploy` 即可在不到 1 分钟内完成商用级代理网关的部署。

---

## 🔑 二、 极速一键加白：智能书签（Bookmarklet）配置参考

为了给用户和运维提供极其顺滑、点击即入的“无感级”白名单授权与免密登录体验，本项目设计了**一键智能授权书签**（无需打开 App，浏览器点击书签即可瞬间对当前设备的最新公网 IP 完成安全授权）。

该书签内置了 **Service Worker 物理断路器机制**，会在激活前对当前域下的任何 Service Workers 强行注销。这在代理高复杂度 PWA Web 网盘（如 Cloudreve、AList 等）时，能 100% 杜绝浏览器端发生的 SPA 强拦截死锁！代码内部已完全抹去一切隐私与具体域名，其他人可将下述通用模板作为参考并进行微调：

### 📝 书签 URL 代码：
```javascript
javascript:(function(){var domain="YOUR_AUTH_DOMAIN";var prefix="YOUR_PATH_PREFIX";var token="YOUR_SECRET_TOKEN";var username="YOUR_PROXY_USERNAME";var baseUrl="https://"+domain+"/"+prefix+"/"+token;if('serviceWorker'in navigator){navigator.serviceWorker.getRegistrations().then(function(regs){for(var i=0;i<regs.length;i++){regs[i].unregister();}}).catch(function(){});}if(window.location.href.indexOf(domain)!==-1){if(document.cookie.indexOf("gkp_active=1")!==-1){window.location.reload();}else{var code=prompt("🔑 [RestyTunnel 双重验证]\n\n您的 30 天免密已过期。\n请输入您手机 App (Google Authenticator) 上的 6 位动态验证码：");if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}}else{var code=prompt("🔑 [RestyTunnel 智能免密通道]\n\n若当前已处于 30 天免密期内，可直接不输入并点“确定/回车”直入网页控制台。\n\n新设备请直接输入您手机上的 6 位动态验证码：");if(code===""){window.location.href=baseUrl;}else if(code&&/^\d{6}$/.test(code)){window.location.href=baseUrl+"?u="+username+"&code="+code;}}})();
```

---

## 💻 三、 客户端配置与指纹整形

由于防御指纹探测的一半战场在客户端（应用端），**任何原生的、僵硬的 TLS 握手特征（如 Python requests 默认指纹、Go 原生 http 库等）在公网上发送 `CONNECT` 请求，都极易被直接识别。** 我们必须对客户端实施 TLS 指纹整形。

---

## 🔬 三、 核心技术澄清：代理协议与安全性能

在 RestyTunnel 架构中，关于协议的划分和数据传输安全，有一些极其关键的技术细节需要向您理清：

### 1. 为什么管理端（AUTH_DOMAIN）使用 HTTP/2 & HTTP/3？
* **极速自助授权**：用于 IP 加白、多用户管理和控制台登录的 `AUTH_DOMAIN`，在 Nginx 中完全开启了对 **HTTP/2 (H2)** 和 **HTTP/3 (QUIC/H3)** 的支持。
* **极速体验**：这能保证您在手机或桌面浏览器访问控制台、使用“一键加白智能书签”时，享受到 0-RTT/1-RTT 的极速页面加载与高并发防抖性能。

### 2. 为什么代理端（PROXY_DOMAIN）强制运行于 HTTP/1.1 TLS 1.3 之下？
* **原生核心要求**：因为 Nginx 1.31 核心中内置的 `tunnel_pass`（四层盲转）指令仅支持标准的 HTTP/1.1 文本 CONNECT 指令。如果浏览器在连接代理时与 Nginx 协商了 HTTP/2，Chrome 会发送 H2 CONNECT 数据帧，这超出了 Nginx 原生模块的解析能力，会导致浏览器报错 `ERR_TUNNEL_CONNECTION_FAILED`。
* **安全完全不妥协**：为此，我们在代理服务虚拟主机中强制配置了 `http2 off;` 和 `http3 off;`。
* **为什么绝对安全？**：虽然客户端发送的是 HTTP/1.1 格式的 `CONNECT`，但这个传输动作是发生在 **最外层 TLS 1.3 加密信道** 的内部！公网上的任何深度包检测（DPI）或者网络监视器在抓包时，只能看到 TLS 1.3 标准握手包和标准的二进制乱码。**明文的 `CONNECT` 指令在内网内存中传输，公网完全看不见**，具有顶级的指纹隐蔽性。

---

## 💻 四、 客户端配置与自研开发示例

由于代理运行于极佳的 HTTPS (TLS 1.3) 盲加密隧道下，客户端工具无需强开不支持的 H2，而是使用标准连接即可直接通网。

### 1. 桌面端浏览器配置 (SwitchyOmega)
在 Chrome 中安装 **Proxy SwitchyOmega** 插件并进行如下配置：
1. **代理协议**：必须且只能选择 **`HTTPS`** (⚠️ 绝对不能选择普通的 HTTP)。
2. **代理服务器 (Host)**：填写您的代理域名（如 `your-proxy-domain.com`）。
3. **端口 (Port)**：`443`。
4. 点击右侧的 **“锁”图标**，输入您的代理账号（`RT_PROXY_USERNAME`）和密码（`RT_PROXY_PASSWORD`）并保存。
5. **开启白名单时的无感使用**：一旦您的 IP 已经在控制台加白，浏览器启动时就会在第一包请求中主动携带您的加密账密，一次性通过安全大闸，丝滑通网。

### 2. Python 自研客户端开发 (以 `curl_cffi` 为例)
在 Python 脚本中，普通的 `requests` 默认指纹过于单一。我们强烈推荐使用 **`curl_cffi`**，它在底层使用与 Chrome 一致的 TLS 指纹，同时完美支持 HTTPS 代理：

```python
# File: client.py
# Description: 专属桌面端抗检测高隐蔽代理请求示例

from curl_cffi import requests

# 配置标准的 HTTPS 域名代理及账密
proxies = {
    "https": "https://nyd1tz:w6mghyklx6lz0f2b@your-proxy-domain.com:443",
    "http": "http://nyd1tz:w6mghyklx6lz0f2b@your-proxy-domain.com:443"
}

try:
    print("正在通过 HTTPS TLS 1.3 盲加密隧道进行网络传输...")
    # browser="chrome" 会自动整合 JA3/JA4 握手指纹，防范特征探测
    response = requests.get(
        "https://www.google.com", 
        proxies=proxies, 
        browser="chrome", 
        timeout=10
    )
    print("==========================================================")
    print(" [成功] 代理通信完美跑通！")
    print(f"   - 目标源站返回字节大小: {len(response.text)} 字节")
    print("==========================================================")
except Exception as e:
    print(f" [失败] 连接被阻断或鉴权错误: {e}")
```

### 3. Go 语言自研客户端示例
在 Go 语言中进行安全的 HTTPS 代理开发，只需标准库的 `Transport.Proxy` 即可，底层会自动套在加密 TLS 中发送 CONNECT：

```go
package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"net/url"
)

func main() {
	proxyUrl, _ := url.Parse("https://nyd1tz:w6mghyklx6lz0f2b@your-proxy-domain.com:443")
	
	transport := &http.Transport{
		Proxy: http.ProxyURL(proxyUrl),
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS13, // 强制 TLS 1.3 安全握手
		},
	}
	client := &http.Client{ Transport: transport }

	resp, err := client.Get("https://www.wikipedia.org")
	if err == nil {
		fmt.Println("连接维基百科成功，状态码:", resp.Status)
		resp.Body.Close()
	} else {
		fmt.Println("连接失败:", err)
	}
}
```

---

## 🕵️ 四、 核心追问：客户端会指定 HTTP/1.1 访问这个代理吗？

这是一个极其专业、直戳网络工程命门的核心技术追问。
答案是：**是的，非常高频！大量落后、未经过深度优化、或操作系统默认的代理客户端，在公网上发起 HTTPS 代理请求时，会默认指定并使用 HTTP/1.1！**

### 1. 为什么未优化的客户端默认会走 HTTP/1.1？
* **系统原生局限：** 
  绝大多数操作系统级的代理客户端（如 Windows 系统网络代理设置、macOS 系统网络代理、Linux 命令行中的 `export http_proxy` / `https_proxy` 环境变量），在拨号连接 HTTPS 代理服务器时，其内置的简单 HTTP 引擎根本不支持 HTTP/2 CONNECT（H2 隧道多路复用 RFC 8441）。
* **代码原生局限：**
  如果你写一个普通的 Python 脚本、Go 程序或 Java 程序，并在代码中设置 `proxies = {"https": "https://..."}` 并不加任何修饰：
  * **Python `requests` / `urllib3`：** 它们底层的 SSL 传输模块默认发起 TLS 握手，但在 ALPN 协商中**不会发送 `h2` 标记**。它们在握手完毕后，会在加密隧道里雷打不动地发送 `CONNECT target.com:443 HTTP/1.1`。
  * **Go 原生 `net/http`：** Go 的底层正向代理 `Transport.Proxy` 逻辑中，默认的 CONNECT 拨号器同样倾向于只发送标准的 HTTP/1.1 文本控制头。

### 2. HTTP/1.1 代理握手有什么致命危险？
即使流量套在了 TLS 1.3 壳子里，如果你在公网上使用 HTTP/1.1 跑代理：
1. **ALPN 特征泄露：** 在公网上，你的 TLS 握手 ALPN 协商为 `http/1.1` 或干脆缺失 ALPN，这在全网流量高度 H2/H3 化的今天属于非标特征。
2. **队头阻塞与频繁握手：** Chrome 打开一个网页需要并发向几十个不同 IP 获取图片/脚本。如果你用 1.1，客户端必须向你的代理服务器并发进行几十次独立的 TCP+TLS 握手，每次连接里都发一次 1.1 `CONNECT`。这在网络审计的统计学监测和行为打标里，极易暴露明显的代理特征。

### 3. RestyTunnel 是如何终极解决这个问题的？
在 RestyTunnel 中，我们利用 `FORCE_MODERN_PROTO`（默认为 `proxy` 模式）在服务端筑起了降维反探测防线：
* **如果未优化的落后客户端使用 HTTP/1.1 试图强连代理：**
  由于它使用的是 1.1 协议，这直接触发了我们的 Lua 拦截哨卡。Lua 判定其协议安全强度不足以抵抗现代 DPI 的流量分析和时序检测，**直接在内存里抹掉其代理意图，强行重定向重写为 GET `/index.html`**，把它甩到静态站点页面（返回 200 OK 静态源码）。
  * 结果：这个使用 1.1 协议的代理客户端将完全无法连接，它在接收端看到的将是你的静态站点 HTML。这既保护了你的服务器免受非标 1.1 代理流量的行为学连累，又实现了 100% 的反探测洗白。
* **我们如何强迫客户端在公网走 H2/H3？**
  我们必须对客户端的底层网络引擎进行协议强制协商，使它们在公网上发起连接时**必须、且首选 H2 或 H3**：

---

## 💻 五、 强制客户端强开 H2/H3 代理配置与验证

### 1. 桌面端浏览器（Chrome / SwitchyOmega）原生形态
现代 Chrome 浏览器原生内置了对 **HTTP/2 HTTPS 代理** 的顶级支持！只要通过 SwitchyOmega 插件进行正确配置，Chrome 会自动在公网发起完美的 HTTP/2 代理连接：

1. 在 Chrome 浏览器安装 **Proxy SwitchyOmega** 插件。
2. 新建情景模式（类型：代理服务器），命名为 `RestyTunnel`。
3. **关键配置：**
   * **代理协议：** 必须且只能选择 **`HTTPS`** (⚠️ 绝对不能选择 HTTP)。选择 HTTPS 后，Chrome 在 TLS 握手 ALPN 中会强制向服务器索要 `h2`。
   * **代理服务器：** 填写你的解析域名（如 `your-proxy-domain.com`）。
   * **端口：** `443`
4. 点击右侧的 **“锁”图标（授权认证）**，输入账号密码。
5. **在 Chrome 中实时验证公网协议版本：**
   * 在 Chrome 地址栏输入并打开：`chrome://net-internals/#http2`
   * 在列表中寻找你的代理域名（如 `your-proxy-domain.com`）。
   * 你会清爽地看到：它的 **Protocol** 字段显示为 **`h2`**，并且所有去往外网的请求都复用在这一条 H2 连接下的不同 Stream ID 中。
   * 如果开启了 HTTP/3 (QUIC) 且网络无 QoS 阻断，你可以通过 `chrome://net-internals/#quic` 验证其运行在 **`h3`** (QUIC) 之下。

### 2. Python 专属客户端开发：利用 `curl_cffi` 强制协商 H2
在 Python 脚本中，普通的 `requests` 或 `urllib3` 会默认退回传统的 HTTP/1.1。
我们必须使用 **`curl_cffi`**，它不仅会复制 Chrome 120+ 的 JA3/JA4 握手指纹，还会在底层自动通过 ALPN 强制与服务器建立 **HTTP/2** 盲加密多路复用隧道：

```python
# File: client.py
# Description: 专属桌面端抗检测高隐蔽 HTTPS 代理请求示例

from curl_cffi import requests

# 配置标准的 HTTPS 域名代理及动态账密
proxies = {
    "https": "https://myuser:mypassword@your-proxy-domain.com:443",
    "http": "http://myuser:mypassword@your-proxy-domain.com:443"
}

try:
    print("正在通过 H2/H3 混合自适应加密隧道进行网络传输...")
    # 🎯 browser="chrome" 是防御指纹扫描的生死线！
    # 它在底层通过 C 绑定的 NSS/Nettle 库，完美复制了 Chrome 120+ 的 TLS 指纹并强制启用 HTTP/2
    response = requests.get(
        "https://www.google.com", 
        proxies=proxies, 
        browser="chrome", # 强行整形指纹并强制启用 HTTP/2
        timeout=10
    )
    print("==========================================================")
    print(" [成功] 代理通信完美跑通！")
    print(f"   - 目标源站返回字节大小: {len(response.text)} 字节")
    print("==========================================================")
except Exception as e:
    print(f" [失败] 连接被阻断或鉴权错误: {e}")
```

### 3. Go 语言自研客户端：引入 `NextProtos` 强开 H2 协商
在使用 Go 自研代理工具时，必须在 TLS 配置的 ALPN 参数中明确写入 `"h2"`，否则 Go 默认会使用 HTTP/1.1 发送 `CONNECT`：

```go
package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"net/url"
)

func main() {
	proxyUrl, _ := url.Parse("https://myuser:mypassword@your-proxy-domain.com:443")
	
	// 🎯 极限防探测：必须显式地在 ALPN 中加入 "h2"，强迫客户端与 Nginx 进行 HTTP/2 握手
	config := &tls.Config{
		NextProtos: []string{"h2", "http/1.1"}, // 优先强制协商 HTTP/2
	}
	
	transport := &http.Transport{
		Proxy:           http.ProxyURL(proxyUrl),
		TLSClientConfig: config,
	}
	client := &http.Client{ Transport: transport }

	resp, err := client.Get("https://www.wikipedia.org")
	if err == nil {
		fmt.Println("连接维基百科成功，状态码:", resp.Status)
	}
}
```

---

## ⚙️ 六、 容器维护与管理

### 1. 查看容器日志与运行状态
你可以实时观察 Nginx 1.31 核心状态行为：
```bash
docker logs -f restytunnel-proxy
```

### 2. 手动替换证书
如果你不想启用自签名开发证书，想手动使用自己申请的受信任正规证书：
1. 确保 `docker-compose.yml` 中的 `ENABLE_ACME` 设为 `false`。
2. 将你申请到的证书公钥命名为 `fullchain.pem`，私钥命名为 `privkey.pem`。
3. 拷贝并覆写到项目本地的 `./ssl/` 目录下：
   ```bash
   cp my_cert.crt ./ssl/fullchain.pem
   cp my_key.key ./ssl/privkey.pem
   ```
4. 手动平滑重载 Nginx 容器（或者容器内的 Nginx 进程执行 `openresty -s reload`）：
   ```bash
   docker-compose restart restytunnel
   ```

### 3. 自定义替换你的伪装博客网页
我们随项目赠送了一个高可信度的技术博客前端单页。如果你想让它更有生活气息：
1. 用任何静态 HTML 模板框架（如 Hexo, Hugo）生成一个饱满的、多图片、多子页面的静态个人主页。
2. 将生成出的静态网页所有内容放入项目本地的 `./html/` 文件夹下。
3. 容器检测到挂载变更后，无需重启，任何上门探测的盲扫流量在第一微秒就会由原生 `rewrite` 自动呈现全新的伪装网页。
