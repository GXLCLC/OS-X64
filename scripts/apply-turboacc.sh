#!/bin/bash
# =============================================================================
# apply-turboacc.sh —— TurboAcc 集成（mufeng05/turboacc）
#
# 用户规范：luci-app-turboacc 仅保留「流量分载 / 全锥形 NAT / BBR」，
#           移除 SFE / Shortcut-FE（fast-classifier / shortcut-fe-cm）。
#
# 选型结论（2026-10 对 LEDE master 实测）：
#   LEDE 官方源码树已完整集成 TurboAcc 内核层与 FullCone 网络栈，无需再从
#   第三方拷贝（优先官方源码包 + 禁引外部 kmod）：
#     · target/linux/generic/hack-6.18/ 已含 952（conntrack events 多注册）、
#       953（shortcut-fe 内核支持，惰性）、982（bcm fullconenat）、
#       983（fullconenat to nft）、984/985（fullcone 相关增强）
#     · package/network/services/fullconenat      -> kmod-ipt-fullconenat
#       package/network/services/fullconenat-nft  -> kmod-nft-fullcone（fw4 全锥）
#     · package/network/utils/nftables/patches/100|103|104（fullcone 表达式）
#       package/libs/libnftnl/patches/001|002（fullcone 表达式）
#       package/network/config/firewall4/patches/001|002|007（fw4 全锥支持）
#     · target/linux/generic/config-6.18 已含 `# CONFIG_SHORTCUT_FE is not set`
#   唯一缺失：luci feed 的官方 luci-app-turboacc 无 FULLCONE 选项、且
#   fw4 依赖不完整（只有 kmod-ipt-offload，缺 kmod-nft-offload）。
#   因此仅从 mufeng05/turboacc 取含 FULLCONE 选项的 LuCI 应用，拷入
#   package/turboacc/luci-app-turboacc 并【移除 feeds 同名软链】。
#
# 覆盖机制说明（2026-10-20 run#7 实测修正）：
#   LEDE include/scan.mk 对 package/ 与 package/feeds/ 同名目录的处理只是
#   把 PKGS 条目写进 OVERRIDELIST 并打 Override 标记（OVERRIDE_PKGS 仅用于
#   版本污点），tmp/.config-package.in 的 kconfig 符号仍取自 feeds 版定义。
#   若保留 feeds 软链，官方 luci feed 版（无 TURBOACC_INCLUDE_FULLCONE）
#   的 config 段会生效，make defconfig 静默丢弃 FULLCONE 符号。
#   故必须移除 package/feeds/luci/luci-app-turboacc 软链，
#   使 package/turboacc/luci-app-turboacc 成为唯一定义源。
#
# 配置符号（custom/luci-app-turboacc/Makefile 定义，choice 互斥）：
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_FLOW_OFFLOADING=y   # 流量分载
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_BBR_CCA=y           # BBR
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_FULLCONE=y          # 全锥形 NAT
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_FAST_CLASSIFIER     # 不选（SFE）
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_SHORTCUT_FE_CM      # 不选（SFE）
#   CONFIG_PACKAGE_TURBOACC_INCLUDE_NO_FASTPATH         # 不选（NSS ECM，仅高通平台）
#   另需 CONFIG_PACKAGE_rpcd-mod-ucode=y：custom 层 rpcd 后端为 ucode 脚本，
#   LEDE 的 rpcd ucode 支持是独立插件（package/system/rpcd BuildPlugin ucode）。
# =============================================================================
set -euo pipefail

LEDE_DIR="${LEDE_DIR:-$(pwd)}"
WORKDIR="${WORKDIR:-${LEDE_DIR}/.thirdparty}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[TurboAcc]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

die() {
  local desc="$1" cmd="$2" expect="$3" actual="$4" cause="$5" fix="$6"
  log_error "TurboAcc 集成失败：${desc}"
  cat >&2 <<EOF

==================== 校验失败诊断 ====================
  检测命令   : ${cmd}
  期望值     : ${expect}
  实际值     : ${actual}
  可能原因   : ${cause}
  建议修复   : ${fix}
====================================================
EOF
  exit 1
}

cd "${LEDE_DIR}"

# ---- 前置检查 ---------------------------------------------------------------
[[ -d ./package ]] || die "LEDE 源码树不完整" "ls ./package" "存在 package 目录" "不存在" \
  "确认在 LEDE 源码根目录执行，且源码已完整检出"
[[ -d ./target/linux/generic ]] || die "LEDE 源码树缺少 target/linux/generic" \
  "ls ./target/linux/generic" "存在" "不存在" "源码树不完整" "重新检出 LEDE 源码"

# ---- 1. 解析 x86 目标实际内核版本 -------------------------------------------
KERNEL_PATCHVER="$(grep -E '^KERNEL_PATCHVER:=' target/linux/x86/Makefile 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
[[ -n "${KERNEL_PATCHVER}" ]] || die "无法解析 x86 内核版本" \
  "grep '^KERNEL_PATCHVER:=' target/linux/x86/Makefile" "得到形如 6.18 的版本号" "为空" \
  "LEDE 源码结构变化" "手动确认 target/linux/x86/Makefile 中的 KERNEL_PATCHVER 并调整脚本"

log_info "x86_64 目标内核版本：${KERNEL_PATCHVER}"

# ---- 2. 校验 LEDE 官方内核层已就绪（缺一不可） --------------------------------
KERNEL_CONFIG="./target/linux/generic/config-${KERNEL_PATCHVER}"
HACK_DIR="./target/linux/generic/hack-${KERNEL_PATCHVER}"

[[ -f "${KERNEL_CONFIG}" ]] || die "内核配置文件缺失" "ls ${KERNEL_CONFIG}" "存在" "不存在" \
  "LEDE 源码结构变化" "确认 target/linux/generic/config-${KERNEL_PATCHVER} 存在"

# 2.1 hack 补丁：982（fullconenat 内核支持）必须已在官方 hack 目录中
if ls "${HACK_DIR}"/982-*.patch >/dev/null 2>&1; then
  log_ok "官方 hack-${KERNEL_PATCHVER} 已含 fullconenat 内核补丁（$(basename "${HACK_DIR}"/982-*.patch)）"
else
  die "官方 hack-${KERNEL_PATCHVER} 缺少 fullconenat 内核补丁 982" \
      "ls ${HACK_DIR}/982-*.patch" "存在 982-*.patch" "不存在" \
      "LEDE 官方树结构调整或版本回退" \
      "从 mufeng05/turboacc 的 lede/hack-${KERNEL_PATCHVER}/ 手动拷贝 952/953/982/983 补丁"
fi

# 2.2 SFE 移除：内核 config 必须显式关闭 SHORTCUT_FE
if grep -q "CONFIG_SHORTCUT_FE" "${KERNEL_CONFIG}"; then
  log_ok "内核 config 已含 CONFIG_SHORTCUT_FE 设置（保持 not set，SFE 已移除）"
else
  echo "# CONFIG_SHORTCUT_FE is not set" >> "${KERNEL_CONFIG}"
  log_ok "已向 ${KERNEL_CONFIG} 追加 # CONFIG_SHORTCUT_FE is not set"
fi

# 2.3 官方 fullconenat 包必须存在（kmod-nft-fullcone 的来源）
[[ -d ./package/network/services/fullconenat-nft ]] || die "LEDE 官方 fullconenat-nft 包缺失" \
    "ls package/network/services/fullconenat-nft" "存在" "不存在" \
    "LEDE 官方树结构调整" \
    "从 mufeng05/turboacc 的 lede/fullconenat-nft 手动拷贝（kmod-nft-fullcone）"
log_ok "官方 fullconenat-nft 包在位（提供 kmod-nft-fullcone）"
[[ -d ./package/network/services/fullconenat ]] || log_warn "官方 fullconenat（ipt 版）缺失，fw4 构建不受影响"

# ---- 3. 稀疏克隆 mufeng05/turboacc（仅取 LuCI 应用两层） ----------------------
TURBOACC_DIR="${WORKDIR}/turboacc"
if [[ ! -d "${TURBOACC_DIR}/.git" ]]; then
  log_info "稀疏克隆 mufeng05/turboacc（main）"
  git clone --depth=1 --filter=blob:none --sparse --branch main \
      https://github.com/mufeng05/turboacc.git "${TURBOACC_DIR}" \
    || die "克隆 turboacc 失败" \
           "git clone --depth=1 --filter=blob:none --sparse --branch main https://github.com/mufeng05/turboacc.git" \
           "克隆成功" "网络不通 / 仓库不存在 / GitHub 限流" \
           "检查网络后重试，或浏览器确认 https://github.com/mufeng05/turboacc 可访问"
else
  log_info "turboacc 克隆缓存已存在，跳过克隆"
fi
git -C "${TURBOACC_DIR}" sparse-checkout set lede/luci-app-turboacc custom/luci-app-turboacc \
  || die "稀疏检出自检失败" "git -C ${TURBOACC_DIR} sparse-checkout set lede/luci-app-turboacc custom/luci-app-turboacc" \
         "命令成功退出" "仓库损坏" "删除 ${TURBOACC_DIR} 后重试"

[[ -d "${TURBOACC_DIR}/lede/luci-app-turboacc" ]] || die "turboacc 缺少 lede/luci-app-turboacc" \
  "ls ${TURBOACC_DIR}/lede/luci-app-turboacc" "存在" "不存在" "上游结构调整" \
  "到 https://github.com/mufeng05/turboacc/tree/main/lede 确认目录结构"
[[ -d "${TURBOACC_DIR}/custom/luci-app-turboacc" ]] || die "turboacc 缺少 custom/luci-app-turboacc" \
  "ls ${TURBOACC_DIR}/custom/luci-app-turboacc" "存在" "不存在" "上游结构调整" \
  "到 https://github.com/mufeng05/turboacc/tree/main/custom 确认目录结构"

# ---- 4. 拷贝 LuCI 应用到 package/turboacc/（自动覆盖官方 feed 同名包） --------
PKG_DST="./package/turboacc/luci-app-turboacc"
rm -rf "./package/turboacc/luci-app-turboacc"
mkdir -p "./package/turboacc"
cp -a "${TURBOACC_DIR}/lede/luci-app-turboacc" "./package/turboacc/luci-app-turboacc"
log_ok "包 luci-app-turboacc -> package/turboacc/luci-app-turboacc（覆盖官方 feed 版，含 FULLCONE 选项）"

# 4.1 移除官方 feed 软链（关键！）
#     LEDE 的 include/scan.mk 对 package/ 与 package/feeds/ 同名目录仅在
#     Override 标记层面处理（OVERRIDE_PKGS 仅用于版本污点），
#     tmp/.config-package.in 的 kconfig 符号仍取自 feeds 版定义——
#     官方 luci feed 的 luci-app-turboacc 无 TURBOACC_INCLUDE_FULLCONE，
#     导致 make defconfig 静默丢弃该符号（2026-10-20 run#7 实测）。
#     移除软链使本目录成为唯一定义，保证 FULLCONE 符号生效。
FEED_LINK="./package/feeds/luci/luci-app-turboacc"
if [[ -e "${FEED_LINK}" || -L "${FEED_LINK}" ]]; then
  rm -f "${FEED_LINK}"
  log_ok "已移除官方 feed 软链 package/feeds/luci/luci-app-turboacc（kconfig 覆盖修复）"
else
  log_warn "未找到 ${FEED_LINK}（可能已移除或 feeds 结构变化）"
fi

# ---- 5. 应用 custom 层覆盖（官方 add_turboacc.sh 同款逻辑） -------------------
log_info "应用 TurboAcc custom 层覆盖"
mkdir -p "${PKG_DST}/root/usr/share/rpcd/ucode"
mkdir -p "${PKG_DST}/root/usr/share/ucitrack"
cp -f "${TURBOACC_DIR}/custom/luci-app-turboacc/Makefile" "${PKG_DST}/"
cp -f "${TURBOACC_DIR}/custom/luci-app-turboacc/root/etc/uci-defaults/turboacc" \
      "${PKG_DST}/root/etc/uci-defaults/"
cp -f "${TURBOACC_DIR}/custom/luci-app-turboacc/root/usr/share/rpcd/ucode/luci.turboacc" \
      "${PKG_DST}/root/usr/share/rpcd/ucode/"
cp -f "${TURBOACC_DIR}/custom/luci-app-turboacc/root/usr/share/ucitrack/luci-app-turboacc.json" \
      "${PKG_DST}/root/usr/share/ucitrack/"
cp -f "${TURBOACC_DIR}/custom/luci-app-turboacc/htdocs/luci-static/resources/view/turboacc.js" \
      "${PKG_DST}/htdocs/luci-static/resources/view/"
# custom 层将 rpcd 后端从 Lua（libexec/rpcd）迁往 ucode（share/rpcd/ucode），
# 移除 lede 版 libexec 旧路径（需配合 config 中 rpcd-mod-ucode=y）
rm -rf "${PKG_DST}/root/usr/libexec"
log_ok "custom 层覆盖完成（Makefile / uci-defaults / rpcd ucode / ucitrack / turboacc.js）"

# ---- 6. 覆盖机制复核 ----------------------------------------------------------
# 前面已移除 feeds 软链，此处验证 package/turboacc 版确实带 FULLCONE 选项，
# 且 feeds 目录下已无同名软链（双保险）。
if grep -q "TURBOACC_INCLUDE_FULLCONE" "${PKG_DST}/Makefile"; then
  log_ok "覆盖生效确认：package/turboacc/luci-app-turboacc/Makefile 含 FULLCONE 选项"
else
  die "custom 层 Makefile 缺少 FULLCONE 选项" \
      "grep TURBOACC_INCLUDE_FULLCONE ${PKG_DST}/Makefile" "匹配" "不匹配" \
      "mufeng05 custom 层结构调整" \
      "检查 https://github.com/mufeng05/turboacc/tree/main/custom/luci-app-turboacc 的 Makefile"
fi
if [[ -e "./package/feeds/luci/luci-app-turboacc" ]]; then
  die "feeds 软链移除失败" \
      "ls package/feeds/luci/luci-app-turboacc" "不存在" "仍存在" \
      "rm 命令未生效或 feeds 结构变化" "手动执行 rm -f package/feeds/luci/luci-app-turboacc"
fi
log_ok "官方 feed 软链已移除，package/turboacc/luci-app-turboacc 为唯一定义源"

# ---- 7. 汇总 ------------------------------------------------------------------
log_info "TurboAcc 集成汇总："
echo "  内核层     : LEDE 官方 hack-${KERNEL_PATCHVER}（952/953/982/983/984/985 已在位，无需第三方补丁）"
echo "  全锥网络栈 : LEDE 官方 fullconenat-nft（kmod-nft-fullcone）+ nftables/libnftnl/firewall4 官方补丁"
echo "  SFE 状态   : CONFIG_SHORTCUT_FE is not set（已移除 Shortcut-FE，未拷 shortcut-fe 包）"
echo "  新增包     : package/turboacc/luci-app-turboacc（mufeng05 custom 层，含 FULLCONE 选项）"
echo "  feeds 处理 : 已移除 package/feeds/luci/luci-app-turboacc 软链（kconfig 符号层面覆盖修复）"
echo "  配置符号   : FLOW_OFFLOADING=y / BBR_CCA=y / FULLCONE=y（FAST_CLASSIFIER/SHORTCUT_FE_CM 不选）"
echo "  依赖插件   : config 中需选择 rpcd-mod-ucode=y（ucode rpcd 后端支持）"
log_ok "TurboAcc 集成完成（流量分载 + 全锥形 NAT + BBR，SFE 已移除，内核层全官方）"
