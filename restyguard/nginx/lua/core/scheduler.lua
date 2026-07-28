local ngx_timer_at = ngx.timer.at
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR
local tasks = require("tasks") -- 引入我们刚创建的任务模块

local _M = {}

---
-- 通用的定时任务启动器
-- @param delay (number) 任务执行周期（秒）
-- @param task_func (function) 要执行的任务函数
-- @param task_name (string) 任务名称，用于日志记录
-- @param ... (any) 传递给任务函数的额外参数
---
local function schedule_recurring_task(delay, task_func, task_name, ...)
    -- 检查 delay 是否有效
    if not (delay and tonumber(delay) and tonumber(delay) > 0) then
        ngx_log(ngx_INFO, "[SCHEDULER] 任务 '", task_name, "' 因周期无效而被禁用。")
        return
    end

    local args = {...}
    local timer_handler

    timer_handler = function(premature)
        if premature then
            ngx_log(ngx_INFO, "[SCHEDULER] 任务 '", task_name, "' 在 worker 关闭时被中止。")
            return
        end

        -- 在 pcall 中执行任务，防止任务本身的错误导致定时器中断
        local success, err = pcall(task_func, unpack(args))
        if not success then
            ngx_log(ngx_ERR, "[SCHEDULER] 任务 '", task_name, "' 执行失败: ", err)
        end

        -- 任务执行完毕后，再次安排下一次执行
        local ok, err_timer = ngx_timer_at(delay, timer_handler)
        if not ok then
            ngx_log(ngx_ERR, "[SCHEDULER] 无法为任务 '", task_name, "' 安排下一次执行: ", err_timer)
        end
    end

    -- 🚀 [首轮快速响应调优]
    -- 对于周期特别长（如白名单清理的 24 小时）的任务，如果直接干等 86400 秒再执行第一轮，
    -- 会导致容器启动后积压的过期 IP 长期得不到释放。
    -- 优化方案：在容器启动 5 秒后（避开繁忙的系统启动 Hot Path）立即执行一次首轮清理，随后再按照设定周期循环。
    local initial_delay = math.min(5, delay)

    -- 启动第一次任务
    local ok, err = ngx_timer_at(initial_delay, timer_handler)
    if ok then
        ngx_log(ngx_INFO, "[SCHEDULER] 任务 '", task_name, "' 已成功调度，首轮执行延迟为 ", initial_delay, " 秒，后续执行周期为 ", delay, " 秒。")
    else
        ngx_log(ngx_ERR, "[SCHEDULER] 无法启动初始任务 '", task_name, "': ", err)
    end
end

---
-- 启动所有定义的定时任务
---
function _M.start()
    -- 🚀 [多 Worker 冲突隔离调优]
    -- 仅在 worker 0 中运行定时清理及维护任务，防止 N 个 worker 进程产生并发竞争、重复 I/O 以及重置日志信号冲突
    local worker_id = ngx.worker.id()
    if worker_id ~= 0 then
        return
    end

    ngx_log(ngx_INFO, "[SCHEDULER] 正在初始化所有定时任务...")

    -- 1. 日志清理任务
    local log_interval = os.getenv("RG_TASK_CLEAN_LOG_INTERVAL_SECONDS")
    local log_retain_lines = os.getenv("RG_TASK_CLEAN_LOG_RETAIN_LINES")
    schedule_recurring_task(log_interval, tasks.clean_rejected_log, "日志清理", log_retain_lines)

    -- 2. 白名单清理任务
    local whitelist_interval = os.getenv("TASK_CLEAN_WHITELIST_INTERVAL_SECONDS")
    schedule_recurring_task(whitelist_interval, tasks.clean_expired_whitelist_entries, "白名单清理")
    
end

return _M
