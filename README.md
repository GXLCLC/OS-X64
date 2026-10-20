# LEDE X86_64 云编译仓库

基于 **coolsnowwolf/lede（Lean LEDE）master** 的 X86_64 全自动云编译仓库，
通过 **GitHub Actions（Ubuntu 24.04 LTS）+ workflow_dispatch 手动触发**，
无人值守产出 X86_64 Generic / squashfs 固件并自动发布到 Releases。

## 快速开始

1. 仓库主页进入 **Actions → LEDE X86_64 云编译 → Run workflow**（仅此一种触发方式，
   所有自动触发已按规范关闭）。
2. 等待编译完成（x86_64 全量约 1.5~3 小时，含内核与全部插件）。
3. 在仓库 **Releases** 页面下载时间前缀命名的 `*.img.gz`，解压后用
   Etcher / Rufus / dd 写入硬盘或 U 盘。
4. 首次启动自动完成个性化配置，浏览器打开 **http://192.168.2.1**，
   用户 `root`，密码 `12345678`。

## 默认配置

| 项目 | 默认值 |
| --- | --- |
| 管理地址 | http://192.168.2.1 |
| root 密码 | 12345678 |
| 主机名 | LEDE-X64 |
| 时区 | Asia/Shanghai（CST-8） |
| 默认主题 | Argon（登录页 Bing 每日壁纸） |
| 防火墙 | 软件流量分载 开 / 硬件流量分载 关 / 全锥形 NAT 开 |
| 网络加速 | BBR + 流量分载 + 全锥形 NAT（SFE / Shortcut-FE 已移除） |
| AdGuardHome | 开机自启（上游 DNS 5553，dnsmasq 保持 53） |
| 根分区 | 2048 MiB（强制扩容） |
| 镜像形态 | `combined.img`（MBR/BIOS）+ `combined-efi.img`（GPT/UEFI），内容一致 |

## 预装插件（15 项）

| # | 插件 | 说明 |
| --- | --- | --- |
| 1 | luci-app-smartdns | SmartDNS 智能 DNS 分流 |
| 2 | luci-app-ddnsto | DDNSTO 内网穿透（默认中文） |
| 3 | luci-app-adguardhome | AdGuardHome 广告过滤（含核心） |
| 4 | luci-app-oaf | OpenAppFilter 应用过滤（7.0.x 成套） |
| 5 | luci-app-turboacc | TurboAcc：流量分载 + 全锥形 NAT + BBR |
| 6 | luci-app-mwan3 | MWAN3 多线负载均衡 |
| 7 | luci-app-argon-config | Argon 主题配置 |
| 8 | luci-theme-argon | Argon 主题（默认） |
| 9 | luci-app-nlbwmon | 网络负载监视 |
| 10 | luci-app-easytier-next | EasyTier 去中心化组网 |
| 11 | luci-app-wol | 网络唤醒 Wake-on-LAN |
| 12 | luci-app-upnp | UPnP 端口映射 |
| 13 | luci-app-ttyd | 网页终端 TTYD |
| 14 | luci-app-autoreboot | 定时重启 |
| 15 | luci-app-wechatpush | 微信推送 |

> 命名说明：LEDE 官方 feed 现已将 Argon 主题配置更名为 `luci-app-argon-config`、
> EasyTier 套件更名为 `luci-app-easytier-next`（配套官方预编译核心 `easytier-next`），
> 本仓库按「优先官方源码包」原则采用官方现名，功能与需求一致。

## 源码映射（2026-10 实测）

| 组件 | 来源 |
| --- | --- |
| LEDE 主体 / 内核 6.18.55 / feeds | coolsnowwolf/lede master |
| smartdns / adguardhome / mwan3 / nlbwmon / ttyd / etherwake / easytier-next / miniupnpd-nftables | 官方 packages feed |
| 全部 LuCI 应用（含 easytier-next / argon / upnp / wechatpush 等） | 官方 luci feed（openwrt-25.12） |
| TurboAcc 内核层 + FullCone 网络栈（hack-6.18、fullconenat-nft、nftables/libnftnl/firewall4 补丁） | **LEDE 官方源码树已内置，无需第三方** |
| ddnsto + luci-app-ddnsto | kenzok8/openwrt-packages（master） |
| OpenAppFilter 三件套（oaf + appfilter + luci-app-oaf，7.0.x） | destan19/OpenAppFilter（master） |
| luci-app-turboacc（含 FULLCONE 选项的 custom 层） | mufeng05/turboacc |

要点说明：

- **TurboAcc**：官方 luci feed 的旧版无 FULLCONE 选项且 fw4 依赖不完整，故用
  mufeng05 版覆盖（`package/turboacc/` 目录自动顶替 feed 同名包）；内核层
  （952/953/982/983/984/985 补丁、`kmod-nft-fullcone`、BBR）全部来自官方。
- **OpenAppFilter**：官方 feed 版本为 6.1.4 旧快照、无 6.16+ 内核适配，故整体
  采用 destan19 7.0.x 成套版本。
- **RTL8111**：官方与第三方均无 `kmod-r8168`，且规范禁引外部 kmod，故使用
  主线 `kmod-r8169`（6.18 内核完整支持）。
- **UPnP**：fw4 下依赖 `miniupnpd-nftables`（非 miniupnpd）。
- **LuCI 中文**：现代 LuCI 构建时自动将 `po/zh_Hans` 编译进各应用包，无需
  独立 i18n 包；ddnsto / easytier / oaf / turboacc 均内置中文。

## 目录结构

```
├── .github/workflows/build-lede.yml   # 云编译工作流（仅 workflow_dispatch）
├── config/
│   ├── X86_64.config                  # 编译配置（增删插件改这里）
│   └── required-packages.txt          # 必装包校验清单（改配置时同步）
├── scripts/
│   ├── fetch-thirdparty.sh            # 第三方插件稀疏检出 + 前置校验
│   ├── apply-turboacc.sh              # TurboAcc 集成（内核层全官方）
│   ├── personalize.sh                 # 个性化（IP/密码/主题/防火墙 + 源码级密码替换）
│   ├── check-packages.sh              # 插件清单校验（config / manifest 双模式）
│   ├── verify-artifacts.sh            # 镜像校验（文件/格式/分区容量/squashfs/清单）
│   ├── collect-errors.sh              # 失败 ERROR 日志收集
│   └── gen-release-notes.sh           # Release 说明生成
└── README.md
```

## 增删插件

1. 修改 `config/X86_64.config`（增删 `CONFIG_PACKAGE_<包名>=y`）。
2. 同步修改 `config/required-packages.txt`（保持清单与配置一致）。
3. 提交推送，重新 Run workflow。

编译前会自动执行 `check-packages.sh config`（基于最终 `.config`）核对
「15 插件 + 核心 + 驱动 + TurboAcc 开关」；编译后再执行 manifest 模式核对
镜像内实际安装情况，任一不满足即终止构建。

## 编译流程

```
检出本仓库 → 释放磁盘 → 装依赖 → 浅克隆 LEDE master
→ 恢复 DL 缓存 → feeds update/install
→ fetch-thirdparty.sh（ddnsto + OAF，稀疏检出 + 前置校验）
→ apply-turboacc.sh（仅补 LuCI 应用）
→ personalize.sh（files/ 兜底 + 源码级密码替换）
→ 写入 .config → make defconfig → 清单校验(config)
→ make download（DL 缓存）→ make（严格模式）
→ verify-artifacts.sh（MBR/GPT + 2048MiB 分区 + squashfs 魔数 + 插件清单 + AGH 二进制）
→ gzip -9（时间前缀）→ gen-release-notes.sh → 创建 Release 上传
```

任一步骤失败：自动执行 `collect-errors.sh` 收集 ERROR 失败日志
（错误关键行 + `logs/` 全量 + 配置差异 + 环境信息）并上传为工件
（`error-logs-run<编号>`，保留 14 天），不上传任何其他产物。

## 常见问题

- **Release 上传失败提示 2 GiB 上限**：属预期外的镜像超大，检查
  `CONFIG_TARGET_ROOTFS_PARTSIZE` 是否被改动（默认 2048，镜像 ≈ 2112 MiB，
  必须关闭 `CONFIG_TARGET_IMAGES_GZIP` 走手动 gzip 流程）。
- **清单校验失败**：按日志中「检测命令/期望值/实际值/可能原因/建议修复」五段式
  诊断处理；常见原因为上游 feed 改名（同步 `required-packages.txt` 即可）。
- **磁盘不足**：工作流已预清理 runner 预装大件；若仍不足，检查是否误开了
  ISO/qcow2/vdi/vmdk/vhdx 等额外镜像形态。
