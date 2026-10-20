#!/bin/bash
# =============================================================================
# collect-errors.sh —— 编译失败日志收集（用户规范：失败只上传 ERROR 失败日志）
#
# 用法：collect-errors.sh [源码根目录] [主构建日志] [输出目录]
#   源码根目录 : 默认当前目录（LEDE 源码树根）
#   主构建日志 : make 的重定向日志，默认自动探测 build.log / make.log / *.log
#   输出目录   : 默认 <源码根>/error-logs-<UTC时间戳>，供工作流整体上传
#
# 收集内容：
#   1. 主构建日志中的错误/失败关键行（error-summary.txt，含上下文）
#   2. OpenWrt logs/ 目录下全部 *.log（单个文件超限时只保留尾部）
#   3. 最终 .config 与 config/X86_64.config 的差异（config-diff.txt）
#   4. feeds.conf / .config / 关键脚本副本（便于复现）
#   5. 环境信息（内核、gcc、磁盘、内存）
# =============================================================================
set -uo pipefail

SRC_ROOT="${1:-$(pwd)}"
MAIN_LOG="${2:-}"
OUT_DIR="${3:-}"
EARLY_FAILURE=0   # 1 = 源码树尚未生成（早期步骤失败）

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[失败日志]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }

cd "${SRC_ROOT}" 2>/dev/null || {
  # 源码树尚未生成（依赖安装/克隆源码等早期步骤即失败）。
  # 降级处理：以工作区根为收集点，保留环境信息与失败阶段线索，
  # 绝不 exit 1（否则收集步骤自身失败，反而掩盖真实失败原因）。
  echo "源码根目录不存在：${SRC_ROOT}（早期步骤失败，尚未克隆源码）" >&2
  SRC_ROOT="$(pwd)"
  cd "${SRC_ROOT}" || exit 1
  EARLY_FAILURE=1
}

# ---- 自动探测主构建日志 -------------------------------------------------------
if [[ -z "${MAIN_LOG}" ]]; then
  for cand in build.log make.log compile.log openwrt-build.log; do
    [[ -f "${cand}" ]] && { MAIN_LOG="${cand}"; break; }
  done
  if [[ -z "${MAIN_LOG}" ]]; then
    MAIN_LOG="$(ls -t *.log 2>/dev/null | head -1 || true)"
  fi
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-${SRC_ROOT}/error-logs-${TS}}"
mkdir -p "${OUT_DIR}"

log_info "源码根目录：${SRC_ROOT}"
log_info "主构建日志：${MAIN_LOG:-（未找到）}"
log_info "输出目录  ：${OUT_DIR}"

# ---- 1. 主构建日志错误关键行 ---------------------------------------------------
if [[ -n "${MAIN_LOG}" && -f "${MAIN_LOG}" ]]; then
  # 常见失败模式：OpenWrt make 错误 / 依赖冲突 / 编译报错 / 校验失败
  grep -nE -i \
    -e 'collected errors' \
    -e '\berror\b' -e '\bfailed\b' -e '\bfatal\b' \
    -e 'cannot find' -e 'No rule to make' -e 'undefined reference' \
    -e 'missing dependency' -e 'Dependency .* unsatisfied' \
    -e '校验失败' -e '不达标' -e '未找到' -e '不存在' \
    "${MAIN_LOG}" 2>/dev/null | tail -n 300 > "${OUT_DIR}/error-summary.txt" || true
  # 尾部上下文（失败通常发生在最后）
  tail -n 500 "${MAIN_LOG}" > "${OUT_DIR}/build-log-tail.txt"
  cp -f "${MAIN_LOG}" "${OUT_DIR}/" 2>/dev/null || true
  log_ok "已提取错误关键行 -> error-summary.txt（$(wc -l < "${OUT_DIR}/error-summary.txt" 2>/dev/null || echo 0) 行）"
else
  echo "未找到主构建日志（make 输出未重定向或已被清理）" > "${OUT_DIR}/error-summary.txt"
  log_warn "未找到主构建日志，error-summary.txt 记录该情况"
fi

# ---- 2. OpenWrt logs/ 目录 -----------------------------------------------------
if [[ -d logs ]]; then
  mkdir -p "${OUT_DIR}/logs"
  COUNT=0
  while IFS= read -r f; do
    rel="${f#logs/}"
    mkdir -p "${OUT_DIR}/logs/$(dirname "${rel}")"
    # 单个日志超 2 MiB 只保留尾部 5000 行，控制工件体积
    if [[ "$(stat -c%s "${f}" 2>/dev/null || echo 0)" -gt 2097152 ]]; then
      tail -n 5000 "${f}" > "${OUT_DIR}/logs/${rel}"
      echo "... [已截断：仅保留尾部 5000 行] ..." >> "${OUT_DIR}/logs/${rel}"
    else
      cp -f "${f}" "${OUT_DIR}/logs/${rel}"
    fi
    COUNT=$((COUNT + 1))
  done < <(find logs -type f -name '*.log' 2>/dev/null | head -n 2000)
  log_ok "已收集 logs/ 下 ${COUNT} 个日志文件"
else
  log_warn "源码树无 logs/ 目录（可能尚未开始编译即失败）"
fi

# ---- 3. 配置差异 ---------------------------------------------------------------
if [[ -f .config ]]; then
  cp -f .config "${OUT_DIR}/final.config"
  if [[ -f config/X86_64.config ]]; then
    diff -u config/X86_64.config .config > "${OUT_DIR}/config-diff.txt" 2>/dev/null || true
    # .config 自动生成行极多，差异文件超 500 行时截断并提示
    if [[ "$(wc -l < "${OUT_DIR}/config-diff.txt" 2>/dev/null || echo 0)" -gt 500 ]]; then
      head -n 500 "${OUT_DIR}/config-diff.txt" > "${OUT_DIR}/config-diff.txt.tmp"
      echo "... [差异超 500 行，已截断；完整 .config 见 final.config] ..." >> "${OUT_DIR}/config-diff.txt.tmp"
      mv -f "${OUT_DIR}/config-diff.txt.tmp" "${OUT_DIR}/config-diff.txt"
    fi
    log_ok "已生成 config-diff.txt（仓库配置 vs 最终 .config）"
  fi
else
  echo "源码树无 .config（可能尚未执行 make defconfig 即失败）" > "${OUT_DIR}/final.config"
  log_warn "无 .config 可收集"
fi

# ---- 4. 复现要素 ---------------------------------------------------------------
for f in feeds.conf .config config/X86_64.config config/required-packages.txt; do
  [[ -f "${f}" ]] && cp -f "${f}" "${OUT_DIR}/" 2>/dev/null
done
for s in scripts/fetch-thirdparty.sh scripts/apply-turboacc.sh scripts/personalize.sh; do
  [[ -f "${s}" ]] && cp -f "${s}" "${OUT_DIR}/" 2>/dev/null
done

# ---- 4b. 早期失败线索（源码树尚未生成的场景） ---------------------------------
if [[ "${EARLY_FAILURE}" == "1" ]]; then
  {
    echo "==== 失败发生在源码克隆之前（早期步骤失败）"
    echo "==== 可能失败的步骤：检出仓库 / 释放磁盘 / 安装编译依赖 / 克隆 LEDE"
    echo "==== 完整错误请查看 Actions 运行日志中第一个标红步骤的输出"
    echo ""
    echo "==== 工作区顶层内容（判断失败点）："
    ls -la "${SRC_ROOT}" 2>/dev/null | head -30
    echo ""
    echo "==== Actions 运行上下文："
    echo "GITHUB_REPOSITORY : ${GITHUB_REPOSITORY:-（非 Actions 环境）}"
    echo "GITHUB_RUN_ID    : ${GITHUB_RUN_ID:-?}"
    echo "GITHUB_RUN_NUMBER: ${GITHUB_RUN_NUMBER:-?}"
    echo "GITHUB_JOB       : ${GITHUB_JOB:-?}"
    echo "GITHUB_SHA       : ${GITHUB_SHA:-?}"
  } > "${OUT_DIR}/failure-stage.txt"
  log_warn "源码树未生成，已写入 failure-stage.txt（早期失败线索）"
fi

# ---- 5. 环境信息 ---------------------------------------------------------------
{
  echo "==== 收集时间（UTC）: $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "==== 内核: $(uname -a)"
  echo "==== 发行版: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "==== gcc: $(gcc --version 2>/dev/null | head -1)"
  echo "==== 磁盘: $(df -h "${SRC_ROOT}" 2>/dev/null | tail -1)"
  echo "==== 内存: $(free -h 2>/dev/null | head -2 | tail -1)"
  echo "==== CPU: $(nproc 2>/dev/null) 核"
} > "${OUT_DIR}/environment.txt"

# ---- 汇总 ----------------------------------------------------------------------
echo ""
log_info "收集完成，文件清单："
find "${OUT_DIR}" -type f -printf '  %-70p %10s 字节\n' | sort | head -n 60
TOTAL="$(du -sh "${OUT_DIR}" 2>/dev/null | cut -f1)"
log_ok "失败日志收集完毕：${OUT_DIR}（总计 ${TOTAL:-?}）"
echo "${OUT_DIR}"
