local _M = {}

-- 定义内存文件的路径与排他锁目录路径
local whitelist_file_path = "/dev/shm/whitelist.db"
local lock_dir_path = "/dev/shm/whitelist.lock"

-- 🚀 [多 Worker 并发防覆盖调优]
-- Nginx 多进程环境下，多个访客并发写入白名单或者后台过期清理任务并发触发时，
-- 如果没有互斥锁保护，会导致白名单文件被写穿覆盖、产生随机 IP 丢失。
-- 采用具有原子性的 `mkdir` 操作作为分布式互斥锁，确保独占访问。
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

function _M.add(ip_to_add)
    if not ip_to_add or ip_to_add == "" then return false, "IP to add cannot be empty" end
    
    -- 尝试获取互斥写锁
    if not acquire_lock() then
        ngx.log(ngx.ERR, "[http.whitelist] 无法获取文件写锁，写入超时被熔断: ", ip_to_add)
        return false, "failed to acquire write lock"
    end

    local ttl = tonumber(os.getenv("RG_WHITELIST_IP_TTL_SECONDS") or 86400)
    local expiry_time = ngx.time() + ttl
    local new_line = ip_to_add .. "=" .. expiry_time .. "\n"
    local temp_path = whitelist_file_path .. ".tmp"
    
    -- 读取现有白名单，移除同一 IP 的旧条目，写入临时文件
    local has_existing = false
    local existing_file = io.open(whitelist_file_path, "r")
    if existing_file then
        -- 有现有文件，逐行处理
        local temp_file, temp_err = io.open(temp_path, "w")
        if not temp_file then
            existing_file:close()
            release_lock() -- 释放锁
            ngx.log(ngx.ERR, "[http.whitelist] failed to open temp file: ", temp_err)
            return false, "failed to open temp file"
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
        
        -- 写入新条目
        temp_file:write(new_line)
        temp_file:close()
        
        -- 原子替换
        local rename_ok, _, rename_code = os.execute(string.format("mv %s %s", temp_path, whitelist_file_path))
        if not rename_ok then
            release_lock() -- 释放锁
            ngx.log(ngx.ERR, "[http.whitelist] failed to replace whitelist file, code: ", tostring(rename_code))
            return false, "failed to replace whitelist file"
        end
    else
        -- 文件不存在，直接创建
        local file, err = io.open(whitelist_file_path, "w")
        if not file then
            release_lock() -- 释放锁
            ngx.log(ngx.ERR, "[http.whitelist] failed to create whitelist file: ", err)
            return false, "failed to create whitelist file"
        end
        file:write(new_line)
        file:close()
    end
    
    release_lock() -- 成功写入，释放锁

    if has_existing then
        -- 🎯 [安全与审计加固] 模仿 RestyTunnel 日志颜色体系：换成独立的 🔑 🔵 蓝色钥匙，做出极为明显的视觉颜色和场景区分
        ngx.log(ngx.NOTICE, "🔑 🔵 [WHITELIST_ADDED] -> 刷新 IP '", ip_to_add, "' 的白名单 TTL, TTL: ", ttl, " 秒。")
    else
        ngx.log(ngx.NOTICE, "🔑 🔵 [WHITELIST_ADDED] -> 成功将 IP '", ip_to_add, "' 添加到白名单, TTL: ", ttl, " 秒。")
    end
    return true
end

function _M.delete(ip_to_delete)
    if not ip_to_delete or ip_to_delete == "" then return false, "IP to delete cannot be empty" end

    -- 尝试获取互斥写锁
    if not acquire_lock() then
        ngx.log(ngx.ERR, "[http.whitelist] 无法获取文件写锁，删除被熔断: ", ip_to_delete)
        return false, "failed to acquire write lock for delete"
    end

    local temp_path = whitelist_file_path .. ".tmp"
    local has_existing = false
    local existing_file = io.open(whitelist_file_path, "r")
    if existing_file then
        local temp_file, temp_err = io.open(temp_path, "w")
        if not temp_file then
            existing_file:close()
            release_lock()
            return false, "failed to open temp file for delete"
        end

        for line in existing_file:lines() do
            local existing_ip = string.match(line, "([^=]+)=")
            if existing_ip and existing_ip ~= ip_to_delete then
                temp_file:write(line, "\n")
            else
                has_existing = true
            end
        end
        existing_file:close()
        temp_file:close()

        local rename_ok, _, rename_code = os.execute(string.format("mv %s %s", temp_path, whitelist_file_path))
        if not rename_ok then
            release_lock()
            return false, "failed to replace whitelist file in delete"
        end
    end

    release_lock()
    
    -- 🎯 [安全与审计加固] 模仿 RestyTunnel 日志颜色体系：使用 🗑️ 🔴 红色垃圾桶，作为高危管理删除标识
    ngx.log(ngx.NOTICE, "🗑️ 🔴 [WHITELIST_DELETED] -> 成功从授权白名单中移除了 IP: ", ip_to_delete)
    return true
end

return _M
