#!/bin/bash

# 加载同目录下的.env文件（如果存在）
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
if [ -f "$SCRIPT_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^# ]] || [[ -z "$key" ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        export "$key"="$value"
    done < "$SCRIPT_DIR/.env"
fi

# 设置默认值
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER:-""}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-""}
BACKUP_BRANCH=${BACKUP_BRANCH:-"nezha-v1"}

LOG_DIR="/root/argo-nezha-v1"
LOG_FILES=("update.log" "backup.log")
LOG_DAYS=7  # 日志保留天数

urlencode() {
    echo -n "$1" | od -An -tx1 | tr -d '\n ' | sed 's/../%&/g'
}
ENCODED_TOKEN=$(urlencode "$GITHUB_TOKEN")
CLONE_URL=https://${ENCODED_TOKEN}@github.com/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME.git

# 统一错误处理函数
die() { echo "错误: $*" >&2; exit 1; }

# 检查必要环境变量
[ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_REPO_OWNER" ] || [ -z "$GITHUB_REPO_NAME" ] && {
    die "未设置必要环境变量, 正在跳过备份/还原"
}

# 检查并安装依赖
check_dependencies() {
    local missing=()
    # 检查 sqlite3
    if ! command -v sqlite3 &>/dev/null; then
        missing+=("sqlite3")
        echo "正在尝试自动安装 sqlite3..."
        # 根据发行版选择包管理器
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y sqlite3 libsqlite3-dev
        elif command -v yum &>/dev/null; then
            sudo yum install -y sqlite sqlite-devel
        elif command -v apk &>/dev/null; then
            sudo apk add sqlite sqlite-dev
        else
            die "无法自动安装sqlite3，请手动安装后重试"
        fi
    fi
    [ ${#missing[@]} -gt 0 ] && die "以下依赖未安装: ${missing[*]}"
}

# 日志清理函数
clean_old_logs() {
    echo "正在执行日志清理..."
    if [ ! -d "$LOG_DIR" ]; then
        echo "警告: 日志目录不存在 - $LOG_DIR" >&2
        return 1
    fi
    if [ ! -w "$LOG_DIR" ]; then
        echo "错误: 无写入权限 - $LOG_DIR" >&2
        return 2
    fi

    # 清理操作
    local deleted_count=0
    for logfile in "${LOG_FILES[@]}"; do
        find "$LOG_DIR" -maxdepth 1 -name "$logfile" -type f -mtime +$LOG_DAYS | while read -r file; do
            echo "清理过期日志: $(basename "$file")"
            rm -f "$file" && ((deleted_count++))
        done
    done

    echo "已清理 $deleted_count 个过期日志文件"
}

# 初始化环境
export GIT_AUTHOR_NAME="[Auto] DB Backup"
export GIT_AUTHOR_EMAIL="backup@nezhav1.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export TZ=Asia/Shanghai
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 通用恢复函数
restore_latest() {
    local file_type=$1 pattern=$2 target=$3
    local latest_file find_output
    
    # 使用临时文件存储查找结果
    find_output=$(mktemp)
    find "$TEMP_DIR/backup_repo/dashboard" -name "$pattern" -exec stat -c "%Y %n" {} \; 2>/dev/null > "$find_output"
    # 处理查找结果
    latest_file=$(sort -nr "$find_output" | head -1 | awk '{print $2}')
    rm -f "$find_output"
    if [ -z "$latest_file" ]; then
        echo "注意: 未找到$file_type备份文件"
        return 1
    fi
    
    echo "正在恢复$file_type: $latest_file → $target"
    mkdir -p "$(dirname "$target")"
    if cp "$latest_file" "$target" 2>/dev/null; then
        echo "$file_type 恢复成功 (来自: $(basename "$latest_file"))"
        return 0
    else
        die "$file_type 恢复失败"
    fi
}

# 恢复备份
restore_backup() {
    echo "正在检查GitHub repo中的最新备份"
    if ! git ls-remote --heads "$CLONE_URL" "$BACKUP_BRANCH" >/dev/null 2>&1; then
        echo "备份分支不存在，跳过恢复"
        return
    fi

    git clone --depth 1 --branch "$BACKUP_BRANCH" --single-branch "$CLONE_URL" "$TEMP_DIR/backup_repo" 2>/dev/null || \
        die "克隆备份仓库失败"
    
    echo "正在从备份恢复数据..."
    mkdir -p dashboard/
    restore_latest "数据库" "sqlite_*.db" "dashboard/sqlite.db" || return 1
    restore_latest "配置" "config_*.yaml" "dashboard/config.yaml" || return 1
}

check_dependencies

# 创建备份
create_backup() {
    TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
    COMMIT_TIME=$(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S %Z')
    BACKUP_DIR="$TEMP_DIR/backup_$TIMESTAMP"
    
    [ ! -f "dashboard/sqlite.db" ] && die "数据库文件不存在"
    mkdir -p "$BACKUP_DIR/dashboard"
    sqlite3 "dashboard/sqlite.db" "VACUUM INTO '$BACKUP_DIR/dashboard/sqlite_$TIMESTAMP.db'" || \
        die "数据库sqlite.db备份失败"
    [ -f "dashboard/config.yaml" ] && {
        cp "dashboard/config.yaml" "$BACKUP_DIR/dashboard/config_$TIMESTAMP.yaml" || \
        die "配置文件config.yaml备份失败"
    }
    
    # 初始化Git仓库
    if git clone --depth 1 --branch "$BACKUP_BRANCH" --single-branch "$CLONE_URL" "$BACKUP_DIR/repo" 2>/dev/null; then
        mv "$BACKUP_DIR/repo/.git" "$BACKUP_DIR/"
        rm -rf "$BACKUP_DIR/repo"
    else
        git init "$BACKUP_DIR"
        (
            cd "$BACKUP_DIR" || exit 1
            git checkout -b "$BACKUP_BRANCH"
        )
    fi
    
    (
        cd "$BACKUP_DIR" || exit 1
        git remote add origin "$CLONE_URL" 2>/dev/null
        # 清理旧备份
        set -e
        DELETED_FILES=$(find dashboard -type f \( -name "sqlite_*.db" -o -name "config_*.yaml" \) -mtime +7)
        [ -n "$DELETED_FILES" ] && {
            echo "清理过期备份:"
            echo "$DELETED_FILES" | xargs -r git rm --quiet --cached
            echo "$DELETED_FILES" | xargs -r rm -f
            git commit -m "自动清理: 删除超过7天的备份" --allow-empty || true
        }
        git add dashboard/sqlite_$TIMESTAMP.db dashboard/config_$TIMESTAMP.yaml
        git commit -m "新增备份 $COMMIT_TIME" --allow-empty
        git push origin "$BACKUP_BRANCH" || die "推送备份到GitHub失败"
        set +e
    )

    clean_old_logs || { echo "注意: 日志清理未完成，但不影响备份结果" >&2; }
    
    echo "备份完成！新增备份文件："
    echo " - sqlite_$TIMESTAMP.db"
    echo " - config_$TIMESTAMP.yaml"
}

# 主逻辑
case "$1" in
    restore) restore_backup ;;
    backup)  create_backup ;;
    *)
    echo "Usage: $0 {backup|restore}" >&2
    exit 1 ;;
esac
