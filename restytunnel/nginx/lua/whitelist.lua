local _M = {}
local config = require("config")
local iputil = require("iputil")
local whitelist_file_path = config.whitelist_db_path
local resty_lock = require "resty.lock"
local lock_dict_name = "whitelist_lock"
local lock_key = "whitelist"
local lock_opts = {timeout = 2, exptime = 5, step = 0.01, ratio = 2, max_step = 0.2}

local function with_lock(fn)
    local lock, err = resty_lock:new(lock_dict_name, lock_opts)
    if not lock then
        ngx.log(ngx.ERR, "[whitelist] failed to create lock: ", err)
        return false, "failed to create lock: " .. (err or "unknown")
    end
    local elapsed, err = lock:lock(lock_key)
    if not elapsed then
        return false, "failed to acquire write lock: " .. (err or "timeout")
    end
    local ok, res1, res2 = pcall(fn)
    local unlock_ok, unlock_err = lock:unlock()
    if not unlock_ok then
        ngx.log(ngx.WARN, "[whitelist] unlock failed (may have expired): ", tostring(unlock_err))
    end
    if not ok then
        ngx.log(ngx.ERR, "[whitelist] locked operation error: ", tostring(res1))
        return false, tostring(res1)
    end
    return res1, res2
end

local function tmp_path()
    -- unique per worker + timestamp to avoid .tmp collision
    return string.format("%s.tmp.%d.%d", whitelist_file_path, ngx.worker.pid(), math.floor(ngx.now()*1000))
end

-- 从物理 RAM 磁盘加载现有白名单缓存到共享字典，实现微秒级冷启动
function _M.load_to_shared_dict()
    local dict = ngx.shared.whitelist_dict
    if not dict then return end

    local file, err = io.open(whitelist_file_path, "r")
    if not file then
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
    dict:set("system_loaded", true)
end

function _M.check(ip)
    if not ip or ip == "" then return false end
    local dict = ngx.shared.whitelist_dict
    if not dict then
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
    if not iputil.is_valid_ip(ip_to_add) then return false, "invalid IP format" end
    return with_lock(function()
        local ttl_seconds = config.ttl_seconds
        local expiry_time = ngx.time() + ttl_seconds
        local new_line = ip_to_add .. "=" .. expiry_time .. "\n"
        local tpath = tmp_path()
        local existing_file = io.open(whitelist_file_path, "r")
        if existing_file then
            local temp_file, temp_err = io.open(tpath, "w")
            if not temp_file then
                existing_file:close()
                return false, "failed to open temp file for writing: " .. tostring(temp_err)
            end
            for line in existing_file:lines() do
                local existing_ip = string.match(line, "([^=]+)=")
                if existing_ip and existing_ip ~= ip_to_add then
                    temp_file:write(line, "\n")
                end
            end
            existing_file:close()
            temp_file:write(new_line)
            temp_file:close()
            local ok = os.execute(string.format("mv %s %s", iputil.shell_quote(tpath), iputil.shell_quote(whitelist_file_path)))
            if not ok then
                os.execute(string.format("rm -f %s", iputil.shell_quote(tpath)))
                return false, "failed to rename temp whitelist file"
            end
        else
            local file, err = io.open(whitelist_file_path, "w")
            if not file then
                return false, "failed to create whitelist file: " .. tostring(err)
            end
            file:write(new_line)
            file:close()
        end
        local dict = ngx.shared.whitelist_dict
        if dict then
            dict:set(ip_to_add, expiry_time, ttl_seconds)
        end
        local blacklist = require("blacklist")
        blacklist.clear(ip_to_add)
        ngx.log(ngx.NOTICE, "🔑 🔵 [WHITELIST_ADDED] -> 成功向白名单中写入/更新受信任 IP: ", ip_to_add, "，授权有效生存时间 (TTL): ", ttl_seconds, " 秒。")
        return true
    end)
end

function _M.delete(ip_to_delete)
    if not ip_to_delete or ip_to_delete == "" then return false, "IP cannot be empty" end
    if not iputil.is_valid_ip(ip_to_delete) then return false, "invalid IP format" end
    return with_lock(function()
        local tpath = tmp_path()
        local existing_file = io.open(whitelist_file_path, "r")
        local lines = {}
        local found = false
        if existing_file then
            for line in existing_file:lines() do
                local existing_ip = string.match(line, "([^=]+)=")
                if existing_ip and existing_ip ~= ip_to_delete then
                    table.insert(lines, line)
                elseif existing_ip == ip_to_delete then
                    found = true
                end
            end
            existing_file:close()
            local temp_file, temp_err = io.open(tpath, "w")
            if not temp_file then
                return false, "failed to open temp file for delete: " .. tostring(temp_err)
            end
            for _, line in ipairs(lines) do
                temp_file:write(line, "\n")
            end
            temp_file:close()
            local ok = os.execute(string.format("mv %s %s", iputil.shell_quote(tpath), iputil.shell_quote(whitelist_file_path)))
            if not ok then
                os.execute(string.format("rm -f %s", iputil.shell_quote(tpath)))
                return false, "failed to replace whitelist file in delete"
            end
        end
        local dict = ngx.shared.whitelist_dict
        if dict then
            dict:delete(ip_to_delete)
        end
        return true
    end)
end

return _M
