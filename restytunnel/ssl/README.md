# RestyTunnel SSL/TLS 证书及安全规范说明

此目录用于存放本地开发自签名或生产环境的 SSL/TLS 证书。

## 目录结构
通常，您应该将以下文件放置在此处：
- `cert.pem` - 公钥证书（以前称为 `fullchain.pem`）
- `key.pem` - 证书私钥（以前称为 `privkey.pem`）
- `ca.pem` - 双向 mTLS 客户端 CA 验证证书

## 常见问题

### 1. 为什么目录和变量仍然叫作 "SSL"？它与 TLS 有什么区别？
*   **历史根源**：SSL（Secure Sockets Layer）是网景公司（Netscape）最早开发的加密协议。后来经过标准化，它被更名为 **TLS（Transport Layer Security，传输层安全）**。
*   **行业惯例**：尽管如今 SSL 协议（包括 SSLv2、SSLv3）由于安全性太差已经被互联网彻底淘汰，现代网络全部在跑 TLS 1.2 或 TLS 1.3，但是由于历史积淀，整个 IT 行业在命名、术语、工具（如 OpenSSL、Nginx 里的 `ssl_certificate` 命令、`ssl/` 文件夹等）依然沿用 "SSL" 这个简称。
*   **总结**：在本项目中，`ssl/` 目录和带有 `SSL_` 前缀的环境变量，在实际运行和数据加密层面 **100% 运行的是最顶级的 TLS 1.3 安全传输协议**，绝非已被淘汰的 SSL。

### 2. 证书的文件名和位置要求
为了简化和统一 `restyguard` 与 `restytunnel` 两个项目的部署心智，本目录下推荐默认使用 `cert.pem` 和 `key.pem`：
*   **公钥证书（PEM 格式）**：默认推荐命名为 `cert.pem`。
*   **证书私钥（PEM 格式）**：默认推荐命名为 `key.pem`。
*   如果您想自定义文件名或存放路径，可以通过修改以下环境变量自由调整：
    *   `RT_SSL_CERT_PATH` (默认值为 `/etc/nginx/ssl/cert.pem`)
    *   `RT_SSL_KEY_PATH` (默认值为 `/etc/nginx/ssl/key.pem`)

## 安全说明
为了防止密钥泄露，生产环境的私钥和证书（如 `*.pem`、`*.key`）**严禁**提交到公共代码仓库。本目录下的真实证书文件已通过 `.gitignore` 自动忽略。
