#!/usr/bin/env bash
# ============================================================
# 脚本名称 : 02-feeds-and-packages.sh
# 功能     : 1) 配置并安装官方 feeds
#            2) 按需拉取缺失的第三方插件：
#               浅克隆(--depth=1) + 部分克隆(--filter=blob:none)
#               + 稀疏检出(sparse-checkout) 组合策略
#            3) 拉取前强制前置校验：仓库连通性 / 分支存在 /
#               目录完整（含 Makefile 才是有效软件包）
# 运行位置 : lede 源码根目录（由工作流调用）
# ============================================================
set -euo pipefail

EXTRA_DIR="package/extra"      # 第三方插件统一落位目录
SPARSE_CACHE=".sparse-cache"   # 稀疏克隆缓存（同一仓库只克隆一次）
mkdir -p "$EXTRA_DIR" "$SPARSE_CACHE"

# ------------------------------------------------------------
# 第三方插件映射表
# 策略：优先使用 LEDE 内置 / 官方 feed 源码包；
#       仅当本地缺失时，才按候选源顺序稀疏拉取第三方仓库。
#       同一包可配置多个候选源（目录更名 / 仓库搬家时自动回退）。
# ------------------------------------------------------------
declare -A CANDIDATES

add_pkg() { # add_pkg <包名> <仓库URL> <分支> <仓库内目录>（"." 表示整仓库即一个包）
  CANDIDATES["$1"]+="$2|$3|$4 "
}

# ---- kenzok8/small-package（main 分支，openwrt-packages 的补充源） ----
add_pkg smartdns               https://github.com/kenzok8/small-package main smartdns
add_pkg luci-app-smartdns      https://github.com/kenzok8/small-package main luci-app-smartdns
add_pkg ddnsto                 https://github.com/kenzok8/small-package main ddnsto
add_pkg luci-app-ddnsto        https://github.com/kenzok8/small-package main luci-app-ddnsto
add_pkg adguardhome            https://github.com/kenzok8/small-package main adguardhome
add_pkg adguardhome            https://github.com/kenzok8/small-package main AdGuardHome
add_pkg luci-app-adguardhome   https://github.com/kenzok8/small-package main luci-app-adguardhome
add_pkg easytier               https://github.com/kenzok8/small-package main easytier
add_pkg luci-app-easytier      https://github.com/kenzok8/small-package main luci-app-easytier
add_pkg luci-app-wechatpush    https://github.com/kenzok8/small-package main luci-app-wechatpush
add_pkg luci-theme-argon-config https://github.com/kenzok8/small-package main luci-theme-argon-config
add_pkg luci-theme-argon       https://github.com/kenzok8/small-package main luci-theme-argon
add_pkg luci-app-autoreboot    https://github.com/kenzok8/small-package main luci-app-autoreboot

# ---- kenzok8/openwrt-packages（main 分支）备选补充源 ----
add_pkg luci-app-ddnsto        https://github.com/kenzok8/openwrt-packages main luci-app-ddnsto
add_pkg luci-app-smartdns      https://github.com/kenzok8/openwrt-packages main luci-app-smartdns
add_pkg luci-app-wechatpush    https://github.com/kenzok8/openwrt-packages main luci-app-wechatpush
add_pkg luci-app-autoreboot    https://github.com/kenzok8/openwrt-packages main luci-app-autoreboot

# ---- OAF 应用行为管理（含 kmod-oaf 内核模块源码，随本机内核编译） ----
add_pkg oaf                    https://github.com/destan19/OpenAppFilter master oaf
add_pkg luci-app-oaf           https://github.com/destan19/OpenAppFilter master luci-app-oaf

# ---- TurboACC 加速（仓库根目录即包内容） ----
add_pkg luci-app-turboacc      https://github.com/mufeng05/turboacc master .


# ============================================================
# 工具函数
# ============================================================

# 检查包是否已在本地（LEDE 内置 / 官方 feed 已安装 / 已拷贝的 extra）
pkg_available() {
  find package feeds -maxdepth 4 -type d -name "$1" -print -quit 2>/dev/null | grep -q .
}

# 前置校验：仓库连通性 + 分支存在性
precheck_repo() { # precheck_repo <仓库URL> <分支>
  git ls-remote --heads "$1" "refs/heads/$2" 2>/dev/null | grep -q "refs/heads/$2"
}

# 稀疏克隆（带缓存）：
#   --filter=blob:none  部分克隆，按需下载 blob，避免整仓库冗余下载
#   --depth=1           浅克隆，裁剪提交历史
#   --sparse            稀疏检出，仅检出后续 sparse-checkout 指定的目录
sparse_clone() { # sparse_clone <仓库URL> <分支> <目录("."=整仓库)> ; 输出缓存目录
  local repo="$1" branch="$2" dir="$3" name cache
  name="$(echo "$repo" | sed -E 's#https?://[^/]+/##; s#\.git$##; s#/#_#g')"
  cache="$SPARSE_CACHE/$name"
  if [ ! -d "$cache/.git" ]; then
    echo "  [克隆] $repo ($branch) --filter=blob:none --depth=1"
    if [ "$dir" = "." ]; then
      git clone --filter=blob:none --depth=1 -b "$branch" "$repo" "$cache" >&2
    else
      git clone --filter=blob:none --sparse --depth=1 -b "$branch" "$repo" "$cache" >&2
    fi
  fi
  echo "$cache"
}

# ============================================================
# 1. 官方 feeds 配置
#    lede 默认 feeds.conf.default 已内置 kenzok8 两个第三方源；
#    为避免 feeds update 全量克隆第三方仓库造成冗余下载，
#    此处注释这两行，统一改由下方稀疏检出策略按需拉取。
# ============================================================
if grep -q "kenzok8" feeds.conf.default 2>/dev/null; then
  sed -i -E 's@^(src-git.*kenzok8.*)@# \1  # 已改用稀疏检出策略按需拉取@' feeds.conf.default
  echo "[OK] kenzok8 第三方源已从默认 feeds 注释（改用稀疏检出）"
fi

# ============================================================
# 2. 更新并安装官方 feeds（packages / luci / routing / telephony）
# ============================================================
echo "===== 更新并安装官方 feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a

# ============================================================
# 3. 按需稀疏拉取缺失的第三方插件（优先官方源）
# ============================================================
echo "===== 第三方插件按需拉取 ====="
PULLED=()
FAILED_PKG=""

for pkg in "${!CANDIDATES[@]}"; do
  # 优先官方：本地（lede 内置 / 官方 feed）已有则直接跳过
  if pkg_available "$pkg"; then
    echo "[跳过] $pkg（官方/内置源已提供）"
    continue
  fi

  pulled=0
  for cand in ${CANDIDATES["$pkg"]}; do
    IFS='|' read -r repo branch dir <<< "$cand"
    # 前置校验 1：仓库连通性 + 分支存在
    if ! precheck_repo "$repo" "$branch"; then
      echo "  [警告] $repo 分支 $branch 不可达，尝试下一候选源"
      continue
    fi
    cache="$(sparse_clone "$repo" "$branch" "$dir")"
    # 根目录即包的仓库（如 turboacc）：整仓库拷贝并剔除 git 元数据
    if [ "$dir" = "." ]; then
      mkdir -p "$EXTRA_DIR/$pkg"
      cp -a "$cache/." "$EXTRA_DIR/$pkg/"
      rm -rf "$EXTRA_DIR/$pkg/.git" "$EXTRA_DIR/$pkg/.github"
      pulled=1; break
    fi
    # 稀疏检出目标目录
    git -C "$cache" sparse-checkout set "$dir" >&2
    # 前置校验 2：目录完整性（必须包含 Makefile 才是有效软件包）
    if [ ! -f "$cache/$dir/Makefile" ]; then
      echo "  [警告] $repo 中不存在有效包目录: $dir，尝试下一候选源"
      continue
    fi
    cp -a "$cache/$dir" "$EXTRA_DIR/$pkg"
    pulled=1; break
  done

  if [ "$pulled" -eq 1 ]; then
    PULLED+=("$pkg")
    echo "[拉取] $pkg"
  else
    FAILED_PKG="$FAILED_PKG $pkg"
  fi
done

# ============================================================
# 4. 结果汇总：任一插件拉取失败 -> 直接终止并输出修复建议
# ============================================================
if [ -n "$FAILED_PKG" ]; then
  {
    echo "ERROR: 以下第三方插件拉取失败:$FAILED_PKG"
    echo "修复建议："
    echo "  1. 检查仓库连通性：git ls-remote <仓库URL>"
    echo "  2. 确认上游分支是否更名（main / master 互换）"
    echo "  3. 确认仓库内包目录是否更名或移动"
    echo "  4. 手动修正 scripts/02-feeds-and-packages.sh 映射表后重新触发工作流"
  } >&2
  exit 1
fi

echo "===== 第三方插件拉取完成 ====="
if [ "${#PULLED[@]}" -gt 0 ]; then
  printf '本次稀疏拉取清单：\n - %s\n' "${PULLED[@]}"
else
  echo "全部插件均由官方/内置源提供，无需拉取第三方仓库"
fi
echo "package/extra 目录内容："
ls -1 "$EXTRA_DIR" 2>/dev/null || echo "（空）"
