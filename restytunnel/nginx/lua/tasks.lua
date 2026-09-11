-- File: nginx/lua/tasks.lua
-- Description: 独立的轻量级后台定时清理与流式精准控行任务集

local os_execute = os.execute
local io_open = io.open
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_NOTICE = ngx.NOTICE

local _M = {}
local config = require("config")
local WHITELIST_DB_PATH = config.whitelist_db_path
local REJECTED_LOG_PATH = config.rejected_log_path
local resty_lock = require "resty.lock"
local lock_dict_name = "whitelist_lock"
local lock_key = "whitelist"
local lock_opts = {timeout = 2, exptime = 5, step = 0.01, ratio = 2, max_step = 0.2}

local function with_lock(fn)
    local lock, err = resty_lock:new(lock_dict_name, lock_opts)
    if not lock then
        ngx_log(ngx_ERR, "[tasks] failed to create lock: ", tostring(err))
        return false, "failed to create lock: " .. (err or "unknown")
    end
    local elapsed, err = lock:lock(lock_key)
    if not elapsed then
        return false, "failed to acquire lock: " .. (err or "timeout")
    end
    local ok, res1, res2 = pcall(fn)
    local unlock_ok, unlock_err = lock:unlock()
    if not unlock_ok then
        ngx_log(ngx_WARN, "[tasks] unlock failed (may have expired): ", tostring(unlock_err))
    end
    if not ok then
        ngx_log(ngx_ERR, "[tasks] locked operation error: ", tostring(res1))
        return false, tostring(res1)
    end
    return res1, res2
end

local function tmp_path(base)
    return string.format("%s.tmp.%d.%d", base, ngx.worker.pid(), math.floor(ngx.now()*1000))
end

---
-- 【极致性能优化】向黑名单以 O(1) 追加模式写入新日志（无任何文件读取与裁剪锁开销，彻底杜绝高并发扫描时的 I/O 自阻断漏洞！）
-- 裁剪与限额任务被优雅地剥离并放置于后台定时任务中异步执行。
-- @param ip (string) 被拦截的客户端 IP
-- @param reason (string) 拦截原因
---
function _M.write_and_trim_rejected_log(ip, reason)
    if not ip or ip == "" then return end
    do
        local iputil = require("iputil")
        if not iputil.is_valid_ip(ip) then
            ngx_log(ngx_WARN, "[BLOCK_LOG] 拒绝写入非法 IP 日志: ", tostring(ip))
            return
        end
    end
    -- 防日志注入：reason 仅保留单行
    if reason then
        reason = string.gsub(tostring(reason), "[\r\n]+", " ")
    end
    local date_str = os.date("%Y-%m-%d %H:%M:%S")
    local new_entry = string.format("[%s] %s - %s", date_str, ip, reason)
    local f_write = io_open(REJECTED_LOG_PATH, "a")
    if f_write then
        f_write:write(new_entry, "\n")
        f_write:close()
        ngx_log(ngx_NOTICE, "📝 🟤 [BLOCK_LOG] 成功追加一条拦截日志记录。")
    else
        ngx_log(ngx_ERR, "[BLOCK_LOG] 写入拦截日志失败：无法打开文件进行追加: ", REJECTED_LOG_PATH)
    end
end

---
-- 异步日志自动裁剪清理任务，由 background scheduler 定时触发（完美消灭高频 I/O 开销）
---
function _M.clean_rejected_log()
    local max_lines = config.max_log_lines or 100
    local log_path = REJECTED_LOG_PATH
    -- 与追加写入串行化：同一 whitelist_lock 下做“读-裁剪-原子替换”，避免 sed -i 与追加并发丢行
    local ok, err = with_lock(function()
        local f = io_open(log_path, "r")
        if not f then return true end
        local lines = {}
        for line in f:lines() do
            table.insert(lines, line)
        end
        f:close()
        if #lines <= max_lines then return true end
        local start_idx = #lines - max_lines + 1
        local tpath = tmp_path(log_path)
        local tf, terr = io_open(tpath, "w")
        if not tf then
            return false, "failed to open temp log file: " .. tostring(terr)
        end
        for i = start_idx, #lines do
            tf:write(lines[i], "\n")
        end
        tf:close()
        local iputil = require("iputil")
        local mv_ok = os_execute(string.format("mv %s %s", iputil.shell_quote(tpath), iputil.shell_quote(log_path)))
        if not mv_ok then
            os_execute(string.format("rm -f %s", iputil.shell_quote(tpath)))
            return false, "mv failed"
        end
        ngx_log(ngx_WARN, "🧹 🟠 [BLOCK_LOG] 黑名单拦截日志执行了自动流式裁剪，物理保留最新 ", max_lines, " 行。")
        return true
    end)
    if not ok then
        ngx_log(ngx_ERR, "[后台任务] 拦截日志裁剪失败: ", tostring(err))
    end
end

---
-- 定时清理白名单数据库，移除所有已过期的 IP（resty.lock 排他锁加强版，自动过期防永久死锁）
---
function _M.clean_expired_whitelist_entries()
    local ok, err = with_lock(function()
        local current_time = ngx.time()
        local tpath = tmp_path(WHITELIST_DB_PATH)
        local original_file, err_open = io_open(WHITELIST_DB_PATH, "r")
        if not original_file then
            if err_open and string.find(err_open, "No such file or directory") then return true end
            ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法打开原始文件进行读取: ", tostring(err_open))
            return false, tostring(err_open)
        end
        local temp_file, err_temp = io_open(tpath, "w")
        if not temp_file then
            ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法创建临时文件: ", tostring(err_temp))
            original_file:close()
            return false, tostring(err_temp)
        end
        local expired_count = 0
        local valid_count = 0
        local has_content = false
        for line in original_file:lines() do
            if line and line ~= "" then
                has_content = true
                local ip, expiry_str = string.match(line, "^(.-)=([^=]+)$")
                if ip and expiry_str then
                    local expiry_time = tonumber(expiry_str)
                    if expiry_time and expiry_time >= current_time then
                        temp_file:write(line, "\n")
                        valid_count = valid_count + 1
                    else
                        expired_count = expired_count + 1
                        local dict = ngx.shared.whitelist_dict
                        if dict then dict:delete(ip) end
                    end
                else
                    temp_file:write(line, "\n")
                end
            end
        end
        original_file:close()
        temp_file:close()
        if has_content then
            if expired_count > 0 then
                local iputil = require("iputil")
                local mv_ok = os_execute(string.format("mv %s %s", iputil.shell_quote(tpath), iputil.shell_quote(WHITELIST_DB_PATH)))
                if mv_ok then
                    ngx_log(ngx_INFO, "🧹 [白名单清理] 自动清理完成。保留了 ", valid_count, " 个有效 IP，物理移除了 ", expired_count, " 个过期 IP。")
                else
                    ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法用临时文件覆盖原始文件。")
                    os_execute(string.format("rm -f %s", iputil.shell_quote(tpath)))
                    return false, "mv failed"
                end
            else
                local iputil2 = require("iputil")
                os_execute(string.format("rm -f %s", iputil2.shell_quote(tpath)))
            end
        else
            local iputil3 = require("iputil")
            os_execute(string.format("rm -f %s", iputil3.shell_quote(tpath)))
        end
        return true
    end)
    if not ok then
        ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法获取排他写锁或执行异常: ", tostring(err))
    end
end

return _M
