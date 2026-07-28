#!/bin/sh
# File: scripts/generate-dev-certs.sh
# Description: 生成开发/测试用的自签名 TLS 证书。
# 生产环境请使用受信任的 CA 签发的证书。

set -e

CERT_DIR="/app/certs"
mkdir -p "$CERT_DIR"

echo "=> 正在生成开发用自签名证书..."

# 生成 CA 密钥和证书
openssl genrsa -out "${CERT_DIR}/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" \
    -sha256 -days 3650 \
    -subj "/C=CN/O=RestyGuard-Dev-CA/CN=RestyGuard Dev CA" \
    -out "${CERT_DIR}/ca.pem" 2>/dev/null

# 生成服务器密钥
openssl genrsa -out "${CERT_DIR}/key.pem" 2048 2>/dev/null

# 生成服务器证书签名请求
openssl req -new -key "${CERT_DIR}/key.pem" \
    -subj "/C=CN/O=RestyGuard-Dev/CN=localhost" \
    -out "${CERT_DIR}/cert.csr" 2>/dev/null

# 使用 CA 签名服务器证书
openssl x509 -req -in "${CERT_DIR}/cert.csr" \
    -CA "${CERT_DIR}/ca.pem" -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial -out "${CERT_DIR}/cert.pem" \
    -days 365 -sha256 2>/dev/null

# 清理临时文件
rm -f "${CERT_DIR}/ca.key" "${CERT_DIR}/cert.csr" "${CERT_DIR}/ca.srl"

echo "=> 证书生成完成！"
echo "   - ${CERT_DIR}/ca.pem"
echo "   - ${CERT_DIR}/cert.pem"
echo "   - ${CERT_DIR}/key.pem"
echo ""
echo "注意：这些是自签名证书，仅用于开发/测试。"
