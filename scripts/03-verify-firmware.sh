#!/usr/bin/env bash
# ============================================================
# 脚本名称 : 03-verify-firmware.sh
# 功能     : 编译后严格校验 —— 目标镜像存在性 / 压缩包完整性 /
#            镜像格式 / 根分区扩容 2G / 冲突模块 / 插件完整性
# 任一项不达标：直接终止流程（未生成目标镜像即判定编译失败）
# 运行位置 : lede 源码根目录
# ============================================================
set -euo pipefail

TARGET_DIR="bin/targets/x86/64"
ERRLOG="ERROR_BUILD_CHECK.log"
: > "$ERRLOG"

fail() { # 记录错误到日志并立即终止
  echo "ERROR: $*" | tee -a "$ERRLOG"
  exit 1
}

echo "===== 固件严格校验开始 ====="

# ---- 1. 目标镜像存在性（squashfs + img.gz，优先 EFI，回退 Legacy） ----
IMG_GZ="$(find "$TARGET_DIR" -maxdepth 1 -name "*-x86-64-generic-squashfs-combined-efi.img.gz" -print -quit)"
if [ -z "$IMG_GZ" ]; then
  IMG_GZ="$(find "$TARGET_DIR" -maxdepth 1 -name "*-x86-64-generic-squashfs-combined.img.gz" -print -quit)"
fi
[ -n "$IMG_GZ" ] || fail "未生成目标镜像 *-x86-64-generic-squashfs-combined*.img.gz（判定编译失败）"
echo "[OK] 目标镜像: $IMG_GZ ($(du -h "$IMG_GZ" | cut -f1))"

# ---- 2. 压缩包完整性 ----
gzip -t "$IMG_GZ" || fail "img.gz 压缩包损坏（gzip 完整性校验失败）"
echo "[OK] img.gz 压缩包完整性通过"

# ---- 3. 镜像格式校验（解压检查引导扇区） ----
IMG="${IMG_GZ%.gz}"
gunzip -k -f "$IMG_GZ"
trap 'rm -f "$IMG"' EXIT   # 校验完清理解压的临时镜像
file "$IMG" | grep -qiE "boot sector" || fail "镜像缺少引导扇区，分区表/格式异常"
echo "[OK] 镜像格式校验通过"

# ---- 4. 根分区容量校验（强制扩容 2G：默认 104MB + 2048MB = 2152MB） ----
ROOT_MB="$(parted -sm "$IMG" unit MB print 2>/dev/null \
  | awk -F: '/^[0-9]+:/ {s=$4; gsub(/MB/,"",s); if (s+0 > m) m=s+0} END {printf "%d", m}')"
echo "根分区（最大数据分区）容量: ${ROOT_MB}MB"
[ "${ROOT_MB:-0}" -ge 2048 ] || fail "根分区容量 ${ROOT_MB}MB 未达到扩容 2G 要求（需 ≥ 2048MB）"
echo "[OK] 根分区容量校验通过（≥2048MB）"

# ---- 5. 冲突模块审计（保留官方内核：禁止 SFE / Shortcut-FE 残留） ----
MANIFEST="$(find "$TARGET_DIR" -maxdepth 1 -name "*.manifest" -print -quit)"
[ -n "$MANIFEST" ] || fail "未找到 manifest 清单文件，无法审计"
if grep -qiE "shortcut-fe|fast-classifier|kmod-sfe" "$MANIFEST"; then
  fail "检测到 SFE/Shortcut-FE 冲突内核模块，违反『保留官方内核、仅移除冲突第三方模块』策略"
fi
echo "[OK] 冲突模块审计通过（无 SFE/Shortcut-FE）"

# ---- 6. 必需插件逐项核对（杜绝假成功 / 缺插件） ----
REQUIRED_PKGS="
luci-app-smartdns luci-app-ddnsto luci-app-adguardhome luci-app-oaf kmod-oaf
luci-app-turboacc luci-app-mwan3 luci-theme-argon luci-theme-argon-config
luci-app-nlbwmon luci-app-easytier luci-app-wol luci-app-upnp luci-app-ttyd
luci-app-autoreboot luci-app-wechatpush"
MISSING_PKGS=""
for p in $REQUIRED_PKGS; do
  grep -q "^$p - " "$MANIFEST" || MISSING_PKGS="$MISSING_PKGS $p"
done
[ -z "$MISSING_PKGS" ] || fail "以下必需插件未编入固件（缺插件即失败）:$MISSING_PKGS"
echo "[OK] 全部必需插件已编入固件"

echo "===== 固件校验全部通过 ====="
