#!/usr/bin/env bash
# =====================================================================
# 脚本 2：第三方插件拉取（浅克隆子目录方式）
# ---------------------------------------------------------------------
# 规范：
#   1. 优先使用官方源码包（官方已有插件不在此拉取）；
#   2. 第三方插件采用浅克隆（--depth 1）+ 仅复制所需子目录，禁止冗余下载；
#   3. 拉取前强制前置校验：仓库连通性、分支存在、目录完整，异常立即终止。
#
# 源码：
#   kenzok8/openwrt-packages  —— 主软件源
#   kenzok8/small-package      —— 作为 openwrt-packages 的补充
#   mufeng05/turboacc          —— TurboACC 加速
#   destan19/OpenAppFilter     —— oaf 应用过滤上游（缺失功能兜底引入）
#
# 用法：./setup-thirdparty.sh <lede 目录>
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: setup-thirdparty.sh <lede 目录>}"
[ -d "$LEDE_DIR" ] || { echo "[错误] LEDE 目录不存在: $LEDE_DIR"; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------- 需从第三方拉取的插件/核心目录名 ----------
# 说明：官方 LEDE 已含 mwan3/wol/upnp/ttyd/nlbwmon/autoreboot，无需在此拉取。
PKGS=(
  smartdns luci-app-smartdns
  luci-app-ddnsto
  adguardhome luci-app-adguardhome
  oaf kmod-oaf luci-app-oaf
  luci-app-turboacc turboacc
  luci-theme-argon luci-app-argon-config
  luci-app-easytier
  luci-app-wechatpush
)

# ---------- 第三方仓库（url|目录名） ----------
declare -A REPOS=(
  [kenzo]="https://github.com/kenzok8/openwrt-packages"
  [small]="https://github.com/kenzok8/small-package"
  [turboacc]="https://github.com/mufeng05/turboacc"
  [oaf]="https://github.com/destan19/OpenAppFilter"
)

echo "==> [thirdparty] 前置校验：仓库连通性 + 默认分支（自动识别 master/main）"
for name in "${!REPOS[@]}"; do
  url="${REPOS[$name]}"
  ok=0
  for attempt in 1 2 3; do
    git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1 && { ok=1; break; }
    sleep 3
  done
  if [ "$ok" -eq 1 ]; then
    echo "    ✓ ${name} 连通正常"
  else
    echo "[错误] 仓库不可达或不存在：${url}"
    echo "       修复建议：检查网络 / 仓库是否被删除或改名"
    exit 1
  fi
done

echo "==> [thirdparty] 浅克隆第三方仓库（自动跟随默认分支）"
for name in "${!REPOS[@]}"; do
  url="${REPOS[$name]}"
  echo "    · 克隆 ${name}"
  git clone --depth 1 "$url" "$WORK_DIR/$name" >/dev/null 2>&1 \
    || { echo "[错误] 浅克隆失败：${url}"; exit 1; }
done

echo "==> [thirdparty] 复制所需子目录到 lede/package/"
MISSING=0
for pkg in "${PKGS[@]}"; do
  # 在全部第三方仓库中按目录名查找（深度 5 以内）
  found="$(find "$WORK_DIR" -maxdepth 5 -type d -name "$pkg" -print -quit 2>/dev/null || true)"
  if [ -n "$found" ] && [ -f "$found/Makefile" ]; then
    # 复制成为 lede 主树内的包
    rm -rf "$LEDE_DIR/package/$pkg"
    cp -r "$found" "$LEDE_DIR/package/$pkg"
    echo "    ✓ ${pkg}  <-- ${found#$WORK_DIR/}"
  else
    echo "    ✗ 未找到 ${pkg}（请确认第三方仓库包含该目录）"
    MISSING=1
  fi
done

echo "==> [thirdparty] 校验目录完整性"
if [ "$MISSING" -ne 0 ]; then
  echo "[错误] 存在缺失的第三方插件目录，终止流程。"
  echo "       修复建议："
  echo "         1. 确认 kenzok8/openwrt-packages 与 small-package 的目录名是否变更（可 clone 后 ls 查看）；"
  echo "         2. 确认 mufeng05/turboacc 是否包含 luci-app-turboacc；"
  echo "         3. 确认 destan19/OpenAppFilter 是否包含 oaf / kmod-oaf / luci-app-oaf。"
  exit 1
fi

echo "==> [thirdparty] 第三方插件拉取完成 ✔"