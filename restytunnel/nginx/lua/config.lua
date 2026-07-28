-- File: nginx/lua/config.lua
-- Description: 高性能集中配置管理器，在内存中一次性加载并预计算所有环境变量，杜绝运行时 os.getenv 的 system 调用开销

local _M = {}

-- 🚀 [自适应时间单位转换器]
-- 支持解析: "30d" (30天), "24h" (24小时), "60m" (60分钟), "300s" (300秒) 或纯数字秒
local function parse_time_to_seconds(val, default_val)
    if not val or val == "" then
        return default_val
    end
    
    local num = tonumber(val)
    if num then
        return num -- 纯数字，直接当成秒返回
    end

    -- 过滤可能存在的空格并转小写
    val = string.lower(string.gsub(val, "%s+", ""))
    local unit = string.sub(val, -1)
    local value = tonumber(string.sub(val, 1, -2))

    if not value then
        return default_val
    end

    if unit == "d" then
        return value * 86400
    elseif unit == "h" then
        return value * 3600
    elseif unit == "m" then
        return value * 60
    elseif unit == "s" then
        return value
    end

    return default_val
end

-- 1. 代理基础认证与鉴权配置
local expected_user = os.getenv("RT_PROXY_USERNAME") or os.getenv("PROXY_USERNAME") or "myuser"
local expected_pass = os.getenv("RT_PROXY_PASSWORD") or os.getenv("PROXY_PASSWORD") or "mypassword"
_M.expected_auth = "Basic " .. ngx.encode_base64(expected_user .. ":" .. expected_pass)
_M.expected_user = expected_user
_M.expected_pass = expected_pass

-- 支持多用户及 TOTP 认证相关配置（以 RestyGuard 为蓝本）
_M.raw_users = os.getenv("RT_USERS") or (expected_user .. ":" .. expected_pass)
_M.session_ttl_seconds = parse_time_to_seconds(os.getenv("RT_SESSION_TTL_SECONDS") or os.getenv("RT_SESSION_TTL"), 2592000) -- 默认 30 天
_M.totp_valid_window_seconds = parse_time_to_seconds(os.getenv("RT_TOTP_VALID_WINDOW_SECONDS") or os.getenv("RT_TOTP_VALID_WINDOW"), 300) -- 默认 300 秒

-- 2. 基础域名及回落伪装后端
_M.proxy_domain = os.getenv("RT_PROXY_DOMAIN") or os.getenv("PROXY_DOMAIN") or "localhost"
_M.auth_domain = os.getenv("RT_AUTH_DOMAIN") or os.getenv("AUTH_DOMAIN") or "auth.localhost"
_M.fallback_backend = os.getenv("RT_FALLBACK_BACKEND") or os.getenv("FALLBACK_BACKEND") or "https://cn.bing.com"
_M.auth_fallback_backend = os.getenv("RT_AUTH_FALLBACK_BACKEND") or os.getenv("AUTH_FALLBACK_BACKEND") or _M.fallback_backend

-- 3. 安全防线与白名单核心配置
_M.enable_whitelist = os.getenv("RT_ENABLE_IP_WHITELIST") or os.getenv("ENABLE_IP_WHITELIST") or "false"
_M.disable_reject_log = os.getenv("RT_DISABLE_REJECT_LOG") or os.getenv("DISABLE_REJECT_LOG") or "false"

-- 4. TTL（有效生存期）计算
_M.ttl_days = tonumber(os.getenv("RT_WHITELIST_IP_TTL_DAYS") or os.getenv("WHITELIST_IP_TTL_DAYS") or 7)
local ttl_seconds = os.getenv("RT_WHITELIST_IP_TTL_SECONDS") or os.getenv("WHITELIST_IP_TTL_SECONDS")
_M.ttl_seconds = parse_time_to_seconds(ttl_seconds, _M.ttl_days * 86400)

-- 5. 网页控制台可见性安全开关
_M.enable_view_whitelist = os.getenv("RT_ENABLE_VIEW_WHITELIST") or os.getenv("ENABLE_VIEW_WHITELIST") or "true"
_M.enable_view_blacklist = os.getenv("RT_ENABLE_VIEW_BLACKLIST") or os.getenv("ENABLE_VIEW_BLACKLIST") or "true"

-- 6. 后台任务运行周期及日志截断限制
_M.whitelist_interval = parse_time_to_seconds(os.getenv("RT_TASK_CLEAN_WHITELIST_INTERVAL_SECONDS") or os.getenv("TASK_CLEAN_WHITELIST_INTERVAL_SECONDS") or os.getenv("RT_TASK_CLEAN_WHITELIST_INTERVAL"), 3600)
_M.max_log_lines = tonumber(os.getenv("RT_TASK_CLEAN_LOG_RETAIN_LINES") or os.getenv("TASK_CLEAN_LOG_RETAIN_LINES") or 30)

-- 7. 🎯 [高弹性调优] 支持通过环境变量自定义白名单和黑名单（拦截日志）的硬盘存储路径，并采用极致性能的 RAM 磁盘作为默认值
_M.whitelist_db_path = os.getenv("RT_WHITELIST_DB_PATH") or os.getenv("WHITELIST_DB_PATH") or "/dev/shm/whitelist.db"
_M.rejected_log_path = os.getenv("RT_REJECTED_LOG_PATH") or os.getenv("REJECTED_LOG_PATH") or "/dev/shm/rejected_ips.log"

return _M
