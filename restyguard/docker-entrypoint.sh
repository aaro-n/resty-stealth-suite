#!/bin/sh

set -e
SCRIPTS_DIR="/app/scripts"

# 安全验证：RG_SECRET_TOKEN 必须被显式设置，且不能为空
if [ -z "$RG_SECRET_TOKEN" ] || [ "$RG_SECRET_TOKEN" = "change-me-please" ]; then
    echo "[FATAL] RG_SECRET_TOKEN 环境变量未设置或使用了不安全的默认值。"
    echo "       请通过 '-e RG_SECRET_TOKEN=你的安全密钥' 设置一个唯一的密钥。"
    exit 1
fi

# 🗺️ [自适应时区同步机制] 
# 在容器启动的最前置阶段，将系统 tzdata 时区文件软链接至 /etc/localtime 并更新 /etc/timezone，
# 确保在 Alpine 镜像下任何时间计算、日志打印以及 Nginx 底层时间均完美对齐用户设置。
TARGET_TZ="${RG_TZ:-Asia/Shanghai}"
if [ -f "/usr/share/zoneinfo/${TARGET_TZ}" ]; then
    echo "=> [0/3] 正在应用系统时区：${TARGET_TZ} ..."
    ln -sf "/usr/share/zoneinfo/${TARGET_TZ}" /etc/localtime
    echo "${TARGET_TZ}" > /etc/timezone
else
    # 兼容在一些未安装完整 tzdata 的裁剪系统下，缺省生成北京时间软链的策略
    echo "=> [0/3] 未找到时区文件 ${TARGET_TZ}，保底软链接为北京时间..."
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
fi

echo "=> [1/3] 正在加载并编译统一配置..."
. "${SCRIPTS_DIR}/bootstrap.sh"

echo "=> [2/3] 正在执行启动前任务..."
# [v3.3.0 核心修正] 直接使用硬编码的日志文件路径
REJECT_LOG_FULL_PATH="/dev/shm/rejected_ips.log"

if [ -f "$REJECT_LOG_FULL_PATH" ]; then
    echo "   - 正在裁剪拒绝日志文件 '$REJECT_LOG_FULL_PATH'..."
    tail -n 10 "$REJECT_LOG_FULL_PATH" > "${REJECT_LOG_FULL_PATH}.tmp" && mv "${REJECT_LOG_FULL_PATH}.tmp" "$REJECT_LOG_FULL_PATH"
else
    echo "   - 拒绝日志文件不存在，无需裁剪。"
fi

echo "--- 初始化完成 ---"
echo ""

echo "=> [3/3] 准备启动 Nginx 服务..."
if [ "$$" -eq 1 ]; then
    exec "$@"
else
    exec unshare -fp --mount-proc sh -c 'exec "$@"' sh "$@"
fi
