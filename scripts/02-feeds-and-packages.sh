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

EXTRA_DIR="package/extra"
TMP_CLONE=".tmp-clone"
mkdir -p "$EXTRA_DIR"
rm -rf "$TMP_CLONE"

# ------------------------------------------------------------
# 第三方插件映射表
# 策略：优先使用 LEDE 内置 / 官方 feed 源码包；
#       仅当本地缺失时，才按候选源顺序稀疏拉取第三方仓库。
# ------------------------------------------------------------
declare -A CANDIDATES

add_pkg() { # add_pkg <包名> <仓库URL> <分支> <仓库内目录>（"." 表示整仓库即一个包）
  CANDIDATES["$1"]+="$2|$3|$4 "
}

# ---- kenzok8/small-package（main 分支） ----
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
# ✅修复argon包名
add_pkg luci-app-argon-config https://github.com/kenzok8/small-package main luci-app-argon-config
add_pkg luci-theme-argon       https://github.com/kenzok8/small-package main luci-theme-argon
add_pkg luci-app-autoreboot    https://github.com/kenzok8/small-package main luci-app-autoreboot

# ---- kenzok8/openwrt-packages 备选源 ----
add_pkg luci-app-ddnsto        https://github.com/kenzok8/openwrt-packages main luci-app-ddnsto
add_pkg luci-app-smartdns      https://github.com/kenzok8/openwrt-packages main luci-app-smartdns
add_pkg luci-app-wechatpush    https://github.com/kenzok8/openwrt-packages main luci-app-wechatpush
add_pkg luci-app-autoreboot    https://github.com/kenzok8/openwrt-packages main luci-app-autoreboot

# ---- OAF ----
add_pkg oaf                    https://github.com/destan19/OpenAppFilter master oaf
add_pkg luci-app-oaf           https://github.com/destan19/OpenAppFilter master luci-app-oaf

# ---- TurboACC ----
add_pkg luci-app-turboacc      https://github.com/mufeng05/turboacc master .


# ============================================================
# 工具函数
# ============================================================
pkg_available() {
  find package feeds -maxdepth 4 -type d -name "$1" -print -quit 2>/dev/null | grep -q .
}

precheck_repo() {
  git ls-remote --heads "$1" "refs/heads/$2" 2>/dev/null | grep -q "refs/heads/$2"
}

# ============================================================
# 1. feeds 处理
# ============================================================
if grep -q "kenzok8" feeds.conf.default 2>/dev/null; then
  sed -i -E 's@^(src-git.*kenzok8.*)@# \1  # 已改用稀疏检出策略按需拉取@' feeds.conf.default
  echo "[OK] kenzok8源注释完成"
fi

echo "===== 更新并安装官方 feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a

# ============================================================
# 2. 拉取插件主逻辑
# ============================================================
echo "===== 第三方插件按需拉取 ====="
PULLED=()
FAILED_PKG=""

for pkg in "${!CANDIDATES[@]}"; do
  if pkg_available "$pkg"; then
    echo "[跳过] $pkg（官方/内置源已提供）"
    continue
  fi

  pulled=0
  for cand in ${CANDIDATES["$pkg"]}; do
    IFS='|' read -r repo branch dir <<< "$cand"
    if ! precheck_repo "$repo" "$branch"; then
      echo "  [警告] $repo 分支 $branch 不可达，尝试下一候选源" >&2
      continue
    fi

    # 每次拉取新建独立临时目录，用完删除，规避sparse --add兼容问题
    rm -rf "$TMP_CLONE"
    mkdir -p "$TMP_CLONE"
    if [ "$dir" = "." ]; then
      git clone --filter=blob:none --depth=1 -b "$branch" "$repo" "$TMP_CLONE" >&2
      mkdir -p "$EXTRA_DIR/$pkg"
      cp -a "$TMP_CLONE/." "$EXTRA_DIR/$pkg/"
      rm -rf "$EXTRA_DIR/$pkg/.git" "$EXTRA_DIR/$pkg/.github"
      pulled=1; break
    else
      git clone --filter=blob:none --sparse --depth=1 -b "$branch" "$repo" "$TMP_CLONE" >&2
      git -C "$TMP_CLONE" sparse-checkout init --cone >&2
      git -C "$TMP_CLONE" sparse-checkout set "$dir" >&2
      # 校验Makefile
       if [ ! -f "$TMP_CLONE/$dir/Makefile" ]; then
         echo "  [警告] $repo 中不存在有效包目录: $dir，尝试下一候选源" >&2
         continue
       fi
       cp -a "$TMP_CLONE/$dir" "$EXTRA_DIR/$pkg"
       pulled=1; break
     fi
   done
   if [ "$pulled" -eq 1 ]; then
     PULLED+=("$pkg")
     echo "[拉取] $pkg"
   else
     FAILED_PKG="$FAILED_PKG $pkg"
   fi
 done
 rm -rf "$TMP_CLONE"
 # ============================================================
 # 3. 结果汇总
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