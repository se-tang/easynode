#!/bin/bash

#################################################
# EasyNode
# VPS 一键节点部署工具
#
# Version: 1.2 (域名守护 + 健壮性加固版)
#################################################

set -e

# 本脚本依赖 bash（ RANDOM / {1..12} 等）；Alpine 默认无 bash，需先 apk add bash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "请用 bash 运行本脚本（Alpine: apk add bash 后再执行）"
    exit 1
fi

VERSION="1.2"


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
clear 2>/dev/null || true
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
# busybox 变体的 free 可能没有 Swap 行，不兜底的话下面的 -lt 比较会报 test 语法错
[ -z "$SWAP_TOTAL" ] && SWAP_TOTAL=0

echo -e "内存: ${YELLOW}${MEM_TOTAL}MB${RESET}，Swap: ${YELLOW}${SWAP_TOTAL}MB${RESET}"

# 小内存（<=512MB）且 swap 不足（<256MB）→ 尝试创建 swap 防 OOM
if [ "$MEM_TOTAL" -le 512 ] && [ "$SWAP_TOTAL" -lt 256 ]; then
    echo -e "${YELLOW}⚠️ 检测到小内存机器，尝试创建 swap...${RESET}"

    # 先探测 swapon 是否可用（容器常禁 swapon：Operation not permitted）
    # 用 1MB 小文件测试，避免先写大文件再失败、还触发 OOM
    dd if=/dev/zero of=/tmp/.swaptest bs=1M count=1 oflag=direct 2>/dev/null
    chmod 600 /tmp/.swaptest 2>/dev/null
    mkswap /tmp/.swaptest >/dev/null 2>&1
    if swapon /tmp/.swaptest >/dev/null 2>&1; then
        swapoff /tmp/.swaptest >/dev/null 2>&1
        rm -f /tmp/.swaptest
    else
        rm -f /tmp/.swaptest
        echo -e "${YELLOW}⚠️ 此环境禁止 swapon（容器限制），跳过 swap，改用精简安装避免 OOM${RESET}"
        return
    fi

    FREE_DISK=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$FREE_DISK" ] && FREE_DISK=1024

    # 按内存动态定 swap 大小：小内存用大 swap 兜底（测速/突发流量会瞬间拉高内存）
    if [ "$MEM_TOTAL" -lt 96 ]; then
        SWAP_SIZE=256
    elif [ "$FREE_DISK" -lt 1024 ]; then
        SWAP_SIZE=256
    else
        SWAP_SIZE=512
    fi

    # 磁盘封顶：可用磁盘连 "swap + 200MB 余量" 都不够就降档/放弃（根分区顶满比 OOM 更难收拾）
    if [ "$FREE_DISK" -lt $((SWAP_SIZE + 200)) ]; then
        if [ "$SWAP_SIZE" -eq 512 ] && [ "$FREE_DISK" -ge 456 ]; then
            SWAP_SIZE=256
        else
            echo -e "${YELLOW}⚠️ 可用磁盘不足（${FREE_DISK}MB 可用），跳过 swap${RESET}"
            return
        fi
    fi

    # dd 用 oflag=direct 绕过 page cache（64MB 小内存下普通 dd 会撑爆缓存导致 OOM 断 SSH）
    echo "创建 ${SWAP_SIZE}MB swap 文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE oflag=direct 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE conv=fdatasync 2>/dev/null

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1

    if swapon /swapfile >/dev/null 2>&1; then
        grep -q "swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}✅ swap ${SWAP_SIZE}MB 启用成功${RESET}"
    else
        rm -f /swapfile
        echo -e "${YELLOW}⚠️ swap 文件无法启用，跳过，改用精简安装避免 OOM${RESET}"
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

# 先检查 curl/unzip 是否已装（小内存镜像常预装，跳过 apt/apk 避免 64MB 内存 OOM）
NEED=""
command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
command -v unzip >/dev/null 2>&1 || NEED="$NEED unzip"

if [ -z "$NEED" ]; then
    echo "curl/unzip 已安装，跳过"
    return
fi

case $PKG in
apt)
    # 非交互模式，防止个别镜像卡在 apt 确认提示
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y --no-install-recommends $NEED
    apt clean
    ;;
apk)
    # --no-cache 边取索引边装，不落缓存，省磁盘
    apk add --no-cache $NEED
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
    # 确保可执行（容器里可能残留 644 无执行权限的 xray）
    chmod +x "$(command -v xray)" 2>/dev/null || true
    # 验证 xray 真的可用（残留的可能是下载中断的不完整二进制，会段错误）
    if xray version >/dev/null 2>&1; then
        echo "检测到 Xray 已安装"
        xray version | head -n 1
        return
    fi
    echo "检测到残留 Xray 二进制损坏，重新安装..."
    rm -f "$(command -v xray)"
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

# 流式解压 + direct IO 写盘（绕过 page cache，64MB 小内存下 unzip 直接写盘会 OOM 断 SSH）
# unzip -p 解压到 stdout，dd oflag=direct 直接写盘，不占 page cache
# oflag=direct 在 tmpfs/FUSE/老内核 overlayfs/部分 ZFS 上会 EINVAL，失败时回退普通写
if ! unzip -p "$TMP" xray 2>/dev/null | dd of=/usr/local/bin/xray bs=1M oflag=direct 2>/dev/null; then
    if ! unzip -p "$TMP" xray 2>/dev/null | dd of=/usr/local/bin/xray bs=1M conv=fdatasync 2>/dev/null; then
        echo "Xray 解压失败"
        rm -f "$TMP" /usr/local/bin/xray
        exit 1
    fi
fi

chmod +x /usr/local/bin/xray

rm -f "$TMP"

# 显式校验解压产物：管道退出码只看 dd，zip 损坏/截断时会写出空文件，必须单独判断
if [ ! -s /usr/local/bin/xray ]; then
    echo "Xray 二进制为空（下载或解压不完整）"
    rm -f /usr/local/bin/xray
    exit 1
fi
if ! xray version >/dev/null 2>&1; then
    echo "Xray 二进制损坏，无法执行"
    rm -f /usr/local/bin/xray
    exit 1
fi

echo
echo "Xray 版本:"
xray version | head -n 1
echo
echo -e "${GREEN}Xray 安装完成${RESET}"
}


#############################################
# 端口选择（避开 Linux 临时端口段 32768-60999）
#############################################

port_in_use(){
    # Alpine 可能没有 ss，退回 netstat；都没有就当作空闲（真被占用时服务起不来，Restart 会暴露）
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$1 "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q ":$1 "
    else
        return 1
    fi
}

pick_port(){
    local port i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        port=$((10000 + RANDOM % 20000))
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    # 10 次都撞上占用就随机交一个，概率极低
    echo $((10000 + RANDOM % 20000))
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
    PORT=$(pick_port)
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
    # supervise-daemon 提供进程守护（等价 systemd 的 Restart=always），需 OpenRC >= 0.42
cat >/etc/init.d/easynode-xray <<EOF
#!/sbin/openrc-run
name="easynode-xray"
description="EasyNode Xray Service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -config /etc/easynode/config.json"
pidfile="/run/easynode-xray.pid"
depend() {
    need net
}
EOF
    chmod +x /etc/init.d/easynode-xray
    rc-update add easynode-xray default >/dev/null 2>&1
    rc-service easynode-xray restart
else
    # systemd（Debian/Ubuntu）——总是重写，确保新版本内存限制等配置生效
cat >/etc/systemd/system/easynode-xray.service <<EOF
[Unit]
Description=EasyNode Xray Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/easynode
Environment=GOMEMLIMIT=35MiB
ExecStart=/usr/local/bin/xray run -config /etc/easynode/config.json
Restart=always
RestartSec=5
MemoryHigh=30M
MemoryMax=50M
TimeoutStartSec=30
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable easynode-xray.service 2>/dev/null

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
    # 与 xray 同样的完整性校验：残留的可能是下载中断的不完整二进制
    chmod +x "$(command -v cloudflared)" 2>/dev/null || true
    if cloudflared --version >/dev/null 2>&1; then
        echo "检测到 cloudflared 已安装"
        cloudflared --version
        return
    fi
    echo "检测到残留 cloudflared 二进制损坏，重新安装..."
    rm -f "$(command -v cloudflared)"
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

if ! cloudflared --version >/dev/null 2>&1; then
    echo "cloudflared 二进制损坏（下载不完整或架构不对）"
    rm -f /usr/local/bin/cloudflared
    exit 1
fi

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
    # supervise-daemon 守护进程（挂了自动拉起），output_log 供提取 tunnel 地址
    # （sh/supervise-daemon.sh 会把 output_log/error_log 转成 --stdout/--stderr），需 OpenRC >= 0.42
cat >/etc/init.d/easynode-cloudflared <<EOF
#!/sbin/openrc-run
name="easynode-cloudflared"
description="EasyNode Cloudflare Tunnel"
supervisor="supervise-daemon"
command="/usr/local/bin/cloudflared"
command_args="tunnel --url http://127.0.0.1:$PORT --no-autoupdate"
pidfile="/run/easynode-cloudflared.pid"
output_log="/var/log/easynode-cloudflared.log"
error_log="/var/log/easynode-cloudflared.log"
depend() {
    need net
}
EOF
    chmod +x /etc/init.d/easynode-cloudflared
    rc-update add easynode-cloudflared default >/dev/null 2>&1
    # 清空旧日志，避免 get_tunnel_domain 抓到上一次部署的旧隧道域名
    > /var/log/easynode-cloudflared.log 2>/dev/null || true
    rc-service easynode-cloudflared restart
else
    # systemd（Debian/Ubuntu）——总是重写
    # HOME 指到独立目录 + ReadWritePaths：让 ProtectSystem=strict 可用（strict 会把 /root 挂只读）
    mkdir -p /var/lib/easynode-cloudflared
    chmod 700 /var/lib/easynode-cloudflared

cat >/etc/systemd/system/easynode-cloudflared.service <<EOF
[Unit]
Description=EasyNode Cloudflare Tunnel
After=network.target

[Service]
Type=simple
Environment=HOME=/var/lib/easynode-cloudflared
Environment=GOMEMLIMIT=45MiB
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$PORT --no-autoupdate
Restart=always
RestartSec=5
MemoryHigh=40M
MemoryMax=60M
TimeoutStartSec=90
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/easynode-cloudflared

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable easynode-cloudflared.service 2>/dev/null

    # 记录 restart 时间戳，供 get_tunnel_domain 只提取本次新隧道域名（避免抓到旧域名）
    CF_RESTART_AT=$(date +"%Y-%m-%d %H:%M:%S")
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
    DOMAIN=$(journalctl -u easynode-cloudflared --since "${CF_RESTART_AT:-5 minutes ago}" -n 200 --no-pager -l 2>/dev/null | grep -oE "https://[-a-zA-Z0-9]+\.trycloudflare\.com" | tail -n1)
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

NODE="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F$WS_PATH#easynode"

echo "$NODE" > "$BASE_DIR/node.txt"
chmod 600 "$BASE_DIR/node.txt"

# 侧车元数据：当前域名 + 更新时间（watchdog 检测到域名变化时也会刷新）
printf 'domain=%s\nupdated=%s\n' "$DOMAIN" "$(date '+%Y-%m-%d %H:%M:%S')" > "$BASE_DIR/tunnel.meta"
chmod 600 "$BASE_DIR/tunnel.meta"

echo
echo "=============================="
echo "EasyNode 部署完成"
echo
echo "$NODE"
echo "=============================="
}


#############################################
# 端到端校验：确认隧道真的能用，而不只是"服务在跑"
# 404 = 隧道通且 Xray 在应答（Xray 对非匹配路径的标准响应）
# 502 = cloudflared 正常但 Xray 未应答；530 = 隧道未注册/连接器掉线
#############################################

verify_tunnel(){
echo
echo "端到端校验（期望 HTTP 404）"

CODE=""
for i in 1 2 3; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$DOMAIN/" 2>/dev/null)
    [ "$CODE" = "404" ] && break
    [ "$i" -lt 3 ] && sleep 5
done

if [ "$CODE" = "404" ]; then
    echo -e "${GREEN}✅ 隧道校验通过${RESET}"
    return 0
fi

echo -e "${YELLOW}⚠️ 隧道校验未通过（期望 404，实际 ${CODE:-无响应}）${RESET}"
echo "   502=cloudflared 正常但 Xray 未应答；530=隧道未注册或连接器掉线"
echo "   新隧道偶尔需要更长时间生效，可查看 easynode-cloudflared 服务状态/日志排查，"
echo "   或稍后重新运行本脚本重新部署"
return 0
}


#############################################
# 安装域名守护（watchdog）
# Quick Tunnel 每次 cloudflared 重启/机器重启都会换域名，而 node.txt 只在部署时写一次，
# 结果是"服务看着都正常、节点其实已失效"。watchdog 定时检测域名变化并自动重写 node.txt。
#############################################

install_watchdog(){
echo
echo "安装域名守护（watchdog）"

# 1. 守护脚本本体（每次部署都重写，幂等）
cat > /usr/local/bin/easynode-watchdog <<'WEOF'
#!/bin/bash
# EasyNode watchdog：检测 Quick Tunnel 域名变化并重写 node.txt
# 设计为完全静默：域名没变/未部署/信息不全时零输出零写盘

BASE_DIR="/etc/easynode"
NODE_FILE="$BASE_DIR/node.txt"
META_FILE="$BASE_DIR/tunnel.meta"
CF_LOG="/var/log/easynode-cloudflared.log"

# 未部署或已卸载 → 静默退出
[ -f "$NODE_FILE" ] || exit 0

# 取当前域名：journal / 日志里"最后一次出现"的 trycloudflare URL 即当前隧道
# （quick tunnel 每次 start 打印一次 URL，tail -1 天然等于现值，无需时间窗；
#   部署期 get_tunnel_domain 用的是时间窗方案，两者场景不同，正则需保持一致）
DOMAIN=""
if command -v journalctl >/dev/null 2>&1; then
    DOMAIN=$(journalctl -u easynode-cloudflared -n 500 --no-pager 2>/dev/null | grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' | tail -n1)
fi
if [ -z "$DOMAIN" ] && [ -f "$CF_LOG" ]; then
    DOMAIN=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -n1)
fi
[ -n "$DOMAIN" ] || exit 0
DOMAIN=${DOMAIN#https://}

# OpenRC 日志轮转：cloudflared 日志超 5MB 截留尾部 256KB（systemd 走 journal，无此文件）
# 注意要在域名提取之后、退出判断之前做，否则域名长期不变时日志永远轮转不到
if [ -f "$CF_LOG" ]; then
    LOG_SIZE=$(wc -c < "$CF_LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 5242880 ] 2>/dev/null; then
        tail -c 262144 "$CF_LOG" > "$CF_LOG.tmp" 2>/dev/null && cat "$CF_LOG.tmp" > "$CF_LOG" && rm -f "$CF_LOG.tmp"
    fi
fi

# 域名没变 → 静默退出
OLD_DOMAIN=$(sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p' "$NODE_FILE" 2>/dev/null)
[ "$OLD_DOMAIN" = "$DOMAIN" ] && exit 0

# 域名变了 → 复用原有 UUID/WS_PATH 重拼节点链接（端口/UUID/路径都不变，只有域名会变）
[ -f "$BASE_DIR/info" ] || exit 0
. "$BASE_DIR/info"
if [ -z "${UUID:-}" ] || [ -z "${WS_PATH:-}" ]; then
    exit 0
fi

NODE="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F$WS_PATH#easynode"

# 原子替换（tmp + mv），umask 077 保证新文件仍是 600
umask 077
printf '%s\n' "$NODE" > "$NODE_FILE.tmp" 2>/dev/null && mv -f "$NODE_FILE.tmp" "$NODE_FILE" || exit 0
printf 'domain=%s\nupdated=%s\n' "$DOMAIN" "$(date '+%Y-%m-%d %H:%M:%S')" > "$META_FILE.tmp" 2>/dev/null && mv -f "$META_FILE.tmp" "$META_FILE"

exit 0
WEOF
chmod 700 /usr/local/bin/easynode-watchdog

# 2. 定时执行
if [ "$INIT" = "openrc" ]; then
    # Alpine：busybox crond（base 自带），crontab 里只追加自己的行
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    grep -q "easynode-watchdog" /etc/crontabs/root 2>/dev/null || \
        echo "*/3 * * * * /usr/local/bin/easynode-watchdog" >> /etc/crontabs/root
else
cat >/etc/systemd/system/easynode-watchdog.service <<'EOF'
[Unit]
Description=EasyNode Watchdog (tunnel domain sync)
After=easynode-cloudflared.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/easynode-watchdog
EOF

cat >/etc/systemd/system/easynode-watchdog.timer <<'EOF'
[Unit]
Description=Run EasyNode Watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
Unit=easynode-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now easynode-watchdog.timer >/dev/null 2>&1 || true
fi

echo -e "${GREEN}域名守护已启用（域名变化后约 3 分钟内自动更新 node.txt）${RESET}"
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

if [ "$INIT" = "none" ]; then
    echo
    echo -e "${RED}未检测到 systemd 或 OpenRC，无法创建系统服务，退出${RESET}"
    exit 1
fi

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
install_watchdog
verify_tunnel

echo
echo "===================================="
echo -e "${GREEN}EasyNode 部署完成${RESET}"
echo
echo "服务状态:"
echo "- Xray: systemctl status easynode-xray"
echo "- Tunnel: systemctl status easynode-cloudflared"
echo
echo "域名守护:"
if [ "$INIT" = "openrc" ]; then
    echo "- crond 每 3 分钟执行 /usr/local/bin/easynode-watchdog"
else
    echo "- systemctl list-timers easynode-watchdog.timer"
fi
echo
echo "节点保存:"
echo "/etc/easynode/node.txt"
echo "（隧道/机器重启后域名会变，watchdog 会自动更新该文件，客户端重新导入一次即可）"
echo "===================================="
}


#############################################
# 一键卸载（删除所有痕迹）
#############################################

uninstall(){
show_logo
check_root
detect_init

echo
echo -e "${YELLOW}开始卸载 EasyNode...${RESET}"
echo

# 1. 停止并删除服务
if [ "$INIT" = "openrc" ]; then
    rc-service easynode-xray stop >/dev/null 2>&1 || true
    rc-service easynode-cloudflared stop >/dev/null 2>&1 || true
    rc-update del easynode-xray default >/dev/null 2>&1 || true
    rc-update del easynode-cloudflared default >/dev/null 2>&1 || true
    rm -f /etc/init.d/easynode-xray /etc/init.d/easynode-cloudflared
    # crontab 只删 watchdog 那一行（可能有用户自己的任务）
    sed -i '/easynode-watchdog/d' /etc/crontabs/root 2>/dev/null || true
else
    systemctl stop easynode-xray.service easynode-cloudflared.service >/dev/null 2>&1 || true
    systemctl disable easynode-xray.service easynode-cloudflared.service >/dev/null 2>&1 || true
    systemctl disable --now easynode-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/easynode-xray.service /etc/systemd/system/easynode-cloudflared.service
    rm -f /etc/systemd/system/easynode-watchdog.service /etc/systemd/system/easynode-watchdog.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 1.5 停掉可能正在执行的 watchdog，防止卸载过程中又写一次 node.txt
pkill -f "easynode-watchdog" >/dev/null 2>&1 || true

# 2. 杀掉残留进程
pkill -f "/usr/local/bin/xray" >/dev/null 2>&1 || true
pkill -f "/usr/local/bin/cloudflared" >/dev/null 2>&1 || true

# 3. 删除二进制与守护
rm -f /usr/local/bin/xray /usr/local/bin/cloudflared
rm -f /usr/local/bin/easynode-watchdog
rm -rf /var/lib/easynode-cloudflared
rm -f /var/log/easynode-cloudflared.log

# 4. 删除配置目录
rm -rf /etc/easynode

# 5. 删除 swap（如有）
if [ -f /swapfile ]; then
    swapoff /swapfile >/dev/null 2>&1 || true
    rm -f /swapfile
    sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
fi

echo
echo -e "${GREEN}EasyNode 已卸载，所有痕迹已清理${RESET}"
echo
echo "已清理："
echo "  - 系统服务（easynode-xray / easynode-cloudflared）"
echo "  - 域名守护（watchdog 脚本 / systemd timer 或 crond 任务 / tunnel.meta）"
echo "  - 二进制（/usr/local/bin/xray / cloudflared / easynode-watchdog）"
echo "  - 配置目录（/etc/easynode）"
echo "  - cloudflared 状态目录（/var/lib/easynode-cloudflared）"
echo "  - cloudflared 日志（/var/log/easynode-cloudflared.log，如有）"
echo "  - swap 文件（/swapfile，如有）"
echo
}


case "${1:-}" in
    uninstall|remove|delete)
        uninstall
        ;;
    *)
        main
        ;;
esac
