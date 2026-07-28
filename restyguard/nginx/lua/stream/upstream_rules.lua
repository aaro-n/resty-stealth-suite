local _M = {}
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_WARN = ngx.WARN

local rules = {}
local wildcards = {} -- 🚀 [引入通配符正则快速查询区，实现 *.domain.com 的高性能模糊匹配]
local default_upstream = "127.0.0.1:9999"
local has_explicit_default = false

-- 🚀 [一键配置具体位置与内存级预载入]
-- 可以通过环境变量 RG_UPSTREAM_RULES_FILE 自定义规则文件路径，默认是空的。
-- 若未配置或为空，则自适应回退到默认位置 /etc/nginx/rules/upstream_rules.conf
local config_file_path = os.getenv("RG_UPSTREAM_RULES_FILE")
if not config_file_path or config_file_path == "" then
    config_file_path = "/etc/nginx/rules/upstream_rules.conf"
end

local f, err = io.open(config_file_path, "r")
if f then
    for line in f:lines() do
        -- 过滤掉空白字符、回车以及注释行
        line = string.gsub(line, "%s+", "")
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            -- 🚀 [一键配置 * 任意域名模式：支持 * 或 *=* or *=dynamic 或 *=any]
            if line == "*" or line == "*=*" or line == "*=any" or line == "*=dynamic" then
                default_upstream = "DYNAMIC"
                has_explicit_default = true
            else
                -- 静态文件统一采用清爽的 Key-Value (key=host:port) 格式
                local key, host, port = string.match(line, "([^=]+)=([^:]+):([^:]+)")
                if key and host and port then
                    if key == "*" then
                        default_upstream = host .. ":" .. port
                        has_explicit_default = true
                    elseif string.sub(key, 1, 2) == "*." then
                        -- 🚀 [通配符智能适配]
                        -- 自动将通配符转换为 Lua 极速正则，并进行点分安全转义：
                        -- "*.123.cn" -> "%.123%.cn$"
                        local domain_suffix = string.sub(key, 3)
                        local pattern = "%." .. string.gsub(domain_suffix, "%.", "%%.") .. "$"
                        table.insert(wildcards, { pattern = pattern, destination = host .. ":" .. port, raw = key })
                    else
                        rules[key] = host .. ":" .. port
                    end
                end
            end
        end
    end
    f:close()
    ngx_log(ngx_INFO, "[upstream_rules] 🚀 成功将静态配置文件 '", config_file_path, "' 全量载入 Lua 虚拟机内存，实现零 I/O 极速路由。")
else
    ngx_log(ngx_WARN, "[upstream_rules] ⚠️ 未配置或无法读取静态路由规则文件 '", config_file_path, "': ", tostring(err))
end

-- 🚀 [超宽容自适应双格式环境变量合并]
-- 1. 新版推荐等号语法：STREAM_UPSTREAM_RULES="domain1=host1:port1,domain2=host2:port2" 或 YAML 形式多行列表。
-- 2. 旧版兼容冒号语法：STREAM_UPSTREAM_MAP="domain1:host1:port1,domain2:host2:port2"
local function parse_env_rules(env_str, is_new_format)
    if not env_str or env_str == "" then return end
    
    -- 🚀 [自适应多行分流调优]
    -- 将所有的 Windows/Linux 换行符（\r\n, \n）统一替换为逗号（,），
    -- 从而支持在 YAML 中通过 `|` 或 `>-` 声明的优雅多行配置，极其护眼。
    env_str = string.gsub(env_str, "\r\n", ",")
    env_str = string.gsub(env_str, "\n", ",")
    
    for rule in string.gmatch(env_str, "([^,]+)") do
        -- 去除每行首尾多余的空白字符
        rule = string.gsub(rule, "^%s*(.-)%s*$", "%1")
        
        -- 🚀 [极其强悍的列表与符号清洗容错]
        -- 1. 去除 YAML 列表可能存在的前导减号 "-" 与其空格 (e.g., "- api.com..." -> "api.com...")
        rule = string.gsub(rule, "^-%s*", "")
        
        -- 2. 强力脱去所有中英文、花角/半角单双引号外壳壳 (包括: ', ", “, ”, ‘, ’)
        rule = string.gsub(rule, "^['\"“‘]", "")
        rule = string.gsub(rule, "['\"”’]$", "")
        
        -- 3. 再次去除可能由脱壳引发的前后二次空格
        rule = string.gsub(rule, "^%s*(.-)%s*$", "%1")

        if rule ~= "" then
            -- 🚀 [一键配置 * 任意域名模式：支持 * 或 *=* 或 *=dynamic 或 *=any]
            if rule == "*" or rule == "*=*" or rule == "*=any" or rule == "*=dynamic" then
                default_upstream = "DYNAMIC"
                has_explicit_default = true
            else
                local key, host, port
                if is_new_format then
                    key, host, port = string.match(rule, "([^=]+)=([^:]+):([^:]+)")
                else
                    key, host, port = string.match(rule, "([^:]+):([^:]+):([^:]+)")
                end

                if key and host and port then
                    if key == "*" then
                        default_upstream = host .. ":" .. port
                        has_explicit_default = true
                    elseif string.sub(key, 1, 2) == "*." then
                        -- 🚀 [通配符智能适配]
                        -- 环境变量配置同样享受通配符热载入与转义支持
                        local domain_suffix = string.sub(key, 3)
                        local pattern = "%." .. string.gsub(domain_suffix, "%.", "%%.") .. "$"
                        table.insert(wildcards, { pattern = pattern, destination = host .. ":" .. port, raw = key })
                    else
                        rules[key] = host .. ":" .. port
                    end
                end
            end
        end
    end
end

-- 执行环境变量合并（环境变量优先级高，支持临时覆盖静态文件规则）
parse_env_rules(os.getenv("RG_STREAM_UPSTREAM_RULES"), true)
parse_env_rules(os.getenv("RG_STREAM_UPSTREAM_MAP"), false)

function _M.get_route(sni)
    if not sni or sni == "" then return nil end
    
    -- 1. 优先执行 O(1) 的超极速精确 Hash 查找（保障传统业务延迟绝对零抖动）
    local exact_match = rules[sni]
    if exact_match then
        return exact_match
    end
    
    -- 2. 次之，自适应进行正则通配符模糊适配 (如 test.123.cn 命中 *.123.cn)
    for _, wc in ipairs(wildcards) do
        if string.find(sni, wc.pattern) then
            return wc.destination
        end
    end
    
    return nil
end

function _M.get_default()
    return default_upstream, has_explicit_default
end

-- 导出路由匹配表（调试用）
function _M.is_bound(sni)
    if not sni or sni == "" then return false end
    if rules[sni] ~= nil then
        return true
    end
    for _, wc in ipairs(wildcards) do
        if string.find(sni, wc.pattern) then
            return true
        end
    end
    return false
end

return _M
