#!/bin/bash
# =============================================================================
# check-packages.sh —— 插件清单双模式校验（config / manifest）
#
# 用途：保证「用户规范的 15 插件 + 核心 + 驱动」真正进入构建，防止配置文件
#       笔误、feed 结构调整、包被改名/移除等问题流入最终镜像。
#
# 用法：check-packages.sh <mode> [路径]
#   config   : 校验 .config（或指定配置文件）满足 config/required-packages.txt
#              全部条目（每个包对应 CONFIG_PACKAGE_<包名>=y；@symbol 行为原样匹配）
#   manifest : 校验构建产物 manifest（默认 bin/targets/x86/64/*.manifest）
#              已包含全部必装包
#
# 校验依据：config/required-packages.txt（本仓库维护，增删插件时同步更新）
#
# 失败行为：一次性列出全部缺失项，逐项输出
#           「检测命令 / 期望值 / 实际值 / 可能原因 / 建议修复」，以退出码 1 终止。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="${1:-}"
TARGET="${2:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[清单校验]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

case "${MODE}" in
  config)
    CONFIG_FILE="${TARGET:-${REPO_ROOT}/config/X86_64.config}"
    ;;
  manifest)
    MANIFEST="${TARGET:-}"
    ;;
  *)
    log_error "用法：$0 <config|manifest> [路径]"
    log_error "  config   : 校验 config/X86_64.config（或指定 .config）"
    log_error "  manifest : 校验 bin/targets/x86/64/*.manifest（或指定 manifest 文件）"
    exit 2
    ;;
esac

REQUIRED_LIST="${REPO_ROOT}/config/required-packages.txt"
[[ -f "${REQUIRED_LIST}" ]] || { log_error "缺少校验清单：${REQUIRED_LIST}"; exit 1; }

# 读取清单：包名（普通行）与符号（@symbol 行），保留注释忽略空行
mapfile -t PKG_LINES < <(grep -vE '^\s*(#|$)' "${REQUIRED_LIST}" | grep -v '^@symbol')

FAIL_COUNT=0
FAILED_ITEMS=()

# ---- 统一失败诊断 -------------------------------------------------------------
report_fail() {
  local item="$1" cmd="$2" expect="$3" actual="$4" cause="$5" fix="$6"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_ITEMS+=("${item}")
  cat >&2 <<EOF
-------------------- 缺失项 ${FAIL_COUNT}: ${item} --------------------
  检测命令   : ${cmd}
  期望值     : ${expect}
  实际值     : ${actual}
  可能原因   : ${cause}
  建议修复   : ${fix}
EOF
}

# =============================================================================
# 模式一：config 校验
# =============================================================================
if [[ "${MODE}" == "config" ]]; then
  [[ -f "${CONFIG_FILE}" ]] || { log_error "配置文件不存在：${CONFIG_FILE}"; exit 1; }
  log_info "config 模式：校验 ${CONFIG_FILE}"

  # 0. 目标平台 sanity（本仓库固定 X86_64 Generic + squashfs）
  for sym in "CONFIG_TARGET_x86=y" "CONFIG_TARGET_x86_64=y" "CONFIG_TARGET_ROOTFS_SQUASHFS=y"; do
    if ! grep -qE "^${sym}([[:space:]]|$)" "${CONFIG_FILE}"; then
      report_fail "${sym}" "grep -E '^${sym}([[:space:]]|$)' ${CONFIG_FILE}" "存在" "不存在" \
        "配置文件被改动或本仓库目标规范变化" "确认本仓库固定编译 X86_64 Generic + squashfs"
    fi
  done

  # 1. 每个必装包必须 CONFIG_PACKAGE_<包名>=y
  #    匹配容忍行尾注释（config 文件中形如 CONFIG_PACKAGE_x=y # 说明），
  #    defconfig 归一化后的 .config 同样兼容。
  for pkg in "${PKG_LINES[@]}"; do
    sym="CONFIG_PACKAGE_${pkg}=y"
    if ! grep -qE "^${sym}([[:space:]]|$)" "${CONFIG_FILE}"; then
      # 区分「完全没写」与「写了但被关掉」两种实际值，便于定位
      if grep -qE "^# CONFIG_PACKAGE_${pkg} is not set" "${CONFIG_FILE}"; then
        actual="# CONFIG_PACKAGE_${pkg} is not set（被显式关闭）"
      else
        actual="配置文件中无 ${sym}"
      fi
      report_fail "${pkg}" "grep -E '^${sym}([[:space:]]|$)' ${CONFIG_FILE}" "${sym}" "${actual}" \
        "插件未写入 config/X86_64.config；或官方 feed 已改名/移除该包；或被误关" \
        "在 config/X86_64.config 增补 '${sym}'；若上游改名请同步更新 required-packages.txt"
    fi
  done

  # 2. @symbol 行原样匹配（TurboAcc 功能开关等非包符号）
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    sym="${line#@symbol }"
    sym="$(echo "${sym}" | xargs)"
    [[ -z "${sym}" ]] && continue
    if ! grep -qF "${sym}" "${CONFIG_FILE}"; then
      report_fail "${sym}" "grep -F '${sym}' ${CONFIG_FILE}" "存在" "不存在" \
        "TurboAcc 功能开关未写入配置，或取值被改" \
        "在 config/X86_64.config 中补上 '${sym}'（流量分载/BBR/全锥均需开启）"
    fi
  done < <(grep '^@symbol' "${REQUIRED_LIST}")

  # 3. 反向检查：被显式关闭的 TurboAcc 开关（SFE 系）必须保持关闭
  for sym in "CONFIG_PACKAGE_TURBOACC_INCLUDE_FAST_CLASSIFIER" \
             "CONFIG_PACKAGE_TURBOACC_INCLUDE_SHORTCUT_FE_CM" \
             "CONFIG_PACKAGE_TURBOACC_INCLUDE_NO_FASTPATH"; do
    if grep -qE "^${sym}=y" "${CONFIG_FILE}"; then
      report_fail "${sym}" "grep -E '^${sym}=y' ${CONFIG_FILE}" "未开启（SFE 系已移除）" "被开启" \
        "有人误开了 SFE 相关开关" \
        "删除/注释 config/X86_64.config 中的 ${sym}=y（用户规范：移除 SFE/Shortcut-FE）"
    fi
  done

  if [[ ${FAIL_COUNT} -eq 0 ]]; then
    log_ok "config 校验通过：${#PKG_LINES[@]} 个必装包 + 功能开关全部就位（${CONFIG_FILE}）"
    exit 0
  else
    log_error "config 校验失败：共 ${FAIL_COUNT} 项不满足"
    exit 1
  fi
fi

# =============================================================================
# 模式二：manifest 校验
# =============================================================================
if [[ "${MODE}" == "manifest" ]]; then
  # 未显式指定时自动定位 bin/targets/x86/64/*.manifest
  if [[ -z "${MANIFEST}" ]]; then
    shopt -s nullglob
    candidates=(bin/targets/x86/64/*.manifest)
    shopt -u nullglob
    if [[ ${#candidates[@]} -eq 0 ]]; then
      log_error "未找到 manifest 文件：bin/targets/x86/64/*.manifest"
      log_error "请确认编译已完成，或显式指定 manifest 路径：$0 manifest <路径>"
      exit 1
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
      log_error "找到多个 manifest 文件，请显式指定其一："
      printf '    %s\n' "${candidates[@]}" >&2
      exit 1
    fi
    MANIFEST="${candidates[0]}"
  fi
  [[ -f "${MANIFEST}" ]] || { log_error "manifest 文件不存在：${MANIFEST}"; exit 1; }
  log_info "manifest 模式：校验 ${MANIFEST}"

  # manifest 行格式：<包名> - <版本>
  for pkg in "${PKG_LINES[@]}"; do
    if ! awk -v p="${pkg}" '$1 == p { found = 1 } END { exit(found ? 0 : 1) }' "${MANIFEST}"; then
      # 给出实际值：manifest 中是否有相近包名（改名/拆分线索）
      sim_pkgs="$(awk '{print $1}' "${MANIFEST}" | grep -F "${pkg}" | head -3 | tr '\n' ' ')"
      report_fail "${pkg}" "awk '\$1 == \"${pkg}\"' ${MANIFEST}" "镜像已安装 ${pkg}" "未安装（相近包名：${sim_pkgs:-无}）" \
        "插件未进 config；feed 结构调整导致包名变化；依赖冲突被构建系统丢弃" \
        "核对 config/X86_64.config 是否含 CONFIG_PACKAGE_${pkg}=y；检查编译日志有无依赖冲突；确认上游包名是否变化"
    fi
  done

  # 附加：镜像中不得包含被禁用的 TurboAcc 开关对应包（SFE 系）
  for bad in "kmod-fast-classifier" "kmod-shortcut-fe-cm"; do
    if awk -v p="${bad}" '$1 == p { found = 1 } END { exit(found ? 0 : 1) }' "${MANIFEST}"; then
      report_fail "${bad}" "awk '\$1 == \"${bad}\"' ${MANIFEST}" "镜像不含 ${bad}（SFE 已移除）" "竟然安装了 ${bad}" \
        "TurboAcc 开关被误开或上游依赖变化" \
        "检查 config 中 TURBOACC_INCLUDE_FAST_CLASSIFIER / SHORTCUT_FE_CM 是否为 not set"
    fi
  done

  if [[ ${FAIL_COUNT} -eq 0 ]]; then
    log_ok "manifest 校验通过：${#PKG_LINES[@]} 个必装包全部在镜像中（${MANIFEST}）"
    exit 0
  else
    log_error "manifest 校验失败：共 ${FAIL_COUNT} 个必装包缺失"
    exit 1
  fi
fi
