local _M = {}
local config = require("config")
local whitelist_file_path = config.whitelist_db_path
local lock_dir_path = "/dev/shm/whitelist_lock"

-- 🚀 [多 Worker 并发防覆盖调优]
-- 采用 POSIX 原子目录操作 mkdir 作为分布式排他锁，杜绝高并发下的读写冲突
local function acquire_lock()
    local max_attempts = 40
    local delay = 0.05 -- 50ms
    for i = 1, max_attempts do
        local ok = os.execute("mkdir " .. lock_dir_path .. " 2>/dev/null")
        if ok then
            return true
        end
        ngx.sleep(delay)
    end
    return false
end

local function release_lock()
    os.execute("rmdir " .. lock_dir_path .. " 2>/dev/null")
end

-- 🎯 从物理 RAM 磁盘加载现有白名单缓存到共享字典，实现微秒级冷启动
function _M.load_to_shared_dict()
    local dict = ngx.shared.whitelist_dict
    if not dict then return end

    local file, err = io.open(whitelist_file_path, "r")
    if not file then
        -- 即使白名单文件不存在，也要标记系统已载入，避免后续频繁触发 file IO 读取
        dict:set("system_loaded", true)
        return
    end

    local current_time = ngx.time()
    for line in file:lines() do
        local ip, expiry_str = string.match(line, "([^=]+)=([^=]+)")
        if ip and expiry_str then
            local expiry_time = tonumber(expiry_str)
            if expiry_time and expiry_time >= current_time then
                local ttl = expiry_time - current_time
                dict:set(ip, expiry_time, ttl)
            end
        end
    end
    file:close()
    
    -- 🚀 [修复] 标记冷启动已全量装载完毕，保证之后 cache miss 达到真正的零 I/O 穿透
    dict:set("system_loaded", true)
end

function _M.check(ip)
    if not ip or ip == "" then return false end
    
    local dict = ngx.shared.whitelist_dict
    if not dict then
        -- 降级到纯文件直接读取逻辑 (防灾兜底)
        local file = io.open(whitelist_file_path, "r")
        if not file then return false end
        local current_time = ngx.time()
        for line in file:lines() do
            local existing_ip, expiry_str = string.match(line, "([^=]+)=([^=]+)")
            if existing_ip == ip then
                local expiry_time = tonumber(expiry_str)
                if expiry_time and expiry_time >= current_time then
                    file:close()
                    return true
                end
            end
        end
        file:close()
        return false
    end
    
    local current_time = ngx.time()
    local expiry_time = dict:get(ip)
    if expiry_time then
        if type(expiry_time) == "number" then
            if expiry_time >= current_time then
                return true
            else
                dict:delete(ip)
                return false
            end
        end
    end
    
    -- 🚀 [极致安全加固：抵御恶意扫描器的高并发探测扫端口暴风雨]
    -- 如果检测到白名单已经冷启动全量装载完毕，那么缓存未中即代表绝对未授权，直接返回 false！
    -- 这项重磅优化使得外部一切恶意随机 IP 的探测请求，在 Nginx 层面将 100% 免疫任何物理文件 I/O 读取，将攻击者的 I/O 消耗完美降为 0！
    local system_loaded = dict:get("system_loaded")
    if not system_loaded then
        _M.load_to_shared_dict()
        expiry_time = dict:get(ip)
        if expiry_time and type(expiry_time) == "number" and expiry_time >= current_time then
            return true
        end
    end
    
    return false
end

function _M.add(ip_to_add)
    if not ip_to_add or ip_to_add == "" then return false, "IP cannot be empty" end
    
    -- 尝试获取互斥锁
    if not acquire_lock() then
        ngx.log(ngx.ERR, "[whitelist] 无法获取写锁以添加 IP: ", ip_to_add)
        return false, "failed to acquire write lock"
    end

    local config = require("config")
    local ttl_seconds = config.ttl_seconds
    local expiry_time = ngx.time() + ttl_seconds
    local new_line = ip_to_add .. "=" .. expiry_time .. "\n"
    local temp_path = whitelist_file_path .. ".tmp"
    
    local has_existing = false
    local existing_file = io.open(whitelist_file_path, "r")
    if existing_file then
        local temp_file, temp_err = io.open(temp_path, "w")
        if not temp_file then
            existing_file:close()
            release_lock()
            return false, "failed to open temp file for writing"
        end
        
        for line in existing_file:lines() do
            local existing_ip = string.match(line, "([^=]+)=")
            if existing_ip and existing_ip ~= ip_to_add then
                temp_file:write(line, "\n")
            else
                has_existing = true
            end
        end
        existing_file:close()
        
        temp_file:write(new_line)
        temp_file:close()
        
        -- 原子替换
        local ok = os.execute(string.format("mv %s %s", temp_path, whitelist_file_path))
        if not ok then
            release_lock()
            return false, "failed to rename temp whitelist file"
        end
    else
        local file, err = io.open(whitelist_file_path, "w")
        if not file then
            release_lock()
            return false, "failed to create whitelist file: " .. tostring(err)
        end
        file:write(new_line)
        file:close()
    end
    
    release_lock() -- 成功释放锁

    -- 🚀 同步写穿 (Write-Through) 到 C 共享内存，令所有 Worker 进程在微秒级立即生效！
    local dict = ngx.shared.whitelist_dict
    if dict then
        dict:set(ip_to_add, expiry_time, ttl_seconds)
    end
    
    -- 🎯 [安全与审计加固] 换成独立的 🔑 🔵 蓝色钥匙，与主连接的 🟢 绿色/黑名单的 🟤 褐色做出极为明显的视觉颜色和场景区分
    ngx.log(ngx.NOTICE, "🔑 🔵 [WHITELIST_ADDED] -> 成功向白名单中写入/更新受信任 IP: ", ip_to_add, "，授权有效生存时间 (TTL): ", ttl_seconds, " 秒。")

    return true
end

function _M.delete(ip_to_delete)
    if not ip_to_delete or ip_to_delete == "" then return false, "IP cannot be empty" end

    -- 尝试获取互斥锁
    if not acquire_lock() then
        ngx.log(ngx.ERR, "[whitelist] 无法获取写锁以删除 IP: ", ip_to_delete)
        return false, "failed to acquire write lock for delete"
    end

    local temp_path = whitelist_file_path .. ".tmp"
    local has_existing = false
    local existing_file = io.open(whitelist_file_path, "r")
    local lines = {}
    if existing_file then
        for line in existing_file:lines() do
            local existing_ip = string.match(line, "([^=]+)=")
            if existing_ip and existing_ip ~= ip_to_delete then
                table.insert(lines, line)
            else
                has_existing = true
            end
        end
        existing_file:close()
        
        local temp_file, temp_err = io.open(temp_path, "w")
        if not temp_file then
            release_lock()
            return false, "failed to open temp file for delete"
        end
        for _, line in ipairs(lines) do
            temp_file:write(line, "\n")
        end
        temp_file:close()

        local ok = os.execute(string.format("mv %s %s", temp_path, whitelist_file_path))
        if not ok then
            release_lock()
            return false, "failed to replace whitelist file in delete"
        end
    end

    release_lock() -- 成功释放锁

    -- 同步在物理共享内存中立即剔除
    local dict = ngx.shared.whitelist_dict
    if dict then
        dict:delete(ip_to_delete)
    end

    return true
end

return _M
