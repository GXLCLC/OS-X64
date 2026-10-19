#!/usr/bin/env bash
# =====================================================================
# 脚本 3：编译前严格校验（插件完整性 / 冲突 / 缺依赖）
# ---------------------------------------------------------------------
# 校验项：
#   1. 必需插件 CONFIG_PACKAGE_xxx=y 是否在 defconfig 后仍被保留
#   2. 禁用项（SFE / Shortcut-FE）是否已被移除
#   3. 内核模块（网卡 / USB / 存储）是否齐全
#   4. 第三方插件源码目录是否已就位
#
# 用法：./pre-verify.sh <lede 目录>
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: pre-verify.sh <lede 目录>}"
CONFIG="$LEDE_DIR/.config"

[ -f "$CONFIG" ] || { echo "[错误] 未找到 .config （请先 cp 配置并 make defconfig）: $CONFIG"; exit 1; }

FAIL=0

# ---------- 1. 必需插件 + 内核模块（缺失直接失败） ----------
REQUIRED_PKGS=(
  # 插件（15 项）
  luci-app-smartdns
  luci-app-ddnsto
  luci-app-adguardhome
  luci-app-oaf
  kmod-oaf
  luci-app-turboacc
  luci-app-mwan3
  luci-app-argon-config
  luci-theme-argon
  luci-app-nlbwmon
  luci-app-easytier
  luci-app-wol
  luci-app-upnp
  luci-app-ttyd
  luci-app-autoreboot
  luci-app-wechatpush
  # 网卡驱动（i211 / RTL8111 / e1000e）
  kmod-igb
  kmod-r8169
  kmod-e1000e
  # USB 网卡 + 存储
  kmod-usb2
  kmod-usb3
  kmod-usb-net
  kmod-usb-net-rtl8152
  kmod-usb-net-asix
  kmod-usb-net-asix-ax88179
  kmod-usb-storage
  kmod-usb-storage-extras
  # 存储文件系统
  kmod-fs-ext4
  kmod-fs-vfat
  kmod-fs-exfat
)

echo "==> 校验必需插件与内核模块（共 ${#REQUIRED_PKGS[@]} 项）"
for pkg in "${REQUIRED_PKGS[@]}"; do
  if grep -qE "^CONFIG_PACKAGE_${pkg}=y$" "$CONFIG"; then
    echo "    ✓ 必需   ${pkg}"
  else
    echo "    ✗ 缺失   ${pkg}   <-- 请检查插件源/依赖是否完整"
    FAIL=1
  fi
done

# ---------- 2. 禁用项（SFE / Shortcut-FE 必须移除） ----------
DISALLOWED=(
  kmod-fast-classifier
  kmod-shortcut-fe
  kmod-shortcut-fe-cm
)

echo "==> 校验 SFE / Shortcut-FE 已移除"
for pkg in "${DISALLOWED[@]}"; do
  if grep -qE "^CONFIG_PACKAGE_${pkg}=y$" "$CONFIG"; then
    echo "    ✗ 仍存在  ${pkg}   <-- 应移除 SFE/Shortcut-FE"
    FAIL=1
  else
    echo "    ✓ 已移除  ${pkg}"
  fi
done

# ---------- 3. 语言包（可选，缺失仅警告，不致命） ----------
OPTIONAL_I18N=(
  luci-i18n-smartdns-zh-cn
  luci-i18n-adguardhome-zh-cn
  luci-i18n-mwan3-zh-cn
  luci-i18n-nlbwmon-zh-cn
  luci-i18n-wol-zh-cn
  luci-i18n-upnp-zh-cn
  luci-i18n-ttyd-zh-cn
  luci-i18n-turboacc-zh-cn
)

echo "==> 校验 zh-cn 语言包（缺失仅警告）"
for pkg in "${OPTIONAL_I18N[@]}"; do
  grep -qE "^CONFIG_PACKAGE_${pkg}=y$" "$CONFIG" \
    && echo "    ✓ 语言包  ${pkg}" \
    || echo "    ! 警告    ${pkg} 未启用（不影响主插件）"
done

# ---------- 4. 第三方插件已通过 feeds 就位 ----------
# feeds install 后，第三方包以符号链接存在于 package/feeds/<feed>/<包名>/
THIRD_PARTY_PKGS=(
  smartdns luci-app-smartdns
  luci-app-ddnsto
  adguardhome luci-app-adguardhome
  luci-app-oaf kmod-oaf appfilter
  luci-app-turboacc
  luci-theme-argon luci-app-argon-config
  luci-app-easytier easytier
  luci-app-wechatpush
)

echo "==> 校验第三方插件已通过 feeds 就位"
for p in "${THIRD_PARTY_PKGS[@]}"; do
  if [ -n "$(find -L "$LEDE_DIR/package/feeds" -maxdepth 2 -type d -name "$p" -print -quit 2>/dev/null)" ]; then
    echo "    ✓ 就位   ${p}"
  else
    echo "    ✗ 缺失   ${p}   <-- 第三方 feed 未安装"
    FAIL=1
  fi
done

# ---------- 汇总 ----------
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "======================================================"
  echo "[失败] 前置校验未通过，终止编译，避免假成功 / 缺插件。"
  echo "修复建议："
  echo "  1. 缺失插件：确认 third-party feeds 已注册、feeds install -a 成功，或 feed 仓库是否改名/删除；"
  echo "  2. 内核模块缺失：确认 target=x86_64 且内核版本匹配；"
  echo "  3. SFE 残留：确认 config 中未启用 kmod-shortcut-fe / fast-classifier。"
  echo "======================================================"
  exit 1
fi

echo ""
echo "==> 前置校验全部通过 ✔"