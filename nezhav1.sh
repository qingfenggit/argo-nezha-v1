#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # 重置颜色

# 带颜色的输出函数
info() { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }

# 设置变量
GH_PROXY_URL="https://ghproxy.net"
GH_CLONE_URL="https://github.com/yutian81/argo-nezha-v1.git"
project_dir="argo-nezha-v1"

# 检查并自动安装docker环境
check_docker() {
    # 检查并安装 Docker
    if ! command -v docker &>/dev/null; then
        warning "Docker未安装, 正在自动安装..."
        curl -fsSL https://get.docker.com | sh || {
            error "Docker安装失败! 请手动安装后重试"
            exit 1
        }
        success "Docker安装成功! "
    fi

    # 检查 Docker Compose 插件是否可用（无需单独安装）
    if ! docker compose version &>/dev/null; then
        error "Docker Compose 插件不可用! 请确保安装的是 Docker v20.10+ 版本"
        exit 1
    fi
    
    # 检查 Docker 服务状态
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        warning "Docker服务未运行, 正在尝试启动..."
        systemctl start docker || {
            error "Docker服务启动失败!"
            exit 1
        }
    fi
}

# 检查443端口占用
check_ports() {
    local port_occupied=false
    if command -v ss &>/dev/null && ss -tulnp | grep -q ':443\b'; then
        port_occupied=true
    elif command -v netstat &>/dev/null && netstat -tulnp | grep -q ':443\b'; then
        port_occupied=true
    fi
    if $port_occupied; then
        error "443端口已被占用, 请先停止占用服务"
        exit 1
    fi
    success "443端口可用"
}

# 验证GitHub Token
validate_github_token() {
    info "验证GitHub Token权限..."
    response=$(curl -s -w "%{http_code}" \
             -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" \
             https://api.github.com/user)
    status=${response: -3}
    body=${response%???}
    if [ "$status" -ne 200 ]; then
        error "Token验证失败! HTTP状态码: $status\n响应信息: $body"
        exit 1
    fi
}

# 克隆或更新仓库
clone_or_update_repo() {
    local clone_url="$1"
    
    info "正在处理仓库: $project_dir"
    if [ -d "$project_dir" ]; then
        warning "检测到现有安装，执行安全更新..."
        local backup_dir=$(mktemp -d) || {
            error "临时目录创建失败"
            return 1
        }
        # 设置退出时自动清理备份目录
        trap 'rm -rf "$backup_dir"' EXIT
        # 备份关键数据（静默失败处理）
        cp -rf "$project_dir/dashboard" "$backup_dir/" 2>/dev/null || :
        cp -f "$project_dir/.env" "$backup_dir/" 2>/dev/null || :
        # 清理旧目录
        if ! rm -rf "$project_dir"; then
            error "旧目录清理失败"
            return 2
        fi
        
        # 尝试克隆仓库（带重试机制）
        if ! retry 3 git clone --branch github --depth 1 "$clone_url" "$project_dir"; then
            error "克隆失败！正在恢复备份..."
            mkdir -p "$project_dir" || return 3
            mv "$backup_dir"/* "$project_dir"/ 2>/dev/null || :
            return 4
        fi
        
        # 恢复备份数据
        [ -d "$backup_dir/dashboard" ] && cp -r "$backup_dir/dashboard" "$project_dir/"
        [ -f "$backup_dir/.env" ] && cp "$backup_dir/.env" "$project_dir/"
        
        success "仓库更新完成，用户数据保留成功！"
    else
        info "全新安装模式..."
        if ! retry 3 git clone --branch github --depth 1 "$clone_url" "$project_dir"; then
            error "克隆失败！原因: 1. 网络问题 2. 镜像不可用"
            return 5
        fi
    fi
    return 0
}

# 重试函数
retry() {
    local max=$1
    shift
    local attempt=1
    while [ $attempt -le $max ]; do
        "$@" && return 0
        warning "操作失败，第 $attempt 次重试..."
        ((attempt++))
        sleep $((attempt * 2))
    done
    return 1
}

# 交互式输入变量
input_variables() {
    echo -e "\n${YELLOW}==== 配置输入 (按Ctrl+C退出) ====${NC}"
    
    while true; do
        read -p "GitHub Token: " GITHUB_TOKEN
        [ -n "$GITHUB_TOKEN" ] && break
        warning "Token不能为空!"
    done
    
    validate_github_token
    
    while true; do
        read -p "GitHub 用户名: " GITHUB_REPO_OWNER
        [ -n "$GITHUB_REPO_OWNER" ] && break
        warning "用户名不能为空!"
    done
    
    read -p "用于备份的 GitHub 仓库名 (默认创建私有仓库 nezha-backup): " GITHUB_REPO_NAME
    GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-nezha-backup}
    # 检查仓库是否存在，不存在则创建
    repo_status=$(curl -s -o /dev/null -w "%{http_code}" \
                 -H "Authorization: token $GITHUB_TOKEN" \
                 -H "Accept: application/vnd.github+json" \
                 https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME)

    case $repo_status in
        200) success "仓库已存在，跳过创建" ;;
        404)
            info "正在创建私有仓库..."
            curl -X POST -H "Authorization: token $GITHUB_TOKEN" \
                 -H "Accept: application/vnd.github+json" \
                 -d '{"name":"'"$GITHUB_REPO_NAME"'","private":true}' \
                 https://api.github.com/user/repos || {
                error "仓库创建失败！请检查：\n1. Token是否有repo权限\n2. 仓库名是否合法"
                exit 1
            }
            success "私有仓库 $GITHUB_REPO_NAME 创建成功！" ;;
        403) error "API速率限制已达上限, 请稍后重试" ;;
        *)   error "GitHub API访问异常 (HTTP $repo_status)" ;;
    esac
    
    echo -e "\n${YELLOW}Argo Token 说明：${NC}"
    echo -e " - 纯Token格式: 'ey开头的一长串字符'"
    echo -e " - JSON格式: '{\"Token\":\"xxx\"}' (注意单引号包裹)"
    while true; do
        read -p "请输入Argo Token: " ARGO_AUTH
        [ -n "$ARGO_AUTH" ] && break
        warning "Token不能为空!"
    done
    
    while true; do
        read -p "哪吒面板域名 (如nezha.example.com): " ARGO_DOMAIN
        if [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            warning "域名格式无效！请使用类似 nezha.example.com 的格式"
        fi
    done
    
    cat >.env << EOF
GITHUB_TOKEN=${GITHUB_TOKEN}
GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME}
BACKUP_BRANCH=nezha-v1
ARGO_AUTH=${ARGO_AUTH}
ARGO_DOMAIN=${ARGO_DOMAIN}
EOF
    
    # 显示配置摘要（隐藏敏感信息）
    success "生成配置摘要："
    awk -F'=' '{
        if($1=="GITHUB_TOKEN" || $1=="ARGO_AUTH") 
            print $1 "=" substr($2,1,4) "******"
        else 
            print $0
    }' .env | column -t
}

# 主流程
main() {
    trap 'error "脚本被用户中断"; exit 1' INT
    check_docker # 检查docker环境
    check_ports # 检查端口占用
    
	info "正在检查网络连接..."
	if ! retry 3 curl -s -I https://github.com >/dev/null; then
		error "网络连接异常，请检查网络设置！"
		exit 1
	fi

	# 克隆项目仓库
    clone_url="${GH_PROXY_URL}/${GH_CLONE_URL}"
    if ! clone_or_update_repo "$clone_url"; then
        error "仓库处理失败，错误码: $?"
        exit 1
    fi

	# 输入环境变量
    cd "$project_dir" || { error "目录切换失败"; exit 1; }
    grep -qxF ".env" .gitignore || echo ".env" >> .gitignore
    input_variables
    
    info "正在启动服务..."
    docker compose pull && docker compose up -d || {
        error "启动失败！请检查:\n1. Docker服务状态\n2. 磁盘空间\n3. 端口冲突"
        exit 1
    }
    success "\n✅ 哪吒面板部署成功! 访问地址: https://${ARGO_DOMAIN}"
    
    # 显示初始访问信息
    echo -e "\n${YELLOW}首次访问可能需要：${NC}"
    echo -e "1. 等待SSL证书自动签发(约1-2分钟)"
    echo -e "2. 检查防火墙/安全组放行443端口"
    echo -e "3. aogo 隧道要打开--其他设置--TLS--无TLS验证: on; HTTP2连接: on"
    
    echo -e "\n${BLUE}▍管理命令: ${NC}"
    echo -e "  🔍 查看状态\t${GREEN}docker ps -a${NC}"
    echo -e "  📜 查看日志\t${GREEN}docker logs -f argo-nezha-v1${NC}"
    echo -e "\n${BLUE}▍操作指引: ${NC}"
    echo -e "  📂 请先执行\t${GREEN}cd $project_dir${NC}"
    echo -e "  🟢 启动服务\t${GREEN}docker compose up -d${NC}"
    echo -e "  🔴 停止服务\t${GREEN}docker compose stop${NC}"
    echo -e "  🔄 重启服务\t${GREEN}docker compose restart${NC}"
    echo -e "  ⬇️ 更新镜像\t${GREEN}docker compose pull && docker compose up -d${NC}"
    echo -e "  ⚠️ 完全删除\t${GREEN}docker compose down -v${NC} ${RED}警告: 请先备份数据!${NC}"
}
main
