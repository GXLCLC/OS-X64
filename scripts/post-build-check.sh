#!/usr/bin/env bash
# =====================================================================
# 脚本 4：编译后校验（文件存在 / 格式 squashfs / 分区容量 / 插件）
# ---------------------------------------------------------------------
# 用法：./post-build-check.sh <lede 目录> [期望根分区大小 MB]
#
# 校验项：
#   1. 目标镜像 squashfs-combined.img.gz 是否生成（未生成即判定编译失败）
#   2. gzip 完整性
#   3. 是否包含 squashfs 根文件系统
#   4. 根分区容量是否 >= 期望值（不达标直接终止）
#   5. .config 中的 CONFIG_TARGET_ROOTFS_PARTSIZE 是否达标
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: post-build-check.sh <lede 目录> [期望根分区大小 MB]}"
ROOTFS_PARTSIZE="${2:-2048}"   # 期望根分区大小（MB）

BIN_DIR="$LEDE_DIR/bin/targets/x86/64"
CONFIG="$LEDE_DIR/.config"

FAIL=0
ROOTFS_RAW=""   # 用于清理解压产物，避免 set -u 下未绑定报错

# ---------- 1. 目标镜像存在性 ----------
echo "==> 定位目标镜像"
COMBINED_GZ="$(find "$BIN_DIR" -maxdepth 1 -name '*squashfs-combined.img.gz' | head -n1 || true)"
ROOTFS_GZ="$(find "$BIN_DIR" -maxdepth 1 -name '*squashfs-rootfs.img*' | head -n1 || true)"

if [ -z "$COMBINED_GZ" ] || [ ! -f "$COMBINED_GZ" ]; then
  echo "[失败] 未生成目标镜像 squashfs-combined.img.gz，判定编译失败。"
  exit 1
fi
echo "    ✓ 目标镜像: $(basename "$COMBINED_GZ")"

# ---------- 2. gzip 完整性 ----------
echo "==> gzip 完整性校验"
if gzip -t "$COMBINED_GZ"; then
  echo "    ✓ gzip 校验通过"
else
  echo "[失败] gzip 包损坏"; exit 1
fi

# ---------- 3. squashfs 格式校验 ----------
echo "==> squashfs 根文件系统校验"
if [ -n "$ROOTFS_GZ" ]; then
  ROOTFS_RAW="${ROOTFS_GZ%.gz}"
  case "$ROOTFS_GZ" in
    *.gz) gzip -dkf "$ROOTFS_GZ" ;;
  esac
  if command -v file >/dev/null 2>&1 && file "$ROOTFS_RAW" 2>/dev/null | grep -qi 'squashfs'; then
    echo "    ✓ 检测到 squashfs 文件系统"
  else
    echo "[失败] 未检测到 squashfs 根文件系统"
    FAIL=1
  fi
else
  echo "[失败] 缺少 squashfs-rootfs 镜像，无法确认文件系统格式"
  FAIL=1
fi

# ---------- 4. .config 中根分区大小校验 ----------
echo "==> 根分区大小（.config）校验"
if grep -qE "^CONFIG_TARGET_ROOTFS_PARTSIZE=" "$CONFIG"; then
  CFG_SIZE="$(grep -E '^CONFIG_TARGET_ROOTFS_PARTSIZE=' "$CONFIG" | cut -d= -f2)"
  echo "    .config CONFIG_TARGET_ROOTFS_PARTSIZE=${CFG_SIZE} MB"
  if [ "$CFG_SIZE" -ge "$ROOTFS_PARTSIZE" ] 2>/dev/null; then
    echo "    ✓ 配置达标 (>= ${ROOTFS_PARTSIZE} MB)"
  else
    echo "[失败] 配置未达标：${CFG_SIZE} MB < ${ROOTFS_PARTSIZE} MB"
    FAIL=1
  fi
else
  echo "[失败] 未找到 CONFIG_TARGET_ROOTFS_PARTSIZE，分区大小配置异常"
  FAIL=1
fi

# ---------- 5. 实际分区容量校验（sfdisk 解析，退路用字节数） ----------
echo "==> 实际分区容量校验（combined 镜像）"
COMBINED_RAW="${COMBINED_GZ%.gz}"
gzip -dkf "$COMBINED_GZ"

if command -v sfdisk >/dev/null 2>&1 && python3 -c 'import json' 2>/dev/null; then
  python3 - "$COMBINED_RAW" "$ROOTFS_PARTSIZE" <<'PY'
import sys, subprocess, json
img, need_mb = sys.argv[1], int(sys.argv[2])
try:
    out = subprocess.run(["sfdisk", "-J", img], capture_output=True, text=True)
    data = json.loads(out.stdout)
    pt = data["partitiontable"]
    secsz = int(pt.get("sectorsize", 512))
    # 根文件系统分区通常是容量最大的那个分区
    sizes = [int(p["size"]) * secsz for p in pt.get("partitions", [])]
    if not sizes:
        print("[失败] 未解析到分区"); sys.exit(1)
    max_mb = max(sizes) // (1024 * 1024)
    print(f"    最大分区容量: {max_mb} MB")
    if max_mb >= need_mb:
        print(f"    ✓ 分区容量达标 (>= {need_mb} MB)")
        sys.exit(0)
    else:
        print(f"[失败] 根分区容量 {max_mb} MB < {need_mb} MB")
        sys.exit(1)
except Exception as e:
    print(f"[失败] 分区解析失败: {e}")
    sys.exit(1)
PY
  PART_RC=$?
else
  # 退路：用 raw 镜像字节数粗校验（combined = boot + 根分区）
  RAW_BYTES="$(wc -c < "$COMBINED_RAW")"
  RAW_MB=$(( RAW_BYTES / 1024 / 1024 ))
  echo "    raw 镜像约 ${RAW_MB} MB"
  if [ "$RAW_MB" -ge "$ROOTFS_PARTSIZE" ]; then
    echo "    ✓ 镜像体积达标"; PART_RC=0
  else
    echo "[失败] 镜像体积 ${RAW_MB} MB < ${ROOTFS_PARTSIZE} MB"; PART_RC=1
  fi
fi

# 清理解压出的 raw 大文件，避免占用磁盘与影响打包
rm -f "$COMBINED_RAW" "$ROOTFS_RAW"

if [ "$PART_RC" -ne 0 ]; then FAIL=1; fi

# ---------- 汇总 ----------
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "======================================================"
  echo "[失败] 编译后校验未通过，终止发布。"
  echo "======================================================"
  exit 1
fi

echo ""
echo "==> 编译后校验全部通过 ✔（固件格式 / 分区容量 / 配置均达标）"