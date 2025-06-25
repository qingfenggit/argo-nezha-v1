#!/bin/bash

# 设置默认值
ARGO_DOMAIN=${ARGO_DOMAIN:-""}
ARGO_AUTH=${ARGO_AUTH:-""}
export TZ=Asia/Shanghai

# 定义函数
check_sqlite() {
    if ! command -v sqlite3 &>/dev/null; then
        echo "正在安装 sqlite3..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y sqlite3 libsqlite3-dev || { echo "sqlite 安装失败"; exit 1; }
        elif command -v yum &>/dev/null; then
            yum install -y sqlite sqlite-devel || { echo "sqlite 安装失败"; exit 1; }
        elif command -v apk &>/dev/null; then
            apk add --no-interactive sqlite sqlite-dev || { echo "sqlite 安装失败"; exit 1; }
        else
            echo "无法识别包管理器，请手动安装 sqlite"
        fi
        echo "sqlite 已安装"
    fi
}

check_cron() {
    # 仅安装不启动，启动放在主流程中统一处理
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        echo "正在安装 cron 服务..."
        if command -v apt-get >/dev/null; then
            apt-get update && apt-get install -y cron || { echo "[Debian/Ubuntu] cron 服务安装失败"; return 1; }
        elif command -v yum >/dev/null; then
            yum install -y cronie || { echo "[CentOS] cron 服务安装失败"; return 1; }
        elif command -v apk >/dev/null; then
            apk add --no-interactive dcron || { echo "[Alpine] cron 服务安装失败"; return 1; }
        else
            echo "不支持的发行版，cron 服务无法安装"
            return 1
        fi
        echo "cron 服务已安装"
    fi
}

start_cron_service() {
    if command -v systemctl >/dev/null; then
        os_id=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
        case "$os_id" in
            centos|rhel|fedora) service_name="crond" ;;
            *) service_name="cron" ;;
        esac
        
        if ! systemctl is-active $service_name &>/dev/null; then
            systemctl enable --now "$service_name" &>/dev/null || { 
                echo "警告: 服务启动失败，自动备份将不可用"; 
                return 1
            }
        fi
    elif command -v rc-service >/dev/null; then
        rc-update add dcron && rc-service dcron start || { 
            echo "警告: 服务启动失败，自动备份将不可用";
            return 1
        }
    else
        echo "警告: 不支持的服务管理器，自动备份将不可用"
        return 1
    fi
    echo "cron 服务已启动"
}

config_cron() {
    echo "设置自动备份任务"
    CRON_DIR="$(pwd)"
    backup_script="$CRON_DIR/backup.sh"
    log_dir="$CRON_DIR/logs"
    mkdir -p "$log_dir" || { echo "警告: 无法创建日志目录"; return 1; }
    
    [ -f "$backup_script" ] || { echo "警告: 未找到备份脚本: $backup_script"; return 1; }
    chmod +x "$backup_script" || { echo "警告: 权限设置失败: $backup_script"; return 1; }
    
    local nezhav1="# NEZHA-V1-BACKUP"
    local backup_job="0 2 * * * ("
    backup_job+="export TZ=Asia/Shanghai; "
    backup_job+="log_file=\"$log_dir/backup-\$(date +\%Y\%m\%d-\%H\%M\%S).log\"; "
    backup_job+="/bin/bash '$backup_script' backup > \"\$log_file\" 2>&1"
    backup_job+=") $nezhav1"
    
    ( crontab -l 2>/dev/null | grep -vF "$nezhav1"; echo "$backup_job" ) | crontab - || {
        echo "警告: 无法设置cron任务";
        return 1
    }
    
    echo "自动备份任务已配置"
    return 0
}

# 1检查并安装依赖
check_sqlite
check_cron

# 尝试恢复备份
/backup.sh restore || echo "警告: 备份恢复失败"

# 启动定时任务服务
if start_cron_service; then
    config_cron || echo "警告: 定时任务配置失败"
fi

# 启动 dashboard app
echo "正在启动哪吒面板"
/dashboard/app &
sleep 3

# 检查并生成证书
if [ -n "$ARGO_DOMAIN" ]; then
    echo "正在生成域名证书: $ARGO_DOMAIN"
    openssl genrsa -out /dashboard/nezha.key 2048 || echo "警告: 生成密钥失败"
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr || echo "警告: 生成CSR失败"
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem || echo "警告: 生成证书失败"
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
