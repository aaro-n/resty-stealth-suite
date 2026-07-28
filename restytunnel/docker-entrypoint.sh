#!/bin/sh
# File: docker-entrypoint.sh
# Description: RestyTunnel 容器启动主入口控制脚本 (已升级为统一 Bootstrap 模式)

set -e

BOOTSTRAP_SCRIPT="/app/scripts/bootstrap.sh"

echo "=========================================================="
echo "          欢迎使用 RestyTunnel 极速代理控制台             "
echo "=========================================================="

if [ -f "$BOOTSTRAP_SCRIPT" ]; then
    . "$BOOTSTRAP_SCRIPT"
else
    echo "[ERROR] 未找到统一引导脚本 $BOOTSTRAP_SCRIPT，启动失败。"
    exit 1
fi

# 接管进程，优雅向下执行镜像中的 CMD 或者是命令行参数
exec "$@"
