# EasyNode

> 一台 NAT 小鸡，一条命令，一个能用的节点。

专为 NAT VPS 设计：没有公网 IP、没有开放端口、内存只有 128MB，也能一键部署出可用的 VLESS 节点。

```
你的客户端 ──▶ Cloudflare Quick Tunnel ──▶ 小鸡上的 Xray (127.0.0.1)
  vless+ws        trycloudflare.com            随机本地端口
```

**不需要**公网 IP、开放端口、域名、证书——全部免费。隧道由小鸡主动出站建立，所以 NAT 天然穿透。

## 安装与卸载

在目标机器上以 root 执行。

**部署**（首次安装，或想重新生成节点）

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash
```

跑完会输出一条 `vless://` 链接，导入客户端（v2rayN / v2rayNG / Shadowrocket 等）即可。链接同时保存在 `/etc/easynode/node.txt`。

**卸载**（删掉服务、二进制、配置、swap，不留痕迹）

```bash
curl -fsSL https://raw.githubusercontent.com/se-tang/easynode/main/easynode.sh | bash -s -- uninstall
```

> Alpine 需先 `apk add bash`。重跑部署不会换 UUID / 端口 / 路径，只换隧道域名。

## 特性

- **一键部署**：Debian / Ubuntu / Alpine，amd64 / arm64
- **域名自愈**：隧道换域名后自动同步 `node.txt`
- **节点自愈**：每分钟端到端体检，服务"看着正常但用不了"时自动恢复
- **只恢复不重建**：UUID / 端口 / 路径全程复用，xray 崩溃恢复后客户端无需改动
- **小内存可用**：自动建 swap、精简安装、按机器内存自动设置合理上限

## 内存挡位自适应

脚本按实测内存自动落挡，给 xray / cloudflared 设置合适的 `GOMEMLIMIT` + `MemoryHigh` + `MemoryMax`：

| 机器内存 | xray High/Max | cloudflared High/Max |
|:--|:--|:--|
| 64M | 32M / 40M | 36M / 44M |
| 128M | 48M / 56M | 52M / 64M |
| 256M | 72M / 88M | 80M / 96M |
| 512M | 96M / 128M | 80M / 112M |
| 1G+ | 256M / 384M | 128M / 256M |

落挡按**商家标称值**判断，不是直接卡实测值——装完系统 `MemTotal` 会比标称少 2%~10%（内核、保留内存、固件占用），小机器这一份固定开销占比更大。所以阈值留了「下浮 15% 再减 12MB」的容差：标称 512M 实测 452M、标称 1G 实测 910M 都能正确落挡。

> 为什么要分层而不是一律给很小的值：xray 空载就要十几 MB，卡太紧会被 cgroup OOM 杀掉；而 `MemoryHigh` 长期顶住会让进程把 CPU 全耗在内存回收上，表现为 **`systemctl status` 一切正常、节点却连不上**。容差故意往大一挡偏——限制偏宽只是少层护栏，偏紧会直接卡死。

## 支持环境

Debian / Ubuntu / Alpine（Alpine 需 bash） · amd64 / arm64 · 内存 64MB 起（128MB 以下建议有 swap） · 磁盘 1GB 起

## 常见问题

**节点连不上怎么办？**
按顺序看三处：`cat /etc/easynode/health.json`（`status: ok` 表示链路通）→ `systemctl status easynode-xray easynode-cloudflared` → `cat /etc/easynode/node.txt`。服务都在跑还连不上，通常是隧道换过域名，拿 `node.txt` 里的新链接重新导入一次即可。

**`systemctl status` 正常，为什么还是不能用？**
这是两种不同的"死法"。`Restart=always` 只能发现进程退出；内存被卡死或隧道连接掉线时进程还活着，status 正常但节点已经不可用。内置的健康守护（每分钟）专门检测这种情况并自动恢复。

**崩溃后节点会被重建吗？**
不会。自愈只做"重启服务"和"域名变化时重写 node.txt"，UUID / 端口 / 路径永远是原来那套。

**隧道域名能固定吗？**
不能。Quick Tunnel 是临时隧道，cloudflared 每次重启域名都会变（脚本会在 1~3 分钟内自动同步到 `node.txt`，但客户端要重新导入一次）。要固定域名需要 Cloudflare 命名 Tunnel，得有自己托管的域名。

**需要开放端口吗？**
不需要，全程出站。

## 关于速度

如实说：**不快**。流量走 Cloudflare 中转，国内直连延迟偏高。配合 Cloudflare 优选 IP（如 CloudflareSpeedTest 选出本地延迟最低的 CF 节点 IP，替换节点里的 host）会有明显改善，但速度上限仍取决于小鸡到 Cloudflare 的线路。

> 定位：备用节点、轻量使用，别当主力大流量线路。

## 免责声明

本项目仅供学习和技术交流，请遵守当地法律法规及服务商条款，使用后果由使用者自行承担。
