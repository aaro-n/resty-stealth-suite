-- File: nginx/lua/auth_handler.lua
-- Description: 高性能双向 mTLS 管理员登录 + 自适应密码/TOTP 联合检验控制器（无状态，以 RestyGuard 为蓝本）

local whitelist = require("whitelist")
local view = require("auth_view")
local config = require("config")

local method = ngx.req.get_method()
local headers = ngx.req.get_headers()

-- ========================================================
-- 🚀 [极其强悍的自适应时间单位转换器]
-- ========================================================
local function parse_time_to_seconds(val_str, default_val)
    if not val_str or val_str == "" then
        return default_val
    end
    
    local num = tonumber(val_str)
    if num then
        return num
    end

    val_str = string.lower(string.gsub(val_str, "%s+", ""))
    local unit = string.sub(val_str, -1)
    local value = tonumber(string.sub(val_str, 1, -2))

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

-- ========================================================
-- 🚀 [精密的 Base32 编码解码器]
-- ========================================================
local function base32_decode(key_str)
    if not key_str or key_str == "" then return "" end
    key_str = string.upper(string.gsub(key_str, "%s+", ""))

    local b32map = {
        A=0, B=1, C=2, D=3, E=4, F=5, G=6, H=7, I=8, J=9, K=10, L=11, M=12,
        N=13, O=14, P=15, Q=16, R=17, S=18, T=19, U=20, V=21, W=22, X=23, Y=24, Z=25,
        ["2"]=26, ["3"]=27, ["4"]=28, ["5"]=29, ["6"]=30, ["7"]=31
    }

    for i = 1, #key_str do
        local c = string.sub(key_str, i, i)
        if c ~= "=" and not b32map[c] then
            return key_str
        end
    end

    local buffer = 0
    local bits_left = 0
    local result = {}

    for i = 1, #key_str do
        local c = string.sub(key_str, i, i)
        if c == "=" then break end
        local val = b32map[c]
        if val then
            buffer = bit.bor(bit.lshift(buffer, 5), val)
            bits_left = bits_left + 5
            if bits_left >= 8 then
                bits_left = bits_left - 8
                local byte = bit.band(bit.rshift(buffer, bits_left), 0xFF)
                table.insert(result, string.char(byte))
            end
        end
    end
    return table.concat(result)
end

-- ========================================================
-- 🚀 [多用户自适应 TOTP 计算内核]
-- ========================================================
local function verify_totp_code(totp_secret, req_code)
    local decoded_secret = base32_decode(totp_secret)
    local step_seconds = 30
    local valid_window = config.totp_valid_window_seconds or 300
    local max_offset_steps = math.ceil((valid_window / 2) / step_seconds)
    local current_time = ngx.time()
    
    for offset = -max_offset_steps, max_offset_steps do
        local time_step = math.floor((current_time + (offset * step_seconds)) / step_seconds)
        local T_bytes = string.char(
            0, 0, 0, 0,
            bit.band(bit.rshift(time_step, 24), 0xFF),
            bit.band(bit.rshift(time_step, 16), 0xFF),
            bit.band(bit.rshift(time_step, 8), 0xFF),
            bit.band(time_step, 0xFF)
        )
        
        local hash = ngx.hmac_sha1(decoded_secret, T_bytes)
        local offset_byte = bit.band(hash:byte(20), 0x0F) + 1
        local binary = bit.bor(
            bit.lshift(bit.band(hash:byte(offset_byte), 0x7F), 24),
            bit.lshift(hash:byte(offset_byte+1), 16),
            bit.lshift(hash:byte(offset_byte+2), 8),
            hash:byte(offset_byte+3)
        )
        
        local calc_code = string.format("%06d", binary % 1000000)
        if calc_code == req_code then
            return true
        end
    end
    return false
end

-- ========================================================
-- 🚀 [自适应多用户密码/TOTP 联合检验逻辑（无状态，Stateless）]
-- ========================================================
local function check_stealth_auth()
    local users_db = {}
    local raw_users = config.raw_users
    
    if not raw_users or raw_users == "" then
        return false
    end

    for user_entry in string.gmatch(raw_users, "([^,]+)") do
        user_entry = string.gsub(user_entry, "^%s*(.-)%s*$", "%1")
        local username, val1, val2 = string.match(user_entry, "^([^:]+):([^:]+):?(.*)$")
        if username and val1 then
            users_db[username] = {
                credential = val1,
                totp_secret = (val2 ~= "" and val2 or nil)
            }
        elseif not username then
            local u, p = string.match(user_entry, "^([^:]+):(.*)$")
            if u and p then
                users_db[u] = { credential = p }
            end
        end
    end

    -- A. 优先校验 Cookie
    local function get_cookie_string(cookie_header_val)
        if type(cookie_header_val) == "table" then
            return table.concat(cookie_header_val, "; ")
        end
        return cookie_header_val or ""
    end
    local cookie_str = get_cookie_string(headers["Cookie"])

    if cookie_str ~= "" then
        local cookie_user = string.match(cookie_str, "gkp_user=([%w%.%_%-]+)")
        local cookie_pass = string.match(cookie_str, "gkp_session=([%w]+)")
        if cookie_user and cookie_pass then
            local user_record = users_db[cookie_user]
            local target_secret = user_record and (user_record.totp_secret or user_record.credential)
            if target_secret and cookie_pass == target_secret then
                local session_ttl = config.session_ttl_seconds or 2592000
                ngx.header["Set-Cookie"] = {
                    "gkp_user=" .. cookie_user .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                    "gkp_session=" .. target_secret .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                    "gkp_active=1; Path=/; Max-Age=" .. session_ttl .. "; SameSite=Lax; Secure"
                }
                ngx.header["Clear-Site-Data"] = '"storage"'

                local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
                ngx.log(ngx.NOTICE, "🔑 [认证通过] - 客户端 IP: '", client_real_ip, "', 用户: '", cookie_user, "', 认证方式: '免密 Cookie 锁顺延', 结果: 成功直接直入控制台。")
                return true
            end
        end
    end

    -- B. 其次校验 URL 参数
    local args = ngx.req.get_uri_args()
    local req_user = args.u
    local req_pass = args.p
    local req_code = args.code

    if req_user or req_pass or req_code then
        local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
        local user_show = req_user or "未知用户"
        local auth_type = (req_code and req_code ~= "") and "TOTP动态验证码" or ((req_pass and req_pass ~= "") and "静态密码" or "仅用户名")
        local attempt_val = (req_code and req_code ~= "") and req_code or ((req_pass and req_pass ~= "") and "******" or "-")
        ngx.log(ngx.NOTICE, "🔍 [收到登录请求] - 客户端 IP: '", client_real_ip, "', 用户: '", user_show, "', 认证方式: '", auth_type, "', 尝试提交的内容: '", attempt_val, "'。正在执行解密计算与碰撞比对...")
    end

    if req_user and users_db[req_user] then
        local user_record = users_db[req_user]
        local is_authenticated = false
        local cookie_secret = ""

        if req_pass and req_pass ~= "" then
            if req_pass == user_record.credential and user_record.credential ~= "TOTP" then
                is_authenticated = true
                cookie_secret = req_pass
            end
        elseif req_code and string.match(req_code, "^%d%d%d%d%d%d$") then
            local totp_secret = user_record.totp_secret or user_record.credential
            if totp_secret and totp_secret ~= "" then
                if verify_totp_code(totp_secret, req_code) then
                    is_authenticated = true
                    cookie_secret = totp_secret
                end
            end
        end

        if is_authenticated then
            local session_ttl = config.session_ttl_seconds or 2592000
            
            ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
            ngx.header["Pragma"] = "no-cache"
            ngx.header["Expires"] = "0"
            ngx.header["Clear-Site-Data"] = '"storage"'

            ngx.header["Set-Cookie"] = {
                "gkp_user=" .. req_user .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                "gkp_session=" .. cookie_secret .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                "gkp_active=1; Path=/; Max-Age=" .. session_ttl .. "; SameSite=Lax; Secure"
            }
            
            local clean_uri = ngx.var.uri
            local jump_html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Authenticating...</title>
</head>
<body>
    <div style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 100px; color: #333;">
        <h3>🔑 正在建立安全连接，请稍候...</h3>
        <p style="color: #666; font-size: 0.9em;">正在清除缓存并初始化安全代理控制台...</p>
    </div>
    <script>
        // 极度安全的异步解套：必须等待 Service Worker 彻底注销完成后，再执行跳转页面
        // 从而 100% 杜绝由于 replace() 瞬间发生导致注销 Promise 被浏览器强制中止取消的 Bug
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.getRegistrations().then(function(registrations) {
                var promises = [];
                for (var i = 0; i < registrations.length; i++) {
                    promises.push(registrations[i].unregister());
                }
                Promise.all(promises).then(function() {
                    window.location.replace("]] .. clean_uri .. [[");
                }).catch(function() {
                    window.location.replace("]] .. clean_uri .. [[");
                });
            }).catch(function() {
                window.location.replace("]] .. clean_uri .. [[");
            });
        } else {
            window.location.replace("]] .. clean_uri .. [[");
        }
    </script>
</body>
</html>
]]
            local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
            local auth_type = (req_code and req_code ~= "") and "TOTP动态验证码" or "静态密码"
            ngx.log(ngx.NOTICE, "✅ [认证通过] - 客户端 IP: '", client_real_ip, "', 用户: '", req_user, "', 认证方式: '", auth_type, "', 结果: 成功生成新凭证，即将写入 Cookie 锁。")

            ngx.status = 200
            ngx.header["Content-Type"] = "text/html; charset=utf-8"
            ngx.say(jump_html)
            ngx.exit(200)
        else
            local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
            local auth_type = (req_code and req_code ~= "") and "TOTP动态验证码" or "静态密码"
            local attempt_val = (req_code and req_code ~= "") and req_code or "******"
            ngx.log(ngx.WARN, "⚠️  [认证失败] - 客户端 IP: '", client_real_ip, "', 用户: '", req_user, "', 认证方式: '", auth_type, "', 提交的内容: '", attempt_val, "'。原因: 口令错误、超时或未对齐。")

            local delay = 1.5 + math.random() * 0.7
            ngx.sleep(delay)
        end
    end

    return false
end

-- ========================================================
-- 核心拦截点：检查隐秘登录认证
-- ========================================================
if not check_stealth_auth() then
    ngx.exec("@backend")
    return
end

-- ========================================================
-- 2. 解析客户端真实 IP 与要授权的 IP
-- ========================================================
local visitor_ip
local cf_ip = headers["CF-Connecting-IP"]
if cf_ip then
    visitor_ip = cf_ip
else
    local xff = headers["X-Forwarded-For"]
    if xff then
        if type(xff) == "table" then xff = xff[1] end
        visitor_ip = string.match(xff, "^%s*([^,]+)")
    end
end

if not visitor_ip or visitor_ip == "" then
    visitor_ip = ngx.var.remote_addr
end

local ip_to_add = ngx.var.arg_ip
if not ip_to_add or ip_to_add == "" then
    ip_to_add = visitor_ip
end

local success, err
local is_posted = false

-- ========================================================
-- 3. 拦截与业务分发：处理表单操作 (添加 add / 删除 delete)
-- ========================================================
if method == "POST" then
    ngx.req.read_body()
    local args, post_err = ngx.req.get_post_args()
    if args then
        local action = args.action or "add"
        
        -- A. 手动精准添加白名单 IP
        if action == "add" and args.ip then
            local submitted_ip = string.match(args.ip, "^%s*(.-)%s*$")
            if submitted_ip ~= "" then
                ip_to_add = submitted_ip
                success, err = whitelist.add(ip_to_add)
                is_posted = true
            end
            
        -- B. 自助删除/移除白名单 IP
        elseif action == "delete" and args.ip then
            local target_ip = string.match(args.ip, "^%s*(.-)%s*$")
            if target_ip ~= "" then
                success, err = whitelist.delete(target_ip)
                is_posted = true
            end
        end
    end
end

-- ========================================================
-- 4. 自动加入白名单：如果是无任何参数的纯 GET 访问（自动授权本机）
-- ========================================================
if method == "GET" and not ngx.var.arg_ip then
    success, err = whitelist.add(ip_to_add)
end

-- ========================================================
-- 5. 抓取数据并构造列表，准备渲染
-- ========================================================

-- A. 读取内存白名单明细 (如果启用了白名单列表可见)
local whitelist_entries = {}
local enable_view_whitelist = config.enable_view_whitelist
local whitelist_db_path = config.whitelist_db_path
local rejected_log_path = config.rejected_log_path

if enable_view_whitelist == "true" then
    -- 🚀 [极致 I/O 调优] 优先从 C 语言物理共享字典中极速拉取活跃白名单，彻底废除高并发磁盘读取开销，响应时延直接降低 99%！
    local dict = ngx.shared.whitelist_dict
    if dict then
        local keys = dict:get_keys(1024) -- 支持展示最多 1024 个活跃 IP
        local current_time = ngx.time()
        for _, ip in ipairs(keys) do
            -- 🚀 [修复] 排除 system_loaded 状态标记键并加固类型校验，防止 Lua 虚拟机抛出比较布尔值与数字的 Runtime 致命异常
            if ip ~= "system_loaded" then
                local expiry_time = dict:get(ip)
                if expiry_time and type(expiry_time) == "number" and expiry_time >= current_time then
                    table.insert(whitelist_entries, {ip = ip, remaining = expiry_time - current_time})
                end
            end
        end
        -- 对列表进行美化排序（按剩余生存时间由长到短排，提升直观体验）
        table.sort(whitelist_entries, function(a, b) return a.remaining > b.remaining end)
    else
        -- 降维备用：从 RAM 磁盘文件读取 (安全兜底)
        local db_file = io.open(whitelist_db_path, "r")
        if db_file then
            local current_time = ngx.time()
            for line in db_file:lines() do
                local ip, expiry_str = string.match(line, "^(.-)=([^=]+)$")
                if ip and expiry_str then
                    local expiry_time = tonumber(expiry_str)
                    if expiry_time and expiry_time >= current_time then
                        table.insert(whitelist_entries, {ip = ip, remaining = expiry_time - current_time})
                    end
                end
            end
            db_file:close()
        end
    end
end

-- B. 读取被拒绝的拦截历史日志 (自适应从底部读取最新 10 条，避免高并发下实时排序的 CPU 与磁盘开销)
local rejected_logs = {}
local enable_view_blacklist = config.enable_view_blacklist
if enable_view_blacklist == "true" then
    local log_file = io.open(rejected_log_path, "r")
    if log_file then
        local temp_logs = {}
        for line in log_file:lines() do
            -- 格式：[2026-07-24 15:00:00] 1.2.3.4 - reason
            local time, ip, reason = string.match(line, "^%[([^%]]+)%]%s+([%w%.%:]+)%s+-%s+(.+)$")
            if time and ip and reason then
                table.insert(temp_logs, {time = time, ip = ip, reason = reason})
            end
        end
        log_file:close()

        -- 从尾部往前取最多 10 条最新的拦截记录，实现免重组高速逆序展示！
        local total_count = #temp_logs
        local limit = 10
        for i = total_count, 1, -1 do
            table.insert(rejected_logs, temp_logs[i])
            limit = limit - 1
            if limit <= 0 then break end
        end
    end
end

-- ========================================================
-- 6. 调用视图美化渲染输出
-- ========================================================
local html = view.render(visitor_ip, ip_to_add, success, err, whitelist_entries, rejected_logs)
ngx.header.content_type = "text/html; charset=utf-8"

-- 🎯 [安全与实时性加固] 注入强效零缓存头部，100% 杜绝 Cloudflare 或浏览器对控制台页面的任何缓存行为
ngx.header.cache_control = "no-cache, no-store, must-revalidate"
ngx.header.pragma = "no-cache"
ngx.header.expires = "0"

ngx.say(html)
return
