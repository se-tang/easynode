# EasyNode

> 一台 NAT 小鸡，一条命令，一个能用的节点。

EasyNode 是一个 **VPS 一键节点部署工具**，专为 NAT 机器设计——没有公网 IP、没有开放端口、内存小到只有 128MB 的"小鸡"，也能一键部署出一个能用的 VLESS 节点。

---

## 它解决什么问题

玩 VPS 的都知道，便宜的 NAT 小鸡（NAT VPS）有个共同的尴尬：

- **没有独立公网 IP**，共享一个出口 IP，端口还只分给你几个
- **内存极小**，常见 1C / 128MB / 1GB 配置，跑个 apt 都可能被 OOM 杀
- **端口受限**，自己搭节点要么没端口用，要么被运营商封

EasyNode 的思路是绕开这些限制：

```
Xray 监听本地端口 → Cloudflare Quick Tunnel 打洞到公网 → 生成 VLESS 节点
```

不需要公网 IP、不需要开放端口、不需要买域名、不需要配证书——**全部免费，一条命令搞定**。

---

## 工作原理

```
┌─────────────┐      ┌──────────────┐      ┌─────────────────┐
│  你的客户端  │ ───▶ │ Cloudflare    │ ───▶ │  NAT 小鸡        │
│  (vless+ws) │      │  Quick Tunnel │      │  Xray (127.0.0.1)│
└─────────────┘      └──────────────┘      └─────────────────┘
                     trycloudflare.com         随机本地端口
```

1. **Xray** 在小鸡上监听 `127.0.0.1` 的一个随机端口，跑 VLESS + WebSocket
2. **cloudflared**（Cloudflare Tunnel 客户端）从本机发起出站连接，把本地端口打到公网
3. 拿到一个 `xxx.trycloudflare.com` 的临时域名（自带 TLS 证书）
4. 脚本拼出 `vless://` 节点链接，客户端导入即用

关键点：**隧道是小鸡主动向外连接的**，所以 NAT 机器不需要任何入站端口，天然穿透。

---

## 特性

- 🚀 **一键部署**：复制粘贴回车，全自动完成
- 🐕 **域名自愈**：内置 watchdog，隧道换域名后自动更新节点文件（客户端重新导入一次即可）
- 🩺 **节点自愈**：内置健康守护，每分钟端到端体检，节点"看着正常但用不了"时自动恢复
- 🧠 **内存挡位自适应**：按机器实际内存自动落挡，64M~1G+ 各有合适的内存上限
- 🌐 **NAT 友好**：无需公网 IP、无需开放端口，出站打洞
- 💰 **全程免费**：Xray 开源、Cloudflare Quick Tunnel 免费
- 🪶 **小内存可用**：针对 128MB 小鸡做了专项优化（见下文）
- 🔒 **自带 TLS**：走 Cloudflare 隧道，连接自带 TLS 加密
- 🖥️ **多系统支持**：Debian / Ubuntu / Alpine，amd64 / arm64

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash
```

> Alpine 系统没有预装 bash，先执行 `apk add bash` 再运行上面的命令。

跑完会输出一个 `vless://` 节点链接，直接导入客户端（V2rayN / v2rayNG / Shadowrocket 等）即可。

节点也会保存到 `/etc/easynode/node.txt`。

---

## 使用说明

### 首次部署

运行脚本，自动完成：系统检测 → swap 检查 → 装依赖 → 装 Xray → 生成配置 → 装 cloudflared → 建隧道 → 输出节点。

### VPS 重启后

Cloudflare Quick Tunnel 是**临时隧道**，cloudflared 每次重启（包括机器重启）域名都会变。

v1.2 起内置**域名守护（watchdog）**：域名变化后约 3 分钟内自动更新服务器上的 `/etc/easynode/node.txt`，无需重跑脚本。注意客户端里的旧链接不会自己变，重新导入一次新链接即可：

```bash
cat /etc/easynode/node.txt
```

如果节点还是不通，先看健康守护的自检结果（见下文「节点健康守护」），再考虑重跑部署脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash
```

### 节点健康守护（自愈）

`systemctl status` 显示服务正常，**不代表节点能用**——进程可能还活着但已经卡死，或者隧道连接掉了。v1.3 起内置健康守护，**每 1 分钟**做一次端到端体检：

| 检查项 | 判定标准 | 失败时的动作 |
|:--|:--|:--|
| xray 本地端口 | `http://127.0.0.1:<PORT>/` 返回 **404** | 重启 `easynode-xray` 并复检 |
| 隧道端到端 | `https://<当前域名>/` 返回 **404** | 重启 `easynode-cloudflared` 并复检 |
| 隧道域名 | 与 `node.txt` 一致 | 域名变了就只重写 `node.txt` |

> 404 是 Xray 对不匹配路径的标准应答，代表"链路通且 Xray 在干活"。502 = cloudflared 正常但 Xray 没应答；530 = 隧道未注册/掉线。

**只恢复，不重建**：UUID / 端口 / 路径永远复用，自愈过程中不会重新生成。所以 xray 崩溃或被 OOM 杀死这类情况，恢复后**客户端完全不用动**；只有 cloudflared 重启导致隧道域名变化时，才需要重新导入一次链接。

查看状态与手动体检：

```bash
cat /etc/easynode/health.json          # 最近一次体检结果
systemctl list-timers easynode-health.timer
/usr/local/bin/easynode-health         # 手动跑一次
```

已经用旧版本部署过的机器，可以只补装健康守护，不用重新部署：

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash -s -- health
```

### 更换节点

想换一个新的节点链接，直接重跑脚本，会生成新的隧道地址并更新 `node.txt`（UUID/端口/路径保持不变，只换域名）。

### 卸载（一键删除所有痕迹）

不想用了，一条命令删除所有安装痕迹：

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash -s -- uninstall
```

会清理：

- 系统服务（easynode-xray / easynode-cloudflared）
- 域名守护（watchdog 脚本与常驻循环、systemd timer / OpenRC 服务、tunnel.meta）
- 健康守护（easynode-health 脚本与常驻循环、systemd timer / OpenRC 服务、health.json）
- 二进制（/usr/local/bin/xray、cloudflared、easynode-watchdog、easynode-health 等）
- 配置目录（/etc/easynode，含节点信息）
- cloudflared 日志（/var/log/easynode-cloudflared.log，如有）
- swap 文件（/swapfile，如有）

---

## 关于延迟和速度

如实说明：**这个节点的延迟和速度并不快**。

流量走 Cloudflare 中转，国内直连时 Cloudflare 默认分配的节点 IP 往往不是最优线路，延迟偏高、速度上不去。

**改善方式：配合 Cloudflare 优选 IP 使用**——用测速工具（如 CloudflareSpeedTest）选出你本地延迟最低的 CF 节点 IP，替换到节点配置的 host 里。配合优选 IP 后延迟会有明显改善，但速度上限仍受限于小鸡到 Cloudflare 的线路质量。

> 定位：备用节点、轻量使用，别把它当主力大流量线路。

---

## NAT 小内存优化（v1.2 起，v1.3 扩充）

针对 1C / 128MB / 1GB 的机器，做了针对性优化，解决"跑一半断开 / 自动停止"（OOM 被杀）的问题：

| 优化 | 说明 |
|:--|:--|
| **自动创建 swap** | 内存 ≤512MB 且 swap 不足（<256MB）时自动创建 256~512MB swap；磁盘吃紧会自动降档或跳过 |
| **SSH 断开保护** | 忽略挂断信号，SSH 断线不中断部署 |
| **分步喘息** | 重操作之间刷磁盘 + 释放缓存 + 停顿，避免内存峰值叠加 |
| **精简依赖** | 去掉无用依赖，`--no-install-recommends`，装完清理缓存 |
| **Xray 只装二进制** | 跳过用不上的 geo 数据文件，省约 29MB 磁盘 |
| **内存挡位自适应** | 按实测内存落挡（64M/128M/256M/512M/1G+）给 `GOMEMLIMIT`+`MemoryHigh`+`MemoryMax`，不再用一套值套所有机器 |
| **停止超时收敛** | `TimeoutStopSec=15`，内存卡死时停止/重启不再干等默认 90 秒（v1.2 部署/卸载卡住的根因） |
| **域名守护** | watchdog 定时同步隧道域名到 `node.txt`，防止"服务正常但节点悄悄失效" |
| **健康守护** | health 每分钟端到端体检，进程活着但不可用时自动重启恢复，只恢复不重建 |
| **进程守护** | OpenRC 侧改用 `supervise-daemon`，与 systemd 的 `Restart=always` 对齐 |

> **原理**：小内存机器"爆了"，通常是瞬时内存峰值叠加（apt 缓存 + 解压 + 下载挤在一起）触发了 OOM killer。swap 提供兜底，分步喘息让峰值不叠加，精简安装降低单步峰值。

---

## 内存挡位自适应（v1.3）

`MemoryMax` 不是"随便设个小值更安全"——设得太紧会**直接把节点掐死**。真实世界里机器内存就那么几档，脚本按实测内存自动落挡：

| 机器内存 | xray GOMEMLIMIT | xray High/Max | cloudflared GOMEMLIMIT | cloudflared High/Max |
|:--|:--|:--|:--|:--|
| **64M** | 24MiB | 32M / 40M | 28MiB | 36M / 44M |
| **128M** | 36MiB | 48M / 56M | 40MiB | 52M / 64M |
| **256M** | 56MiB | 72M / 88M | 60MiB | 80M / 96M |
| **512M** | 96MiB | 96M / 128M | 64MiB | 80M / 112M |
| **1G+** | 256MiB | 256M / 384M | 96MiB | 128M / 256M |

判定规则：实测总内存 ≤64 → 64 挡；≤128 → 128 挡；≤256 → 256 挡；≤512 → 512 挡；>512 → 1G+ 挡。部署时会直接打印落到哪一挡。

### 为什么不能一路按小内存给

实测 xray 空载就要吃十几 MB，cloudflared 20~45MB。**"1G+ 的机器用 50M 上限"会出人命**：

- 被 cgroup OOM killer 杀掉时，内核日志里的 `anon-rss` 往往只有几十 KB——撑爆配额的其实是 Go 运行时的 file-rss / page cache / 内核账目，不是你的流量
- `MemoryHigh` 一旦被长期顶住，进程会把时间全耗在内存回收上，表现就是 **`systemctl status` 一片正常、节点却完全不可用**
- 内存被卡死时进程连 SIGTERM 都响应不过来，systemd 会干等到默认 90 秒超时才 SIGKILL，于是**部署卡在「创建系统服务」、卸载卡住不出日志**（v1.2 的真实故障）

因此 v1.3 同时给两个服务加了 **`TimeoutStopSec=15`**：即使再被内存卡死，停止/重启最多等 15 秒就强杀，脚本不会再假死。

> 1G+ 挡不是"不设限"，而是给一个远高于真实工作集的护栏，防止异常暴涨吃光母机内存。多服务共存的大机器建议留意整体余量。

---

## 支持环境

| 项目 | 支持 |
|:--|:--|
| 系统 | Debian / Ubuntu / Alpine（Alpine 需先 `apk add bash`） |
| 架构 | amd64 / arm64 |
| 内存 | 64MB 起（128MB 以下强烈建议有 swap） |
| 磁盘 | 1GB 起 |

---

## 常见问题

**Q：为什么节点连不上？**
先看健康守护的自检结果：`cat /etc/easynode/health.json`（`status: ok` 表示链路通）。也可以手动跑一次 `/usr/local/bin/easynode-health`。若服务没在跑：`systemctl status easynode-xray` 和 `systemctl status easynode-cloudflared`（Alpine 用 `rc-service easynode-cloudflared status`）。服务都在跑还连不上，多半是隧道换过域名——`cat /etc/easynode/node.txt` 拿最新链接重新导入。

**Q：`systemctl status` 显示服务正常，为什么节点还是不能用？**
这是两种不同的"死法"。systemd 的 `Restart=always` 只能发现**进程退出**；但内存被 `MemoryHigh` 卡死、或隧道 connector 掉线时，进程还活着，status 一切正常而节点已经不可用。v1.3 的健康守护专门解决这种情况：每分钟用 HTTP 404 做端到端判定，发现不可用就自动重启对应服务，全自动恢复。

**Q：节点崩溃后会重建吗？我的节点链接会变吗？**
不会重建。UUID / 端口 / 路径全程复用，自愈只做"重启服务"和"域名变化时重写 node.txt"。所以 **xray 崩溃 / 被 OOM 杀死 → 恢复后客户端完全不用动**；只有 **cloudflared 重启导致隧道域名变化 → 才需要重新导入一次链接**（这是 Quick Tunnel 的固有限制，见下一问）。

**Q：Quick Tunnel 域名能固定吗？**
不能。`trycloudflare.com` 是临时隧道，cloudflared 每次重启域名都会变。watchdog / health 会在域名变化后 1~3 分钟内自动更新服务器上的 `node.txt`，但客户端需要重新导入。要彻底固定域名需要配置 Cloudflare 命名的 Tunnel（需要自己的域名），后续版本可考虑支持。

**Q：为什么内存上限要按挡位来，不能直接设很小？**
设小了会被 cgroup OOM killer 杀掉，而且 `MemoryHigh` 长期顶住会让进程把时间全耗在内存回收上——服务看着正常但节点卡死，甚至连 SIGTERM 都响应不了（导致部署/卸载卡住 90 秒）。详见「内存挡位自适应」一节。

**Q：节点速度/延迟怎么样？**
如实说：不快。流量走 Cloudflare 中转，国内直连延迟偏高，需配合 Cloudflare 优选 IP 使用才能改善（详见上面「关于延迟和速度」）。

**Q：需要开放端口吗？**
不需要。隧道由小鸡主动出站建立，NAT 机器无需任何入站端口。

---

## 免责声明

本项目仅供学习和技术交流使用，请遵守当地法律法规及服务商条款。使用本工具产生的任何后果由使用者自行承担。
