#!/bin/sh

# 设置默认值
ARGO_DOMAIN=${ARGO_DOMAIN:-""}
ARGO_AUTH=${ARGO_AUTH:-""}

# 检查并安装 sqlite
check_dependencies() {
    if ! command -v sqlite3 &>/dev/null; then
        echo "正在尝试自动安装 sqlite3..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y sqlite3 libsqlite3-dev || echo "sqlite 安装失败"
        elif command -v yum &>/dev/null; then
            yum install -y sqlite sqlite-devel || echo "sqlite 安装失败"
        elif command -v apk &>/dev/null; then
            apk add sqlite sqlite-dev || echo "sqlite 安装失败"
        else
            echo "无法识别包管理器，请手动安装 sqlite"
        fi
        command -v sqlite3 &>/dev/null || echo "sqlite 安装后仍不可用"
    fi
}
check_dependencies

# 安装 cron 服务
check_cron() {
    if ! command -v cron > /dev/null 2>&1; then
        echo "正在安装 cron 服务..."
        if command -v apt-get > /dev/null 2>&1; then
            apt-get update && apt-get install -y cron || echo "使用 apt-get 安装 cron 服务失败，请手动检查并安装。"
        elif command -v yum > /dev/null 2>&1; then
            yum install -y cronie || echo "使用 yum 安装 cron 服务失败，请手动检查并安装。"
        elif command -v apk > /dev/null 2>&1; then
            apk add dcron || echo "使用 apk 安装 cron 服务失败，请手动检查并安装。"
        else
            echo "无法识别当前系统的包管理器，请手动安装 cron 服务。"
        fi
    fi
}
check_cron

# 配置定时备份任务（北京时间每天凌晨2点）
echo "设置自动备份任务"
chmod +x /backup.sh
backup_job="0 2 * * * /bin/sh /backup.sh backup >> /backup.log 2>&1"
(
    crontab -l 2>/dev/null | grep -vF "$backup_job"
    echo "$backup_job"
) | crontab -

/backup.sh restore # 尝试恢复备份

start_cron() {
if ! pgrep -x "cron" > /dev/null; then
    echo "正在启动 cron 服务"
    if command -v systemctl > /dev/null 2>&1; then
        systemctl start cron || echo "使用 systemctl 启动 cron 服务失败，请手动检查并启动。"
    elif command -v service > /dev/null 2>&1; then
        service cron start || echo "使用 service 启动 cron 服务失败，请手动检查并启动。"
    elif command -v rc-service > /dev/null 2>&1; then
        rc-service cron start || echo "使用 rc-service 启动 cron 服务失败，请手动检查并启动。"
    elif command -v crond > /dev/null 2>&1; then
        crond || echo "使用 crond 启动 cron 服务失败，请手动检查并启动。"
    else
        echo "无法识别当前系统的服务管理命令，请手动启动 cron 服务。"
    fi
fi
}
start_cron

# 启动 dashboard app
echo "正在启动哪吒面板"
/dashboard/app &
sleep 3

# 检查并生成证书
if [ -n "$ARGO_DOMAIN" ]; then
    echo "正在生成域名证书: $ARGO_DOMAIN"
    openssl genrsa -out /dashboard/nezha.key 2048
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem
else
    echo "警告: 未设置ARGO_DOMAIN，正在跳过证书生成"
fi

# 启动 Nginx
echo "正在启动 nginx..."
nginx -g "daemon off;" &
sleep 3

# 启动 cloudflared
if [ -n "$ARGO_AUTH" ]; then
    echo "正在启动 cloudflared..."
    cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
else
    echo "警告: 未设置 ARGO_AUTH，正在跳过执行 cloudflared"
fi

# 等待所有后台进程
wait
