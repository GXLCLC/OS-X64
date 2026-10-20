#!/bin/bash
# =============================================================================
# gen-release-notes.sh —— 生成 GitHub Release 发布说明（用户规范）
#
# 用户规范：Release 说明写入「内核版本 / 固件版本 / 纯净插件清单（不展示 kmod）」；
#           默认 IP 192.168.2.1、密码 12345678；15 插件逐项 ✅❌ 标注。
#
# 用法：gen-release-notes.sh [镜像目录] [源码根] [输出文件] [编译时间标签]
#   镜像目录   : 默认 ./bin/targets/x86/64
#   源码根     : 默认当前目录（用于读版本号/manifest）
#   输出文件   : 默认 <镜像目录>/release-notes.md
#   编译时间标签: 默认当前时间（Asia/Shanghai），格式 YYYYMMDD-HHMMSS
#
# 退出码：0 成功；1 参数/文件错误；2 存在未安装插件（仍生成说明，工作流可据此判定）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_DIR="${1:-./bin/targets/x86/64}"
SRC_ROOT="${2:-$(pwd)}"
OUT_FILE="${3:-${IMAGE_DIR}/release-notes.md}"
TIME_TAG="${4:-$(TZ='Asia/Shanghai' date +%Y%m%d-%H%M%S)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[发布说明]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

cd "${SRC_ROOT}" 2>/dev/null || { log_error "源码根目录不存在：${SRC_ROOT}"; exit 1; }
[[ -d "${IMAGE_DIR}" ]] || { log_error "镜像目录不存在：${IMAGE_DIR}"; exit 1; }

# ---- 版本信息采集 -------------------------------------------------------------
# 固件版本：最终 .config 的 CONFIG_VERSION_NUMBER / CONFIG_VERSION_DIST
FW_NUMBER="24.10.5"; FW_DIST="LEDE"
if [[ -f .config ]]; then
  v="$(grep -E '^CONFIG_VERSION_NUMBER=' .config | head -1 | cut -d= -f2 | tr -d '"')"
  [[ -n "${v}" ]] && FW_NUMBER="${v}"
  d="$(grep -E '^CONFIG_VERSION_DIST=' .config | head -1 | cut -d= -f2 | tr -d '"')"
  [[ -n "${d}" ]] && FW_DIST="${d}"
fi
# 源码版本号（git describe，CI 克隆可用）
FW_REV="$(git describe --always --dirty 2>/dev/null || echo 'unknown')"

# 内核版本：target/linux/x86/Makefile 的 KERNEL_PATCHVER + include/kernel-<ver>
KERNEL_VER="unknown"
KERNEL_PATCHVER="$(grep -E '^KERNEL_PATCHVER:=' target/linux/x86/Makefile 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
if [[ -n "${KERNEL_PATCHVER}" && -f "include/kernel-${KERNEL_PATCHVER}" ]]; then
  patch="$(grep -E "^LINUX_VERSION-${KERNEL_PATCHVER} =" "include/kernel-${KERNEL_PATCHVER}" | head -1 | awk '{print $NF}')"
  [[ -n "${patch}" ]] && KERNEL_VER="${KERNEL_PATCHVER}${patch}"
fi

# manifest（插件状态判定依据）
MANIFEST="$(ls "${IMAGE_DIR}"/*.manifest 2>/dev/null | head -1)"
MISSING_COUNT=0

pkg_in_manifest() {
  [[ -n "${MANIFEST}" ]] && awk -v p="$1" '$1 == p { found = 1 } END { exit(found ? 0 : 1) }' "${MANIFEST}"
}

# ---- 15 插件清单（纯净：只列 LuCI 应用，不展示 kmod） -------------------------
# 格式：显示名|实际包名|备注
PLUGIN_LIST='SmartDNS 智能 DNS 分流|luci-app-smartdns|核心 smartdns 随装
DDNSTO 内网穿透|luci-app-ddnsto|核心 ddnsto 随装，默认中文
AdGuardHome 广告过滤|luci-app-adguardhome|含核心二进制
OpenAppFilter 应用过滤|luci-app-oaf|7.0.x 成套（kmod-oaf + appfilter）
TurboAcc 网络加速|luci-app-turboacc|流量分载 + 全锥形 NAT + BBR（SFE 已移除）
MWAN3 多线负载均衡|luci-app-mwan3|核心 mwan3 随装
Argon 主题|luci-theme-argon|默认主题（Bing 每日壁纸）
Argon 主题配置|luci-app-argon-config|主题可视化配置
Nlbwmon 流量统计|luci-app-nlbwmon|核心 nlbwmon 随装
EasyTier 组网|luci-app-easytier-next|官方 easytier-next 成套
WOL 网络唤醒|luci-app-wol|etherwake 随装
UPnP 端口映射|luci-app-upnp|miniupnpd-nftables 随装
TTYD 网页终端|luci-app-ttyd|ttyd 随装
定时重启|luci-app-autoreboot|支持计划任务
微信推送|luci-app-wechatpush|Server 酱/微信等通道'

PLUGIN_TABLE=""
PLUGIN_IDX=0
while IFS= read -r row; do
  [[ -z "${row}" ]] && continue
  name="${row%%|*}"; rest="${row#*|}"; pkg="${rest%%|*}"
  PLUGIN_IDX=$((PLUGIN_IDX + 1))
  if pkg_in_manifest "${pkg}"; then
    status="✅ 已安装"
  else
    status="❌ 未安装"
    MISSING_COUNT=$((MISSING_COUNT + 1))
  fi
  PLUGIN_TABLE+="| ${PLUGIN_IDX} | ${name} | ${status} |"$'\n'
done <<< "${PLUGIN_LIST}"

# ---- 文件清单（sha256 + MiB） -------------------------------------------------
FILE_TABLE=""
while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  fname="$(basename "${f}")"
  fsize="$(awk -v b="$(stat -c%s "${f}")" 'BEGIN{printf "%.1f", b/1048576}')"
  fsha="$(sha256sum "${f}" | cut -d' ' -f1)"
  FILE_TABLE+="| \`${fname}\` | ${fsize} MiB | \`${fsha}\` |"$'\n'
done < <(ls -1 "${IMAGE_DIR}"/*.img.gz "${IMAGE_DIR}"/*.img 2>/dev/null | sort -u)

# ---- 生成说明 -----------------------------------------------------------------
BUILD_TIME_CN="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z')"

cat > "${OUT_FILE}" <<EOF
# ${FW_DIST} X86_64 固件 · ${TIME_TAG}

> 本固件由 GitHub Actions（Ubuntu 24.04 LTS）自动编译发布 · 源码：coolsnowwolf/lede master

## 版本信息

| 项目 | 值 |
| --- | --- |
| 固件版本 | ${FW_DIST} ${FW_NUMBER}（源码版本 ${FW_REV}） |
| 内核版本 | Linux ${KERNEL_VER} |
| 编译目标 | x86_64 Generic · squashfs |
| 根分区容量 | 2048 MiB（强制扩容） |
| 编译时间 | ${BUILD_TIME_CN} |

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
| AdGuardHome | 开机自启，上游 DNS 5553（dnsmasq 保持 53） |

## 预装插件（15 项）

| # | 插件 | 状态 |
| --- | --- | --- |
${PLUGIN_TABLE}
> 插件核心组件（smartdns / ddnsto / adguardhome / easytier 等）随 LuCI 应用自动安装；内核驱动（kmod）不在本表列示。

## 文件清单

| 文件 | 大小 | SHA256 |
| --- | --- | --- |
${FILE_TABLE}

镜像说明：

- \`combined.img.gz\` —— MBR + GRUB，BIOS 引导（兼容带 CSM 的传统 UEFI）
- \`combined-efi.img.gz\` —— GPT + GRUB EFI，UEFI 引导（推荐新机器使用）
- 两个镜像内容一致，仅引导方式不同；刷入任一即可，二选一。

## 刷入提示

1. 解压得到 \`.img\` 后，用 Etcher / Rufus / dd 写入硬盘或 U 盘。
2. 首次启动自动完成个性化配置（IP / 密码 / 主题 / 时区），无需手动操作。
3. 若从旧版固件升级，建议备份 \`/etc/config\` 后在 LuCI「系统 - 备份/升级」中操作，保留配置需勾选。

---

*本说明由 scripts/gen-release-notes.sh 自动生成（${TIME_TAG}）*
EOF

log_ok "发布说明已生成：${OUT_FILE}"

if [[ ${MISSING_COUNT} -gt 0 ]]; then
  log_warn "有 ${MISSING_COUNT} 个插件未在 manifest 中检出（已标注 ❌）"
  exit 2
fi
log_ok "15 个插件全部在镜像中检出"
exit 0
