#!/bin/bash

#################################################
# EasyNode
# VPS 一键节点部署工具
#
# Version: 1.3 (内存挡位自适应 + 健康守护自愈版)
#################################################

set -e

# 本脚本依赖 bash（ RANDOM / {1..12} 等）；Alpine 默认无 bash，需先 apk add bash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "请用 bash 运行本脚本（Alpine: apk add bash 后再执行）"
    exit 1
fi

VERSION="1.3"


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
# 内存挡位表（核心）
#
# 机器内存五花八门，但真实世界里几乎是这几个档：
#     64M / 128M / 256M / 512M / 1G 及以上
# 这里按实测内存自动落到对应挡位，并由挡位统一给出
# xray / cloudflared 的 GOMEMLIMIT + MemoryHigh + MemoryMax。
#
# 设计原则（对应 v1.2 的两个线上事故）：
#  1) 挡位越高给得越宽，不做"算术等比缩放"——1G 以上的机器上
#     xray 即使空载也要吃十几 MB，硬卡 50M 会被 cgroup OOM 杀掉，
#     而 OOM 杀人时 anon-rss 往往只有几十 KB，撑爆配额的是
#     Go 运行时的 file-rss / page cache / 内核账目。
#  2) MemoryHigh 与 MemoryMax 之间留足余量：MemoryHigh 一旦被
#     长期顶住，进程会把时间全耗在内存回收上，表现就是
#     "systemctl status 显示 active，节点却完全不可用"。
#  3) 1G+ 是"不设上限"挡：不写 MemorySwapMax、不加 CPUQuota，
#     只是给一个远高于真实工作集的护栏，防止异常暴涨吃光母机。
#
# 挡位对应关系（xray 真实工作集约 10-20MB，cloudflared 约 20-45MB）：
#   机器内存   GOMEMLIMIT(High/Max) xray      cloudflared
#   64M        24MiB (32M/40M)                28MiB (36M/44M)
#   128M       36MiB (48M/56M)                40MiB (52M/64M)
#   256M       56MiB (72M/88M)                60MiB (80M/96M)
#   512M       96MiB (96M/128M)               64MiB (80M/112M)
#   1G+        256MiB (256M/384M)             96MiB (128M/256M)
#
# 落挡容差（重要）：
#   商家说的"128M / 512M / 1G"是物理内存，装完系统后 /proc/meminfo 的
#   MemTotal 一定更小（内核镜像、保留内存、固件占用等，通常少 2%~10%）。
#   如果按标称值直接卡边界，就会出现：
#     - 标称 64M  的机器实测才 58M   → 掉到"比 64 更小"的兜底逻辑
#     - 标称 512M 的机器实测才 480M  → 被误判成 256 挡（挡位偏小，反而更危险）
#     - 标称 1G   的机器实测才 950M  → 被误判成 512 挡
#   所以判定阈值下浮约 10%，让"标称值"而不是"实测值"决定挡位。
#   注意：偏大的挡位只是限制更宽松，不会把机器撑爆；偏小才有卡死风险，
#   因此宁可靠大一挡。
#############################################

MEM_TIER=""
XRAY_GOMEMLIMIT=""; XRAY_MEM_HIGH=""; XRAY_MEM_MAX=""
CF_GOMEMLIMIT="";   CF_MEM_HIGH="";   CF_MEM_MAX=""

select_mem_tier(){
    # 取实测总内存（MB）：优先 /proc/meminfo（busybox 也一定有），退回 free
    if [ -r /proc/meminfo ]; then
        MEM_TOTAL=$(awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    fi
    [ -z "${MEM_TOTAL:-}" ] && MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
    [ -z "${MEM_TOTAL:-}" ] && MEM_TOTAL=512

    # 落挡阈值（下浮 15% 再减 12MB，抵消装完系统后的内存损耗）：
    #   >858 → 1G+   (标称 1024)
    #   >423 → 512   (标称 512)
    #   >206 → 256   (标称 256)
    #   >97  → 128   (标称 128)
    #   其余 → 64
    # 为什么"百分比 + 固定值"两层：小机器的损耗里有一部分是固定的
    # （内核镜像/保留内存/固件通常吃掉 10MB 上下），对 1024MB 的机器只占 1%，
    # 对 128MB 的机器却占 8%。只按百分比下浮，小机器容易被误判掉挡。
    # 实测覆盖（约 15% 损耗 + 12MB 固定开销）：
    #   标称 1024 实测 910 → 1G+；标称 512 实测 452 → 512；
    #   标称 256 实测 226 → 256；标称 128 实测 113 → 128；标称 64 实测 56 → 64
    if   [ "$MEM_TOTAL" -gt 858 ]; then MEM_TIER=1G
    elif [ "$MEM_TOTAL" -gt 423 ]; then MEM_TIER=512
    elif [ "$MEM_TOTAL" -gt 206 ]; then MEM_TIER=256
    elif [ "$MEM_TOTAL" -gt 97  ]; then MEM_TIER=128
    else                                MEM_TIER=64
    fi

    case "$MEM_TIER" in
    64)
        XRAY_GOMEMLIMIT=24MiB; XRAY_MEM_HIGH=32M; XRAY_MEM_MAX=40M
        CF_GOMEMLIMIT=28MiB;   CF_MEM_HIGH=36M;   CF_MEM_MAX=44M
        ;;
    128)
        XRAY_GOMEMLIMIT=36MiB; XRAY_MEM_HIGH=48M; XRAY_MEM_MAX=56M
        CF_GOMEMLIMIT=40MiB;   CF_MEM_HIGH=52M;   CF_MEM_MAX=64M
        ;;
    256)
        XRAY_GOMEMLIMIT=56MiB; XRAY_MEM_HIGH=72M; XRAY_MEM_MAX=88M
        CF_GOMEMLIMIT=60MiB;   CF_MEM_HIGH=80M;   CF_MEM_MAX=96M
        ;;
    512)
        XRAY_GOMEMLIMIT=96MiB; XRAY_MEM_HIGH=96M; XRAY_MEM_MAX=128M
        CF_GOMEMLIMIT=64MiB;   CF_MEM_HIGH=80M;   CF_MEM_MAX=112M
        ;;
    1G)
        XRAY_GOMEMLIMIT=256MiB; XRAY_MEM_HIGH=256M; XRAY_MEM_MAX=384M
        CF_GOMEMLIMIT=96MiB;    CF_MEM_HIGH=128M;   CF_MEM_MAX=256M
        ;;
    esac

    # 实测值一定比商家标称小（内核镜像/保留内存/固件占用），提示一下避免误会
    echo -e "内存挡位: ${GREEN}${MEM_TIER}${RESET}（进程可见 ${MEM_TOTAL}MB，通常略低于商家标称）"
    echo -e "  xray        GOMEMLIMIT=${XRAY_GOMEMLIMIT} MemoryHigh=${XRAY_MEM_HIGH} MemoryMax=${XRAY_MEM_MAX}"
    echo -e "  cloudflared GOMEMLIMIT=${CF_GOMEMLIMIT} MemoryHigh=${CF_MEM_HIGH} MemoryMax=${CF_MEM_MAX}"
}


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

# 按实测内存落挡，并由挡位决定 xray / cloudflared 的内存限制（供 [4/6][5/6] 使用）
select_mem_tier

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

    # cat|cut 管道会吞掉 cat 的失败（/proc 不可用的极端容器），空 WS_PATH 会静默生成坏配置
    if [ -z "$WS_PATH" ]; then
        echo "错误: 生成 WS_PATH 失败（/proc/sys/kernel/random/uuid 不可用？）"
        exit 1
    fi

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
Environment=GOMEMLIMIT=${XRAY_GOMEMLIMIT:-256MiB}
ExecStart=/usr/local/bin/xray run -config /etc/easynode/config.json
Restart=always
RestartSec=5
MemoryHigh=${XRAY_MEM_HIGH:-256M}
MemoryMax=${XRAY_MEM_MAX:-384M}
TimeoutStartSec=30
# 内存卡死时进程可能长时间不响应 SIGTERM；不设此项时 systemd 会干等默认 90s，
# 表现为"部署卡在创建系统服务" / "卸载卡住不显示日志"。收敛到 15s 超时即 SIGKILL。
TimeoutStopSec=15
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
Environment=GOMEMLIMIT=${CF_GOMEMLIMIT:-96MiB}
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$PORT --no-autoupdate
Restart=always
RestartSec=5
MemoryHigh=${CF_MEM_HIGH:-128M}
MemoryMax=${CF_MEM_MAX:-256M}
TimeoutStartSec=90
# 同 xray：避免内存受限时 stop/restart 干等 90s
TimeoutStopSec=15
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
    # || true：set -e 下 curl 失败（新域名 DNS/握手未就绪，rc=6 等）会中止整个脚本，
    # 重试循环形同虚设（真机回归：Alpine 部署停在端到端校验、退出码 6）
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$DOMAIN/" 2>/dev/null || true)
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

# OpenRC 日志轮转（放在域名提取之前）：超 5MB 截留尾部 256KB（systemd 走 journal，无此文件）。
# 域名行只在 cloudflared 启动时打一次，节点跑久了会落在被裁部分；把当前域名补回尾部，
# 保证 URL 已被裁掉时 watchdog 依然"看得见"当前域名，且超大日志总能被轮到
if [ -f "$CF_LOG" ]; then
    LOG_SIZE=$(wc -c < "$CF_LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 5242880 ] 2>/dev/null; then
        tail -c 262144 "$CF_LOG" > "$CF_LOG.tmp" 2>/dev/null
        CUR_DOM=$(sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p' "$NODE_FILE" 2>/dev/null)
        [ -n "$CUR_DOM" ] && echo "https://$CUR_DOM" >> "$CF_LOG.tmp"
        cat "$CF_LOG.tmp" > "$CF_LOG" 2>/dev/null && rm -f "$CF_LOG.tmp"
    fi
fi

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
    # 不依赖 crond：实测部分精简 Alpine 没有 crond 的 init 脚本（/etc/init.d/crond 缺失），
    # rc-update 静默失败后 watchdog 永远不会被执行。改用 supervise-daemon 守护一个
    # 常驻循环（与其余服务同一守护风格），每 3 分钟跑一次 watchdog
    # 顺带清理早期版本用 crond 调度时写入的 crontab 行
    sed -i '/easynode-watchdog/d' /etc/crontabs/root 2>/dev/null || true

cat > /usr/local/bin/easynode-watchdog-loop <<'LEOF'
#!/bin/sh
# EasyNode watchdog 常驻循环：每 3 分钟检测一次隧道域名
while true; do
    /usr/local/bin/easynode-watchdog >/dev/null 2>&1 || true
    sleep 180
done
LEOF
    chmod 700 /usr/local/bin/easynode-watchdog-loop

cat >/etc/init.d/easynode-watchdog <<'EOF'
#!/sbin/openrc-run
name="easynode-watchdog"
description="EasyNode Watchdog (tunnel domain sync)"
supervisor="supervise-daemon"
command="/usr/local/bin/easynode-watchdog-loop"
pidfile="/run/easynode-watchdog.pid"
EOF
    # 缺了这行 rc-service 会 Permission denied、rc-update 注册不进 runlevel
    # （与 xray/cloudflared 两个 init 脚本保持一致）
    chmod +x /etc/init.d/easynode-watchdog

    if rc-update add easynode-watchdog default >/dev/null 2>&1 && rc-service easynode-watchdog restart >/dev/null 2>&1; then
        echo -e "${GREEN}域名守护已启用（常驻循环每 3 分钟检测一次，域名变化后自动更新 node.txt）${RESET}"
    else
        echo -e "${YELLOW}⚠️ watchdog 服务启动失败，隧道换域名后需重跑本脚本同步节点${RESET}"
    fi
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
    if systemctl enable --now easynode-watchdog.timer >/dev/null 2>&1; then
        echo -e "${GREEN}域名守护已启用（timer 每 3 分钟检测一次，域名变化后自动更新 node.txt）${RESET}"
    else
        echo -e "${YELLOW}⚠️ watchdog timer 启用失败，隧道换域名后需重跑本脚本同步节点${RESET}"
    fi
fi
}


#############################################
# 安装健康守护（end-to-end 自愈）
#
# 与 watchdog 的分工：
#   watchdog        —— 只管"隧道域名变了要同步 node.txt"，不看节点死活
#   health（本项）  —— 只管"节点到底还能不能用"，看死活并自动恢复
#
# 为什么必须有它：systemd 的 Restart=always 只能发现"进程退出"。但线上更多见的是
# 进程活着却不可用（内存被 MemoryHigh 卡死、隧道 connector 掉线但进程没退），
# 此时 systemctl status 一片正常，节点却已经死了，没有任何机制会去救。
#
# 判定标准（HTTP 404 = xray 对不匹配路径的标准应答）：
#   本地 127.0.0.1:$PORT  → 404 才算 xray 活
#   隧道 https://域名/    → 404 才算端到端通（502 = xray 没应答；530 = 隧道掉线）
#
# 只恢复不重建：UUID / PORT / WS_PATH 永远从 info 复用，绝不重新生成。
#############################################

install_health_guard(){
echo
echo "安装健康守护（节点自愈）"

cat > /usr/local/bin/easynode-health <<'HEOF'
#!/bin/bash
# EasyNode 健康守护：检测"服务在跑但节点不可用"并自动恢复。
# 只做恢复，不重建：UUID/PORT/WS_PATH 永不改动。
# 退出码 0 = 健康或已自愈；1 = 仍异常。
BASE=/etc/easynode
NODE_FILE=$BASE/node.txt
INFO=$BASE/info
STATUS=$BASE/health.json
[ -f "$NODE_FILE" ] || exit 0          # 未部署 → 静默退出
[ -f "$INFO" ] || exit 0

log(){ echo "easynode-health: $*"; }
restart_unit(){ systemctl restart "$1" >/dev/null 2>&1 || true; }

write_status(){
    # $1=ok/fail  $2=domain  $3=xray_ok  $4=action
    local st="$1" dom="${2:-}" xo="${3:-0}" act="${4:-none}"
    umask 077
    # 注意：分隔符不能叫 EOF —— 本段整体处在外层 <<'HEOF' 里，
    # 内层若用 EOF 会让 bash 提前结束外层 heredoc，整个脚本语法崩掉。
    cat > "$STATUS.tmp" 2>/dev/null <<JSONEOF
{
  "checked": "$(date '+%Y-%m-%d %H:%M:%S%z')",
  "status": "$st",
  "domain": "$dom",
  "xray_local_ok": $xo,
  "action": "$act",
  "xray_restarts": $(systemctl show easynode-xray -p NRestarts --value 2>/dev/null || echo 0),
  "cloudflared_restarts": $(systemctl show easynode-cloudflared -p NRestarts --value 2>/dev/null || echo 0),
  "xray_mem_peak": $(cat /sys/fs/cgroup/system.slice/easynode-xray.service/memory.peak 2>/dev/null || echo 0),
  "cloudflared_mem_peak": $(cat /sys/fs/cgroup/system.slice/easynode-cloudflared.service/memory.peak 2>/dev/null || echo 0)
}
JSONEOF
    mv -f "$STATUS.tmp" "$STATUS" 2>/dev/null || true
}

. "$INFO"
PORT=${PORT:-0}
WS_PATH=${WS_PATH:-}
[ "$PORT" != 0 ] || exit 0

ACTION="none"

# ---- 1. xray：本地回环端口必须有人应答 ----
xray_ok=0
for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true)
    [ "$code" = "404" ] && { xray_ok=1; break; }
    sleep 1
done
if [ "$xray_ok" != 1 ]; then
    log "xray 未应答（code=${code:-无}），重启 easynode-xray"
    restart_unit easynode-xray
    ACTION="restart-xray"
    sleep 6
    for i in 1 2 3; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true)
        [ "$code" = "404" ] && { xray_ok=1; break; }
        sleep 2
    done
    [ "$xray_ok" = 1 ] && log "xray 已恢复" || log "xray 重启后仍未应答"
fi

# ---- 2. 取当前隧道域名（日志里最后一次出现的即为当前隧道）----
get_dom(){
    local d=""
    if command -v journalctl >/dev/null 2>&1; then
        d=$(journalctl -u easynode-cloudflared -n 500 --no-pager 2>/dev/null \
            | grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' | tail -n1)
    fi
    if [ -z "$d" ] && [ -f /var/log/easynode-cloudflared.log ]; then
        d=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' /var/log/easynode-cloudflared.log 2>/dev/null | tail -n1)
    fi
    echo "${d#https://}"
}
DOM=$(get_dom)

# ---- 3. cloudflared：隧道必须端到端可达 ----
if [ -z "$DOM" ]; then
    log "日志中找不到隧道域名，重启 easynode-cloudflared"
    restart_unit easynode-cloudflared
    ACTION="restart-cloudflared"
    sleep 15
    DOM=$(get_dom)
else
    tun_ok=0
    for i in 1 2 3; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOM/" 2>/dev/null || true)
        [ "$code" = "404" ] && { tun_ok=1; break; }
        sleep 3
    done
    if [ "$tun_ok" != 1 ]; then
        log "隧道不可用（https://$DOM/ -> code=${code:-无}），重启 easynode-cloudflared"
        restart_unit easynode-cloudflared
        ACTION="restart-cloudflared"
        sleep 20
        DOM=$(get_dom)
    fi
fi

[ -n "$DOM" ] || { log "仍无法取得隧道域名"; write_status fail "" "$xray_ok" "$ACTION"; exit 1; }

# ---- 4. 同步 node.txt（只换域名，UUID/PORT/WS_PATH 复用）----
OLD=""
[ -f "$NODE_FILE" ] && OLD=$(sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p' "$NODE_FILE" 2>/dev/null)
if [ "$OLD" != "$DOM" ]; then
    NODE="vless://$UUID@$DOM:443?encryption=none&security=tls&type=ws&host=$DOM&path=%2F$WS_PATH#easynode"
    umask 077
    printf '%s\n' "$NODE" > "$NODE_FILE.tmp" 2>/dev/null && mv -f "$NODE_FILE.tmp" "$NODE_FILE"
    printf 'domain=%s\nupdated=%s\n' "$DOM" "$(date '+%Y-%m-%d %H:%M:%S')" > "$BASE/tunnel.meta.tmp" 2>/dev/null && mv -f "$BASE/tunnel.meta.tmp" "$BASE/tunnel.meta"
    log "隧道域名变化: $OLD -> $DOM，已更新 node.txt（客户端重新导入一次即可）"
    [ "$ACTION" = "none" ] && ACTION="sync-domain"
fi

# ---- 5. 复检 ----
sleep 2
FINAL=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOM/" 2>/dev/null || true)
if [ "$FINAL" = "404" ]; then
    log "复检通过：https://$DOM/ -> 404"
    write_status ok "$DOM" "$xray_ok" "$ACTION"
    exit 0
fi
log "复检未通过：https://$DOM/ -> code=${FINAL:-无}"
write_status fail "$DOM" "$xray_ok" "$ACTION"
exit 1
HEOF
chmod 700 /usr/local/bin/easynode-health

if [ "$INIT" = "openrc" ]; then
    # OpenRC：复用 watchdog 那套常驻循环的做法（部分精简 Alpine 没有 crond init 脚本）
    sed -i '/easynode-health/d' /etc/crontabs/root 2>/dev/null || true
cat > /usr/local/bin/easynode-health-loop <<'LEOF'
#!/bin/sh
# EasyNode 健康守护常驻循环：每 60 秒端到端自检一次
while true; do
    /usr/local/bin/easynode-health >/dev/null 2>&1 || true
    sleep 60
done
LEOF
    chmod 700 /usr/local/bin/easynode-health-loop

cat >/etc/init.d/easynode-health <<'EOF'
#!/sbin/openrc-run
name="easynode-health"
description="EasyNode Health Guard (end-to-end self-healing)"
supervisor="supervise-daemon"
command="/usr/local/bin/easynode-health-loop"
pidfile="/run/easynode-health.pid"
EOF
    chmod +x /etc/init.d/easynode-health

    if rc-update add easynode-health default >/dev/null 2>&1 && rc-service easynode-health restart >/dev/null 2>&1; then
        echo -e "${GREEN}健康守护已启用（常驻循环每 60 秒自检一次，节点不可用会自动恢复）${RESET}"
    else
        echo -e "${YELLOW}⚠️ 健康守护启动失败，节点异常时需手工 systemctl/rc-service 重启${RESET}"
    fi
else
cat >/etc/systemd/system/easynode-health.service <<'EOF'
[Unit]
Description=EasyNode Health Guard (end-to-end self-healing)
After=easynode-xray.service easynode-cloudflared.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/easynode-health
EOF

cat >/etc/systemd/system/easynode-health.timer <<'EOF'
[Unit]
Description=Run EasyNode Health Guard every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=1min
AccuracySec=5s
Unit=easynode-health.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if systemctl enable --now easynode-health.timer >/dev/null 2>&1; then
        echo -e "${GREEN}健康守护已启用（timer 每 1 分钟自检一次，节点不可用会自动恢复）${RESET}"
    else
        echo -e "${YELLOW}⚠️ 健康守护 timer 启用失败，节点异常时需手工 systemctl restart${RESET}"
    fi
fi

echo -e "  状态文件: ${YELLOW}${BASE_DIR}/health.json${RESET}"
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
install_health_guard
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
    echo "- watchdog 常驻循环每 3 分钟检测（rc-service easynode-watchdog status）"
else
    echo "- systemctl list-timers easynode-watchdog.timer"
fi
echo
echo "健康守护（节点不可用会自动恢复）:"
if [ "$INIT" = "openrc" ]; then
    echo "- health 常驻循环每 60 秒自检（rc-service easynode-health status）"
else
    echo "- systemctl list-timers easynode-health.timer"
fi
echo "- 状态文件: /etc/easynode/health.json"
echo "- 手动执行一次: /usr/local/bin/easynode-health"
echo
echo "内存挡位:"
echo "- 实测 ${MEM_TOTAL}MB → 挡位 ${MEM_TIER}"
echo "- xray: MemoryHigh=$XRAY_MEM_HIGH MemoryMax=$XRAY_MEM_MAX"
echo "- cloudflared: MemoryHigh=$CF_MEM_HIGH MemoryMax=$CF_MEM_MAX"
echo
echo "节点保存:"
echo "/etc/easynode/node.txt"
echo "（隧道/机器重启后域名会变，watchdog 会自动更新该文件，客户端重新导入一次即可）"
echo "（只重启 xray 不会换域名；只有 cloudflared 重启才会换域名）"
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
    # 停掉 watchdog 常驻服务并删除其 init 脚本
    rc-service easynode-watchdog stop >/dev/null 2>&1 || true
    rc-update del easynode-watchdog default >/dev/null 2>&1 || true
    rm -f /etc/init.d/easynode-watchdog
    # 清理早期版本用 crond 调度时写入的行（只删自己的，可能有用户自己的任务）
    sed -i '/easynode-watchdog/d' /etc/crontabs/root 2>/dev/null || true
else
    systemctl stop easynode-xray.service easynode-cloudflared.service >/dev/null 2>&1 || true
    systemctl disable easynode-xray.service easynode-cloudflared.service >/dev/null 2>&1 || true
    systemctl disable --now easynode-watchdog.timer >/dev/null 2>&1 || true
    # 先停健康守护：否则卸载中途它可能把已停掉的 xray 又拉起来
    systemctl disable --now easynode-health.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/easynode-xray.service /etc/systemd/system/easynode-cloudflared.service
    rm -f /etc/systemd/system/easynode-watchdog.service /etc/systemd/system/easynode-watchdog.timer
    rm -f /etc/systemd/system/easynode-health.service /etc/systemd/system/easynode-health.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 1.5 停掉可能正在执行的 watchdog / health，防止卸载过程中又写一次 node.txt
pkill -f "easynode-watchdog" >/dev/null 2>&1 || true
pkill -f "easynode-health"   >/dev/null 2>&1 || true

# 2. 杀掉残留进程
pkill -f "/usr/local/bin/xray" >/dev/null 2>&1 || true
pkill -f "/usr/local/bin/cloudflared" >/dev/null 2>&1 || true

# 3. 删除二进制与守护
rm -f /usr/local/bin/xray /usr/local/bin/cloudflared
rm -f /usr/local/bin/easynode-watchdog /usr/local/bin/easynode-watchdog-loop
rm -f /usr/local/bin/easynode-health /usr/local/bin/easynode-health-loop
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
echo "  - 域名守护（watchdog 脚本与常驻循环 / systemd timer 或 OpenRC 服务 / tunnel.meta）"
echo "  - 健康守护（easynode-health 脚本与常驻循环 / systemd timer 或 OpenRC 服务 / health.json）"
echo "  - 二进制（/usr/local/bin/xray / cloudflared / easynode-watchdog / easynode-watchdog-loop / easynode-health / easynode-health-loop）"
echo "  - 配置目录（/etc/easynode）"
echo "  - cloudflared 状态目录（/var/lib/easynode-cloudflared）"
echo "  - cloudflared 日志（/var/log/easynode-cloudflared.log，如有）"
echo "  - swap 文件（/swapfile，如有）"
echo
}


#############################################
# 只安装/重装健康守护（给已经用 v1.2 部署好的机器补上自愈能力）
# 用法： curl -fsSL <脚本地址> | bash -s -- health
#############################################

install_health_only(){
show_logo
check_root
detect_init
[ "$INIT" = "none" ] && { echo -e "${RED}未检测到 systemd 或 OpenRC，退出${RESET}"; exit 1; }
[ -f "$BASE_DIR/info" ] || { echo -e "${RED}未检测到 $BASE_DIR/info，请先正常部署一次${RESET}"; exit 1; }
select_mem_tier
install_health_guard
echo
echo "健康守护安装完成。查看状态："
echo "  systemctl list-timers easynode-health.timer   # 或 rc-service easynode-health status"
echo "  cat $BASE_DIR/health.json"
}


#############################################
# ⚠️ 请不要 source 本脚本（重要）
#
# `source easynode.sh` / `. easynode.sh`（不带参数）会让下面的 case 落到
# * 分支，等于在真实机器上跑一次完整部署：重启 tunnel（换域名）、覆盖
# /etc/easynode 的 info / config.json。做函数级测试请到容器/临时机器里做。
#
# v1.3.0 曾在这里加过一个"被 source 就自动跳过"的守卫，结果把 README 的
# `curl -fsSL ... | bash` 一起拦掉了，导致完全装不上（已回滚）。
# 根因是 bash 里 `bash easynode.sh` 与 `source easynode.sh` 无法可靠区分：
#     bash 文件执行 : $0=/path/easynode.sh   BASH_SOURCE[0]=同值
#     source 载入   : $0=/path/easynode.sh   BASH_SOURCE[0]=同值   <- 完全相同
#     curl | bash   : $0=bash                BASH_SOURCE[0]=空
# 所以任何"能拦住 source"的判断都会同时拦住正常执行。这个守卫不要再加了。
#############################################

case "${1:-}" in
    uninstall|remove|delete)
        uninstall
        ;;
    health|health-guard|guard)
        install_health_only
        ;;
    *)
        main
        ;;
esac
