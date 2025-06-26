#!/bin/bash

# 设置默认值
ARGO_DOMAIN=${ARGO_DOMAIN:-""}
CF_TOKEN=${CF_TOKEN:-""}

# 配置定时备份任务
echo "配置定时备份任务..."
mkdir -p "/logs" || echo "无法创建日志目录"
echo "0 2 * * * /backup.sh backup > /logs/backup.log 2>&1 # NEZHA-V1-BACKUP" > /var/spool/cron/crontabs/root

# 尝试恢复备份
echo "尝试恢复备份..."
/backup.sh restore

# 启动 crond
echo "启动 cron 定时任务服务..."
crond

# 启动 dashboard app
echo "启动 dashboard app..."
/dashboard/app &
sleep 3

# 检查并生成证书
if [ -n "$ARGO_DOMAIN" ]; then
    echo "正在生成域名证书: $ARGO_DOMAIN"
    openssl genrsa -out /dashboard/nezha.key 2048
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem
else
    echo "警告: 未设置 ARGO_DOMAIN, 跳过生成证书"
fi

# 启动 Nginx
echo "启动 Nginx..."
nginx -g "daemon off;" &
sleep 3

# 启动 cloudflared
if [ -n "$ARGO_AUTH" ]; then
    echo "启动 cloudflared..."
    cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
else
    echo "警告: 未设置 ARGO_AUTH，正在跳过执行 cloudflared"
fi

# 等待所有后台进程
wait
