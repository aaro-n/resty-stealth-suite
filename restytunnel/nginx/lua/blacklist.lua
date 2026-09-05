-- File: nginx/lua/blacklist.lua
-- Description: 错密黑名单（防爆破减速带）。仅对「携带凭证但密码错误」的请求计数；
-- 达到阈值后拉黑该 IP 一段时间。方案 3 语义：黑名单内「正确密码照常放行」，
-- 黑名单只拦「无凭证 / 错密」请求，作为纯粹的限速器存在。
-- 存储介质：ngx.shared.blacklist_dict（C 共享内存，跨 Worker 天然共享，自带 TTL 自动过期，零磁盘 I/O）。

local _M = {}
local config = require("config")

local DICT_PREFIX_COUNT = "cnt:"   -- 错密计数键前缀
local DICT_PREFIX_BLOCK = "bl:"    -- 拉黑标记键前缀

local function get_dict()
    return ngx.shared.blacklist_dict
end

-- 是否已拉黑
function _M.check(ip)
    if not ip or ip == "" then return false end
    if config.blacklist_enabled ~= "true" then return false end

    local dict = get_dict()
    if not dict then return false end
    return dict:get(DICT_PREFIX_BLOCK .. ip) ~= nil
end

-- 记录一次错密。返回 true 表示本次触发了拉黑。
-- 已在黑名单内的 IP 不再重复计数（设计约定：黑名单内计数不再增长）。
function _M.record_failure(ip)
    if not ip or ip == "" then return false end
    if config.blacklist_enabled ~= "true" then return false end

    local dict = get_dict()
    if not dict then return false end

    local block_key = DICT_PREFIX_BLOCK .. ip
    -- 已拉黑：不再计数
    if dict:get(block_key) ~= nil then return false end

    local count_key = DICT_PREFIX_COUNT .. ip
    local threshold = config.blacklist_threshold
    local ttl = config.blacklist_ttl_seconds

    -- incr 带初始值与过期时间：计数窗口 = 拉黑 TTL（窗口内累计错密）
    local newval, err = dict:incr(count_key, 1, 0, ttl)
    if not newval then
        ngx.log(ngx.ERR, "[blacklist] 计数失败 IP: ", ip, " err: ", tostring(err))
        return false
    end

    if newval >= threshold then
        -- 达到阈值：写入拉黑标记（TTL 自动过期），并清掉计数键
        dict:set(block_key, ngx.time(), ttl)
        dict:delete(count_key)
        ngx.log(ngx.WARN, "🟤 [BLACKLISTED] -> IP: ", ip, " 错密累计 ", newval,
            " 次达到阈值 ", threshold, "，拉黑 ", tostring(ttl),
            " 秒。期间该 IP 的无凭证/错密请求一律回落伪装（正确密码仍照常放行）。")
        return true
    end

    return false
end

-- 清除某 IP 的黑名单记录与计数（B 兜底：TOTP 加白动作时顺手调用）
function _M.clear(ip)
    if not ip or ip == "" then return false end
    local dict = get_dict()
    if not dict then return false end
    dict:delete(DICT_PREFIX_BLOCK .. ip)
    dict:delete(DICT_PREFIX_COUNT .. ip)
    ngx.log(ngx.NOTICE, "🟤 [BLACKLIST_CLEARED] -> 已清除 IP: ", ip, " 的黑名单记录与错密计数。")
    return true
end

return _M
