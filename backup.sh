#!/bin/bash

# 确保在 Bash 中执行
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
    exit 0
fi

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

# 设置日志变量
LOG_DIR="$SCRIPT_DIR/logs"
LOG_DAYS=7  # 日志保留天数
DATA_DIR="$SCRIPT_DIR/dashboard"
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
[ ! -d "$DATA_DIR" ] && mkdir -p "$DATA_DIR"
CLONE_DEPTH=20

# 初始化环境
export GIT_AUTHOR_NAME="[Auto] DB Backup"
export GIT_AUTHOR_EMAIL="backup@nezhav1.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export LANG=en_US.UTF-8
export TZ=Asia/Shanghai
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

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

# 日志清理函数
clean_old_logs() {
    echo "正在执行日志清理..."
    [ ! -w "$LOG_DIR" ] && { echo "错误: 无写入权限 - $LOG_DIR" >&2; return 2; }
    
    local deleted_count=0
    while IFS= read -r -d $'\0' file; do
        rm -f "$file"
        echo "已删除日志: $(basename "$file")"
        ((deleted_count++))
    done < <(find "$LOG_DIR" -maxdepth 1 -type f \
        \( -name "update-*.log" -o -name "backup-*.log" \) \
        -mtime +"$LOG_DAYS" -print0 2>/dev/null)
    
    echo "已清理 $deleted_count 个过期日志文件"
}

# 克隆备份仓库
clone_backup_branch() {
    local target_dir=$1
    if git clone --depth "$CLONE_DEPTH" --branch "$BACKUP_BRANCH" --single-branch "$CLONE_URL" "$target_dir" 2>/dev/null; then
        return 0
    else
        echo "❌ 克隆分支失败：$BACKUP_BRANCH"
        return 1
    fi
}

# 通用恢复函数
restore_latest() {
    local file_type=$1 pattern=$2 target=$3
    local latest_file find_output
    
    # 使用临时文件存储查找结果
    find_output=$(mktemp)
    find "$TEMP_DIR/backup_repo/dashboard" -name "$pattern" -exec stat -c "%Y %n" {} \; 2>/dev/null > "$find_output"
    # 处理查找结果
    latest_file=$(sort -nr "$find_output" | head -1 | cut -d' ' -f2-)
    # latest_file=$(sort -nr "$find_output" | head -1 | awk '{print $2}')
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

    clone_backup_branch "$TEMP_DIR/backup_repo" || die "克隆备份仓库失败"
    
    echo "正在从备份恢复数据..."
    if [ ! -d "$DATA_DIR" ]; then
        echo "没有找到备份文件夹，跳过恢复"
        return
    fi
    restore_latest "数据库" "sqlite_*.db" "$DATA_DIR/sqlite.db" || return 1
    restore_latest "配置" "config_*.yaml" "$DATA_DIR/config.yaml" || return 1
}

# 删除旧备份
cleanup_old_backups() {
    echo "开始清理 GitHub 仓库中超过 7 天的备份..."
    local repo_dir="$TEMP_DIR/cleanup_repo"
    if ! clone_backup_branch "$repo_dir"; then
        echo "未找到备份分支或克隆失败，跳过清理"
        return
    fi
    cd "$TEMP_DIR/cleanup_repo" || return 1

    cutoff_date=$(date -u -v-7d +%Y%m%d 2>/dev/null || date -d "-7 days" +%Y%m%d)
    DELETED_FILES=()

    while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        if [[ "$filename" =~ ^sqlite_([0-9]{8})- ]]; then
            file_date="${BASH_REMATCH[1]}"
        elif [[ "$filename" =~ ^config_([0-9]{8})- ]]; then
            file_date="${BASH_REMATCH[1]}"
        else
            continue
        fi

        if [[ "$file_date" -le "$cutoff_date" ]]; then
            DELETED_FILES+=("$file")
        fi
    done < <(find dashboard -type f \( -name "sqlite_*.db" -o -name "config_*.yaml" \) -print0 2>/dev/null)

    if [ ${#DELETED_FILES[@]} -eq 0 ]; then
        echo "没有需要清理的旧备份。"
        return
    fi

    echo "准备删除以下过期备份文件："
    for file in "${DELETED_FILES[@]}"; do
        echo " - $(basename "$file")"
        git rm -q "$file" 2>/dev/null || true
    done

    git commit -m "自动清理: 删除超过7天的备份" || true
    git push origin "$BACKUP_BRANCH" || echo "⚠️ 删除旧备份失败，请检查远程权限"
}

# 创建备份
create_backup() {
    TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
    COMMIT_TIME=$(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S %Z')
    BACKUP_DIR="$TEMP_DIR/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_DIR/dashboard" || die "无法创建目录"
    
    sqlite3 "$DATA_DIR/sqlite.db" "VACUUM INTO '$BACKUP_DIR/dashboard/sqlite_$TIMESTAMP.db'" || \
        die "数据库sqlite.db备份失败"
    cp "$DATA_DIR/config.yaml" "$BACKUP_DIR/dashboard/config_$TIMESTAMP.yaml" || \
        die "配置文件config.yaml备份失败"

    # 初始化 Git 仓库
    if clone_backup_branch "$BACKUP_DIR/repo"; then
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
        git add dashboard/sqlite_$TIMESTAMP.db dashboard/config_$TIMESTAMP.yaml
        git commit -m "新增备份 $COMMIT_TIME" --allow-empty
        git push origin "$BACKUP_BRANCH" || die "推送备份到 GitHub 失败"
    )

    echo "✅ 备份完成！新增备份文件："
    echo " - sqlite_$TIMESTAMP.db"
    echo " - config_$TIMESTAMP.yaml"
}

# 主逻辑
case "$1" in
    restore)
        restore_backup
        ;;
    backup)
        cleanup_old_backups
        create_backup
        clean_old_logs || echo "未执行日志清理"
        ;;
    *)
        echo "Usage: $0 {backup|restore}" >&2
        exit 1
        ;;
esac
