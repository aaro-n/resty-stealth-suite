-- File: nginx/lua/session.lua
-- Description: HMAC 签名 Cookie 会话（防明文密码回放 / 防篡改用户名字段）
-- 格式：gkp_user=<user>；gkp_session=<exp>.<sig>
-- 其中 sig = hex_hmac_sha256(session_key, user .. "|" .. exp)
-- session_key 派生自各用户密钥材料（密码或 TOTP secret），服务端无状态校验。

local _M = {}

-- 优先 resty.openssl.hmac (SHA256)，不可用则退化为 ngx.hmac_sha1（仍签名态，不回退明文）
local hmac_sha256 = nil
pcall(function()
    local openssl_hmac = require("resty.openssl.hmac")
    hmac_sha256 = function(key, msg)
        local h, err = openssl_hmac.new(key, "sha256")
        if not h then return nil, err end
        return h:final(msg)
    end
end)

local function session_key_for(user_record)
    if not user_record then return nil end
    return user_record.totp_secret or user_record.credential
end

-- 签发：ttl 秒后过期
function _M.issue(user, user_record, ttl)
    if not user or not user_record then return nil end
    local key = session_key_for(user_record)
    if not key or key == "" then return nil end
    ttl = tonumber(ttl) or 2592000
    local exp = ngx.time() + ttl
    local msg = user .. "|" .. tostring(exp)
    local sig
    if hmac_sha256 then
        sig = hmac_sha256(key, msg)
    else
        -- 兜底：仅 ngx.hmac_sha1 可用时退化为 SHA1（仍为签名态，不回退明文）
        sig = ngx.hmac_sha1(key, msg)
    end
    if not sig then return nil end
    -- 转 hex（避免 base64 的 +/= 在 Cookie 中惹麻烦）
    local hex = string.gsub(sig, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
    return tostring(exp) .. "." .. hex
end

-- 校验：返回 true/false；过期、串改、用户不存在均 false
function _M.verify(user, token, users_db)
    if not user or not token or not users_db then return false end
    local user_record = users_db[user]
    if not user_record then return false end
    local key = session_key_for(user_record)
    if not key or key == "" then return false end
    local exp_str, sig = string.match(token, "^(%d+)%.([0-9a-fA-F]+)$")
    if not exp_str or not sig then return false end
    local exp = tonumber(exp_str)
    if not exp or exp < ngx.time() then return false end
    local msg = user .. "|" .. exp_str
    local expect
    if hmac_sha256 then
        expect = hmac_sha256(key, msg)
    else
        expect = ngx.hmac_sha1(key, msg)
    end
    if not expect then return false end
    local expect_hex = string.gsub(expect, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
    -- 常量时间比较（防时序侧信道）
    if #expect_hex ~= #sig then return false end
    local diff = 0
    local sl = string.lower(sig)
    for i = 1, #expect_hex do
        local a = string.byte(expect_hex, i)
        local b = string.byte(sl, i)
        if a ~= b then diff = diff + 1 end
    end
    return diff == 0
end

function _M.parse_users(raw_users)
    local users_db = {}
    if not raw_users or raw_users == "" then return users_db end
    for user_entry in string.gmatch(raw_users, "([^,]+)") do
        user_entry = string.gsub(user_entry, "^%s*(.-)%s*$", "%1")
        local username, val1, val2 = string.match(user_entry, "^([^:]+):([^:]+):?(.*)$")
        if username and val1 then
            users_db[username] = {
                credential = val1,
                totp_secret = (val2 ~= "" and val2 or nil)
            }
        end
    end
    return users_db
end

return _M
