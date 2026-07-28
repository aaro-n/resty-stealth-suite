# TLS 证书

此目录包含 TLS 证书文件。

## 安全警告

**切勿将生产环境的私钥（key.pem）提交到公共版本控制仓库！**
如果您使用的是公共 Git 仓库，建议通过 Fly.io 的 Secrets 功能将私钥挂载，或仅在私有 Git 仓库中进行同步。

## 证书文件命名规则 (Cloudflare 支持)

当您在 **Cloudflare (CF)** 中使用本网关时，建议使用 **CF Origin Certificate (15年自签证书)** 与 **mTLS 客户端证书** 结合实现最高安全级别的双向校验。

请直接将以下三个文件放入此目录（容器启动脚本会自动检测并无缝加载它们，不再生成保底证书）：

1. **`cert.pem`** (服务端证书)
   * **内容**：Cloudflare 申请的 15 年 Origin Certificate (PEM 格式)
2. **`key.pem`** (服务端私钥)
   * **内容**：申请上述 15 年证书时生成的 Private Key (PEM 格式)
3. **`ca.pem`** (客户端 CA 证书)
   * **内容**：Cloudflare 提供的 mTLS CA 根证书，或您自定义生成的**区域级/主机名专属级**私有 CA 根证书。用于校验连接本网关的客户端证书合法性（如开启 CF Authenticated Origin Pulls 场景，对应锁死 auth.yourdomain.com）。

## 开发环境

运行 `scripts/generate-dev-certs.sh` 重新生成开发用自签名证书。

## 生产环境

请使用受信任的 CA 签发的证书替换这些文件。
