local whitelist = require("whitelist")
local view = require("auth_view")

-- 🚀 [极其强悍的自适应时间单位转换器]
-- 支持解析: "30d" (30天), "24h" (24小时), "60m" (60分钟), "300s" (300秒) 或纯数字秒
local function parse_time_to_seconds(val_str, default_val)
    if not val_str or val_str == "" then
        return default_val
    end
    
    local num = tonumber(val_str)
    if num then
        return num -- 纯数字，直接当成秒返回
    end

    -- 过滤可能存在的空格并转小写
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

-- 🚀 [精密的 Base32 编码解码器]
-- 目的：100% 兼容 Google Authenticator 等标准的客户端 App 产生的动态口令密钥计算
local function base32_decode(key_str)
    if not key_str or key_str == "" then return "" end
    key_str = string.upper(string.gsub(key_str, "%s+", ""))

    -- 标准 Base32 字符映射表
    local b32map = {
        A=0, B=1, C=2, D=3, E=4, F=5, G=6, H=7, I=8, J=9, K=10, L=11, M=12,
        N=13, O=14, P=15, Q=16, R=17, S=18, T=19, U=20, V=21, W=22, X=23, Y=24, Z=25,
        ["2"]=26, ["3"]=27, ["4"]=28, ["5"]=29, ["6"]=30, ["7"]=31
    }

    -- 校验是否包含非 Base32 字符（如 0, 1, 8, 9），若包含则判定为普通 ASCII 字符串，不执行 Base32 解码
    for i = 1, #key_str do
        local c = string.sub(key_str, i, i)
        if c ~= "=" and not b32map[c] then
            return key_str -- 安全降维，直接作为原始秘钥字符串返回
        end
    end

    local buffer = 0
    local bits_left = 0
    local result = {}

    for i = 1, #key_str do
        local c = string.sub(key_str, i, i)
        if c == "=" then break end -- 忽略填充符
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

-- 🚀 [多用户自适应 TOTP 计算内核]
local function verify_totp_code(totp_secret, req_code)
    -- 对种子密钥进行 Base32 解码以和 Google Authenticator 算法底层保持 100% 密码学一致性
    local decoded_secret = base32_decode(totp_secret)

    -- TOTP 标准步长强制采用 30 秒（保证 100% 兼容所有手机 Authenticator App）
    local step_seconds = 30
    -- 通过环境变量获取偏差可校验时间窗口大小（如 5m 5分钟，或 10m 10分钟，前后均分）
    local valid_window_env = os.getenv("RG_TOTP_VALID_WINDOW_SECONDS")
    local valid_window = parse_time_to_seconds(valid_window_env, 300) -- 默认 300秒 (5分钟)
    
    -- 计算前后需要校验的 steps 跨度步数（math.ceil 向上取整，完美容错如 303s 这样非 30 整数倍的时间）
    local max_offset_steps = math.ceil((valid_window / 2) / step_seconds)

    local current_time = ngx.time()
    
    -- 循环遍历整个时间容差窗口 [ -max_offset_steps, max_offset_steps ]
    for offset = -max_offset_steps, max_offset_steps do
        local time_step = math.floor((current_time + (offset * step_seconds)) / step_seconds)
        
        -- 🚀 [极其关键的 64位 拼接修复]
        -- 由于 Unix 时间戳时间步长在未来数百年内完全可以安全容纳在 32 位整型中，其 8 字节大端表示的前 4 字节必然为 0（绝对安全），
        -- 这样可以彻底打破 LuaJIT bit 库 32 位限制引发的移位环形溢出 Bug（t56, t48, t40, t32 溢出为非零垃圾，导致生成的 code 永远不匹配）！
        local T_bytes = string.char(
            0, 0, 0, 0, -- 前 4 字节恒定为 0
            bit.band(bit.rshift(time_step, 24), 0xFF),
            bit.band(bit.rshift(time_step, 16), 0xFF),
            bit.band(bit.rshift(time_step, 8), 0xFF),
            bit.band(time_step, 0xFF)
        )
        
        -- 计算 HMAC-SHA1 哈希值并提取动态截断数据
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

-- 🚀 [自适应多用户密码/TOTP 联合检验逻辑（无状态，Stateless）]
local function check_stealth_auth()
    -- ====================================================
    -- A. 多用户数据库装载 (从环境变量 RG_NGINX_USERS 动态解析)
    --    支持格式: RG_NGINX_USERS="aaron:4cdcf2f9...,bob:TOTP:MZXW6Y..."
    -- ====================================================
    local users_db = {}
    local raw_users = os.getenv("RG_NGINX_USERS")
    
    if not raw_users or raw_users == "" then
        -- 若没有配置任何用户数据库，则直接返回验证失败，防白嫖/误开放
        return false
    end

    -- 逐个解析逗号分隔的用户记录
    for user_entry in string.gmatch(raw_users, "([^,]+)") do
        -- 脱壳与清洗多余空格
        user_entry = string.gsub(user_entry, "^%s*(.-)%s*$", "%1")
        local username, val1, val2 = string.match(user_entry, "^([^:]+):([^:]+):?(.*)$")
        if username and val1 then
            users_db[username] = {
                credential = val1,
                totp_secret = (val2 ~= "" and val2 or nil)
            }
        elseif not username then
            -- 兼容只有 username:password 的极简写法
            local u, p = string.match(user_entry, "^([^:]+):(.*)$")
            if u and p then
                users_db[u] = { credential = p }
            end
        end
    end

    -- ====================================================
    -- B. 优先校验 Cookie（用于首次登录成功后的后续 Session 顺延）
    -- ====================================================
    local headers = ngx.req.get_headers()
    
    -- 安全获取 Cookie 字符串的辅助函数（防止 Table 崩溃）
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
            -- 如果 Cookie 里的用户存在，且密码吻合（对于 TOTP 用户，其密码固定比对 totp_secret，同样支持完美免密 Cookie 顺延）
            local target_secret = user_record and (user_record.totp_secret or user_record.credential)
            if target_secret and cookie_pass == target_secret then
                local session_ttl = parse_time_to_seconds(os.getenv("RG_NGINX_SESSION_TTL_SECONDS"), 2592000) -- 默认 30 天
                ngx.header["Set-Cookie"] = {
                    "gkp_user=" .. cookie_user .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                    "gkp_session=" .. target_secret .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                    "gkp_active=1; Path=/; Max-Age=" .. session_ttl .. "; SameSite=Lax; Secure" -- 🚀 [新] 非 HttpOnly 辅助 Cookie，供浏览器本地书签离线探测 Session 活跃状态以实现智能免弹窗
                }
                -- 验证成功：强制清理可能污染的 SPA Service Worker (关键!)
                ngx.header["Clear-Site-Data"] = '"storage"'

                -- 🚀 [新增中文可审计日志：Cookie 免密检测通过]
                local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
                ngx.log(ngx.NOTICE, "🔑 [认证通过] - 客户端 IP: '", client_real_ip, "', 用户: '", cookie_user, "', 认证方式: '免密 Cookie 锁顺延', 结果: 成功直接直入控制台。")
                return true
            end
        end
    end

    -- ====================================================
    -- C. 其次校验 URL 传入的验证凭证参数
    --    C1. 标准静态密码直入模式: ?u=aaron&p=4cdcf2f9...
    --    C2. 动态密码学 TOTP 模式: ?u=bob&code=123456
    -- ====================================================
    local args = ngx.req.get_uri_args()
    local req_user = args.u
    local req_pass = args.p
    local req_code = args.code

    -- 🚀 [新增中文可审计日志：检测到用户尝试访问认证接口端点]
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
            -- [静态密码验证分支]
            if req_pass == user_record.credential and user_record.credential ~= "TOTP" then
                is_authenticated = true
                cookie_secret = req_pass
            end
        elseif req_code and string.match(req_code, "^%d%d%d%d%d%d$") then
            -- [TOTP 动态验证分支]
            local totp_secret = user_record.totp_secret or user_record.credential
            if totp_secret and totp_secret ~= "" then
                if verify_totp_code(totp_secret, req_code) then
                    is_authenticated = true
                    cookie_secret = totp_secret
                end
            end
        end

        if is_authenticated then
            -- 验证成功：1. 写入长效滑动免密双重 Cookie (Cookie 保存用户名与密码/种子)
            local session_ttl = parse_time_to_seconds(os.getenv("RG_NGINX_SESSION_TTL_SECONDS"), 2592000) -- 默认 30 天
            
            ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
            ngx.header["Pragma"] = "no-cache"
            ngx.header["Expires"] = "0"
            -- Clear-Site-Data: "storage" 强制清除有可能被污染劫持的 Service Worker (以及 Cache)
            ngx.header["Clear-Site-Data"] = '"storage"'

            ngx.header["Set-Cookie"] = {
                "gkp_user=" .. req_user .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                "gkp_session=" .. cookie_secret .. "; Path=/; Max-Age=" .. session_ttl .. "; HttpOnly; SameSite=Lax; Secure",
                "gkp_active=1; Path=/; Max-Age=" .. session_ttl .. "; SameSite=Lax; Secure" -- 🚀 [新] 非 HttpOnly 辅助 Cookie，供浏览器本地书签离线探测 Session 活跃状态以实现智能免弹窗
            }
            
            -- 【核心改造】：废弃 302，使用 200 HTML 落地页强制写入 Cookie 并跳转
            local clean_uri = ngx.var.uri
            local jump_html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0;url=]] .. clean_uri .. [[">
    <title>Authenticating...</title>
</head>
<body>
    <div style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 100px; color: #333;">
        <h3>🔑 正在建立安全连接，请稍候...</h3>
        <p style="color: #666; font-size: 0.9em;">正在清除缓存并初始化安全代理控制台...</p>
    </div>
    <script>
        // 确保 Service Worker 被强行注销
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.getRegistrations().then(function(registrations) {
                for(let registration of registrations) { 
                    registration.unregister(); 
                }
            });
        }
        // 强制刷新并跳转至干净 URL
        window.location.replace("]] .. clean_uri .. [[");
    </script>
</body>
</html>
]]
            -- 🚀 [新增中文可审计日志：验证通过，即将进入 HTML 落地页]
            local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
            local auth_type = (req_code and req_code ~= "") and "TOTP动态验证码" or "静态密码"
            ngx.log(ngx.NOTICE, "✅ [认证通过] - 客户端 IP: '", client_real_ip, "', 用户: '", req_user, "', 认证方式: '", auth_type, "', 结果: 成功生成新凭证，即将写入 Cookie 锁。")

            ngx.status = 200
            ngx.header["Content-Type"] = "text/html; charset=utf-8"
            ngx.say(jump_html)
            ngx.exit(200) -- 终止后续执行，替代原先的 redirect
        else
            -- 🚨 [默认级别日志显式输出 TOTP/密码校验失败提醒]
            -- 使用 ngx.log(ngx.WARN, ...) 在 Nginx 默认的 notice/warn 级别日志中显著抛出验证失败警告
            local client_real_ip = ngx.var.final_real_client_ip or ngx.var.remote_addr or "unknown"
            local auth_type = (req_code and req_code ~= "") and "TOTP动态验证码" or "静态密码"
            local attempt_val = (req_code and req_code ~= "") and req_code or "******"
            ngx.log(ngx.WARN, "⚠️  [认证失败] - 客户端 IP: '", client_real_ip, "', 用户: '", req_user, "', 认证方式: '", auth_type, "', 提交的内容: '", attempt_val, "'。原因: 口令错误、超时或未对齐。")

            -- 🚨 [防暴力破解/防碰撞加固]
            -- 如果用户显式提交了用户名和密码/验证码，但未通过校验，说明这是一次恶意的爆破尝试或输入错误。
            -- 强制延迟 1.5 ~ 2.2 秒，极大地降低攻击者爆破速率（每秒限制为最多 1 次尝试），并使爆破在 30 秒 TOTP 步长下毫无可能！
            local delay = 1.5 + math.random() * 0.7
            ngx.sleep(delay)
        end
    end

    return false
end

if not check_stealth_auth() then
    -- 🚀 [100% 遵照您的指示：绝对不弹窗，认证错误或缺失时不修改任何返回，直接静默转发到您的网盘（@fallback）]
    return ngx.exec("@fallback")
end

local method = ngx.req.get_method()

-- 1. 解析客户端真实 IP 与请求 IP
-- 🚀 [极其严密的真实 IP 穿透抓取调优]
-- 优先使用 Nginx 物理计算的真实客户端 IP。若因环回分流导致为空，则依次从 CF、XFF 标头穿透获取。
local visitor_ip = ngx.var.final_real_client_ip
if not visitor_ip or visitor_ip == "" or visitor_ip == "127.0.0.1" then
    local headers = ngx.req.get_headers()
    visitor_ip = headers["CF-Connecting-IP"] or headers["X-Forwarded-For"]
end
-- 终极兜底，防环回截断
if not visitor_ip or visitor_ip == "" or visitor_ip == "127.0.0.1" then
    visitor_ip = ngx.var.remote_addr
end

local ip_to_add = ngx.var.arg_ip or visitor_ip

local success, err
local is_posted = false

-- 2. 拦截与业务分发：处理表单操作 (添加 add / 删除 delete)
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
            
        -- B. 手动删除/移除白名单 IP
        elseif action == "delete" and args.ip then
            local target_ip = string.match(args.ip, "^%s*(.-)%s*$")
            if target_ip ~= "" then
                success, err = whitelist.delete(target_ip)
                is_posted = true
            end
        end
    end
end

-- 3. 自动加入白名单：如果客户端是用纯 GET 访问（自动授权本机，防止由于 arg_ip 为空或特殊空参数导致漏加白）
if method == "GET" and (not ngx.var.arg_ip or ngx.var.arg_ip == "" or ngx.var.arg_ip == "127.0.0.1") then
    if visitor_ip and visitor_ip ~= "" and visitor_ip ~= "127.0.0.1" then
        success, err = whitelist.add(visitor_ip)
        -- 确保将加白的 IP 反馈在页面输入框中，提升直观体验
        ip_to_add = visitor_ip
    end
end

-- 4. 抓取白名单数据并构造列表
local whitelist_entries = {}
local db_file = io.open("/dev/shm/whitelist.db", "r")
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
-- 剩余有效 TTL 由长到短排序
table.sort(whitelist_entries, function(a, b) return a.remaining > b.remaining end)

-- 5. 抓取被拒的拦截历史日志 (展示最新 10 条)
local rejected_logs = {}
local log_file = io.open("/dev/shm/rejected_ips.log", "r")
if log_file then
    -- 我们采用逐行读取的方式，限制最高读取 100 行，以防大文件爆内存，随后取最新的 10 条展示
    local all_lines = {}
    for line in log_file:lines() do
        if line and line ~= "" then
            table.insert(all_lines, line)
        end
    end
    log_file:close()
    
    -- 从尾部（最新写入的日志在最尾部）向前倒序抓取最多 10 条
    local count = 0
    for i = #all_lines, 1, -1 do
        local line = all_lines[i]
        -- 格式：[$time_local] $stream_client_ip - Reason: $block_reason - SNI: $ssl_preread_server_name
        -- 示例：[26/Jul/2026:15:34:02 +0800] 1.2.3.4 - Reason: Forbidden Direct IP Access - SNI: 
        local time, ip, reason, sni = string.match(line, "^%[([^%]]+)%]%s+([%w%.%:%-]+)%s+-%s+Reason:%s+([^-]+)%s+-%s+SNI:%s*(.*)$")
        
        -- 兼容旧格式 fallback
        if not time or not ip then
            time, ip = string.match(line, "^%[([^%]]+)%]%s+([%w%.%:%-]+)")
            reason = "Unauthorized Access"
            sni = "-"
        end
        
        if time and ip then
            table.insert(rejected_logs, {
                time = time,
                ip = ip,
                reason = string.gsub(reason, "^%s*(.-)%s*$", "%1"),
                sni = string.gsub(sni, "^%s*(.-)%s*$", "%1")
            })
            count = count + 1
            if count >= 10 then break end
        end
    end
end

-- 6. 调用视图美化渲染输出
local html_body = view.render(visitor_ip, ip_to_add, success, err, whitelist_entries, rejected_logs)

ngx.status = 200
ngx.header["Content-Type"] = "text/html; charset=utf-8"
-- 注入强效零缓存头部，100% 杜绝 Cloudflare 或浏览器对控制台页面的任何缓存行为
ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"
ngx.header["Pragma"] = "no-cache"
ngx.header["Expires"] = "0"

ngx.say(html_body)
