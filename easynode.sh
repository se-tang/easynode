#!/bin/bash

#################################################
# EasyNode
# VPS 一键节点部署工具
#
# Version: 1.1 (NAT 小内存机器优化版)
#################################################

set -e

VERSION="1.1"


#############################################
# 颜色
#############################################

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"


#############################################
# 基础变量
#############################################

BASE_DIR="/etc/easynode"

# SSH 断开保护：忽略挂断信号（SIGHUP），防止 SSH 断线导致脚本中断
trap '' HUP


#############################################
# Logo
#############################################

show_logo(){
clear
echo "
====================================
        EasyNode v${VERSION}

   VPS 一键节点部署工具

====================================
"
}


#############################################
# Root 检查
#############################################

check_root(){
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行${RESET}"
    exit 1
fi
}


#############################################
# 系统检测
#############################################

detect_os(){
echo
echo "正在检测系统..."
echo

if [ ! -f /etc/os-release ]; then
    echo "无法识别系统"
    exit 1
fi

source /etc/os-release

OS=$ID
VERSION_ID=$VERSION_ID

echo -e "系统: ${GREEN}$PRETTY_NAME${RESET}"

case $OS in
debian|ubuntu)
    PKG="apt"
    ;;
alpine)
    PKG="apk"
    ;;
*)
    echo
    echo "暂不支持系统:"
    echo "$PRETTY_NAME"
    exit 1
    ;;
esac
}


#############################################
# 架构检测
#############################################

detect_arch(){
echo
echo "检测CPU架构..."
ARCH=$(uname -m)

case $ARCH in
x86_64)
    ARCH_NAME="amd64"
    ;;
aarch64)
    ARCH_NAME="arm64"
    ;;
*)
    echo
    echo "暂不支持架构:"
    echo "$ARCH"
    exit 1
    ;;
esac

echo -e "架构: ${GREEN}$ARCH_NAME${RESET}"
}


#############################################
# 服务管理检测（systemd vs OpenRC）
#############################################

detect_init(){
    if command -v systemctl >/dev/null 2>&1; then
        INIT="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT="openrc"
    else
        INIT="none"
    fi
    echo -e "服务管理: ${GREEN}${INIT}${RESET}"
}


#############################################
# 内存检查 + swap（新增：防 OOM）
#############################################

ensure_swap(){
echo
echo "[0/6] 检查内存和 swap"

# 兼容 busybox 的 free（alpine 无 -m 输出 Mem:/Swap: 行）
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}')
[ -z "$MEM_TOTAL" ] && MEM_TOTAL=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", $2/1024}')
[ -z "$SWAP_TOTAL" ] && SWAP_TOTAL=$(free 2>/dev/null | awk '/^Swap:/ {printf "%.0f", $2/1024}')
[ -z "$MEM_TOTAL" ] && MEM_TOTAL=512

echo -e "内存: ${YELLOW}${MEM_TOTAL}MB${RESET}，Swap: ${YELLOW}${SWAP_TOTAL}MB${RESET}"

# 小内存（<256MB）且 swap 不足（<128MB）→ 自动创建 swap 防 OOM
if [ "$MEM_TOTAL" -lt 256 ] && [ "$SWAP_TOTAL" -lt 128 ]; then
    echo -e "${YELLOW}⚠️ 检测到小内存机器，自动创建 swap 防止安装过程 OOM...${RESET}"

    FREE_DISK=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$FREE_DISK" ] && FREE_DISK=1024

    SWAP_SIZE=256
    [ "$FREE_DISK" -lt 512 ] && SWAP_SIZE=128

    echo "创建 ${SWAP_SIZE}MB swap 文件（dd 写实数据）..."
    # 用 dd 写实数据，不用 fallocate（fallocate 的稀疏文件会被 swapon 拒绝："it appears to have holes"）
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE 2>/dev/null

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1

    # 检测 swapon 是否真的成功（ZFS/容器环境可能拒绝 swap 文件）
    if swapon /swapfile >/dev/null 2>&1; then
        grep -q "swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}✅ swap ${SWAP_SIZE}MB 启用成功${RESET}"
    else
        rm -f /swapfile
        echo -e "${YELLOW}⚠️ 此环境不支持 swap 文件（ZFS/容器限制），跳过 swap，改用精简安装避免 OOM${RESET}"
    fi
else
    echo -e "${GREEN}内存/swap 充足，跳过${RESET}"
fi
}


#############################################
# 喘息机制（防低性能机器 OOM）
# 重操作之间：刷磁盘 + 释放 page cache + 停顿，避免内存峰值叠加
#############################################

breathe(){
echo
echo -e "${YELLOW}释放内存缓存，防止低配机器 OOM...${RESET}"
sync
{ echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null || true
sleep 1
}


#############################################
# 安装依赖（精简：去掉 wget/jq，--no-install-recommends）
#############################################

install_dependencies(){
echo
echo "[1/6] 安装基础依赖"

case $PKG in
apt)
    apt update
    apt install -y --no-install-recommends curl unzip
    apt clean
    ;;
apk)
    apk update
    apk add curl unzip
    ;;
esac

echo
echo -e "${GREEN}依赖安装完成${RESET}"
}


#############################################
# 创建目录
#############################################

prepare_directory(){
echo
echo "创建工作目录"
mkdir -p "$BASE_DIR"
chmod 700 "$BASE_DIR"
}


#############################################
# 安装 Xray（精简：只解压二进制，跳过 geoip/geosite 省 29MB）
#############################################

install_xray(){
echo
echo "[2/6] 安装 Xray"

if command -v xray >/dev/null 2>&1; then
    echo "检测到 Xray 已安装"
    xray version | head -n 1
    return
fi

TMP=/tmp/xray.zip

case $ARCH_NAME in
amd64)
    URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    ;;
arm64)
    URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
    ;;
esac

echo
echo "下载 Xray..."
curl -fL --retry 5 --connect-timeout 15 "$URL" -o "$TMP"

mkdir -p /tmp/xray_extract

# 只解压 xray 二进制（geoip.dat/geosite.dat 对 vless+ws 无用，跳过省磁盘+内存）
unzip -j -o "$TMP" xray -d /tmp/xray_extract >/dev/null || {
    echo "Xray 解压失败"
    rm -rf /tmp/xray_extract "$TMP"
    exit 1
}

mv /tmp/xray_extract/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray

rm -rf /tmp/xray_extract "$TMP"

echo
echo "Xray 版本:"
xray version | head -n 1
echo
echo -e "${GREEN}Xray 安装完成${RESET}"
}


#############################################
# 生成 Xray 配置
#############################################

generate_xray_config(){
echo
echo "[3/6] 生成 Xray 配置"

if [ -f "$BASE_DIR/info" ]; then
    echo "检测到已有配置"
    source "$BASE_DIR/info"
    if [ -z "$UUID" ] || [ -z "$PORT" ] || [ -z "$WS_PATH" ]; then
        echo "错误: 配置文件损坏"
        exit 1
    fi
else
    UUID=$(xray uuid)
    PORT=$((20000 + RANDOM % 40000))
    WS_PATH=$(cat /proc/sys/kernel/random/uuid | cut -d "-" -f1)

cat > "$BASE_DIR/info" <<EOF
UUID=$UUID
PORT=$PORT
WS_PATH=$WS_PATH
EOF

chmod 600 "$BASE_DIR/info"
fi

cat > "$BASE_DIR/config.json" <<EOF
{
 "log":{
   "loglevel":"warning"
 },
 "inbounds":[
  {
   "listen":"127.0.0.1",
   "port":$PORT,
   "protocol":"vless",
   "settings":{
    "clients":[
     {
      "id":"$UUID"
     }
    ],
    "decryption":"none"
   },
   "streamSettings":{
    "network":"ws",
    "wsSettings":{
     "path":"/$WS_PATH"
    }
   }
  }
 ],
 "outbounds":[
  {
   "protocol":"freedom"
  }
 ]
}
EOF

chmod 600 "$BASE_DIR/config.json"

echo
echo "UUID: $UUID"
echo "端口: $PORT"
echo "路径: /$WS_PATH"
echo
echo "检查 Xray 配置"

if ! xray run -test -config "$BASE_DIR/config.json"; then
    echo "Xray 配置错误"
    exit 1
fi

echo -e "${GREEN}配置生成完成${RESET}"
}


#############################################
# 创建 systemd 服务（加内存限制）
#############################################

create_service(){
echo
echo "[4/6] 创建系统服务"

if [ "$INIT" = "openrc" ]; then
    # OpenRC（Alpine 等）
    if [ -f /etc/init.d/easynode-xray ]; then
        echo "检测到 Xray 服务已存在"
    else
cat >/etc/init.d/easynode-xray <<EOF
#!/sbin/openrc-run
name="easynode-xray"
description="EasyNode Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /etc/easynode/config.json"
command_background="yes"
pidfile="/run/easynode-xray.pid"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/easynode-xray
        rc-update add easynode-xray default >/dev/null 2>&1
    fi
    rc-service easynode-xray restart
else
    # systemd（Debian/Ubuntu）
    if [ -f /etc/systemd/system/easynode-xray.service ]; then
        echo "检测到 Xray 服务已存在"
    else
cat >/etc/systemd/system/easynode-xray.service <<EOF
[Unit]
Description=EasyNode Xray Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/easynode
ExecStart=/usr/local/bin/xray run -config /etc/easynode/config.json
Restart=always
RestartSec=5
MemoryMax=50M
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable easynode-xray.service
    fi

    systemctl restart easynode-xray.service
fi

echo
echo -e "${GREEN}服务启动完成${RESET}"
}


#############################################
# 安装 Cloudflare Tunnel
#############################################

install_cloudflared(){
echo
echo "[5/6] 安装 Cloudflare Tunnel"

if command -v cloudflared >/dev/null 2>&1; then
    echo "检测到 cloudflared 已安装"
    cloudflared --version
    return
fi

case $ARCH_NAME in
amd64)
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    ;;
arm64)
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    ;;
esac

echo "下载 cloudflared..."
curl -fL --retry 5 --connect-timeout 15 "$URL" -o "/usr/local/bin/cloudflared"

chmod +x /usr/local/bin/cloudflared

echo
cloudflared --version
echo
echo -e "${GREEN}cloudflared 安装完成${RESET}"
}


#############################################
# 创建 Cloudflare Tunnel 服务（加内存限制）
#############################################

create_cloudflared_service(){
echo
echo "创建 Cloudflare Tunnel 服务"

source "$BASE_DIR/info"

if [ "$INIT" = "openrc" ]; then
    # OpenRC（Alpine 等）：用 output_log 记录日志，供获取 tunnel 地址
    if [ -f /etc/init.d/easynode-cloudflared ]; then
        echo "检测到 Cloudflare Tunnel 服务已存在"
    else
cat >/etc/init.d/easynode-cloudflared <<EOF
#!/sbin/openrc-run
name="easynode-cloudflared"
description="EasyNode Cloudflare Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --url http://127.0.0.1:$PORT --no-autoupdate"
command_background="yes"
pidfile="/run/easynode-cloudflared.pid"
output_log="/var/log/easynode-cloudflared.log"
error_log="/var/log/easynode-cloudflared.log"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/easynode-cloudflared
        rc-update add easynode-cloudflared default >/dev/null 2>&1
    fi
    rc-service easynode-cloudflared restart
else
    # systemd（Debian/Ubuntu）
    if [ -f /etc/systemd/system/easynode-cloudflared.service ]; then
        echo "检测到 Cloudflare Tunnel 服务已存在"
    else
cat >/etc/systemd/system/easynode-cloudflared.service <<EOF
[Unit]
Description=EasyNode Cloudflare Tunnel
After=network.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$PORT --no-autoupdate
Restart=always
RestartSec=5
MemoryMax=60M
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable easynode-cloudflared.service
    fi

    systemctl restart easynode-cloudflared.service
fi

echo
echo -e "${GREEN}Cloudflare Tunnel 服务完成${RESET}"
}


#############################################
# 获取 Tunnel 地址
#############################################

get_tunnel_domain(){
echo
echo "获取 Cloudflare Tunnel 地址"

unset DOMAIN

for i in {1..12}
do
if [ "$INIT" = "openrc" ]; then
    DOMAIN=$(grep -oE "https://[-a-zA-Z0-9]+\.trycloudflare\.com" /var/log/easynode-cloudflared.log 2>/dev/null | tail -n1)
else
    DOMAIN=$(journalctl -u easynode-cloudflared --since "5 minutes ago" -n 20 --no-pager -l 2>/dev/null | grep -oE "https://[-a-zA-Z0-9]+\.trycloudflare\.com" | tail -n1)
fi

if [ -n "$DOMAIN" ]; then
    break
fi

echo "等待 Tunnel 创建... ${i}/12"
sleep 5
done

if [ -z "$DOMAIN" ]; then
    echo "获取 Tunnel 地址失败"
    exit 1
fi

DOMAIN=${DOMAIN#https://}

echo
echo "Tunnel 地址: $DOMAIN"
}


#############################################
# 生成节点
#############################################

generate_node(){
echo
echo "生成节点"

source "$BASE_DIR/info"

NODE="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F$WS_PATH"

echo "$NODE" > "$BASE_DIR/node.txt"
chmod 600 "$BASE_DIR/node.txt"

echo
echo "=============================="
echo "EasyNode 部署完成"
echo
echo "$NODE"
echo "=============================="
}


#############################################
# 主流程
#############################################

main(){
show_logo
check_root
detect_os
detect_arch
detect_init
ensure_swap
install_dependencies
breathe
prepare_directory
install_xray
breathe
generate_xray_config
create_service
install_cloudflared
breathe
create_cloudflared_service
get_tunnel_domain
generate_node

echo
echo "===================================="
echo -e "${GREEN}EasyNode 部署完成${RESET}"
echo
echo "服务状态:"
echo "- Xray: systemctl status easynode-xray"
echo "- Tunnel: systemctl status easynode-cloudflared"
echo
echo "节点保存:"
echo "/etc/easynode/node.txt"
echo "===================================="
}


main
