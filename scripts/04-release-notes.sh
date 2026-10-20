#!/usr/bin/env bash
# ============================================================
# 脚本名称 : 04-release-notes.sh
# 功能     : 生成 GitHub Release 发布说明
#            （内核版本 / 固件版本 / 默认管理信息 / 纯净插件清单）
# 运行位置 : lede 源码根目录；结果输出到 stdout
# ============================================================
set -euo pipefail

TARGET_DIR="bin/targets/x86/64"
MANIFEST="$(find "$TARGET_DIR" -maxdepth 1 -name "*.manifest" -print -quit)"
[ -n "$MANIFEST" ] || { echo "ERROR: 未找到 manifest 清单"; exit 1; }

# 内核版本（manifest 中 kernel 行）
KERNEL_VER="$(grep -E '^kernel - ' "$MANIFEST" | awk '{print $3}' | head -n1)"
KERNEL_VER="${KERNEL_VER:-unknown}"

# 固件版本（staging_dir 中的发行信息）
FW_VER="$(grep -h '^DISTRIB_RELEASE' staging_dir/target-*/etc/openwrt_release 2>/dev/null \
  | head -n1 | cut -d"'" -f2)"
FW_VER="${FW_VER:-unknown}"

# 纯净插件清单：仅展示 luci-app / luci-theme，过滤 kmod 与 i18n 语言包
PLUGIN_LIST="$(grep -E '^luci-(app|theme)-' "$MANIFEST" | awk '{print $1}' \
  | grep -v -- '-i18n' | sort -u | sed 's/^/- /')"

cat <<EOF
## 📦 LEDE X86_64 固件（squashfs 镜像）

| 项目 | 说明 |
| ---- | ---- |
| **内核版本** | ${KERNEL_VER} |
| **固件版本** | ${FW_VER} |
| **目标架构** | X86_64 Generic |
| **镜像格式** | squashfs-combined（img.gz） |
| **时区 / 主题** | Asia/Shanghai / Argon |

## 🔑 默认管理信息
- 管理地址：**http://192.168.2.1**
- 默认密码：**12345678**（用户名 root）
- ⚠️ 首次开机后请及时修改默认密码

## 🧩 集成插件清单（纯净展示，不含 kmod 依赖明细）
${PLUGIN_LIST}

> 本固件由 GitHub Actions 全自动编译（lean LEDE master 分支），任何包报错即判定构建失败。
EOF
