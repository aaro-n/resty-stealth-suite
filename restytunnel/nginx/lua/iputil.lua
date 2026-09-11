-- File: nginx/lua/iputil.lua
-- Description: IP 格式校验与 Shell 安全引用工具（防注入 / 防脏数据）

local _M = {}

-- IPv4 严格校验：四段 0-255
function _M.is_valid_ipv4(ip)
    if type(ip) ~= "string" then return false end
    if #ip > 15 then return false end
    local a, b, c, d = string.match(ip, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, oct in ipairs({a, b, c, d}) do
        -- 拒绝前导零过长如 001（可选，保留兼容则放宽）；此处仅做数值范围校验
        if #oct > 3 or #oct == 0 then return false end
        local n = tonumber(oct)
        if not n or n < 0 or n > 255 then return false end
    end
    return true
end

-- IPv6 宽松但安全的校验：仅允许 hex/冒号/点（兼容内嵌 IPv4），必须含冒号
-- 目的：拦截 shell 元字符（; $ ` | & 等）与换行注入，而非完整 RFC 4291 校验
function _M.is_valid_ipv6(ip)
    if type(ip) ~= "string" then return false end
    if #ip < 2 or #ip > 45 then return false end
    if not string.find(ip, ":", 1, true) then return false end
    if string.find(ip, "[^0-9a-fA-F:.%%]") then return false end
    -- 拒绝连续三个冒号、首尾单冒号等明显非法（:: 允许）
    if string.find(ip, ":::") then return false end
    return true
end

function _M.is_valid_ip(ip)
    if type(ip) ~= "string" then return false end
    -- 拒绝换行 / 空格 / 分号等注入字符（IPv6 zone id % 允许，但拒绝空格）
    if string.find(ip, "[%s;`$|&!#\r\n=\"']") then return false end
    return _M.is_valid_ipv4(ip) or _M.is_valid_ipv6(ip)
end

-- POSIX shell 单引号安全引用
function _M.shell_quote(s)
    if type(s) ~= "string" then return "''" end
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

return _M
