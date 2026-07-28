# 使用本地缓存中已存在的 OpenResty 1.31 Alpine 镜像作为基础镜像
FROM openresty/openresty:1.31-alpine

# 安装 gettext(用于envsubst), procps/util-linux(用于unshare), apache2-utils(用于htpasswd), openssl(用于自签名保底证书)
RUN apk add --no-cache gettext procps util-linux apache2-utils openssl

# 将项目所有文件复制到容器的 /app 目录
COPY . /app
# 设置工作目录为 /app
WORKDIR /app

# 创建 Nginx 运行所需要的目录并创建默认的路由配置文件
RUN mkdir -p /run/nginx /etc/nginx/certs /etc/nginx/conf.d /etc/nginx/stream.d /etc/nginx/rules
# 将证书文件复制到 Nginx 配置目录
COPY certs/ /etc/nginx/certs/
# 复制默认路由规则文件
COPY upstream_rules.conf /etc/nginx/rules/upstream_rules.conf
# 移动入口脚本并赋予执行权限
RUN mv docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh && chmod +x /usr/local/bin/docker-entrypoint.sh
# 赋予 /app/scripts 目录下所有脚本执行权限，这会自动包含我们新增的 24-generate-debug-server.sh
RUN chmod +x /app/scripts/*.sh

# 声明容器对外暴露的端口（已极致精简，仅暴露 443 极速网关入口）
EXPOSE 443

# [新] 定义优雅停止的信号
STOPSIGNAL SIGTERM

# 定义容器启动时默认执行的入口点
ENTRYPOINT ["docker-entrypoint.sh"]

# 定义容器启动时默认执行的命令
CMD ["/usr/local/openresty/bin/openresty", "-c", "/etc/nginx/nginx.conf", "-g", "daemon off;"]
