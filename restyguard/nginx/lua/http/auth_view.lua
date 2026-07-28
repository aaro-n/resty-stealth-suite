local _M = {}

local function html_escape(str)
    if not str then return "" end
    str = tostring(str)
    str = string.gsub(str, "&", "&amp;")
    str = string.gsub(str, "<", "&lt;")
    str = string.gsub(str, ">", "&gt;")
    str = string.gsub(str, '"', "&quot;")
    str = string.gsub(str, "'", "&#39;")
    return str
end

function _M.render(visitor_ip, ip_to_add, success, err, whitelist_entries, rejected_logs)
    local ip_val = html_escape(ip_to_add or "")
    local visitor_ip_val = html_escape(visitor_ip or "")
    local status_box = ""
    
    if success ~= nil then
        if success then
            status_box = "<div class='status-box success-box'>✅ <strong>白名单授权成功</strong>：IP <code>" .. ip_val .. "</code> 已加入授权白名单！</div>"
        else
            status_box = "<div class='status-box error-box'>❌ <strong>写入失败</strong>：无法写入白名单，原因: " .. html_escape(err) .. "</div>"
        end
    end

    -- 构造白名单列表表格
    local whitelist_html = ""
    
    if whitelist_entries and #whitelist_entries > 0 then
        for _, entry in ipairs(whitelist_entries) do
            local rem_h = math.floor(entry.remaining / 3600)
            local rem_m = math.floor((entry.remaining % 3600) / 60)
            local time_str = string.format("%d 小时 %d 分", rem_h, rem_m)
            if rem_h == 0 then
                time_str = string.format("%d 分钟", rem_m)
            end
            whitelist_html = whitelist_html .. string.format([[
                <tr>
                    <td><code>%s</code></td>
                    <td><span class="badge badge-success">活跃中</span></td>
                    <td>剩余 %s</td>
                    <td>
                        <form method="POST" action="" style="display:inline; margin:0; padding:0;">
                            <input type="hidden" name="action" value="delete">
                            <input type="hidden" name="ip" value="%s">
                            <button type="submit" class="btn-delete" onclick="return confirm('确定要移除该 IP 授权吗？')">🗑️ 移除</button>
                        </form>
                    </td>
                </tr>
            ]], html_escape(entry.ip), time_str, html_escape(entry.ip))
        end
    else
        whitelist_html = "<tr><td colspan='4' style='text-align:center; color:#999; padding:20px;'>🚫 暂无授权白名单 IP 数据</td></tr>"
    end

    -- 构造被拒日志列表
    local rejected_html = ""
    if rejected_logs and #rejected_logs > 0 then
        for _, log in ipairs(rejected_logs) do
            rejected_html = rejected_html .. string.format([[
                <tr>
                    <td style="font-size:0.85em; color:#666;">%s</td>
                    <td><code>%s</code></td>
                    <td class="reason-cell" title="%s">%s</td>
                    <td style="color:#2c3e50; font-family:monospace; font-size:0.9em;">%s</td>
                </tr>
            ]], html_escape(log.time), html_escape(log.ip), html_escape(log.reason), html_escape(log.reason), html_escape(log.sni ~= "" and log.sni or "-"))
        end
    else
        rejected_html = "<tr><td colspan='4' style='text-align:center; color:#999; padding:20px;'>🍃 暂无探测被拒阻断日志</td></tr>"
    end

    local html_template = [[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="manifest" href="/gkp-manifest.json">
    <title>RestyGuard 安全网关 IP 自助管理控制台</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; color: #333; max-width: 750px; margin: 40px auto; padding: 20px; background-color: #f4f7f6; }
        .card { background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); border-top: 5px solid #007bff; margin-bottom: 25px; }
        h1 { font-size: 1.6em; color: #007bff; margin-top: 0; display: flex; align-items: center; gap: 10px; }
        h2 { font-size: 1.25em; color: #495057; border-bottom: 2px solid #eaeaea; padding-bottom: 8px; margin-top: 0; margin-bottom: 15px; display: flex; align-items: center; gap: 8px; }
        .status-box { padding: 15px; border-radius: 8px; margin: 20px 0; font-weight: 500; }
        .success-box { background: #e2f0d9; border-left: 5px solid #385723; color: #385723; }
        .error-box { background: #fce4d6; border-left: 5px solid #c65911; color: #c65911; }
        
        .input-group { display: flex; gap: 10px; margin: 15px 0; }
        input[type="text"] { flex: 1; padding: 12px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 6px; font-size: 1em; }
        
        .btn-group { display: flex; gap: 10px; }
        .btn { display: inline-block; background: #007bff; color: white; border: none; padding: 12px 20px; border-radius: 6px; cursor: pointer; font-size: 1em; text-decoration: none; text-align: center; transition: background 0.2s; font-weight: 500; }
        .btn:hover { background: #0056b3; }
        .btn-secondary { background: #6c757d; }
        .btn-secondary:hover { background: #5a6268; }
        .btn-delete { background: #dc3545; color: white; border: none; padding: 5px 10px; border-radius: 4px; cursor: pointer; font-size: 0.85em; transition: background 0.2s; }
        .btn-delete:hover { background: #bd2130; }

        /* 表格排版 */
        .table-container { overflow-x: auto; max-height: 280px; overflow-y: auto; border: 1px solid #eee; border-radius: 8px; margin-bottom: 5px; }
        table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9em; }
        th { background-color: #f8f9fa; padding: 12px; font-weight: 600; color: #495057; border-bottom: 2px solid #dee2e6; position: sticky; top: 0; z-index: 10; }
        td { padding: 10px 12px; border-bottom: 1px solid #dee2e6; vertical-align: middle; }
        
        .badge { display: inline-block; padding: 2px 6px; font-size: 0.8em; font-weight: 600; border-radius: 4px; }
        .badge-success { background-color: #d4edda; color: #155724; }
        .badge-error { background-color: #f8d7da; color: #721c24; }
        
        .reason-cell { max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #6c757d; }
        .info { font-size: 0.88em; color: #666; margin-top: 25px; border-top: 1px dashed #ddd; padding-top: 15px; }
        code { background: rgba(0,0,0,0.05); padding: 2px 6px; border-radius: 4px; font-family: monospace; }
        
        /* 强制美化滚动条 */
        .table-container::-webkit-scrollbar { width: 6px; height: 6px; }
        .table-container::-webkit-scrollbar-thumb { background: #ccc; border-radius: 3px; }

        /* 📱 极致移动端自适应流式排版优化 */
        @media (max-width: 600px) {
            body { margin: 10px auto; padding: 10px; font-size: 14px; }
            .card { padding: 15px; border-radius: 8px; margin-bottom: 15px; }
            h1 { font-size: 1.35em; gap: 6px; }
            h2 { font-size: 1.1em; margin-bottom: 10px; }
            .input-group { flex-direction: column; gap: 8px; }
            input[type="text"] { width: 100%; padding: 10px; font-size: 15px; }
            .btn-group { flex-direction: column; width: 100%; gap: 8px; }
            .btn { width: 100%; padding: 10px; font-size: 15px; text-align: center; }
            td, th { padding: 8px; font-size: 13px; }
            /* 让超长的 IPv6 或是 IP 在小屏幕下能自动无损折行，绝不撑大撑变形卡片 */
            td code { word-break: break-all; white-space: normal; display: inline-block; max-width: 100%; }
            .reason-cell { max-width: 110px; font-size: 12px; }
        }
    </style>
</head>
<body>
    <div class="card">
        <h1>🛡️ RestyGuard 安全代理授权管理</h1>
        
        @@STATUS_BOX@@

        <div style="margin-bottom: 15px; font-size: 0.95em; color: #555; background: #e8f4fd; padding: 10px 15px; border-radius: 6px; border-left: 4px solid #007bff; display: inline-block;">
            🖥️ 您的当前实际访问 IP：<strong style="color: #007bff; font-family: monospace; font-size: 1.1em;">@@VISITOR_IP@@</strong>
        </div>

        <form method="POST" action="">
            <input type="hidden" name="action" value="add">
            <label style="font-weight: bold; color: #495057; display: block; margin-top: 10px;">要授权/更新的客户端 IP 地址：</label>
            <div class="input-group">
                <input type="text" name="ip" value="@@IP_VAL@@" placeholder="请输入合法 IP 地址，如 1.2.3.4" autocomplete="off">
                <button type="submit" class="btn">➕ 提交授权</button>
            </div>
            <div class="btn-group">
                <a href="?" class="btn btn-secondary">🔄 获取并自动授权本机 IP</a>
                <button type="button" class="btn btn-secondary" style="background:#dc3545;" onclick="unregisterConsolePWA()">🧹 强行卸载此控制台 PWA</button>
            </div>
        </form>

        <p class="info">💡 <strong>使用说明：</strong> 授权成功后，该 IP 地址将被允许通过此服务器建立四层加密盲转发隧道，单次授权有效期为 24 小时（可在服务端修改）。</p>
    </div>

    <!-- 列表展示：当前活跃的白名单 -->
    <div class="card">
        <h2>🟢 当前活跃的白名单 IP 列表</h2>
        <div class="table-container">
            <table>
                <thead>
                    <tr>
                        <th>IP 地址</th>
                        <th>授权状态</th>
                        <th>过期时间</th>
                        <th>管理操作</th>
                    </tr>
                </thead>
                <tbody>
                    @@WHITELIST_ROWS@@
                </tbody>
            </table>
        </div>
    </div>

    <!-- 列表展示：被拒扫描日志 -->
    <div class="card">
        <h2>🔴 恶意探测与非合规阻断拦截日志</h2>
        <div class="table-container">
            <table>
                <thead>
                    <tr>
                        <th>拦截时间</th>
                        <th>来源 IP</th>
                        <th>拦截原因</th>
                        <th>探测 SNI</th>
                    </tr>
                </thead>
                <tbody>
                    @@REJECTED_ROWS@@
                </tbody>
            </table>
        </div>
    </div>

    <!-- 🚀 [双重保险：在 Window 页面级强力清除残留的恶意 Service Workers，同时激活注册控制台专属 PWA] -->
    <script>
        // 强行自我卸载控制台 PWA（连同 Cookie、SW、缓存全部清除，干净退场）
        function unregisterConsolePWA() {
            if (confirm("🧹 确定要在此浏览器上彻底卸载并清除本安全控制台 PWA 吗？\n\n该操作将：\n1. 强制注销控制台 Service Worker\n2. 物理清除您的 30天 记住登录态（Cookie锁）\n3. 清空所有离线 PWA 缓存\n\n卸载后，您不小心访问根目录时将恢复为直接展现原版后端网站。")) {
                if ('serviceWorker' in navigator) {
                    navigator.serviceWorker.getRegistrations().then(function(registrations) {
                        var promises = [];
                        for (let registration of registrations) {
                            promises.push(registration.unregister());
                        }
                        Promise.all(promises).then(function() {
                            // 物理抹除 Cookie 锁（将 Max-Age 设为 0 瞬间过期）
                            document.cookie = "gkp_user=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure";
                            document.cookie = "gkp_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure";
                            document.cookie = "gkp_active=; Path=/; Max-Age=0; SameSite=Lax; Secure";
                            
                            alert("✅ 控制台 PWA 注销成功，已安全抹除本机的全部登录锁和缓存凭证。网页将自动重载。");
                            window.location.reload();
                        });
                    }).catch(function(err) {
                        alert("❌ 注销失败: " + err);
                    });
                } else {
                    alert("当前浏览器不支持 Service Worker。");
                }
            }
        }

        if ('serviceWorker' in navigator) {
            // 1. 注册控制台专属 PWA 磁贴 Service Worker (gkp-sw.js)
            navigator.serviceWorker.register('/gkp-sw.js').then(function(reg) {
                console.log('RestyGuard: Registered Console PWA SW under scope:', reg.scope);
            }).catch(function(err) {
                console.error('RestyGuard: Console PWA SW registration failed:', err);
            });

            // 2. 深度扫描并注销其他所有被污染残留的 Service Workers (如网盘 SW)，彻底洗白！
            navigator.serviceWorker.getRegistrations().then(function(registrations) {
                for (let registration of registrations) {
                    var scriptURL = (registration.active || registration.installing || registration.waiting || {}).scriptURL || '';
                    if (scriptURL && !scriptURL.includes('gkp-sw.js')) {
                        registration.unregister().then(function(success) {
                            if (success) {
                                console.log('RestyGuard: Cleaned hostile SW:', scriptURL);
                                window.location.reload();
                            }
                        });
                    }
                }
            }).catch(function(err) {
                console.error('RestyGuard SW cleanup error:', err);
            });
        }
    </script>
</body>
</html>
]]

    local function escape_gsub_replacement(s)
        return (string.gsub(tostring(s), "%%", "%%%%"))
    end

    local final_html = html_template
    final_html = string.gsub(final_html, "@@STATUS_BOX@@", escape_gsub_replacement(status_box))
    final_html = string.gsub(final_html, "@@VISITOR_IP@@", escape_gsub_replacement(visitor_ip_val))
    final_html = string.gsub(final_html, "@@IP_VAL@@", escape_gsub_replacement(ip_val))
    final_html = string.gsub(final_html, "@@WHITELIST_ROWS@@", escape_gsub_replacement(whitelist_html))
    final_html = string.gsub(final_html, "@@REJECTED_ROWS@@", escape_gsub_replacement(rejected_html))

    return final_html
end

return _M
