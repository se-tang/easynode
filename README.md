# EasyNode

VPS 一键节点部署工具（Xray + Cloudflare Quick Tunnel，NAT 机器可用）

## 复制粘贴到服务器，回车即可。

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash
```

## 特性：

- 首次使用：运行脚本即可完成部署并生成节点。
- 如果 VPS 重启，需要再次运行脚本，以获取最新的 Cloudflare Quick Tunnel 地址。
- 如果想更换节点链接，也可以再次运行脚本，脚本会生成新的 Quick Tunnel，并更新 node.txt。

## NAT 小内存机器优化（v1.1）

针对 1C / 128MB / 1GB 的小内存 NAT 机器做了针对性优化，解决"跑一半断开 / 自动停止"（OOM 被杀）的问题：

| 优化 | 说明 |
|:--|:--|
| **自动创建 swap** | 内存 <256MB 且 swap 不足时自动创建 256MB swap，防止 apt/解压 OOM |
| **SSH 断开保护** | `trap HUP` 忽略挂断信号，SSH 断线不中断脚本 |
| **分步喘息** | 重操作之间刷磁盘 + 释放 page cache + 停顿，避免内存峰值叠加 |
| **精简依赖** | 去掉无用 wget/jq，`--no-install-recommends`，装完 `apt clean` |
| **Xray 只装二进制** | 跳过 geoip/geosite（vless+ws 用不上），省 29MB 磁盘 |
| **内存限制** | systemd 加 `MemoryMax`，防运行期 OOM 陷入重启循环 |

> 原理：小内存机器"爆了"通常是瞬时内存峰值叠加（apt 缓存 + 解压 + 下载）触发 OOM killer。swap 提供兜底，喘息让峰值不叠加，精简降低单步峰值。
