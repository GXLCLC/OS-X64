#!/usr/bin/env bash
# =====================================================================
# 脚本 2：注册第三方插件 feeds 源（src-git 方式，不做手动物理拷贝）
# ---------------------------------------------------------------------
# 规范：
#   1. 第三方插件一律通过 OpenWrt 标准 feeds 机制引入，由后续
#      `./scripts/feeds update -a && ./scripts/feeds install -a` 统一拉取；
#   2. src-git 会自动跟随各仓库默认分支（master/main 不写死，规避分支改名坑）；
#   3. 嵌套结构（如 small-package 里 other/lean/luci-app-turboacc）、
#      同目录多包（如 oaf/Makefile 同时产出 kmod-oaf）、共享 version.mk
#      等均由 feeds 系统自动解析，不再手工 find/cp；
#   4. 注册前强制前置校验：仓库连通性 + HEAD 可达，异常立即终止。
#
# feeds 源与覆盖插件：
#   kenzok8/openwrt-packages  —— smartdns / adguardhome / argon / ddnsto / wechatpush 等
#   kenzok8/small-package      —— luci-app-turboacc / luci-app-easytier 等
#   destan19/OpenAppFilter     —— luci-app-oaf + kmod-oaf + appfilter
#
# 用法：./setup-thirdparty.sh <lede 目录>
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: setup-thirdparty.sh <lede 目录>}"
FEEDS_FILE="$LEDE_DIR/feeds.conf.default"
[ -d "$LEDE_DIR" ] || { echo "[错误] LEDE 目录不存在: $LEDE_DIR"; exit 1; }
[ -f "$FEEDS_FILE" ] || { echo "[错误] 找不到 feeds.conf.default: $FEEDS_FILE"; exit 1; }

# ---------- 第三方 feed 源（名称|URL） ----------
FEEDS=(
  "kenzo|https://github.com/kenzok8/openwrt-packages"
  "small|https://github.com/kenzok8/small-package"
  "oaf|https://github.com/destan19/OpenAppFilter"
)

echo "==> [thirdparty] 前置校验：仓库连通性（默认分支自动识别）"
for entry in "${FEEDS[@]}"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  ok=0
  for attempt in 1 2 3; do
    if git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 3
  done
  if [ "$ok" -eq 1 ]; then
    echo "    ✓ ${name} 连通正常"
  else
    echo "[错误] 仓库不可达或不存在：${url}"
    exit 1
  fi
done

echo "==> [thirdparty] 注册 feeds 源到 feeds.conf.default"
for entry in "${FEEDS[@]}"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  line="src-git ${name} ${url}"
  if grep -Fq "$line" "$FEEDS_FILE"; then
    echo "    · 已存在：${name}（跳过）"
  else
    echo "$line" >> "$FEEDS_FILE"
    echo "    ✓ 已注册：${name}"
  fi
done

echo "==> [thirdparty] 第三方 feeds 源注册完成（实际拉取由后续 feeds update -a 完成）✔"