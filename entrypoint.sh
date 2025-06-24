#!/bin/sh

# 设置默认值
ARGO_DOMAIN=${ARGO_DOMAIN:-""}
ARGO_AUTH=${ARGO_AUTH:-""}
export TZ=Asia/Shanghai

# 检查并安装 sqlite
check_sqlite() {
    if ! command -v sqlite3 &>/dev/null; then
        echo "正在安装 sqlite3..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y sqlite3 libsqlite3-dev || echo "sqlite 安装失败"
        elif command -v yum &>/dev/null; then
            yum install -y sqlite sqlite-devel || echo "sqlite 安装失败"
        elif command -v apk &>/dev/null; then
            apk add --no-interactive sqlite sqlite-dev || echo "sqlite 安装失败"
        else
            echo "无法识别包管理器，请手动安装 sqlite"
        fi
        command -v sqlite3 &>/dev/null && success "sqlite 已安装" || echo "sqlite 安装失败"
    fi
}
check_sqlite

# 安装 cron 服务
check_cron() {
    # 安装检测逻辑
    if ! command -v cron >/dev/null 2>&1; then
        echo "正在安装 cron 服务..."
        if command -v apt-get >/dev/null; then
            apt-get install -y cron || echo "[Debian/Ubuntu] cron 服务安装失败"
        elif command -v yum >/dev/null; then
            yum install -y cronie || echo "[CentOS] cron 服务安装失败"
        elif command -v apk >/dev/null; then
            apk add --no-interactive dcron || echo "[Alpine] cron 服务安装失败"
        else
            echo "不支持的发行版，cron 服务无法安装"
        fi
		command -v cron >/dev/null 2>&1 && success "cron 服务已安装" || warning "cron 服务安装失败"
    fi

    # 服务管理模块
    echo "尝试启动并设置开机自启..." 
    if command -v systemctl >/dev/null; then
		os_id=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
		case "$os_id" in
		    centos) service_name="crond" ;;
		    *)      service_name="cron" ;;
		esac
	    if systemctl is-active $service_name &>/dev/null; then
			echo "服务已处于运行状态"
		else
		    systemctl enable --now "$service_name" &>/dev/null || echo "服务启动失败，自动备份将不可用"
		fi
    elif command -v rc-service >/dev/null; then
        rc-update add dcron && rc-service dcron start || echo "服务启动失败，自动备份将不可用"  # Alpine使用dcron服务名
    else
        echo "不支持的服务管理器，自动备份将不可用"
    fi
    return 0  # 强制返回成功状态
}
check_cron

# 配置定时备份任务（北京时间每天凌晨2点）
echo "设置自动备份任务"
nezhav1="# NEZHA-V1-BACKUP"
chmod +x /backup.sh
backup_job="0 2 * * * /bin/sh '/backup.sh backup' >> /backup.log 2>&1 $nezhav1"
(
    crontab -l 2>/dev/null | grep -vF "$nezhav1"
    echo "$backup_job"
) | crontab -

# 尝试恢复备份
/backup.sh restore

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
