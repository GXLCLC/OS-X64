#!/bin/bash
# =============================================================================
# fetch-thirdparty.sh —— LEDE X86_64 第三方插件稀疏检出 + 前置校验
#
# 执行时机：必须在 `./scripts/feeds update -a && ./scripts/feeds install -a`
# 之后运行（此时 package/feeds/ 已填充，可判断官方源是否已提供某插件）。
#
# 拉取规范（用户规范）：
#   1) 浅克隆 + 部分克隆 + 稀疏检出（--filter=blob:none + --sparse + sparse-checkout）
#   2) 拉取前强制校验：仓库连通性 / 分支存在 / 目标目录存在
#   3) 异常立即终止，并输出「检测命令 / 期望值 / 实际值 / 可能原因 / 建议修复」
#   4) 优先官方源码包：官方已提供的包不拷贝第三方版本
#
# 第三方源清单与选型结论（2026-10-20 实测）：
#   - kenzok8/openwrt-packages (master) : ddnsto + luci-app-ddnsto（官方 feed 无）
#   - destan19/OpenAppFilter   (master) : OAF 三件套 oaf/kmod-oaf + appfilter + luci-app-oaf
#       说明：官方 packages feed 的 net/open-app-filter 为 2025-07-03 的 6.1.4 快照，
#       且无内核 6.16+ 适配；destan19 master 为 7.0.x 且源码含
#       `LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)` 条件编译，方可在
#       LEDE 6.18 内核上编译。三包版本必须成套（kmod 与用户态协议匹配），
#       故整套取自上游。open-app-filter 目录名与官方 feed 同名，
#       放入 package/ 后由 LEDE 构建系统的「非 feeds 目录覆盖 feeds 同名目录」
#       机制自动顶替官方版（include/scan.awk：PKGS 优先于 FEEDS）。
#   - mufeng05/turboacc                  : 由 apply-turboacc.sh 单独处理
#
# 已不需要的第三方源（优先官方源码包原则，2026-10-20 复核）：
#   - EasyTier/luci-app-easytier : LEDE 官方 luci feed 已提供 luci-app-easytier-next，
#       官方 packages feed 已提供 easytier-next（2.6.4，预编译二进制，无需 Rust
#       源码编译，大幅缩短编译时间），官方成套优于「第三方 LuCI + 官方核心」混搭。
#   - kenzok8/small-package      : 当前 15 插件清单中无任何包来自该仓库，
#       按「优先官方源码包」原则整体移除以减少拉取耗时。
# =============================================================================
set -euo pipefail

LEDE_DIR="${LEDE_DIR:-$(pwd)}"
WORKDIR="${WORKDIR:-${LEDE_DIR}/.thirdparty}"   # 克隆缓存目录（不进入编译树）
FEEDS_DIR="${LEDE_DIR}/package/feeds"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[第三方源]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

# ---- 失败诊断：统一输出 检测命令/期望值/实际值/可能原因/建议修复 -------------
die() {
  local desc="$1" cmd="$2" expect="$3" actual="$4" cause="$5" fix="$6"
  log_error "拉取前置校验失败：${desc}"
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

mkdir -p "${WORKDIR}"
cd "${LEDE_DIR}"

# =============================================================================
# 工具函数
# =============================================================================

# 检测官方 feeds 是否已提供某目录（package/feeds/<任意feed>/<目录名> 存在即已提供）
official_has() {
  local name="$1"
  compgen -G "${FEEDS_DIR}/*/${name}" >/dev/null 2>&1
}

# 稀疏克隆一个仓库：参数 <repo> <branch> <本地目录>
# cone 模式（默认）：只拉取目录，体积最小；文件需配合 --no-cone 使用
sparse_clone() {
  local repo="$1" branch="$2" dest="$3"
  if [[ -d "${dest}/.git" ]]; then
    log_info "仓库已存在克隆缓存，跳过克隆：${repo}"
    return 0
  fi
  log_info "浅克隆 + 部分克隆 + 稀疏检出：${repo} (${branch})"
  git clone --depth=1 --filter=blob:none --sparse \
      --branch "${branch}" "https://github.com/${repo}.git" "${dest}" \
    || die "无法克隆仓库 ${repo}" \
           "git clone --depth=1 --filter=blob:none --sparse --branch ${branch} https://github.com/${repo}.git" \
           "克隆成功" \
           "网络不通 / 仓库被删或改名 / 分支不存在 / GitHub 限流" \
           "检查网络；浏览器访问 https://github.com/${repo} 确认仓库与分支 ${branch} 是否存在"
}

# 稀疏检出指定目录（cone 模式，仅目录）
sparse_set() {
  local dest="$1"; shift
  git -C "${dest}" sparse-checkout set "$@" \
    || die "稀疏检出自检失败（${dest}）" \
           "git -C ${dest} sparse-checkout set $*" \
           "命令成功退出" \
           "仓库损坏 / 路径不存在" \
           "删除 ${dest} 目录后重试"
}

# 从仓库拷贝目录到 package/ 下（保留目录名）
copy_pkg_dir() {
  local src_root="$1" sub="$2" dest_root="${LEDE_DIR}/package"
  local name; name="$(basename "${sub}")"
  local src="${src_root}/${sub}"
  [[ -d "${src}" ]] || die "仓库 ${src_root} 中不存在目录 ${sub}" \
      "ls ${src_root}" "存在目录 ${sub}" "实际不存在 ${sub}" \
      "上游目录结构可能已调整，请到仓库页面确认 ${sub} 路径"
  if official_has "${name}"; then
    log_ok "官方 feeds 已提供 ${name}，跳过第三方拷贝（优先官方源码包）"
    return 0
  fi
  rm -rf "${dest_root:?}/${name}"
  cp -a "${src}" "${dest_root}/${name}"
  log_ok "已拷贝 ${name} -> package/${name}"
}

# =============================================================================
# 1. kenzok8/openwrt-packages（master）—— ddnsto 套件
#    官方 luci feed 与 packages feed 均无 ddnsto/luci-app-ddnsto；
#    luci-app-ddnsto 控制器默认中文（lang = i18n.context.lang or "zh-cn"）。
# =============================================================================
fetch_kenzok8_openwrt_packages() {
  local dest="${WORKDIR}/kenzok8-openwrt-packages"
  sparse_clone "kenzok8/openwrt-packages" "master" "${dest}"
  sparse_set "${dest}" ddnsto luci-app-ddnsto
  copy_pkg_dir "${dest}" "ddnsto"
  copy_pkg_dir "${dest}" "luci-app-ddnsto"
}

# =============================================================================
# 2. destan19/OpenAppFilter（master）—— OAF 三件套 7.0.x
#    oaf/            -> KernelPackage（即 kmod-oaf）
#    open-app-filter/-> package appfilter
#    luci-app-oaf/   -> LuCI 界面
# =============================================================================
fetch_openappfilter() {
  local dest="${WORKDIR}/OpenAppFilter"
  # 注意：上游默认分支为 master（非 main）
  sparse_clone "destan19/OpenAppFilter" "master" "${dest}"
  sparse_set "${dest}" oaf open-app-filter luci-app-oaf
  # 版本一致性说明：三包必须成套取自 destan19 master（7.0.x）。
  # 官方 feed 的 net/open-app-filter（6.1.4 快照）无内核 6.16+ 适配，
  # 且单独 official_has 判断只认目录名——此处 open-app-filter 与官方 feed
  # 同名，拷入 package/open-app-filter 后由 LEDE 构建系统自动覆盖官方版，
  # 因此不做跳过处理，强制使用上游 7.0.x 成套版本。
  copy_pkg_dir "${dest}" "oaf"
  # ---- 消除 kmod-oaf 同名双定义（2026-10-20 run #8 实测问题） ----------------
  # package/oaf（destan19 7.0.x）与官方 packages feed 的 net/open-app-filter
  # （6.1.4）都定义 KernelPackage/oaf，包名均为 kmod-oaf。但两者【目录名不同】
  # （oaf vs open-app-filter），不触发 include/scan.awk 的「PKGS 顶替 FEEDS」
  # 机制，两个定义会同时进入 tmp/.config-package.in，kconfig 报：
  #   error: recursive dependency detected!
  #   symbol PACKAGE_kmod-oaf is selected by PACKAGE_kmod-oaf
  # 导致 make defconfig 阶段符号解析异常（连带其他符号被丢弃）。
  # open-app-filter 目录本身已由 package/open-app-filter（destan19 7.0.1）
  # 顶替官方版，移除官方 feed 软链后 kmod-oaf/appfilter 均只剩唯一定义。
  local link
  for link in "${FEEDS_DIR}"/*/open-app-filter; do
    [[ -e "${link}" ]] || continue
    rm -f "${link}"
    log_ok "已移除官方 feed 软链 ${link#${LEDE_DIR}/}（消除 kmod-oaf 同名双定义）"
  done
  # open-app-filter 与官方 packages feed 的 net/open-app-filter 目录同名，
  # 拷入 package/open-app-filter 后由 LEDE 构建系统的「非 feeds 目录覆盖
  # feeds 同名目录」机制（include/scan.awk）自动顶替官方 6.1.4 旧版。
  rm -rf "${LEDE_DIR}/package/open-app-filter"
  cp -a "${dest}/open-app-filter" "${LEDE_DIR}/package/open-app-filter"
  log_ok "已拷贝 open-app-filter -> package/open-app-filter（覆盖官方 feed 同名包，7.0.x 成套）"
  copy_pkg_dir "${dest}" "luci-app-oaf"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  log_info "第三方插件拉取开始（工作目录：${LEDE_DIR}）"

  # 前置检查：feeds 必须已安装（package/feeds 存在）
  [[ -d "${FEEDS_DIR}" ]] || die "package/feeds 目录不存在" \
      "ls ${LEDE_DIR}/package/feeds" "feeds 已安装" \
      "尚未执行 ./scripts/feeds update -a && ./scripts/feeds install -a" \
      "先运行 feeds update + feeds install，再执行本脚本"

  fetch_kenzok8_openwrt_packages
  fetch_openappfilter

  log_info "第三方插件拉取完成，结果汇总："
  # 注意：appfilter 包定义在 open-app-filter 目录中（PKG_NAME=appfilter），
  # 故按目录名 open-app-filter 检查。
  for p in ddnsto luci-app-ddnsto oaf open-app-filter luci-app-oaf; do
    if official_has "${p}" || [[ -d "${LEDE_DIR}/package/${p}" ]]; then
      echo "  [OK] ${p}"
    else
      log_warn "${p} 未找到（官方与第三方均未提供）"
    fi
  done
  log_ok "全部第三方源处理完毕（其余插件均为官方 feeds 提供，无需第三方）"
}

main "$@"
