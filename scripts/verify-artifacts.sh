#!/bin/bash
# =============================================================================
# verify-artifacts.sh —— 编译产物镜像校验（用户规范：编译后校验文件/格式/分区容量，
#                        不达标终止；未生成目标镜像判定失败）
#
# 用法：verify-artifacts.sh [镜像目录] [配置文件]
#   镜像目录 : 默认 ./bin/targets/x86/64
#   配置文件 : 默认仓库 config/X86_64.config（用于交叉核对 PARTSIZE）
#
# 校验项（任一失败即整体失败，非零退出）：
#   1. 目标镜像存在且唯一（combined.img BIOS 版 + combined-efi.img EFI 版）
#   2. 镜像非空且大小合理（根分区 2G 量级）
#   3. 引导结构合法：MBR（0x55AA 签名）或 GPT（EFI PART 头）
#   4. 根分区容量 = CONFIG_TARGET_ROOTFS_PARTSIZE（强制 2G 扩容生效验证，±2% 容差）
#   5. 根分区起始处 squashfs 魔数（hsqs）—— 根文件系统格式正确
#   6. 镜像必装包齐全（委托 scripts/check-packages.sh manifest 模式）
#   7. AdGuardHome 核心二进制确实打包进 squashfs（unsquashfs 深检，工具缺失则跳过）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_DIR="${1:-./bin/targets/x86/64}"
CONFIG_FILE="${2:-${REPO_ROOT}/config/X86_64.config}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[镜像校验]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

FAIL_COUNT=0
fail() {
  local desc="$1" cmd="$2" expect="$3" actual="$4" cause="$5" fix="$6"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  cat >&2 <<EOF
-------------------- 校验失败 ${FAIL_COUNT}: ${desc} --------------------
  检测命令   : ${cmd}
  期望值     : ${expect}
  实际值     : ${actual}
  可能原因   : ${cause}
  建议修复   : ${fix}
EOF
}

[[ -d "${IMAGE_DIR}" ]] || fail "镜像目录不存在" "ls ${IMAGE_DIR}" "存在" "不存在" \
  "编译未产出镜像或目录路径不对" "确认编译流程已执行到镜像生成阶段（make 完成）"

# ---- 期望根分区大小（从配置交叉核对） -----------------------------------------
PARTSIZE_MIB="$(grep -E '^CONFIG_TARGET_ROOTFS_PARTSIZE=' "${CONFIG_FILE}" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
[[ -n "${PARTSIZE_MIB}" ]] || PARTSIZE_MIB=2048
EXPECT_ROOTFS_BYTES=$((PARTSIZE_MIB * 1024 * 1024))
log_info "期望根分区大小：${PARTSIZE_MIB} MiB（来自 ${CONFIG_FILE}）"

# ---- 校验单个镜像（MBR 或 GPT + squashfs 魔数 + 分区容量） -------------------
# 用法：verify_image <img> <boot_kind: mbr|gpt>
verify_image() {
  local img="$1" kind="$2"
  local base; base="$(basename "${img}")"
  log_info "校验镜像：${base}（${kind} 布局）"

  # 2. 非空且大小合理
  local size_bytes; size_bytes="$(stat -c%s "${img}" 2>/dev/null || echo 0)"
  local min_bytes=$((EXPECT_ROOTFS_BYTES * 98 / 100))
  if [[ "${size_bytes}" -lt "${min_bytes}" ]]; then
    fail "${base} 体积异常" "stat -c%s ${img}" "≥ ${min_bytes} 字节（根分区 ${PARTSIZE_MIB} MiB 量级）" \
      "${size_bytes} 字节" "镜像被截断 / 根分区扩容未生效 / 编译中途失败" \
      "检查 CONFIG_TARGET_ROOTFS_PARTSIZE=2048 是否在最终 .config 中生效；重跑编译"
    return 1
  fi
  log_ok "${base} 体积正常：$(awk -v b="${size_bytes}" 'BEGIN{printf "%.2f", b/1048576}') MiB"

  # 3./4./5. 由 python 解析分区表 + 校验 squashfs 魔数
  python3 - "${img}" "${kind}" "${EXPECT_ROOTFS_BYTES}" <<'PYEOF'
import struct, sys

img_path, kind, expect_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
MIB = 1024 * 1024

with open(img_path, 'rb') as f:
    data = f.read(1024 * 1024)  # 前 1 MiB 足够覆盖 MBR/GPT 头与分区项

def mbr_partitions(data):
    if len(data) < 512 or data[510:512] != b'\x55\xaa':
        return None, 'MBR 签名 0x55AA 缺失'
    parts = []
    for i in range(4):
        e = data[0x1BE + i * 16: 0x1BE + (i + 1) * 16]
        ptype = e[4]
        lba = struct.unpack('<I', e[8:12])[0]
        cnt = struct.unpack('<I', e[12:16])[0]
        if ptype and cnt:
            parts.append((i + 1, ptype, lba * 512, cnt * 512))
    return parts, None

def gpt_partitions(data):
    GPT = 512  # GPT 头位于 LBA1（文件偏移 512）
    if data[GPT:GPT + 8] != b'EFI PART':
        return None, 'GPT 头签名 "EFI PART" 缺失'
    # GPT 头字段（相对头起点）：72=分区表起始 LBA(8B)，80=分区项数(4B)，84=单项大小(4B)
    num = struct.unpack('<I', data[GPT + 80:GPT + 84])[0]
    sz = struct.unpack('<I', data[GPT + 84:GPT + 88])[0]
    tbl_lba = struct.unpack('<Q', data[GPT + 72:GPT + 80])[0]
    parts = []
    with open(img_path, 'rb') as f:
        f.seek(tbl_lba * 512)
        for i in range(num):
            e = f.read(sz)
            if len(e) < sz:
                break
            ptype = e[0:16]
            first = struct.unpack('<Q', e[32:40])[0]
            last = struct.unpack('<Q', e[40:48])[0]
            if ptype != b'\x00' * 16 and last >= first:
                parts.append((i + 1, 'gpt', first * 512, (last - first + 1) * 512))
    return parts, None

parts, err = (mbr_partitions(data) if kind == 'mbr' else gpt_partitions(data))
if err:
    print(f'PARTITION_TABLE_ERROR: {err}')
    sys.exit(3)

if not parts:
    print('PARTITION_TABLE_ERROR: 未解析到任何有效分区')
    sys.exit(3)

# 取最大分区判定为根分区（x86 combined：P1 内核分区 64MiB，P2 根分区 PARTSIZE MiB）
parts.sort(key=lambda p: p[3], reverse=True)
pno, ptype, poff, psize = parts[0]
print(f'PARTITIONS: ' + '; '.join(f'P{n}(type={t},offset={o},size={s})' for n, t, o, s in parts))
print(f'ROOTFS_PARTITION: P{pno} offset={poff} size={psize}')

# 4. 根分区容量校验（±2% 容差；真实失效场景为 448MiB 默认值，偏差 -78%）
tol = expect_bytes * 2 // 100
if abs(psize - expect_bytes) > tol:
    print(f'ROOTFS_SIZE_MISMATCH: expect={expect_bytes}({expect_bytes//MIB}MiB) actual={psize}({psize//MIB}MiB)')
    sys.exit(4)

# 5. squashfs 魔数 hsqs（小端 0x73717368）位于根分区起始
with open(img_path, 'rb') as f:
    f.seek(poff)
    magic = f.read(4)
if magic != b'hsqs':
    print(f'SQUASHFS_MAGIC_MISMATCH: at offset {poff}, got {magic!r}, expect b\'hsqs\'')
    sys.exit(5)

print('ROOTFS_OFFSET=' + str(poff))
sys.exit(0)
PYEOF
  local py_rc=$?
  if [[ ${py_rc} -ne 0 ]]; then
    case ${py_rc} in
      3) fail "${base} 分区表解析失败" "python3 解析 ${img}" "合法 ${kind} 分区表" "解析失败" \
           "镜像损坏 / 引导结构异常 / 非预期镜像文件" "确认编译产物为 x86 combined 镜像；重新编译" ;;
      4) fail "${base} 根分区容量不符" "python3 解析 ${img} 分区表" "根分区 = ${PARTSIZE_MIB} MiB（±2%）" "见上方 ROOTFS_SIZE_MISMATCH" \
           "CONFIG_TARGET_ROOTFS_PARTSIZE=2048 未进入最终 .config（用户规范：强制根分区扩容 2G）" \
           "检查工作流拷贝 config/X86_64.config 的步骤与 make defconfig 是否覆盖该值" ;;
      5) fail "${base} 根分区非 squashfs" "python3 读取根分区魔数" "hsqs" "见上方 SQUASHFS_MAGIC_MISMATCH" \
           "根文件系统格式不对（用户规范：仅 squashfs）/ 镜像损坏" \
           "确认 CONFIG_TARGET_ROOTFS_SQUASHFS=y 生效；确认镜像未被其他步骤改写" ;;
      *) fail "${base} 未知校验错误" "python3 解析 ${img}" "退出码 0" "退出码 ${py_rc}" "未知" "查看上方输出" ;;
    esac
    return 1
  fi
  log_ok "${base} 分区表/根分区容量/squashfs 魔数全部通过"
  return 0
}

# =============================================================================
# 主流程
# =============================================================================
log_info "镜像目录：${IMAGE_DIR}"

# 1. 目标镜像存在且唯一
BIOS_IMGS=("${IMAGE_DIR}"/openwrt-x86-64-generic-squashfs-combined.img)
EFI_IMGS=("${IMAGE_DIR}"/openwrt-x86-64-generic-squashfs-combined-efi.img)

if [[ ! -f "${BIOS_IMGS[0]}" ]]; then
  fail "未生成 BIOS 版 combined 镜像" "ls ${IMAGE_DIR}/openwrt-x86-64-generic-squashfs-combined.img" \
    "存在唯一镜像" "不存在（用户规范：未生成目标镜像判定失败）" \
    "编译失败/中断；CONFIG_GRUB_IMAGES 未开启；镜像命名变化" \
    "查看编译日志；确认 config 中 CONFIG_GRUB_IMAGES=y"
fi
if [[ ! -f "${EFI_IMGS[0]}" ]]; then
  fail "未生成 EFI 版 combined 镜像" "ls ${IMAGE_DIR}/openwrt-x86-64-generic-squashfs-combined-efi.img" \
    "存在唯一镜像" "不存在" \
    "编译失败/中断；CONFIG_GRUB_EFI_IMAGES 未开启；镜像命名变化" \
    "查看编译日志；确认 config 中 CONFIG_GRUB_EFI_IMAGES=y"
fi

# 逐个校验（镜像不存在时跳过详细校验，失败计数已记录）
[[ -f "${BIOS_IMGS[0]}" ]] && verify_image "${BIOS_IMGS[0]}" "mbr"
[[ -f "${EFI_IMGS[0]}" ]] && verify_image "${EFI_IMGS[0]}" "gpt"

# 6. 必装包校验（manifest 模式，从镜像目录所在源码树根执行）
if [[ -x "${SCRIPT_DIR}/check-packages.sh" ]]; then
  SRC_ROOT="$(cd "${IMAGE_DIR}/../../.." && pwd)"   # bin/targets/x86/64 -> 源码根
  log_info "委托 check-packages.sh 校验镜像必装包（源码根：${SRC_ROOT}）"
  if ( cd "${SRC_ROOT}" && "${SCRIPT_DIR}/check-packages.sh" manifest "${IMAGE_DIR}"/*.manifest ); then
    :
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  log_warn "check-packages.sh 不可执行，跳过 manifest 校验"
fi

# 7. AdGuardHome 核心二进制深检（squashfs 内 /usr/bin/AdGuardHome）
AGH_IMG="${BIOS_IMGS[0]}"
if [[ -f "${AGH_IMG}" ]] && command -v unsquashfs >/dev/null 2>&1; then
  ROOTFS_OFFSET="$(python3 - "${AGH_IMG}" "mbr" <<'PYEOF' 2>/dev/null | tail -1 | cut -d= -f2
import struct, sys
with open(sys.argv[1], 'rb') as f:
    data = f.read(512)
best = 0
off = 0
for i in range(4):
    e = data[0x1BE + i * 16:0x1BE + (i + 1) * 16]
    cnt = struct.unpack('<I', e[12:16])[0]
    lba = struct.unpack('<I', e[8:12])[0]
    if e[4] and cnt and cnt > best:
        best = cnt
        off = lba
print(off * 512)
PYEOF
)"
  if [[ -n "${ROOTFS_OFFSET}" ]]; then
    if unsquashfs -o "${ROOTFS_OFFSET}" -l "${AGH_IMG}" 2>/dev/null | grep -q "usr/bin/AdGuardHome"; then
      log_ok "AdGuardHome 核心二进制已打包（squashfs 内 /usr/bin/AdGuardHome）"
    else
      fail "AdGuardHome 核心二进制缺失" "unsquashfs -o ${ROOTFS_OFFSET} -l ${AGH_IMG} | grep AdGuardHome" \
        "squashfs 内含 /usr/bin/AdGuardHome" "未找到" \
        "adguardhome 包未正确编译/安装；官方 feed 结构调整" \
        "检查编译日志中 adguardhome 包构建情况；核对 packages feed net/adguardhome"
    fi
  fi
else
  log_warn "unsquashfs 不可用或镜像缺失，跳过 AdGuardHome 二进制深检（manifest 已含 adguardhome 包校验）"
fi

# ---- 汇总 ---------------------------------------------------------------------
echo ""
if [[ ${FAIL_COUNT} -eq 0 ]]; then
  log_info "镜像清单汇总："
  for img in "${IMAGE_DIR}"/openwrt-x86-64-generic-squashfs-combined*.img; do
    [[ -f "${img}" ]] || continue
    printf '  %-60s %10.2f MiB\n' "$(basename "${img}")" \
      "$(awk -v b="$(stat -c%s "${img}")" 'BEGIN{printf "%.2f", b/1048576}')"
  done
  log_ok "全部镜像校验通过（${FAIL_COUNT} 项失败）"
  exit 0
else
  log_error "镜像校验失败：共 ${FAIL_COUNT} 项不达标（用户规范：不达标终止）"
  exit 1
fi
