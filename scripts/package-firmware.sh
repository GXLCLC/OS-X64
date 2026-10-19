#!/usr/bin/env bash
# =====================================================================
# 脚本 5：打包固件 + 生成 Release 元数据
# ---------------------------------------------------------------------
# 用法：./package-firmware.sh <lede 目录>
# 环境变量：
#   DEFAULT_IP       默认后台 IP   （默认 192.168.2.1）
#   DEFAULT_PASSWORD 默认密码      （默认 12345678）
#   HOSTNAME         主机名        （默认 LEDE）
#
# 产物（输出到 release/）：
#   <时间戳>-LEDE-x86_64-generic-squashfs-combined.img.gz
#   RELEASE_NOTES.md
# 并写入 GITHUB_ENV：RELEASE_TAG=<时间戳>
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: package-firmware.sh <lede 目录>}"
DEFAULT_IP="${DEFAULT_IP:-192.168.2.1}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-12345678}"
HOSTNAME="${HOSTNAME:-LEDE}"

BIN_DIR="$LEDE_DIR/bin/targets/x86/64"
CONFIG="$LEDE_DIR/.config"
OUT_DIR="release"

mkdir -p "$OUT_DIR"

# ---------- 时间戳作为 Release 标签与固件名前缀 ----------
TS="$(date +%Y%m%d-%H%M%S)"
echo "RELEASE_TAG=${TS}" >> "$GITHUB_ENV"

# ---------- 定位目标镜像（只保留 squashfs-combined.img.gz） ----------
IMG_GZ="$(find "$BIN_DIR" -maxdepth 1 -name '*squashfs-combined.img.gz' | head -n1 || true)"
[ -n "$IMG_GZ" ] || { echo "[失败] 未找到目标 img.gz，无法打包"; exit 1; }

NEW_NAME="${TS}-LEDE-x86_64-generic-squashfs-combined.img.gz"
cp "$IMG_GZ" "$OUT_DIR/$NEW_NAME"
echo "==> 固件已打包: $NEW_NAME"

# ---------- 提取内核版本 / 固件版本（优先 manifest） ----------
MANIFEST="$(find "$BIN_DIR" -maxdepth 1 -name '*squashfs-combined.manifest' | head -n1 || true)"
KVER="unknown"
FVER="unknown"
if [ -n "$MANIFEST" ]; then
  KVER="$(grep -m1 '^kernel ' "$MANIFEST" | awk '{print $3}' || echo unknown)"
  FVER="$(grep -m1 '^base-files ' "$MANIFEST" | awk '{print $3}' || echo unknown)"
fi
echo "==> 内核版本: ${KVER}"
echo "==> 固件版本: ${FVER}"

# ---------- 纯净插件清单（不展示 kmod / lib 等依赖） ----------
PLUGIN_LIST="$(grep -E '^CONFIG_PACKAGE_(luci-app-|luci-theme-|smartdns|adguardhome|oaf|turboacc|easytier|nlbwmon|wechatpush|ttyd|mwan3)' "$CONFIG" \
  | sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort -u)"

# ---------- 生成 Release 说明 ----------
cat > "$OUT_DIR/RELEASE_NOTES.md" <<EOF
## LEDE X86_64 固件（自动编译）

- **编译时间**：$(date '+%Y-%m-%d %H:%M:%S %Z')
- **内核版本**：\`${KVER}\`
- **固件版本**：\`${FVER}\`（源码 commit \`${LEDE_SHORT:-unknown}\`）
- **目标架构**：x86_64（Generic，squashfs）

### 默认配置
- 后台 IP：\`${DEFAULT_IP}\`
- 默认密码：\`${DEFAULT_PASSWORD}\`
- 主机名：\`${HOSTNAME}\`
- 时区：\`Asia/Shanghai\`
- 默认主题：\`Argon\`

### 预装插件清单（纯净，不含 kmod）
\`\`\`
${PLUGIN_LIST}
\`\`\`

> 由 GitHub Actions 自动化构建，源码：coolsnowwolf/lede（master 分支）。
EOF

echo "==> Release 说明已生成: $OUT_DIR/RELEASE_NOTES.md"
echo "==> release 目录产物："
ls -lh "$OUT_DIR"
echo "==> RELEASE_TAG=${TS}"