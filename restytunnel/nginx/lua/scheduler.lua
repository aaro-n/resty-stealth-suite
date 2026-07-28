-- File: nginx/lua/scheduler.lua
-- Description: 定时任务主调度器，在 worker 启动时初始化

local ngx_timer_at = ngx.timer.at
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR
local tasks = require("tasks")

local _M = {}

local function schedule_recurring_task(delay, task_func, task_name, ...)
    if not (delay and tonumber(delay) and tonumber(delay) > 0) then
        ngx_log(ngx_INFO, "[任务调度器] 任务 '", task_name, "' 已关闭或未配置运行周期。")
        return
    end

    local args = {...}
    local timer_handler

    timer_handler = function(premature)
        if premature then
            ngx_log(ngx_INFO, "[任务调度器] 任务 '", task_name, "' 在 worker 关闭时被中止。")
            return
        end

        local success, err = pcall(task_func, unpack(args))
        if not success then
            ngx_log(ngx_ERR, "[任务调度器] 任务 '", task_name, "' 执行失败: ", err)
        end

        local ok, err_timer = ngx_timer_at(delay, timer_handler)
        if not ok then
            ngx_log(ngx_ERR, "[任务调度器] 无法为任务 '", task_name, "' 安排下一次执行: ", err_timer)
        end
    end

    local ok, err = ngx_timer_at(delay, timer_handler)
    if ok then
        ngx_log(ngx_INFO, "[任务调度器] 任务 '", task_name, "' 已成功调度，执行周期为 ", delay, " 秒。")
    else
        ngx_log(ngx_ERR, "[任务调度器] 无法启动初始任务 '", task_name, "': ", err)
    end
end

function _M.start()
    -- 仅在 worker 0 中运行定时任务，防止 N 个 worker 进程产生并发竞争和重复 I/O
    local worker_id = ngx.worker.id()
    if worker_id ~= 0 then
        return
    end

    ngx_log(ngx_INFO, "[任务调度器] 正在初始化白名单后台自动维护机制...")

    -- 🚀 [冷启动提速与安全加固] 容器启动时，立即在后台线程中全量预热载入现有白名单，预填充内存高速缓存字典。
    -- 完美配合 system_loaded 机制，使随后的所有探测、刺探请求（如外部的随机 IP 扫描）100% 实现零 I/O 拦截。
    local whitelist = require("whitelist")
    pcall(whitelist.load_to_shared_dict)

    local config = require("config")
    local whitelist_interval = config.whitelist_interval
    schedule_recurring_task(whitelist_interval, tasks.clean_expired_whitelist_entries, "白名单过期清理")

    -- 🚀 [新增] 定时流式裁剪黑名单拦截日志，防止日志文件无限膨胀，保障磁盘空间与读取性能
    local log_interval = tonumber(os.getenv("RT_TASK_CLEAN_LOG_INTERVAL_SECONDS") or 60)
    schedule_recurring_task(log_interval, tasks.clean_rejected_log, "黑名单日志裁剪")
end

return _M
