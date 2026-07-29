#!/bin/sh

set -e

# ANSI 颜色输出支持
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

TEMPLATE_DIR="/app/nginx/templates"
NGINX_CONF_DIR="/etc/nginx/conf.d"

# ========================================================
# 1. 变量初始化函数 (Set Default Environment Variables)
# ========================================================
set_defaults() {
    echo "=> [1/4] 正在加载并校验默认环境变量配置..."

    export RG_STREAM_UPSTREAM_MAP="${RG_STREAM_UPSTREAM_MAP:-*:translate.googleapis.com:443}"
    export RG_NGINX_DNS_RESOLUTION_SECONDS="${RG_NGINX_DNS_RESOLUTION_SECONDS:-600}"
    export RG_SECRET_TOKEN="${RG_SECRET_TOKEN:-}"
    export RG_AUTH_PATH_PREFIX="${RG_AUTH_PATH_PREFIX:-auth}"
    export RG_WHITELIST_IP_TTL_SECONDS="${RG_WHITELIST_IP_TTL_SECONDS:-86400}"
    export RG_NGINX_TLS_MODE="${RG_NGINX_TLS_MODE:-https}"
    export RG_NGINX_USERS="${RG_NGINX_USERS:-}"
    export RG_AUTH_ALLOW_ANY_DOMAIN="${RG_AUTH_ALLOW_ANY_DOMAIN:-false}"
    export RG_AUTH_DOMAIN="${RG_AUTH_DOMAIN:-localhost}"
    export RG_NGINX_PROXY_PROTOCOL="${RG_NGINX_PROXY_PROTOCOL:-off}"
    export RG_NGINX_CDN_IP_HEADERS="${RG_NGINX_CDN_IP_HEADERS:-CF-Connecting-IP:cf,True-Client-IP:cf}"
    export RG_ENABLE_IP_WHITELIST="${RG_ENABLE_IP_WHITELIST:-true}"

    # 🚀 [双重配置调优：Key-Value 静态路由文件 & 环境变量自适应路径及参数自适应声明]
    export RG_UPSTREAM_RULES_FILE="${RG_UPSTREAM_RULES_FILE:-}"
    export RG_STREAM_UPSTREAM_RULES="${RG_STREAM_UPSTREAM_RULES:-}"

    # 日志查看与定时任务参数
    export RG_NGINX_REJECT_LOG_FILENAME="${RG_NGINX_REJECT_LOG_FILENAME:-rejected_ips.log}"
    export RG_TASK_CLEAN_LOG_INTERVAL_SECONDS="${RG_TASK_CLEAN_LOG_INTERVAL_SECONDS:-60}"
    export RG_TASK_CLEAN_LOG_RETAIN_LINES="${RG_TASK_CLEAN_LOG_RETAIN_LINES:-10}"
    export RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS="${RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS:-86400}"

    export RG_SHOW_REJECTED_LOG="${RG_SHOW_REJECTED_LOG:-false}"
    export RG_SHOW_WHITELIST_DB="${RG_SHOW_WHITELIST_DB:-false}"
    export RG_WHITELIST_DB_FILENAME="${RG_WHITELIST_DB_FILENAME:-whitelist.db}"
    export RG_NGINX_LOG_LEVEL="${RG_NGINX_LOG_LEVEL:-notice}" # 🚀 [新功能] 允许用户自定义 Nginx 错误日志级别（如 info, notice, warn, error），保底为 notice 极致静音
    export RG_NGINX_SESSION_TTL_SECONDS="${RG_NGINX_SESSION_TTL_SECONDS:-2592000}" # 🚀 [新] Session Cookie 锁有效期，默认 30 天
    export RG_TOTP_VALID_WINDOW_SECONDS="${RG_TOTP_VALID_WINDOW_SECONDS:-300}" # 🚀 [新] TOTP 可校验的时间偏差窗口大小，默认 300 秒（即前后各 2.5 分钟）
    export RG_TOTP_SECRET="${RG_TOTP_SECRET:-}" # 🚀 [新] TOTP 自定义种子密钥
    export RG_TZ="${RG_TZ:-Asia/Shanghai}" # 🚀 [时区模块调优] 允许用户自定义时区，并保底默认时区设为北京时间（Asia/Shanghai）
    export RG_FALLBACK_BACKEND="${RG_FALLBACK_BACKEND:-https://cn.bing.com}" # 🚀 [回落防刺探调优] 支持未命中管理子路径时，高保真反代到伪装后端

    # 🎯 [证书配置统一设计] 支持自定义路径及文件名，并提供默认值
    export RG_SSL_CERT_PATH="${RG_SSL_CERT_PATH:-${SSL_CERT_PATH:-/etc/nginx/ssl/cert.pem}}"
    export RG_SSL_KEY_PATH="${RG_SSL_KEY_PATH:-${SSL_KEY_PATH:-/etc/nginx/ssl/key.pem}}"
    export RG_CLIENT_CA_CERT_PATH="${RG_CLIENT_CA_CERT_PATH:-${CLIENT_CA_CERT_PATH:-/etc/nginx/ssl/ca.pem}}"
    export RG_ENABLE_CUSTOM_MTLS="${RG_ENABLE_CUSTOM_MTLS:-false}"
    if [ "$RG_ENABLE_CUSTOM_MTLS" = "true" ]; then
        export RG_NGINX_TLS_MODE="mtls"
    fi

    echo "   - 默认环境变量设置成功。"
}

# ========================================================
# 2. 状态打印监控函数 (Print Environment Summary)
# ========================================================
print_env_summary() {
    reveal_secure_val() {
        local val="$1"
        local len=${#val}
        if [ "$len" -le 4 ]; then
            # 🚀 [加固自适应判定：短字符同样输出长度，对齐 SECRET_TOKEN 优雅样式]
            # 兼容 Alpine ash/sh 语法，利用 cut 安全提取首尾字母并完成精准遮罩
            local head=$(echo "$val" | cut -c 1)
            local tail=$(echo "$val" | cut -c "$len")
            echo "${head}***${tail} [长度 ${len} 位的机密配置]"
        else
            local head=$(echo "$val" | cut -c 1-2)
            local tail=$(echo "$val" | cut -c $((len - 1))-$len)
            echo "${head}***${tail} [长度 ${len} 位的机密配置]"
        fi
    }

    # 辅助安全半脱敏透露函数：根据字符串实际长度，智能透露首尾部分，中间隐藏
    reveal_partially() {
        local val="$1"
        local len=${#val}
        if [ "$len" -le 2 ]; then
            echo "**"
        elif [ "$len" -le 5 ]; then
            local head=$(echo "$val" | cut -c 1)
            local tail=$(echo "$val" | cut -c $len)
            echo "${head}***${tail}"
        else
            local half=$((len / 3))
            [ "$half" -lt 1 ] && half=1
            local head=$(echo "$val" | cut -c 1-$half)
            local tail=$(echo "$val" | cut -c $((len - half + 1))-$len)
            echo "${head}***${tail}"
        fi
    }

    parse_users_summary() {
        local raw_users="$1"
        if [ -z "$raw_users" ]; then
            echo "   - 暂无配置用户"
            return
        fi

        local total_users=0
        local totp_users=0
        local displayed_count=0
        
        # 将逗号替换为空格进行遍历，兼容可能有空格的情况
        local IFS_old="$IFS"
        IFS=','
        for user_entry in $raw_users; do
            # 去除首尾空格
            user_entry=$(echo "$user_entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [ -n "$user_entry" ]; then
                total_users=$((total_users + 1))
                
                # 解析字段
                local username=""
                local val1=""
                local val2=""
                
                # 使用 IFS=':' 切分
                local part1=$(echo "$user_entry" | cut -d':' -f1)
                local part2=$(echo "$user_entry" | cut -d':' -f2)
                local part3=$(echo "$user_entry" | cut -d':' -f3)
                
                username="$part1"
                val1="$part2"
                part3=$(echo "$part3" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                
                local auth_type="密码验证"
                if [ "$val1" = "TOTP" ] && [ -n "$part3" ]; then
                    auth_type="TOTP 双向验证"
                    totp_users=$((totp_users + 1))
                elif [ -n "$val1" ] && [ -n "$part3" ]; then
                    auth_type="密码/TOTP 双重验证"
                    totp_users=$((totp_users + 1))
                fi
                
                if [ "$displayed_count" -lt 3 ]; then
                    local masked_user=$(reveal_partially "$username")
                    echo "     -> 用户 $((displayed_count + 1)): ${masked_user} [认证方式: ${auth_type}]"
                    displayed_count=$((displayed_count + 1))
                fi
            fi
        done
        IFS="$IFS_old"
        
        if [ "$total_users" -gt 3 ]; then
            echo "     -> ... 以及其余 $((total_users - 3)) 个用户 ..."
        fi
        echo "   - [用户统计] 累计配置了 ${total_users} 个用户，其中包含 ${totp_users} 个 TOTP 双向验证安全用户。"
    }

    # 🚀 [大吞吐多路由状态透露优化]
    # 如果 STREAM_UPSTREAM_RULES 或是 STREAM_UPSTREAM_MAP 里配置的路由特别多，直接全部打出来会严重刷屏。
    # 采用自适应检测机制：统计出所有逗号分隔出的具体绑定的路由条数（并剔除空行），精简显示总数量和构成预览。
    local total_env_routes=0
    local route_preview=""
    
    # 统计 STREAM_UPSTREAM_RULES 的路由数量
    if [ -n "$STREAM_UPSTREAM_RULES" ]; then
        local count=$(echo "$STREAM_UPSTREAM_RULES" | tr ',' '\n' | grep -v '^[[:space:]]*$' | wc -l)
        total_env_routes=$((total_env_routes + count))
        route_preview="${route_preview} (含 ${count} 条等号路由)"
    fi
    
    # 统计 STREAM_UPSTREAM_MAP 的路由数量并累加
    if [ -n "$STREAM_UPSTREAM_MAP" ]; then
        local count=$(echo "$STREAM_UPSTREAM_MAP" | tr ',' '\n' | grep -v '^[[:space:]]*$' | wc -l)
        total_env_routes=$((total_env_routes + count))
        route_preview="${route_preview} (含 ${count} 条旧版兼容路由)"
    fi

    # 统计静态配置文件的路由数量
    local total_file_routes=0
    local rule_file="${RG_UPSTREAM_RULES_FILE:-/etc/nginx/rules/upstream_rules.conf}"
    if [ -s "$rule_file" ]; then
        total_file_routes=$(grep -v '^[[:space:]]*#' "$rule_file" | grep -v '^[[:space:]]*$' | wc -l)
    fi

    echo "=> [2/4] 正在打印生效的运行配置环境状态监控参数..."
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}              RestyGuard 运行环境变量配置参数               ${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo "   - 静态路由规则文件 [RG_UPSTREAM_RULES_FILE]: ${rule_file} (已载入 ${total_file_routes} 条静态物理路由)"
    echo "   - 动态环境变量路由: 累计合并载入 ${total_env_routes} 条动态域名路由${route_preview}"
    echo "   - DNS 缓存时间 [RG_NGINX_DNS_RESOLUTION_SECONDS]: ${RG_NGINX_DNS_RESOLUTION_SECONDS}s"
    echo "   - 开启 PROXY 协议 [RG_NGINX_PROXY_PROTOCOL]: ${RG_NGINX_PROXY_PROTOCOL}"
    echo "   - 认证子路径前缀 [RG_AUTH_PATH_PREFIX]: /$(reveal_partially "${RG_AUTH_PATH_PREFIX}")"
    echo -n "   - 授权安全密令 [RG_SECRET_TOKEN]: "
    reveal_secure_val "$RG_SECRET_TOKEN"
    echo "   - 授权有效天数 (TTL): $(($RG_WHITELIST_IP_TTL_SECONDS / 86400)) 天 (${RG_WHITELIST_IP_TTL_SECONDS} 秒)"
    echo "   - 运行容器时区 [RG_TZ]: ${RG_TZ}"
    echo "   - TLS 传输模式 [RG_NGINX_TLS_MODE]: ${RG_NGINX_TLS_MODE}"
    if [ -n "$RG_NGINX_USERS" ]; then
        echo "   - 多用户配置列表 [RG_NGINX_USERS]："
        parse_users_summary "$RG_NGINX_USERS"
    fi
    echo "   - 允许任意域名访问 [RG_AUTH_ALLOW_ANY_DOMAIN]: ${RG_AUTH_ALLOW_ANY_DOMAIN}"
    echo "   - 允许管理端域名 [RG_AUTH_DOMAIN]: ${RG_AUTH_DOMAIN}"
    echo "   - 启用白名单防火墙 [RG_ENABLE_IP_WHITELIST]: ${RG_ENABLE_IP_WHITELIST}"
    echo "   - 降维防探回落后端 [RG_FALLBACK_BACKEND]: ${RG_FALLBACK_BACKEND}"
    echo "   - 静态路由规则文件 [RG_UPSTREAM_RULES_FILE]: ${RG_UPSTREAM_RULES_FILE:-[默认: /etc/nginx/rules/upstream_rules.conf]}"
    if [ -n "$RG_STREAM_UPSTREAM_RULES" ]; then
        echo "   - 新版等号路由规则 [RG_STREAM_UPSTREAM_RULES]: ${RG_STREAM_UPSTREAM_RULES}"
    fi
    echo "   - 边缘 CDN IP 头优先级 [RG_NGINX_CDN_IP_HEADERS]: ${RG_NGINX_CDN_IP_HEADERS}"
    echo "   - 开启拒绝日志查看 [RG_SHOW_REJECTED_LOG]: ${RG_SHOW_REJECTED_LOG} (URL 映射为 /${RG_NGINX_REJECT_LOG_FILENAME})"
    echo "   - 开启白名单查看 [RG_SHOW_WHITELIST_DB]: ${RG_SHOW_WHITELIST_DB} (URL 映射为 /${RG_WHITELIST_DB_FILENAME})"
    echo "   - HTTPS证书路径 [RG_SSL_CERT_PATH]: ${RG_SSL_CERT_PATH}"
    echo "   - HTTPS密钥路径 [RG_SSL_KEY_PATH]: ${RG_SSL_KEY_PATH}"
    echo "   - 开启自定义mTLS [RG_ENABLE_CUSTOM_MTLS]: ${RG_ENABLE_CUSTOM_MTLS}"
    if [ "$RG_NGINX_TLS_MODE" = "mtls" ]; then
        echo "   - 自定义CA路径 [RG_CLIENT_CA_CERT_PATH]: ${RG_CLIENT_CA_CERT_PATH}"
    fi
    echo "   - 日志清理周期 [RG_TASK_CLEAN_LOG_INTERVAL_SECONDS]: ${RG_TASK_CLEAN_LOG_INTERVAL_SECONDS}s (保留最新 ${RG_TASK_CLEAN_LOG_RETAIN_LINES} 行)"
    echo "   - 白名单清理周期 [RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS]: ${RG_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS}s"
    echo -e "${BLUE}==========================================================${NC}"

    # 🚀 [双域名极速直连一键加白与控制台配置整合链接生成器 - RestyGuard]
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}             RestyGuard 极速直连与一键加白指南            ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    
    local masked_prefix=$(reveal_partially "${RG_AUTH_PATH_PREFIX}")
    local masked_token=$(reveal_partially "${RG_SECRET_TOKEN}")
    
    # 动态解析出第一个控制台合规用户
    local first_entry=$(echo "$RG_NGINX_USERS" | cut -d',' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    local first_u=$(echo "$first_entry" | cut -d':' -f1)
    local first_v1=$(echo "$first_entry" | cut -d':' -f2)
    local first_v2=$(echo "$first_entry" | cut -d':' -f3 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    local masked_admin_user=$(reveal_partially "$first_u")
    local has_password="true"
    local has_totp="false"
    local masked_admin_pass=""

    if [ -z "$RG_NGINX_USERS" ]; then
        masked_admin_user="[您的用户名]"
        masked_admin_pass="[您的密码]"
    elif [ "$first_v1" = "TOTP" ] && [ -n "$first_v2" ]; then
        has_password="false"
        has_totp="true"
    elif [ -n "$first_v1" ] && [ -n "$first_v2" ]; then
        has_password="true"
        has_totp="true"
        masked_admin_pass=$(reveal_secure_val "$first_v1")
    else
        has_password="true"
        has_totp="false"
        masked_admin_pass=$(reveal_secure_val "$first_v1")
    fi

    # 场景 A: 开启了 IP 白名单防火墙
    if [ "$RG_ENABLE_IP_WHITELIST" = "true" ]; then
        if [ "$has_password" = "true" ]; then
            # 1. 自动加白直连管理链接 ( u=用户名 & p=密码 模式)
            echo -e "   👉 ${YELLOW}[一键自动加白网页控制台主链接]${NC} (安全脱敏示例)"
            echo -e "      https://${RG_AUTH_DOMAIN}/${masked_prefix}/${masked_token}?u=${masked_admin_user}&p=${masked_admin_pass}"
            echo ""
        fi
        
        if [ "$has_totp" = "true" ] || [ "$first_v1" = "TOTP" ]; then
            echo -e "   👉 ${YELLOW}[新设备/动态密码 TOTP 登录链接]${NC} (若配置了 TOTP 种子)"
            echo -e "      https://${RG_AUTH_DOMAIN}/${masked_prefix}/${masked_token}?u=${masked_admin_user}&code=[您的6位手机动态验证码]"
            echo ""
        fi
        
        echo -e "   👉 ${YELLOW}[已授权设备的 30天 免密访问主链接]${NC} (安全脱敏示例)"
        echo -e "      https://${RG_AUTH_DOMAIN}/${masked_prefix}/${masked_token}"
        echo ""
    else
        # 场景 B: 未开启 IP 白名单防火墙
        echo -e "   🔓 ${YELLOW}当前未开启 IP 白名单限制，业务端口已处于公开透传形态。${NC}"
        echo ""
    fi
    echo -e "${GREEN}==========================================================${NC}"
    echo ""
}

# ========================================================
# 3. 动态核心与业务配置文件编译生成 (Compile Configurations)
# ========================================================
setup_configurations() {
    echo "=> [3/4] 正在根据模板生成 Nginx 编译后配置文件..."

    # --- 3a. 动态编译 IP 识别逻辑 (原 20-generate-ip-logic.sh) ---
    echo "   - 正在生成动态客户端 CDN 真实 IP 识别逻辑..."
    local ip_val_template="${TEMPLATE_DIR}/ip-validation.conf.template"
    local ip_val_output="${NGINX_CONF_DIR}/ip-validation.conf"
    
    local header_list=$(echo "$RG_NGINX_CDN_IP_HEADERS" | tr ',' ' ')
    local generated_ip_map_chain=""
    local generated_provider_logic=""
    local has_var_concat_string=""
    local provider_map_rules=""
    local prev_var='""'
    local step=0
    local prefix_regex="~^"

    for item in $header_list; do
        local header=$(echo "$item" | cut -d: -f1)
        local alias=$(echo "$item" | cut -d: -f2)
        local nginx_var="\$http_$(echo "$header" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
        
        local current_step_var="\$cdn_ip_step${step}"
        generated_ip_map_chain=$(cat <<EOF
${generated_ip_map_chain}
map ${prev_var} ${current_step_var} {
    default ${prev_var};
    ""      ${nginx_var};
}
EOF
)
        prev_var="$current_step_var"
        
        local has_var="\$has_${alias}"
        generated_provider_logic=$(cat <<EOF
${generated_provider_logic}
map ${nginx_var} ${has_var} { default 1; "" 0; }
EOF
)
        if ! echo "$has_var_concat_string" | grep -q "$has_var"; then
            has_var_concat_string="${has_var_concat_string}${has_var}"
            provider_map_rules=$(cat <<EOF
${provider_map_rules}
    ${prefix_regex}   "${alias}";
EOF
)
            prefix_regex="${prefix_regex}0"
        fi
        step=$((step + 1))
    done

    generated_ip_map_chain=$(cat <<EOF
${generated_ip_map_chain}
map ${prev_var} \$cdn_client_ip {
    default ${prev_var};
}
EOF
)

    generated_provider_logic=$(cat <<EOF
# 步骤 1.5: 动态生成的 CDN 提供商识别逻辑
${generated_provider_logic}
map "${has_var_concat_string}" \$cdn_provider {
${provider_map_rules}
    default         "none";
}
EOF
)

    local ip_map_file=$(mktemp)
    local provider_map_file=$(mktemp)
    echo "$generated_ip_map_chain" > "$ip_map_file"
    echo "$generated_provider_logic" > "$provider_map_file"

    sed \
        -e "/<% DYNAMIC_CDN_IP_MAP_CHAIN %>/r $ip_map_file" \
        -e "/<% DYNAMIC_CDN_IP_MAP_CHAIN %>/d" \
        -e "/<% DYNAMIC_CDN_PROVIDER_LOGIC %>/r $provider_map_file" \
        -e "/<% DYNAMIC_CDN_PROVIDER_LOGIC %>/d" \
        "$ip_val_template" > "$ip_val_output"

    rm -f "$ip_map_file" "$provider_map_file"
    echo "     -> [IP 模块] 编译并写入 ${ip_val_output} 成功。"

    # --- 3c. 编译核心及 Stream 路由配置 (原 22-generate-core-configs.sh) ---
    echo "   - 正在编译生成主 Nginx 及 Stream 四层核心路由配置文件..."
    
    # 🚀 [证书自签名保底调优]
    # 如果检测到 Nginx 的证书路径下没有证书文件，
    # 自动在后台生成高保真自签名证书，让容器无论如何都能 100% 优雅冷启动开箱即用。
    local cert_file="${RG_SSL_CERT_PATH}"
    local key_file="${RG_SSL_KEY_PATH}"
    local ca_file="${RG_CLIENT_CA_CERT_PATH}"
    
    local cert_dir_parent=$(dirname "$cert_file")
    local key_dir_parent=$(dirname "$key_file")
    local ca_dir_parent=$(dirname "$ca_file")
    mkdir -p "$cert_dir_parent" "$key_dir_parent" "$ca_dir_parent"

    if [ ! -s "$ca_file" ]; then
        echo "   - [证书保底] 未检测到合规的客户端 CA 证书，正在生成开发保底自签名 CA 证书..."
        local ca_key_file="${ca_dir_parent}/ca.key"
        openssl genrsa -out "$ca_key_file" 2048 2>/dev/null
        openssl req -x509 -new -nodes -key "$ca_key_file" \
            -sha256 -days 3650 \
            -subj "/C=CN/O=RestyGuard-Dev-CA/CN=RestyGuard Dev CA" \
            -out "$ca_file" 2>/dev/null
        rm -f "$ca_key_file"
    fi

    if [ ! -s "$cert_file" ] || [ ! -s "$key_file" ]; then
        echo "   - [证书保底] 未检测到合规 the TLS 证书，正在生成开发保底自签名证书..."
        openssl req -x509 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" \
            -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
    fi

    envsubst '$RG_NGINX_DNS_RESOLUTION_SECONDS $RG_NGINX_LOG_LEVEL' < "${TEMPLATE_DIR}/nginx.conf.template" > "/etc/nginx/nginx.conf"
    
    if [ "$RG_NGINX_PROXY_PROTOCOL" = "on" ]; then
        export PROXY_PROTOCOL_PARAM="proxy_protocol"
    else
        export PROXY_PROTOCOL_PARAM="" 
    fi
    envsubst '$PROXY_PROTOCOL_PARAM' < "${TEMPLATE_DIR}/stream-main.conf.template" > "/etc/nginx/stream.d/main.conf"
    echo "     -> [核心模块] 编译并写入 /etc/nginx/nginx.conf 与 /etc/nginx/stream.d/main.conf 成功。"

    # --- 3d. 组装环回 8443 认证与诊断服务 (原 23-generate-auth-server.sh) ---
    echo "   - 正在组装本地 127.0.0.1:8443 安全环回认证及诊断服务器..."
    local auth_server_conf="${NGINX_CONF_DIR}/http.server-8443.conf"
    {
        echo "# [自动生成] 由 bootstrap.sh (v3.8.0) 模块化组装"
        echo "server {"
        if [ "$RG_AUTH_ALLOW_ANY_DOMAIN" = "true" ]; then
            echo "    server_name _;"
        else
            echo "    server_name" $(echo "$RG_AUTH_DOMAIN" | tr ',' ' ') ";"
        fi
        
        if [ "$RG_NGINX_TLS_MODE" = "http" ]; then
            echo "    listen 127.0.0.1:8443;"
        else
            echo "    listen 127.0.0.1:8443 ssl proxy_protocol;"
            envsubst '${RG_SSL_CERT_PATH} ${RG_SSL_KEY_PATH}' < "${TEMPLATE_DIR}/ssl.conf.template"
            if [ "$RG_NGINX_TLS_MODE" = "mtls" ]; then
                envsubst '${RG_CLIENT_CA_CERT_PATH}' < "${TEMPLATE_DIR}/mtls.conf.template"
            fi
            echo "    real_ip_header proxy_protocol;"
            echo "    set_real_ip_from 127.0.0.1;"
        fi

        # 🚀 [终极回落伪装调优：模仿 RestyTunnel 动态域名隔离回落机制]
        # 解析 RG_FALLBACK_BACKEND 提取对应的 Host 首部与协议信息
        local fallback_proto=$(echo "$RG_FALLBACK_BACKEND" | grep -o '^[hH][tT][tT][pP][sS]\?') || fallback_proto="https"
        local fallback_host=$(echo "$RG_FALLBACK_BACKEND" | sed -e 's|^[^/]*//||' -e 's|/.*||' -e 's|:.*||')
        [ -z "$fallback_host" ] && fallback_host="cn.bing.com"

        # 写入根路径 "/" 的自适应高保真回落伪装。
        # 只有在访问精准的路径前缀 + Token（/auth/SECRET_TOKEN）时才被允许添加 IP。
        # 其他一切非合规路径试探、扫描，全部高保真无缝反代至 RG_FALLBACK_BACKEND，
        # 在 HTTP 层面不给刺探者 and 扫描器暴露一丝防火墙后台的指纹！
        echo "    location / {"
        echo "        proxy_pass ${RG_FALLBACK_BACKEND};"
        echo "        proxy_set_header Host ${fallback_host};"
        echo "        proxy_set_header Referer ${RG_FALLBACK_BACKEND};"
        echo "        proxy_set_header User-Agent \$http_user_agent;"
        echo "        proxy_set_header Accept-Encoding \"\";" # 关闭压缩，支持 Nginx 动态重写
        echo "        proxy_ssl_server_name on;"
        echo "        proxy_ssl_name ${fallback_host};"
        echo "    }"

        # 🚀 [新] 写入专门的命名回落 (Named Location) 用于 LUA 级鉴权失败时的影帝级静默无弹窗重定向
        echo "    location @fallback {"
        echo "        proxy_pass ${RG_FALLBACK_BACKEND};"
        echo "        proxy_set_header Host ${fallback_host};"
        echo "        proxy_set_header Referer ${RG_FALLBACK_BACKEND};"
        echo "        proxy_set_header User-Agent \$http_user_agent;"
        echo "        proxy_set_header Accept-Encoding \"\";"
        echo "        proxy_ssl_server_name on;"
        echo "        proxy_ssl_name ${fallback_host};"
        echo "    }"
        
        # 写入主认证 API 端点
        local auth_location=$(envsubst '$RG_AUTH_PATH_PREFIX $RG_SECRET_TOKEN' <<EOF
    location = /\${RG_AUTH_PATH_PREFIX}/\${RG_SECRET_TOKEN} {
EOF
        )
        echo "$auth_location"
        # 🚀 [终极安全加固] 彻底废除、删除 Nginx 原生的 Basic Auth 401 弹窗配置，100% 交给内层 Lua 虚拟机执行静默自适应校验和无缝回落
        echo "        content_by_lua_file /app/nginx/lua/http/auth_handler.lua;"
        echo "    }" 

        # 🚀 [防止 Service Worker 覆盖/劫持管理控制台]
        # 您的真实业务 (RG_FALLBACK_BACKEND) 在根目录下注册并启用了 Service Worker (sw.js / service-worker.js)。
        # 由于其作用域是整个域名，它会把授权域名 (AUTH_DOMAIN) 下的控制台路径也强行用 SPA 壳覆盖。
        # 拦截并返回一个自适应、免崩溃、能自我注销的极健壮 Service Worker 脚本，彻底解脱劫持！
        # 🛡️ [防扫描防指纹漏洞加固] 采用 Lua 动态审计拦截：只有当前 IP 已加入白名单，或者客户端携带了合法的免密 Cookie 凭证时，
        # 才返回自驱动注销的 Service Worker 脚本以打破死锁。其余一切陌生扫描 IP 直接静默反代至伪装后端，100% 隐藏防扫描特征！
        echo "    location ~* /(sw\.js|service-worker\.js) {"
        echo "        access_by_lua_block {"
        echo "            local function check_allowed()"
        echo "                local client_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or \"unknown\""
        echo "                local file = io.open(\"/dev/shm/whitelist.db\", \"r\")"
        echo "                if file then"
        echo "                    local current_time = ngx.time()"
        echo "                    for line in file:lines() do"
        echo "                        local ip, expiry_str = string.match(line, \"([^=]+)=([^=]+)\")"
        echo "                        if ip == client_ip then"
        echo "                            local expiry_time = tonumber(expiry_str)"
        echo "                            if expiry_time and expiry_time >= current_time then"
        echo "                                file:close()"
        echo "                                return true"
        echo "                            end"
        echo "                        end"
        echo "                    end"
        echo "                    file:close()"
        echo "                end"
        echo "                "
        echo "                local headers = ngx.req.get_headers()"
        echo "                local cookie_str = headers[\"Cookie\"]"
        echo "                if type(cookie_str) == \"table\" then"
        echo "                    cookie_str = table.concat(cookie_str, \"; \")"
        echo "                else"
        echo "                    cookie_str = cookie_str or \"\""
        echo "                end"
        echo "                "
        echo "                if cookie_str ~= \"\" then"
        echo "                    local cookie_user = string.match(cookie_str, \"gkp_user=([%w%.%_%-]+)\")"
        echo "                    local cookie_pass = string.match(cookie_str, \"gkp_session=([%w]+)\")"
        echo "                    if cookie_user and cookie_pass then"
        echo "                        local raw_users = os.getenv(\"RG_NGINX_USERS\")"
        echo "                        if raw_users and raw_users ~= \"\" then"
        echo "                            local users_db = {}"
        echo "                            for user_entry in string.gmatch(raw_users, \"([^,]+)\") do"
        echo "                                user_entry = string.gsub(user_entry, \"^%s*(.-)%s*$\", \"%1\")"
        echo "                                local username, val1, val2 = string.match(user_entry, \"^([^:]+):([^:]+):?(.*)$\")"
        echo "                                if username and val1 then"
        echo "                                    users_db[username] = {"
        echo "                                        credential = val1,"
        echo "                                        totp_secret = (val2 ~= \"\" and val2 or nil)"
        echo "                                    }"
        echo "                                end"
        echo "                            end"
        echo "                            local user_record = users_db[cookie_user]"
        echo "                            local target_secret = user_record and (user_record.totp_secret or user_record.credential)"
        echo "                            if target_secret and cookie_pass == target_secret then"
        echo "                                return true"
        echo "                            end"
        echo "                        end"
        echo "                    end"
        echo "                end"
        echo "                return false"
        echo "            end"
        echo "            if not check_allowed() then"
        echo "                ngx.exec(\"@backend\")"
        echo "                return"
        echo "            end"
        echo "        }"
        echo "        default_type application/javascript;"
        echo "        return 200 \"if (typeof ServiceWorkerGlobalScope !== 'undefined' && self instanceof ServiceWorkerGlobalScope) { self.addEventListener('install', function(e) { self.skipWaiting(); }); self.addEventListener('activate', function(e) { e.waitUntil(self.registration.unregister().then(function() { return self.clients.matchAll(); }).then(function(clients) { clients.forEach(function(client) { try { client.navigate(client.url); } catch(err) {} }); })); }); } else { if ('serviceWorker' in navigator) { navigator.serviceWorker.getRegistrations().then(function(regs) { for (let reg of regs) { var scriptURL = (reg.active || reg.installing || reg.waiting || {}).scriptURL || ''; if (scriptURL && !scriptURL.includes('gkp-sw.js')) { reg.unregister(); } } }); } }\";"
        echo "    }"

        # 🚀 [新增控制台 PWA 独立集成模块 - RestyGuard]
        # 动态生成控制台专属 PWA Manifest 配置文件，并实施 Lua 动态审计拦截以完美抹除探测指纹特征
        echo "    location = /gkp-manifest.json {"
        echo "        access_by_lua_block {"
        echo "            local function check_allowed()"
        echo "                local client_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or \"unknown\""
        echo "                local file = io.open(\"/dev/shm/whitelist.db\", \"r\")"
        echo "                if file then"
        echo "                    local current_time = ngx.time()"
        echo "                    for line in file:lines() do"
        echo "                        local ip, expiry_str = string.match(line, \"([^=]+)=([^=]+)\")"
        echo "                        if ip == client_ip then"
        echo "                            local expiry_time = tonumber(expiry_str)"
        echo "                            if expiry_time and expiry_time >= current_time then"
        echo "                                file:close()"
        echo "                                return true"
        echo "                            end"
        echo "                        end"
        echo "                    end"
        echo "                    file:close()"
        echo "                end"
        echo "                return false"
        echo "            end"
        echo "            if not check_allowed() then"
        echo "                ngx.exec(\"@backend\")"
        echo "                return"
        echo "            end"
        echo "        }"
        echo "        default_type application/json;"
        echo "        add_header Cache-Control \"no-cache, no-store, must-revalidate\";"
        echo "        return 200 '{\n  \"name\": \"RestyGuard 安全网关 IP 自助管理控制台\",\n  \"short_name\": \"守卫控制台\",\n  \"description\": \"RestyGuard 动态 IP 白名单授权与自助管理端\",\n  \"start_url\": \"/\${RG_AUTH_PATH_PREFIX}/\${RG_SECRET_TOKEN}\",\n  \"display\": \"standalone\",\n  \"background_color\": \"#f4f7f6\",\n  \"theme_color\": \"#007bff\",\n  \"icons\": [\n    {\n      \"src\": \"data:image/svg+xml;utf8,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>\uD83D\uDEE1\uFE0F</text></svg>\",\n      \"sizes\": \"512x512\",\n      \"type\": \"image/svg+xml\"\n    }\n  ]\n}';"
        echo "    }"

        # 动态生成控制台专属 PWA Service Worker，满足安装标准的同时，绝不进行本地文件缓存，杜绝任何页面更新滞后 Bug
        echo "    location = /gkp-sw.js {"
        echo "        access_by_lua_block {"
        echo "            local function check_allowed()"
        echo "                local client_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or \"unknown\""
        echo "                local file = io.open(\"/dev/shm/whitelist.db\", \"r\")"
        echo "                if file then"
        echo "                    local current_time = ngx.time()"
        echo "                    for line in file:lines() do"
        echo "                        local ip, expiry_str = string.match(line, \"([^=]+)=([^=]+)\")"
        echo "                        if ip == client_ip then"
        echo "                            local expiry_time = tonumber(expiry_str)"
        echo "                            if expiry_time and expiry_time >= current_time then"
        echo "                                file:close()"
        echo "                                return true"
        echo "                            end"
        echo "                        end"
        echo "                    end"
        echo "                    file:close()"
        echo "                end"
        echo "                return false"
        echo "            end"
        echo "            if not check_allowed() then"
        echo "                ngx.exec(\"@backend\")"
        echo "                return"
        echo "            end"
        echo "        }"
        echo "        default_type application/javascript;"
        echo "        add_header Cache-Control \"no-cache, no-store, must-revalidate\";"
        echo "        return 200 \"self.addEventListener('install', function(e) { self.skipWaiting(); }); self.addEventListener('activate', function(e) { e.waitUntil(self.clients.claim()); }); self.addEventListener('fetch', function(e) { e.respondWith(fetch(e.request)); });\";"
        echo "    }"

        # 动态启用拦截日志查看端点
        if [ "$RG_SHOW_REJECTED_LOG" = "true" ]; then
            local reject_loc=$(envsubst '$RG_AUTH_PATH_PREFIX $RG_SECRET_TOKEN $RG_NGINX_REJECT_LOG_FILENAME' <<EOF
    location = /\${RG_AUTH_PATH_PREFIX}/\${RG_SECRET_TOKEN}/\${RG_NGINX_REJECT_LOG_FILENAME} {
EOF
            )
            echo "$reject_loc"
            echo "        alias /dev/shm/rejected_ips.log;"
            echo "        default_type text/plain;"
            echo "        add_header X-Debug-Handled-By 'reject-log-viewer';"
            echo "    }"
        fi

        # 动态启用白名单文件查看端点
        if [ "$RG_SHOW_WHITELIST_DB" = "true" ]; then
            local whitelist_loc=$(envsubst '$RG_AUTH_PATH_PREFIX $RG_SECRET_TOKEN $RG_WHITELIST_DB_FILENAME' <<EOF
    location = /\${RG_AUTH_PATH_PREFIX}/\${RG_SECRET_TOKEN}/\${RG_WHITELIST_DB_FILENAME} {
EOF
            )
            echo "$whitelist_loc"
            echo "        alias /dev/shm/whitelist.db;"
            echo "        default_type text/plain;"
            echo "        add_header X-Debug-Handled-By 'whitelist-db-viewer';"
            echo "    }"
        fi

        echo "}"
    } > "$auth_server_conf"
    echo "     -> [控制网关] 编译并写入 ${auth_server_conf} 成功。"
}

# ========================================================
# 4. 执行并引导启动 (Bootstrap Process Execution)
# ========================================================
set_defaults
print_env_summary
setup_configurations

echo -e "=> [4/4] ${GREEN}RestyGuard 网关所有模块初始化与动态配置编译完毕。${NC}"
echo ""
