
local os_execute = os.execute
local io_open = io.open
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR

local _M = {}

-- 日志和数据库文件路径
local REJECTED_LOG_PATH = "/dev/shm/rejected_ips.log"
local WHITELIST_DB_PATH = "/dev/shm/whitelist.db"
local lock_dir_path = "/dev/shm/whitelist.lock"

-- 🚀 [多 Worker 并发防覆盖调优]
-- 采用原子目录操作实现互斥文件锁，确保清理过期 IP 与用户手动/自动添加 IP 时数据不冲突。
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
-- 【已修正】清理被拒绝的 IP 日志文件，只保留最后的 N 行
-- @param retain_lines (number) 要保留的行数
---
function _M.clean_rejected_log(retain_lines)
    local lines_to_keep = tonumber(retain_lines) or 10
    
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
    REJECTED_LOG_PATH, 
    REJECTED_LOG_PATH, 
    lines_to_keep, 
    REJECTED_LOG_PATH
    )

    local clean_ok, _, clean_code = os_execute(clean_command)

    if not clean_ok then
        if clean_code == 2 then
            -- 💡 [极致静音调优] 日志文件行数未达到保留阈值，或日志文件不存在，无需裁剪，也无需 reopen 重新加载 inode
            return
        else
            ngx_log(ngx_ERR, string.format("[TASK] 日志清理 shell 命令执行失败。OK: %s, Code: %s", tostring(clean_ok), tostring(clean_code)))
            return
        end
    end

    -- vvvvvvvvvv 【核心修正 v2.2.2】 vvvvvvvvvv
    -- 说明：
    -- 修正 reopen 命令，使用 Nginx 启动时真正加载的配置文件路径 /etc/nginx/nginx.conf。
    -- 这样 openresty -s reopen 就能找到正确的配置文件，并从中读取到正确的 pid 文件路径，
    -- 从而向正确的主进程发送信号。
    local reopen_command = "/usr/local/openresty/bin/openresty -c /etc/nginx/nginx.conf -s reopen"
    
    -- os.execute 返回 (true/nil, 'exit'/'signal', exit_code)
    -- 我们需要检查命令是否成功执行并且退出码为 0
    local reopen_ok, reason, code = os_execute(reopen_command)
    
    if reopen_ok and code == 0 then
        ngx_log(ngx_INFO, "[TASK] 已成功通知 Nginx 重新打开日志文件。")
    else
        -- 记录更详细的错误信息，便于调试
        ngx_log(ngx_ERR, string.format("[TASK] 通知 Nginx 重新打开日志文件失败。OK: %s, Reason: %s, Code: %s",
            tostring(reopen_ok), tostring(reason), tostring(code)))
    end
    -- ^^^^^^^^^^ 【核心修正 v2.2.2】 ^^^^^^^^^^

    ngx_log(ngx_INFO, "[TASK] 日志清理任务执行完毕。")
end


---
-- 【安全锁加强版】清理白名单数据库，移除所有已过期的 IP
---
function _M.clean_expired_whitelist_entries()
    -- 尝试获取互斥锁
    if not acquire_lock() then
        ngx_log(ngx_ERR, "[TASK] 白名单清理失败：无法获取排他写锁（锁被占用）。")
        return
    end

    local current_time = ngx.time()
    local temp_path = WHITELIST_DB_PATH .. ".tmp"

    local original_file, err_open = io_open(WHITELIST_DB_PATH, "r")
    if not original_file then
        release_lock() -- 释放锁
        if string.find(err_open, "No such file or directory") then return end
        ngx_log(ngx_ERR, "[TASK] 白名单清理失败：无法打开原始文件进行读取: ", err_open)
        return
    end

    local temp_file, err_temp = io_open(temp_path, "w")
    if not temp_file then
        ngx_log(ngx_ERR, "[TASK] 白名单清理失败：无法创建临时文件: ", err_temp)
        original_file:close()
        release_lock() -- 释放锁
        return
    end

    local expired_count = 0
    local valid_count = 0
    local has_content = false

    for line in original_file:lines() do
        if line and line ~= "" then
            has_content = true
            -- 使用更精确的模式匹配：IP=EXPIRY_TIMESTAMP
            local ip, expiry_str = string.match(line, "^(.-)=([^=]+)$")
            if ip and expiry_str then
                local expiry_time = tonumber(expiry_str)
                if expiry_time and expiry_time >= current_time then
                    temp_file:write(line, "\n")
                    valid_count = valid_count + 1
                else
                    expired_count = expired_count + 1
                end
            else
                -- 格式不匹配的行，保留原样
                temp_file:write(line, "\n")
            end
        end
    end

    original_file:close()
    temp_file:close()

    if has_content then
        local ok, _, code = os_execute(string.format("mv %s %s", temp_path, WHITELIST_DB_PATH))
        if ok then
            -- 🎯 [安全与审计加固] 模仿 RestyTunnel 日志颜色体系：使用 🧹 🟠 橙色扫帚与警告图标，与普通白色做出视觉上极明显的区分
            if expired_count > 0 then
                ngx_log(ngx_NOTICE, "🧹 🟠 [WHITELIST_CLEANED] -> 自动清理过期白名单完成。物理移除了 ", expired_count, " 个过期 IP，保留活跃数: ", valid_count)
            end
        else
            ngx_log(ngx_ERR, "[TASK] 白名单清理失败：无法用临时文件覆盖原始文件。返回码: ", code)
        end
    else
        os_execute(string.format("rm -f %s", temp_path))
    end

    release_lock() -- 释放锁
end

return _M
