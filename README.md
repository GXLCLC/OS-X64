# LEDE X86_64 自动编译仓库

基于 **GitHub Actions + Ubuntu 24.04 LTS** 全自动编译 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) 的 x86_64 固件，仅生成 `squashfs` 格式镜像，编译成功自动发布 GitHub Release。

## 目录结构

```
lede-x86_64-builder/
├── .github/
│   └── workflows/
│       └── build-lede-x86_64.yml   # 唯一工作流（仅手动触发）
├── config/
│   └── X86_64.config               # 编译配置（支持增删插件）
├── scripts/
│   ├── customize-config.sh         # 自定义：密码/主机名/IP/时区/主题/语言
│   ├── setup-thirdparty.sh         # 第三方插件浅克隆（含前置校验）
│   ├── pre-verify.sh               # 编译前严格校验（插件/冲突/内核模块）
│   ├── post-build-check.sh         # 编译后校验（文件/格式/分区容量）
│   └── package-firmware.sh         # 打包 + Release 元数据
├── .gitignore
└── README.md
```

## 快速开始

1. 将本仓库推送到 GitHub（或 Fork 后使用）。
2. 打开仓库 **Actions** 页 → 选择 **编译 LEDE X86_64 固件** → **Run workflow** 手动触发。
3. 构建完成后，自动创建 GitHub Release，上传 `img.gz`。

> 无需配置任何 Secret，`GITHUB_TOKEN` 自动用于发布。

## 关键规范实现对照

| 需求 | 实现方式 |
|------|----------|
| 仅手动触发 | `on: workflow_dispatch`，未配置 push/PR/schedule |
| 固定 master 分支 | `git clone --depth 1 --branch master`（可输入覆盖，默认 master） |
| 时区 Asia/Shanghai | `customize-config.sh` 写入 `CST-8` + `zonename Asia/Shanghai` |
| 默认主题 Argon | 集成 `luci-theme-argon`，开机脚本设为默认主题 |
| 仅 X86_64 Generic squashfs | `CONFIG_TARGET_x86_64=y` + `TARGET_ROOTFS_SQUASHFS=y` |
| 根分区扩容 2G | `CONFIG_TARGET_ROOTFS_PARTSIZE=2048`（可在触发时输入修改） |
| DL 缓存 | `actions/cache@v4` 缓存 `lede/dl` + ccache |
| 严格编译 | `make` 不加 `-k`，`pipefail` 保证任意包报错立即终止 |
| 失败只传 ERROR 日志 | `build.log` 中 grep 错误关键字 + 末尾上下文，单独上传 |
| 编译后校验 | 校验 img.gz 存在/gzip/格式/分区容量，不达标终止 |
| 纯净插件清单 | Release 说明中仅列 `luci-app-*`/`luci-theme-*` 及核心程序，不含 kmod |
| 时间前缀命名 | 固件与 Release tag 均为 `YYYYmmdd-HHMMSS` 前缀 |

## 默认后台信息

| 项目 | 值 |
|------|-----|
| 后台 IP | `192.168.2.1` |
| 默认密码 | `12345678` |
| 主机名 | `LEDE` |
| 时区 | `Asia/Shanghai` |
| 主题 | Argon |

均可在触发 workflow 时通过输入参数覆盖。

## 预装插件清单

1. `luci-app-smartdns`
2. `luci-app-ddnsto`（默认中文）
3. `luci-app-adguardhome`（含核心 + 完整依赖）
4. `luci-app-oaf`（含 `kmod-oaf` 内核模块）
5. `luci-app-turboacc`（仅流量分载 / 全锥形 NAT / BBR，移除 SFE/Shortcut-FE）
6. `luci-app-mwan3`（多拨负载均衡）
7. `luci-app-argon-config`
8. `luci-theme-argon`
9. `luci-app-nlbwmon`（带宽监控）
10. `luci-app-easytier`（异地组网）
11. `luci-app-wol`
12. `luci-app-upnp`
13. `luci-app-ttyd`
14. `luci-app-autoreboot`
15. `luci-app-wechatpush`

内置驱动：`kmod-igb`（i211）、`kmod-r8169`（RTL8111）、`kmod-e1000e`，以及 USB 网卡 / USB 存储 / ext4 / vfat / exfat 内核模块，全部与本机编译内核严格匹配。

## 第三方插件源

| 源 | 地址 | 用途 |
|----|------|------|
| kenzok8/openwrt-packages | https://github.com/kenzok8/openwrt-packages | 主软件源 |
| kenzok8/small-package | https://github.com/kenzok8/small-package | openwrt-packages 补充 |
| mufeng05/turboacc | https://github.com/mufeng05/turboacc | TurboACC 加速 |
| destan19/OpenAppFilter | https://github.com/destan19/OpenAppFilter | oaf 应用过滤上游（兜底） |

> `setup-thirdparty.sh` 采用「浅克隆（`--depth 1`）+ 仅复制所需子目录」方式，拉取前强制校验仓库连通性、分支存在、目录完整，异常直接终止并输出修复建议。

## 如何增删插件

编辑 `config/X86_64.config`：

- **新增**：加一行 `CONFIG_PACKAGE_<软件包名>=y`
- **删除**：删除对应行，或改为 `# CONFIG_PACKAGE_<软件包名> is not set`

> 若新增第三方插件，需同步在 `scripts/setup-thirdparty.sh` 的 `PKGS` 数组中补充目录名，并在 `scripts/pre-verify.sh` 的非必需清单中补齐。

## 自定义维护（解耦说明）

密码 / 主机名 / IP / 时区 / 主题等定制逻辑全部收敛到 `scripts/customize-config.sh`，第三方插件逻辑收敛到 `scripts/setup-thirdparty.sh`，与 workflow 解耦，便于单独修改。

- **改密码/主机名/IP**：改 `customize-config.sh` 顶部的默认值，或触发时传参。
- **改插件**：改 `config/X86_64.config` + `pre-verify.sh`。
- **改发布风格**：改 `package-firmware.sh`。

## 常见问题

- **构建失败排查**：直接看 Actions 中「⑬ 上传失败日志」产物里的 `ERROR-失败日志.log`，已按「缺失依赖 / 路径错误 / 分支异常 / 模块冲突」分类提取。
- **插件目录名变更**：第三方仓库更新后可能改目录名，`setup-thirdparty.sh` 会报「未找到」，按其提示 `git clone` 后 `ls` 核对即可。
- **TurboACC 与 SFE 冲突**：若 `mufeng05/turboacc` 的 Makefile 强依赖 SFE 模块，`pre-verify.sh` 会因「仍存在 kmod-shortcut-fe / fast-classifier」报错，此时需按需裁剪该依赖。