local lrucache = require "resty.lrucache"
local _M = {}

local whitelist_file_path = "/dev/shm/whitelist.db"
local whitelist_cache, err = lrucache.new(10000)
if not whitelist_cache then
    ngx.log(ngx.ERR, "failed to create lrucache: ", err)
end

-- 🚀 [高并发防 I/O 刺探调优]
-- 记录上一次读取物理白名单文件的绝对时间戳，限制最小重载间隔。
local last_load_time = 0
local MIN_RELOAD_INTERVAL_SECONDS = 2  -- 限制每 2 秒至多允许重载 1 次物理文件

local function load_whitelist_into_cache()
    local file, err = io.open(whitelist_file_path, "r")
    if not file then
        if string.find(err, "No such file or directory") then
            return
        end
        ngx.log(ngx.WARN, "[check_whitelist] 无法打开白名单文件进行读取: ", err)
        return
    end

    local current_time = ngx.time()
    for line in file:lines() do
        local ip, expiry_str = string.match(line, "([^=]+)=([^=]+)")
        if ip and expiry_str then
            local expiry_time = tonumber(expiry_str)
            if expiry_time and expiry_time >= current_time then
                local ttl = expiry_time - current_time
                whitelist_cache:set(ip, expiry_time, ttl)
            end
        end
    end
    file:close()
    ngx.log(ngx.INFO, "[check_whitelist] 物理白名单文件重载预载完毕。")
end

function _M.is_allowed()
    -- 直接使用由 nginx.conf 中 map 指令计算好的变量
    local client_ip = ngx.var.stream_client_ip

    if not client_ip or client_ip == "" then
        return false, "Could not get client IP from $stream_client_ip"
    end
    
    local expiry_time = whitelist_cache:get(client_ip)
    
    -- 🚀 [极致速度与防御调优：负防缓存 (Negative Caching)]
    -- 如果该 IP 在高速 LRU 缓存中被标记为 "BLOCKED" 恶意扫描 IP，
    -- 我们不需要进行任何繁复的提取或文件判断，100% 内存命中当场秒回阻断！
    if expiry_time == "BLOCKED" then
        return false, "IP is negative-cached as BLOCKED"
    end
    
    if not expiry_time then
        -- 🚀 缓存未命中（Cache Miss）时的安全限速逻辑，熔断物理 I/O 穿透
        local now = ngx.time()
        if now - last_load_time >= MIN_RELOAD_INTERVAL_SECONDS then
            last_load_time = now
            load_whitelist_into_cache()
            expiry_time = whitelist_cache:get(client_ip)
            
            if not expiry_time then
                -- 🚀 [负防缓存写入]
                -- 在物理文件重新加载读取之后，该 IP 依然没有在白名单内命中。
                -- 我们将其作为 "BLOCKED" 存入 LRU 缓存并分配极短过期时间（3秒），抗击瞬时高并发刺探。
                whitelist_cache:set(client_ip, "BLOCKED", 3)
                return false, "IP not found in whitelist and negative-cached"
            end
        else
            -- 处于高并发限流惩罚期，不执行任何磁盘/内存盘 I/O，直接快速静默阻断
            -- 同时也写入 1 秒的超短临时阻断缓存，极速提速其下一次并发刺探的内存熔断
            whitelist_cache:set(client_ip, "BLOCKED", 1)
            return false, "IP not in cache, and reload is rate-limited (anti-DoS active)"
        end
    end
    
    if expiry_time < ngx.time() then
        return false, "IP found but has expired in cache"
    end
    
    return true, "OK"
end

return _M
