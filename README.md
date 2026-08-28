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

跑完会输出一个 `vless://` 节点链接，直接导入客户端（V2rayN / v2rayNG / Shadowrocket 等）即可。

节点也会保存到 `/etc/easynode/node.txt`。

---

## 使用说明

### 首次部署

运行脚本，自动完成：系统检测 → swap 检查 → 装依赖 → 装 Xray → 生成配置 → 装 cloudflared → 建隧道 → 输出节点。

### VPS 重启后

Cloudflare Quick Tunnel 是**临时隧道**，重启后域名会变。VPS 重启后重新跑一次脚本即可拿到新节点：

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash
```

### 更换节点

想换一个新的节点链接，直接重跑脚本，会生成新的隧道地址并更新 `node.txt`。

---

## NAT 小内存优化（v1.1）

针对 1C / 128MB / 1GB 的机器，做了针对性优化，解决"跑一半断开 / 自动停止"（OOM 被杀）的问题：

| 优化 | 说明 |
|:--|:--|
| **自动创建 swap** | 内存 <256MB 且 swap 不足时，自动创建 256MB swap 防 OOM |
| **SSH 断开保护** | 忽略挂断信号，SSH 断线不中断部署 |
| **分步喘息** | 重操作之间刷磁盘 + 释放缓存 + 停顿，避免内存峰值叠加 |
| **精简依赖** | 去掉无用依赖，`--no-install-recommends`，装完清理缓存 |
| **Xray 只装二进制** | 跳过用不上的 geo 数据文件，省约 29MB 磁盘 |
| **内存限制** | systemd 加 `MemoryMax`，防运行期 OOM 陷入重启循环 |

> **原理**：小内存机器"爆了"，通常是瞬时内存峰值叠加（apt 缓存 + 解压 + 下载挤在一起）触发了 OOM killer。swap 提供兜底，分步喘息让峰值不叠加，精简安装降低单步峰值。

---

## 支持环境

| 项目 | 支持 |
|:--|:--|
| 系统 | Debian / Ubuntu / Alpine |
| 架构 | amd64 / arm64 |
| 内存 | 128MB 起（建议有 swap） |
| 磁盘 | 1GB 起 |

---

## 常见问题

**Q：为什么节点连不上？**
先确认两个服务都在跑：`systemctl status easynode-xray` 和 `systemctl status easynode-cloudflared`。

**Q：Quick Tunnel 域名能固定吗？**
不能。`trycloudflare.com` 是临时隧道，重启后域名会变。要固定域名需要配置 Cloudflare 命名的 Tunnel（需要自己的域名），后续版本可考虑支持。

**Q：节点速度怎么样？**
速度取决于你的小鸡到 Cloudflare 的线路质量，走 Cloudflare 网络中转，国内直连速度一般，适合作为备用节点或轻量使用。

**Q：需要开放端口吗？**
不需要。隧道由小鸡主动出站建立，NAT 机器无需任何入站端口。

---

## 免责声明

本项目仅供学习和技术交流使用，请遵守当地法律法规及服务商条款。使用本工具产生的任何后果由使用者自行承担。
