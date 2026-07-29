#!/bin/sh
# File: scripts/bootstrap.sh
# Description: RestyTunnel 统一启动配置与引导服务脚本 (模块化 Shell 函数设计)
# 支持在 Docker 容器或本地 Host 开发环境中一键完成：变量初始化、环境审查、证书加载及配置动态编译。

set -e

# ANSI 颜色输出支持 (本地运行时带颜色，容器日志保持清洁)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ========================================================
# 1. 变量初始化函数 (Set Default Environment Variables)
# ========================================================
set_defaults() {
    echo "=> [1/4] 正在加载并校验默认环境变量配置..."

    # 1. 代理基础核心配置
    export RT_PROXY_DOMAIN="${RT_PROXY_DOMAIN:-${PROXY_DOMAIN:-localhost}}"
    export PROXY_DOMAIN="$RT_PROXY_DOMAIN"

    export RT_PROXY_USERNAME="${RT_PROXY_USERNAME:-${PROXY_USERNAME:-myuser}}"
    export PROXY_USERNAME="$RT_PROXY_USERNAME"

    export RT_PROXY_PASSWORD="${RT_PROXY_PASSWORD:-${PROXY_PASSWORD:-mypassword}}"
    export PROXY_PASSWORD="$RT_PROXY_PASSWORD"

    export RT_FALLBACK_BACKEND="${RT_FALLBACK_BACKEND:-${FALLBACK_BACKEND:-https://cn.bing.com}}"
    export FALLBACK_BACKEND="$RT_FALLBACK_BACKEND"

    export RT_NGINX_PORT="${RT_NGINX_PORT:-${NGINX_PORT:-443}}"
    export NGINX_PORT="$RT_NGINX_PORT"

    # 2. IP 来源白名单与授权子端点环境变量
    export RT_ENABLE_IP_WHITELIST="${RT_ENABLE_IP_WHITELIST:-${ENABLE_IP_WHITELIST:-false}}"
    export ENABLE_IP_WHITELIST="$RT_ENABLE_IP_WHITELIST"

    export RT_AUTH_DOMAIN="${RT_AUTH_DOMAIN:-${AUTH_DOMAIN:-auth.localhost}}"
    export AUTH_DOMAIN="$RT_AUTH_DOMAIN"

    export RT_AUTH_PATH_PREFIX="${RT_AUTH_PATH_PREFIX:-${AUTH_PATH_PREFIX:-auth}}"
    export AUTH_PATH_PREFIX="$RT_AUTH_PATH_PREFIX"

    export RT_SECRET_TOKEN="${RT_SECRET_TOKEN:-${SECRET_TOKEN:-mysecrettoken123}}"
    export SECRET_TOKEN="$RT_SECRET_TOKEN"
    
    # 🎯 引入 TTL_DAYS (默认 7 天) 并自动转换为秒级
    export RT_WHITELIST_IP_TTL_DAYS="${RT_WHITELIST_IP_TTL_DAYS:-${WHITELIST_IP_TTL_DAYS:-7}}"
    export WHITELIST_IP_TTL_DAYS="$RT_WHITELIST_IP_TTL_DAYS"

    export RT_WHITELIST_IP_TTL_SECONDS="${RT_WHITELIST_IP_TTL_SECONDS:-${WHITELIST_IP_TTL_SECONDS:-$((RT_WHITELIST_IP_TTL_DAYS * 86400))}}"
    export WHITELIST_IP_TTL_SECONDS="$RT_WHITELIST_IP_TTL_SECONDS"

    # 新增以 RestyGuard 为蓝本的多用户和 TOTP 安全配置
    export RT_USERS="${RT_USERS:-${PROXY_USERNAME}:${PROXY_PASSWORD}}"
    export RT_SESSION_TTL_SECONDS="${RT_SESSION_TTL_SECONDS:-2592000}"
    export RT_TOTP_VALID_WINDOW_SECONDS="${RT_TOTP_VALID_WINDOW_SECONDS:-300}"

    # 后台守护进程定时清理任务周期
    export RT_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS="${RT_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS:-${TASK_CLEAN_WHITELIST_INTERVAL_SECONDS:-3600}}"
    export TASK_CLEAN_WHITELIST_INTERVAL_SECONDS="$RT_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS"

    export RT_TASK_CLEAN_LOG_INTERVAL_SECONDS="${RT_TASK_CLEAN_LOG_INTERVAL_SECONDS:-${TASK_CLEAN_LOG_INTERVAL_SECONDS:-60}}"
    export TASK_CLEAN_LOG_INTERVAL_SECONDS="$RT_TASK_CLEAN_LOG_INTERVAL_SECONDS"

    export RT_TASK_CLEAN_LOG_RETAIN_LINES="${RT_TASK_CLEAN_LOG_RETAIN_LINES:-${TASK_CLEAN_LOG_RETAIN_LINES:-30}}"
    export TASK_CLEAN_LOG_RETAIN_LINES="$RT_TASK_CLEAN_LOG_RETAIN_LINES"

    # 可见性安全开关与时区
    export RT_ENABLE_VIEW_WHITELIST="${RT_ENABLE_VIEW_WHITELIST:-${ENABLE_VIEW_WHITELIST:-true}}"
    export ENABLE_VIEW_WHITELIST="$RT_ENABLE_VIEW_WHITELIST"

    export RT_ENABLE_VIEW_BLACKLIST="${RT_ENABLE_VIEW_BLACKLIST:-${ENABLE_VIEW_BLACKLIST:-true}}"
    export ENABLE_VIEW_BLACKLIST="$RT_ENABLE_VIEW_BLACKLIST"

    export RT_TZ="${RT_TZ:-${TZ:-Asia/Shanghai}}"
    export TZ="$RT_TZ"
    
    # 🎯 [高弹性调优] 白/黑名单物理文件路径及环境变量控制
    export RT_WHITELIST_DB_PATH="${RT_WHITELIST_DB_PATH:-${WHITELIST_DB_PATH:-/dev/shm/whitelist.db}}"
    export WHITELIST_DB_PATH="$RT_WHITELIST_DB_PATH"

    export RT_REJECTED_LOG_PATH="${RT_REJECTED_LOG_PATH:-${REJECTED_LOG_PATH:-/dev/shm/rejected_ips.log}}"
    export REJECTED_LOG_PATH="$RT_REJECTED_LOG_PATH"

    # 高级定制：通用真实 IP 获取与自定义 mTLS
    export RT_ENABLE_PROXY_PROTOCOL="${RT_ENABLE_PROXY_PROTOCOL:-${ENABLE_PROXY_PROTOCOL:-false}}"
    export ENABLE_PROXY_PROTOCOL="$RT_ENABLE_PROXY_PROTOCOL"

    export RT_REAL_IP_HEADER="${RT_REAL_IP_HEADER:-${REAL_IP_HEADER:-CF-Connecting-IP}}"
    export REAL_IP_HEADER="$RT_REAL_IP_HEADER"

    export RT_REAL_IP_FROM="${RT_REAL_IP_FROM:-${REAL_IP_FROM}}"
    export REAL_IP_FROM="$RT_REAL_IP_FROM"

    export RT_ENABLE_CUSTOM_MTLS="${RT_ENABLE_CUSTOM_MTLS:-${ENABLE_CUSTOM_MTLS:-false}}"
    export ENABLE_CUSTOM_MTLS="$RT_ENABLE_CUSTOM_MTLS"

    export RT_CLIENT_CA_CERT_PATH="${RT_CLIENT_CA_CERT_PATH:-${CLIENT_CA_CERT_PATH:-/etc/nginx/ssl/ca.pem}}"
    export CLIENT_CA_CERT_PATH="$RT_CLIENT_CA_CERT_PATH"

    # 日志级别、速率限制与日志开关
    export RT_NGINX_LOG_LEVEL="${RT_NGINX_LOG_LEVEL:-${NGINX_LOG_LEVEL:-notice}}"
    export NGINX_LOG_LEVEL="$RT_NGINX_LOG_LEVEL"

    export RT_AUTH_RATE_LIMIT="${RT_AUTH_RATE_LIMIT:-${AUTH_RATE_LIMIT:-5r/m}}"
    export AUTH_RATE_LIMIT="$RT_AUTH_RATE_LIMIT"

    export RT_DISABLE_REJECT_LOG="${RT_DISABLE_REJECT_LOG:-${DISABLE_REJECT_LOG:-false}}"
    export DISABLE_REJECT_LOG="$RT_DISABLE_REJECT_LOG"

    export RT_DNS_RESOLVER="${RT_DNS_RESOLVER:-${DNS_RESOLVER:-1.1.1.1 8.8.8.8 ipv6=off}}"
    export DNS_RESOLVER="$RT_DNS_RESOLVER"

    # 自动从 RT_FALLBACK_BACKEND 提取出高兼容的主机域名，用于反代 Host 和 SNI 头
    export FALLBACK_HOST=$(echo "$RT_FALLBACK_BACKEND" | sed -e 's|^[^/]*//||' -e 's|/.*||' -e 's|:.*||')
    export FALLBACK_HOST="${FALLBACK_HOST:-127.0.0.1}"

    # 🎯 [高级域名隔离回落分拆] 支持主代理域名和授权管理域名配置不同的 Fallback 回落后端，并做自适应降级兜底
    export RT_PROXY_FALLBACK_BACKEND="${RT_PROXY_FALLBACK_BACKEND:-${PROXY_FALLBACK_BACKEND:-$RT_FALLBACK_BACKEND}}"
    export PROXY_FALLBACK_BACKEND="$RT_PROXY_FALLBACK_BACKEND"
    export PROXY_FALLBACK_HOST=$(echo "$RT_PROXY_FALLBACK_BACKEND" | sed -e 's|^[^/]*//||' -e 's|/.*||' -e 's|:.*||')
    export PROXY_FALLBACK_HOST="${PROXY_FALLBACK_HOST:-127.0.0.1}"

    export RT_AUTH_FALLBACK_BACKEND="${RT_AUTH_FALLBACK_BACKEND:-${AUTH_FALLBACK_BACKEND:-$RT_FALLBACK_BACKEND}}"
    export AUTH_FALLBACK_BACKEND="$RT_AUTH_FALLBACK_BACKEND"
    export AUTH_FALLBACK_HOST=$(echo "$RT_AUTH_FALLBACK_BACKEND" | sed -e 's|^[^/]*//||' -e 's|/.*||' -e 's|:.*||')
    export AUTH_FALLBACK_HOST="${AUTH_FALLBACK_HOST:-127.0.0.1}"

    # 动态注入证书
    export RT_SSL_CERT_BASE64="${RT_SSL_CERT_BASE64:-${SSL_CERT_BASE64}}"
    export SSL_CERT_BASE64="$RT_SSL_CERT_BASE64"
    export RT_SSL_KEY_BASE64="${RT_SSL_KEY_BASE64:-${SSL_KEY_BASE64}}"
    export SSL_KEY_BASE64="$RT_SSL_KEY_BASE64"
    
    # 🎯 [证书配置统一设计] 支持自定义路径及文件名，并提供默认值
    export RT_SSL_CERT_PATH="${RT_SSL_CERT_PATH:-${SSL_CERT_PATH:-/etc/nginx/ssl/cert.pem}}"
    export SSL_CERT_PATH="$RT_SSL_CERT_PATH"
    export RT_SSL_KEY_PATH="${RT_SSL_KEY_PATH:-${SSL_KEY_PATH:-/etc/nginx/ssl/key.pem}}"
    export SSL_KEY_PATH="$RT_SSL_KEY_PATH"

    echo "   - 默认环境变量设置成功。"
}

# ========================================================
# 2. 状态打印监控函数 (Print Environment Summary)
# ========================================================
print_env_summary() {
    # 辅助安全半脱敏透露函数：根据字符串实际长度智能透露前 2 位和后 2 位，中间隐藏
    reveal_secure_val() {
        local val="$1"
        local len=${#val}
        if [ "$len" -le 4 ]; then
            echo "[长度为 ${len} 位的短密文：已全隐]"
        else
            local head=$(echo "$val" | cut -c 1-2)
            local tail=$(echo "$val" | cut -c $((len - 1))-$len)
            echo "${head}***${tail} [长度为 ${len} 位]"
        fi
    }

    echo "=> [2/4] 正在加载打印环境状态监控参数..."
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}          RestyTunnel 运行环境变量配置参数                 ${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo "   - 代理业务域名 [RT_PROXY_DOMAIN]:     ${RT_PROXY_DOMAIN}"
    echo "   - 默认代理账号 [RT_PROXY_USERNAME]:   ${RT_PROXY_USERNAME}"
    echo -n "   - 默认代理密码 [RT_PROXY_PASSWORD]:   "
    reveal_secure_val "$RT_PROXY_PASSWORD"
    echo "   - 容器服务端口 [RT_NGINX_PORT]:       ${RT_NGINX_PORT}"
    echo "   - 降维回落后端 [RT_FALLBACK_BACKEND]:    ${RT_FALLBACK_BACKEND}"
    echo "   - 代理专属回落 [RT_PROXY_FALLBACK_BACKEND]: ${RT_PROXY_FALLBACK_BACKEND}"
    echo "   - 授权专属回落 [RT_AUTH_FALLBACK_BACKEND]:  ${RT_AUTH_FALLBACK_BACKEND}"
    echo "   - 运行容器时区 [RT_TZ]:               ${RT_TZ}"
    echo "   - Nginx 日志级别 [RT_NGINX_LOG_LEVEL]:    ${RT_NGINX_LOG_LEVEL}"
    echo "   - 开启白名单 [RT_ENABLE_IP_WHITELIST]: ${RT_ENABLE_IP_WHITELIST}"
    if [ "$RT_ENABLE_IP_WHITELIST" = "true" ]; then
    echo "   - 授权管理域名 [RT_AUTH_DOMAIN]:      ${RT_AUTH_DOMAIN}"
    echo "   - 授权管理路径 [RT_AUTH_PATH_PREFIX]: /${RT_AUTH_PATH_PREFIX}"
    echo -n "   - 授权安全密令 [RT_SECRET_TOKEN]:     "
    reveal_secure_val "$RT_SECRET_TOKEN"
    echo "   - 授权天数 TTL [RT_WHITELIST_IP_TTL_DAYS]: ${RT_WHITELIST_IP_TTL_DAYS} 天"
    echo "   - 授权秒数 TTL [RT_WHITELIST_IP_TTL_SECONDS]: ${RT_WHITELIST_IP_TTL_SECONDS} 秒"
    echo "   - 多用户/TOTP 配置 [RT_USERS]:        $(reveal_secure_val "$RT_USERS")"
    echo "   - 拦截日志最大行数 [RT_TASK_CLEAN_LOG_RETAIN_LINES]: ${RT_TASK_CLEAN_LOG_RETAIN_LINES} 行"
    echo "   - 允许网页查看白名单 [RT_ENABLE_VIEW_WHITELIST]: ${RT_ENABLE_VIEW_WHITELIST}"
    echo "   - 允许网页查看拦截日志 [RT_ENABLE_VIEW_BLACKLIST]: ${RT_ENABLE_VIEW_BLACKLIST}"
    echo "   - 防爆速率限制 [RT_AUTH_RATE_LIMIT]:   ${RT_AUTH_RATE_LIMIT}"
    echo "   - 禁用拒绝日志 [RT_DISABLE_REJECT_LOG]: ${RT_DISABLE_REJECT_LOG}"
    fi
    echo "   - HTTPS证书路径 [RT_SSL_CERT_PATH]: ${RT_SSL_CERT_PATH}"
    echo "   - HTTPS密钥路径 [RT_SSL_KEY_PATH]: ${RT_SSL_KEY_PATH}"
    echo "   - 真实IP来源头 [RT_REAL_IP_HEADER]:    ${RT_REAL_IP_HEADER}"
    echo "   - 白名单物理路径 [RT_WHITELIST_DB_PATH]: ${RT_WHITELIST_DB_PATH}"
    echo "   - 黑名单物理路径 [RT_REJECTED_LOG_PATH]: ${RT_REJECTED_LOG_PATH}"
    echo "   - 启用 PROXY 协议 [RT_ENABLE_PROXY_PROTOCOL]: ${RT_ENABLE_PROXY_PROTOCOL}"
    echo "   - 信任代理地址 [RT_REAL_IP_FROM]:      ${RT_REAL_IP_FROM:-[默认信任CF]}"
    echo "   - 开启自定义mTLS [RT_ENABLE_CUSTOM_MTLS]: ${RT_ENABLE_CUSTOM_MTLS}"
    if [ "$RT_ENABLE_CUSTOM_MTLS" = "true" ]; then
    echo "   - 自定义CA路径 [RT_CLIENT_CA_CERT_PATH]: ${RT_CLIENT_CA_CERT_PATH}"
    fi
    echo -e "${BLUE}==========================================================${NC}"

    # 🚀 [双域名极速直连一键加白与 HTTP 代理配置整合链接生成器]
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}             RestyTunnel 极速直连与一键加白指南            ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    
    # 场景 A: 开启了 IP 白名单防火墙
    if [ "$RT_ENABLE_IP_WHITELIST" = "true" ]; then
        # 1. 自动加白直连管理链接 ( u=用户名 & p=密码 模式)
        echo -e "   👉 ${YELLOW}[一键自动加白网页控制台主链接]${NC}"
        echo -e "      https://${RT_AUTH_DOMAIN}/${RT_AUTH_PATH_PREFIX}/${RT_SECRET_TOKEN}?u=${RT_PROXY_USERNAME}&p=${RT_PROXY_PASSWORD}"
        echo ""
        echo -e "   👉 ${YELLOW}[新设备/动态密码 TOTP 登录链接]${NC} (若配置了 TOTP 种子)"
        echo -e "      https://${RT_AUTH_DOMAIN}/${RT_AUTH_PATH_PREFIX}/${RT_SECRET_TOKEN}?u=${RT_PROXY_USERNAME}&code=[您的6位手机动态验证码]"
        echo ""
        echo -e "   👉 ${YELLOW}[已授权设备的 30天 免密访问主链接]${NC}"
        echo -e "      https://${RT_AUTH_DOMAIN}/${RT_AUTH_PATH_PREFIX}/${RT_SECRET_TOKEN}"
        echo ""
    else
        # 场景 B: 未开启 IP 白名单防火墙
        echo -e "   🔓 ${YELLOW}当前未开启 IP 白名单限制，任何人都可以凭代理账密直接连接。${NC}"
        echo ""
    fi

    # 2. HTTP 代理服务器配置说明
    echo -e "   👉 ${YELLOW}[HTTPS 正向代理配置参考 (小火箭/SwitchyOmega/Shadowrocket)]${NC}"
    echo -e "      - 代理服务器 (Host): ${RT_PROXY_DOMAIN}"
    echo -e "      - 代理端口 (Port):   443"
    echo -e "      - 认证用户名 (User):  ${RT_PROXY_USERNAME}"
    echo -e "      - 认证密码 (Pass):    ${RT_PROXY_PASSWORD}"
    echo -e "${GREEN}==========================================================${NC}"
    echo ""
}

# ========================================================
# 3. 证书与动态配置生成函数 (Setup & Generation)
# ========================================================
setup_configurations() {
    echo "=> [3/4] 正在检查证书与生成动态配置..."
    
    # --- 3a. SSL 证书自签名保底 ---
    KEY_PATH="${RT_SSL_KEY_PATH}"
    CERT_PATH="${RT_SSL_CERT_PATH}"
    
    local cert_dir_parent=$(dirname "$CERT_PATH")
    local key_dir_parent=$(dirname "$KEY_PATH")
    mkdir -p "$cert_dir_parent" "$key_dir_parent"

    if [ -n "$SSL_CERT_BASE64" ] && [ -n "$SSL_KEY_BASE64" ]; then
        echo "   - [证书模块] 检测到 Base64 证书，正在解码..."
        echo "$SSL_CERT_BASE64" | base64 -d > "$CERT_PATH" 2>/dev/null || true
        echo "$SSL_KEY_BASE64" | base64 -d > "$KEY_PATH" 2>/dev/null || true
    fi
    if [ ! -s "$KEY_PATH" ] || [ ! -s "$CERT_PATH" ]; then
        echo "   - [证书模块] 未检测到有效证书，正在生成自签名证书..."
        openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" -out "$CERT_PATH" \
            -days 365 -nodes -subj "/CN=${PROXY_DOMAIN}" 2>/dev/null
    else
        echo "   - [证书模块] 已加载现有证书。"
    fi

    # --- 3b. 动态生成通用真实 IP 获取配置 ---
    local real_ip_conf="/etc/nginx/conf.d/real_ip.conf"
    export PROXY_PROTOCOL_LISTEN_OPTION=""
    export PROXY_REAL_IP_HEADER_LINE=""
    
    if [ "$ENABLE_PROXY_PROTOCOL" = "true" ]; then
        echo "   - [IP模块] 正在生成 Proxy Protocol 真实 IP 获取配置..."
        echo "# 由 bootstrap.sh 动态生成：启用 Proxy Protocol" > "$real_ip_conf"
        echo "set_real_ip_from 172.16.0.0/12;" >> "$real_ip_conf"
        echo "set_real_ip_from 10.0.0.0/8;" >> "$real_ip_conf"
        # 同时也导入 Cloudflare 的 IP 段信赖列表，确保 Auth server 能够正确进行真实 IP 穿透获取
        cat /app/nginx/conf.d/cloudflare-only.conf | grep "set_real_ip_from" >> "$real_ip_conf" 2>/dev/null || true
        if [ -n "$REAL_IP_FROM" ]; then
            for ip in $REAL_IP_FROM; do
                echo "set_real_ip_from $ip;" >> "$real_ip_conf"
            done
        fi
        export PROXY_PROTOCOL_LISTEN_OPTION="proxy_protocol"
        export PROXY_REAL_IP_HEADER_LINE="real_ip_header proxy_protocol;"
    elif [ -n "$REAL_IP_FROM" ]; then
        echo "   - [IP模块] 正在生成自定义真实 IP 获取配置..."
        echo "# 由 bootstrap.sh 动态生成：用于从受信任的前置代理获取真实客户端 IP" > "$real_ip_conf"
        for ip in $REAL_IP_FROM; do
            echo "set_real_ip_from $ip;" >> "$real_ip_conf"
        done
        echo "set_real_ip_from 172.16.0.0/12;" >> "$real_ip_conf" # 信任 Docker 内部网络
        export PROXY_REAL_IP_HEADER_LINE="real_ip_header ${REAL_IP_HEADER};"
    else
        echo "   - [IP模块] 未定义前置代理，默认仅信任 Cloudflare IP 段。"
        cp /app/nginx/conf.d/cloudflare-only.conf "$real_ip_conf"
        # 清理掉 cloudflare-only 中的 real_ip_header 默认声明，避免全局污染干扰 proxy 服务的原生 proxy_protocol。由各 server 自主控制
        sed -i '/real_ip_header/d' "$real_ip_conf" 2>/dev/null || true
        export PROXY_REAL_IP_HEADER_LINE="real_ip_header ${REAL_IP_HEADER};"
    fi

    # --- 3c. mTLS 动态配置生成 (具有优先级) ---
    export MTLS_INCLUDE_LINE="# mTLS 客户端证书校验已默认关闭"
    if [ "$ENABLE_CUSTOM_MTLS" = "true" ]; then
        if [ -f "$CLIENT_CA_CERT_PATH" ]; then
            local custom_mtls_conf="/etc/nginx/conf.d/custom-mtls.conf"
            echo "ssl_verify_client on;" > "$custom_mtls_conf"
            echo "ssl_client_certificate $CLIENT_CA_CERT_PATH;" >> "$custom_mtls_conf"
            export MTLS_INCLUDE_LINE="include /etc/nginx/conf.d/custom-mtls.conf;"
            echo "   - [mTLS模块] 已启用：用户自定义 mTLS (CA: $CLIENT_CA_CERT_PATH) [强制校验模式]"
        else
            echo "   - [mTLS模块警告] ENABLE_CUSTOM_MTLS=true 但未找到 CA 证书于 $CLIENT_CA_CERT_PATH"
        fi
    else
        echo "   - [mTLS模块] mTLS 双向认证已禁用。"
    fi
}

# ========================================================
# 4. 核心配置动态编译与拷贝函数 (Compile & Dynamic Generate Config)
# ========================================================
generate_nginx_config() {
    echo "=> [4/4] 正在编译渲染最终版 Nginx 核心配置文件..."

    # 动态定位模板和资源路径
    local TEMPLATE_PATH="/app/nginx/nginx.conf.template"
    local CONF_D_SRC="/app/nginx/conf.d"
    local LUA_SRC="/app/nginx/lua"
    local CERTS_SRC="/app/nginx/certs"
    local OUTPUT_PATH="/etc/nginx/nginx.conf"

    # 确保运行文件夹存在
    mkdir -p /etc/nginx/conf.d /etc/nginx/certs /etc/nginx/lua

    # A. 编译、渲染并拷贝模块化的子配置文件
    for f in "$CONF_D_SRC"/*; do
        if [ -f "$f" ]; then
            fname=$(basename "$f")
            envsubst '${PROXY_DOMAIN} ${AUTH_DOMAIN} ${SECRET_TOKEN} ${NGINX_PORT} ${FALLBACK_BACKEND} ${FALLBACK_HOST} ${PROXY_FALLBACK_BACKEND} ${PROXY_FALLBACK_HOST} ${AUTH_FALLBACK_BACKEND} ${AUTH_FALLBACK_HOST} ${RT_SSL_CERT_PATH} ${RT_SSL_KEY_PATH}' < "$f" > "/etc/nginx/conf.d/$fname"
        fi
    done

    # B. 拷贝 AOP 根证书目录
    cp -r "$CERTS_SRC"/* "/etc/nginx/certs/" 2>/dev/null || true

    # C. 拷贝 Lua 核心处理模块
    cp -r "$LUA_SRC"/* "/etc/nginx/lua/" 2>/dev/null || true

    # D. 动态渲染最终主配置
    envsubst '${PROXY_DOMAIN} ${AUTH_DOMAIN} ${SECRET_TOKEN} ${NGINX_PORT} ${AUTH_PATH_PREFIX} ${MTLS_INCLUDE_LINE} ${NGINX_LOG_LEVEL} ${AUTH_RATE_LIMIT} ${DNS_RESOLVER} ${PROXY_PROTOCOL_LISTEN_OPTION} ${PROXY_REAL_IP_HEADER_LINE} ${REAL_IP_HEADER} ${FALLBACK_HOST} ${FALLBACK_BACKEND} ${PROXY_FALLBACK_BACKEND} ${PROXY_FALLBACK_HOST} ${AUTH_FALLBACK_BACKEND} ${AUTH_FALLBACK_HOST} ${WHITELIST_DB_PATH} ${REJECTED_LOG_PATH}' < "$TEMPLATE_PATH" > "$OUTPUT_PATH"

    echo "   - 最终配置文件已渲染输出至: $OUTPUT_PATH"
}

# ========================================================
# 🚀 引导启动总控制流
# ========================================================
set_defaults
print_env_summary
setup_configurations
generate_nginx_config

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}      RestyTunnel 初始化配置成功！准备交付控制权启动 Nginx...  ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""
