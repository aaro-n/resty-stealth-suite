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
local lock_dir_path = "/dev/shm/whitelist_lock"

-- 🚀 [多 Worker 并发防覆盖调优]
-- 采用 POSIX 原子目录操作 mkdir 作为分布式排他锁，杜绝高并发下的读写冲突
local function acquire_lock()
    local max_attempts = 40
    local delay = 0.05 -- 50ms
    for i = 1, max_attempts do
        local ok = os_execute("mkdir " .. lock_dir_path .. " 2>/dev/null")
        if ok then
            return true
        end
        ngx.sleep(delay)
    end
    return false
end

local function release_lock()
    os_execute("rmdir " .. lock_dir_path .. " 2>/dev/null")
end

---
-- 【极致性能优化】向黑名单以 O(1) 追加模式写入新日志（无任何文件读取与裁剪锁开销，彻底杜绝高并发扫描时的 I/O 自阻断漏洞！）
-- 裁剪与限额任务被优雅地剥离并放置于后台定时任务中异步执行。
-- @param ip (string) 被拦截的客户端 IP
-- @param reason (string) 拦截原因
---
function _M.write_and_trim_rejected_log(ip, reason)
    if not ip or ip == "" then return end
    
    local date_str = os.date("%Y-%m-%d %H:%M:%S")
    local new_entry = string.format("[%s] %s - %s", date_str, ip, reason)

    -- 🚀 [极致 O(1) 优化] 采用追加模式 "a" 直写文件，物理 I/O 开销压缩至微秒级
    local f_write = io_open(REJECTED_LOG_PATH, "a")
    if f_write then
        f_write:write(new_entry, "\n")
        f_write:close()
        -- 🎯 [安全与审计加固] 换成独立的 📝 🟤 褐色本子与笔图标，记录日志写入
        ngx_log(ngx_NOTICE, "📝 🟤 [BLOCK_LOG] 成功追加一条拦截日志记录。")
    else
        ngx_log(ngx_ERR, "[BLOCK_LOG] 写入拦截日志失败：无法打开文件进行追加: ", REJECTED_LOG_PATH)
    end
end

---
-- 🚀 [新增] 异步日志自动裁剪清理任务，由 background scheduler 定时触发（完美消灭高频 I/O 开销）
---
function _M.clean_rejected_log()
    local max_lines = config.max_log_lines or 100
    local log_path = REJECTED_LOG_PATH
    
    -- 使用高性能的系统管道 and sed 进行流式头部切断，保障 CPU 资源消耗极小
    local clean_command = string.format([[
        if [ ! -f %s ]; then exit 2; fi;
        TOTAL_LINES=$(wc -l < %s | tr -d ' ');
        LINES_TO_DELETE=$((TOTAL_LINES - %d));
        if [ $LINES_TO_DELETE -gt 0 ]; then
            sed -i "1,${LINES_TO_DELETE}d" %s && exit 0;
            exit 1;
        else
            exit 2;
        fi
    ]], 
    log_path, 
    log_path, 
    max_lines, 
    log_path
    )
    
    local clean_ok, _, clean_code = os_execute(clean_command)
    if clean_ok and clean_code == 0 then
        ngx_log(ngx_WARN, "🧹 🟠 [BLOCK_LOG] 黑名单拦截日志执行了自动流式裁剪，物理保留最新 ", max_lines, " 行。")
    end
end

---
-- 定时清理白名单数据库，移除所有已过期的 IP（排他锁加强版）
---
function _M.clean_expired_whitelist_entries()
    -- 尝试获取互斥锁
    if not acquire_lock() then
        ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法获取排他写锁（锁被占用）。")
        return
    end

    local current_time = ngx.time()
    local temp_file_path = WHITELIST_DB_PATH .. ".tmp"

    local original_file, err_open = io_open(WHITELIST_DB_PATH, "r")
    if not original_file then
        release_lock()
        if string.find(err_open, "No such file or directory") then return end
        ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法打开原始文件进行读取: ", err_open)
        return
    end

    local temp_file, err_temp = io_open(temp_file_path, "w")
    if not temp_file then
        ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法创建临时文件: ", err_temp)
        original_file:close()
        release_lock()
        return
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
                    -- 🎯 [双重保障同步] 在后台定时任务剔除过期 IP 时，同步将其在物理共享内存中移除，实现内存与硬盘的高保真一致性
                    local dict = ngx.shared.whitelist_dict
                    if dict then
                        dict:delete(ip)
                    end
                end
            else
                -- 格式不匹配的保留
                temp_file:write(line, "\n")
            end
        end
    end

    original_file:close()
    temp_file:close()

    if has_content then
        if expired_count > 0 then
            local ok, _, code = os_execute(string.format("mv %s %s", temp_file_path, WHITELIST_DB_PATH))
            if ok then
                ngx_log(ngx_INFO, "🧹 [白名单清理] 自动清理完成。保留了 ", valid_count, " 个有效 IP，物理移除了 ", expired_count, " 个过期 IP。")
            else
                ngx_log(ngx_ERR, "[后台任务] 白名单清理失败：无法用临时文件覆盖原始文件。返回码: ", code)
            end
        else
            -- 没有过期的 IP，直接删除临时文件，减少无意义 I/O
            os_execute(string.format("rm -f %s", temp_file_path))
        end
    else
        os_execute(string.format("rm -f %s", temp_file_path))
    end

    release_lock() -- 释放锁
end

return _M
