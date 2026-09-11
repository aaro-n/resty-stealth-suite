# File: Dockerfile
# Description: RestyTunnel 生产级极速反探测 HTTPS 代理镜像
# Based on OpenResty 1.31 (including Nginx 1.31.1 with native tunnel)

FROM openresty/openresty:1.31-alpine

# 安装 runtime 依赖 (envsubst 用于渲染配置，openssl 用于生成自签证书保底，curl 用于健康检查，tzdata 用于动态时区配置)
RUN apk add --no-cache gettext openssl curl bash ca-certificates tzdata

# 创建项目及 Nginx 运行目录
RUN mkdir -p /app /etc/nginx/ssl /var/www/html

# 设置工作目录
WORKDIR /app

# 拷贝项目文件（.dockerignore 排除 ssl/*.pem、.git 等敏感/冗余内容，防私钥烘焙进镜像层）
COPY . /app
# 🛡️ 构建期清理：即使 .dockerignore 缺失，也绝不把宿主机私钥烘焙进镜像层
RUN rm -rf /app/ssl/*.pem /app/ssl/*.key /app/acme_cache 2>/dev/null || true

# 支持在编译构建镜像时，直接将 Lego 或本地 Actions 申请好的证书一键复制 to 运行时证书目录
RUN if [ -d "/app/ssl" ] && [ "$(ls -A /app/ssl 2>/dev/null)" ]; then \
        cp -r /app/ssl/* /etc/nginx/ssl/ 2>/dev/null || true; \
    fi

# 创建 Nginx 静态文件软链接
RUN rm -rf /etc/nginx/conf.d/* && \
    mkdir -p /etc/nginx/conf.d

# 配置静态伪装网页
RUN cp -r /app/html/* /var/www/html/ 2>/dev/null || true

# 移动入口及脚本并赋予执行权限
RUN mv /app/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /app/scripts/bootstrap.sh

# 暴露端口：443 (HTTPS 代理与伪装网站端口；本镜像不监听 80)
EXPOSE 443

STOPSIGNAL SIGTERM

ENTRYPOINT ["docker-entrypoint.sh"]

# 启动 OpenResty Nginx
CMD ["/usr/local/openresty/bin/openresty", "-c", "/etc/nginx/nginx.conf", "-g", "daemon off;"]
