local whitelist_checker = require("check_whitelist")
local upstream_rules_cache = require("upstream_rules") -- 🚀 [引入 100% 内存级预载入路由表模块]
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

-- 🚀 [白名单开关调优：一次性预加载环境变量，杜绝 hot path 系统调用开销]
local enable_ip_whitelist = os.getenv("RG_ENABLE_IP_WHITELIST") ~= "false"

-- 🚀 [精简端口：安全授权域名解析与绕过预加载]
local auth_domain_str = os.getenv("RG_AUTH_DOMAIN") or "auth.localhost"
local auth_domains = {}
for domain in string.gmatch(auth_domain_str, "([^,]+)") do
    -- 去除可能存在的前后空格
    domain = string.gsub(domain, "%s+", "")
    auth_domains[domain] = true
end

local function handle_proxy_request()
    local sni = ngx.var.ssl_preread_server_name

    -- 🚀 [精简端口：自适应安全授权域名 Bypass]
    -- 如果客户端发起的 SNI 正好是授权域名（AUTH_DOMAIN），说明该请求是前来进行白名单授权的。
    -- 此时客户端 IP 自然还不在白名单中。因此我们安全地“无条件绕过阻断逻辑”，
    -- 并将其高速路由到本地环回代理接口 `127.0.0.1:18443`（它会追加 PROXY Protocol 后投递到 8443）
    if sni and auth_domains[sni] then
        ngx.var.final_upstream = "127.0.0.1:18443"
        return
    end

    -- 🚀 [一键关闭白名单，成为纯粹 SNI 转发代理]
    if enable_ip_whitelist then
        local allowed, reason = whitelist_checker.is_allowed()
        if not allowed then
            -- 🚀 [非授权 IP 防护特征分类：禁止 IP 直接访问 & 禁止非绑定域名访问]
            local block_reason = "Unauthorized Access"
            
            if not sni or sni == "" or string.match(sni, "^%d+%.%d+%.%d+%.%d+$") or string.match(sni, ":") then
                -- 客户端没有提供 SNI 域名，或者是通过直接输入 IP 地址进行恶意扫描
                block_reason = "Forbidden Direct IP Access"
            else
                local is_bound = upstream_rules_cache.is_bound(sni)
                if not is_bound then
                    -- 客户端提供了域名，但该域名并没有绑定/配置在我们的静态路由和环境变量中
                    block_reason = "Forbidden Unbound Domain Access"
                else
                    -- 客户端访问的是绑定域名，但其 IP 未在白名单授权中
                    block_reason = "Unauthorized Access to Bound Domain"
                end
            end
            
            -- 将判定原因写入 Nginx 变量中，使得 reject_log 能够优雅记录，完美分类
            ngx.var.block_reason = block_reason
            ngx_log(ngx_ERR, "[stream_handler] Blocked client " .. (ngx.var.stream_client_ip or "unknown") .. ". Reason: " .. block_reason)

            -- 使用 ngx.exit(500) 确保 $status 被设置为 500，
            -- 这样 access_log 的 if=$log_rejected_ip 条件才能正确触发拒绝日志记录。
            ngx.status = 500
            return ngx.exit(500)
        end
    end
    
    if not sni then
        ngx_log(ngx_ERR, "[stream_handler] Deny: Could not extract SNI.")
        return ngx.exit(ngx.ERROR)
    end
    
    -- 🚀 [极致性能：100% 内存哈希级精确路由匹配，避开物理磁盘/内存盘 I/O]
    local destination = upstream_rules_cache.get_route(sni)
    
    if not destination then
        -- 如果没有匹配的显式规则：
        -- 1. 如果用户没有显式设置默认上游（或者默认配置为 DYNAMIC 任意域名自适应路由），
        --    或者默认上游是默认配置的谷歌翻译：我们将流量自动、透明地路由到 [SNI]:443。
        -- 2. 否则，我们尊重用户的设置，走 default_upstream。
        local default_upstream, has_explicit_default = upstream_rules_cache.get_default()
        if default_upstream == "DYNAMIC" then
            destination = sni .. ":443"
        elseif not has_explicit_default or default_upstream == "127.0.0.1:9999" or default_upstream == "translate.googleapis.com:443" then
            destination = sni .. ":443"
        else
            destination = default_upstream
        end
    end

    -- 🚀 [安全加固：防公开敞开代理 (Anti-Open-Proxy Guard)]
    -- 只有当开启白名单防火墙 (ENABLE_IP_WHITELIST=true) 时，才允许任意域名的自适应动态路由 (* / DYNAMIC 转发)。
    -- 若白名单被关闭，且当前解析出的上游地址是动态的 [SNI]:443，系统将强制予以阻断并报警记录，
    -- 防止本 VPS 沦为公网的任意开放 SNI 代理，确保核心底层安全！
    if destination == sni .. ":443" and not enable_ip_whitelist then
        ngx_log(ngx_ERR, "[stream_handler] Blocked client " .. (ngx.var.stream_client_ip or "unknown") .. ". Reason: Forbid dynamic SNI proxying when IP whitelist is disabled (Anti-Open-Proxy Guard active)")
        ngx.status = 500
        return ngx.exit(500)
    end
    
    ngx.var.final_upstream = destination
end

handle_proxy_request()
