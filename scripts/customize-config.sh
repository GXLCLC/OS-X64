#!/usr/bin/env bash
# =====================================================================
# 脚本 1：自定义配置（密码 / 主机名 / 后台 IP / 时区 / 主题 / 语言）
# ---------------------------------------------------------------------
# 用途：在工作流拉取 LEDE 源码后，直接替换源代码中的默认配置，
#       把定制逻辑与 workflow 解耦，便于单独维护。
#
# 用法：./customize-config.sh <lede 目录>
#
# 环境变量（由 workflow 传入，均可覆盖）：
#   DEFAULT_IP       默认后台 IP          （默认 192.168.2.1）
#   DEFAULT_PASSWORD 默认登录密码        （默认 12345678）
#   HOSTNAME         主机名              （默认 LEDE）
# =====================================================================
set -euo pipefail

LEDE_DIR="${1:?用法: customize-config.sh <lede 目录>}"
DEFAULT_IP="${DEFAULT_IP:-192.168.2.1}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-12345678}"
HOSTNAME="${HOSTNAME:-LEDE}"
TIMEZONE_STRING="CST-8"          # POSIX TZ，等价于 Asia/Shanghai
TIMEZONE_NAME="Asia/Shanghai"

SHADOW_FILE="$LEDE_DIR/package/base-files/files/etc/shadow"
SYSTEM_FILE="$LEDE_DIR/package/base-files/files/etc/config/system"
CONFIG_GENERATE="$LEDE_DIR/package/base-files/files/bin/config_generate"
DEFAULTS_DIR="$LEDE_DIR/package/base-files/files/etc/uci-defaults"
LEDE_DEFAULT_SETTINGS="$LEDE_DIR/package/lean/default-settings/files/etc/uci-defaults/zzz-default-settings"

[ -d "$LEDE_DIR" ] || { echo "[错误] LEDE 目录不存在: $LEDE_DIR"; exit 1; }

echo "==> [customize] 开始自定义配置"

# ---------------------------------------------------------------------
# 1) 默认密码
# ---------------------------------------------------------------------
echo "==> 设置默认密码（写入 base-files shadow）"
[ -f "$SHADOW_FILE" ] || { echo "[错误] 找不到 shadow 文件: $SHADOW_FILE"; exit 1; }

# 生成兼容 busybox 的 md5crypt 哈希（优先 openssl，失败回退 python3）
PASS_HASH=""
if command -v openssl >/dev/null 2>&1; then
  PASS_HASH="$(openssl passwd -1 "$DEFAULT_PASSWORD" 2>/dev/null || true)"
fi
if [ -z "$PASS_HASH" ] && command -v python3 >/dev/null 2>&1; then
  PASS_HASH="$(python3 - "$DEFAULT_PASSWORD" <<'PY' 2>/dev/null || true
import sys, crypt
print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_MD5)))
PY
)"
fi
[ -n "$PASS_HASH" ] || { echo "[错误] 生成密码哈希失败，请检查 openssl / python3"; exit 1; }

# 替换 root 密码字段（兼容 lean 的 "root:::0:99999..." 等不同 shadow 格式）
sed -i "s|^root:[^:]*:|root:${PASS_HASH}:|" "$SHADOW_FILE"
if grep -Fq "root:${PASS_HASH}:" "$SHADOW_FILE"; then
  echo "    ✓ 密码已写入"
else
  echo "[错误] 密码写入失败"; exit 1
fi

# ---------------------------------------------------------------------
# 2) 后台 IP / 主机名 / 时区（源码级替换）
# ---------------------------------------------------------------------
echo "==> 设置后台 IP（${DEFAULT_IP}）/ 主机名（${HOSTNAME}）/ 时区"

# 2.1 base-files 的 config_generate（首次开机生成 /etc/config/network 与 system）
if [ -f "$CONFIG_GENERATE" ]; then
  # 同时覆盖可能的默认网段 192.168.1.x / 192.168.5.x（lean 默认）
  sed -i "s/192\.168\.1\.1/${DEFAULT_IP}/g" "$CONFIG_GENERATE"
  sed -i "s/192\.168\.5\.1/${DEFAULT_IP}/g" "$CONFIG_GENERATE"
  sed -i "s/hostname='[^']*'/hostname='${HOSTNAME}'/g" "$CONFIG_GENERATE"
  sed -i "s/timezone='[^']*'/timezone='${TIMEZONE_STRING}'/g" "$CONFIG_GENERATE"
  sed -i "s/zonename='[^']*'/zonename='${TIMEZONE_NAME//\//\\/}'/g" "$CONFIG_GENERATE"
  echo "    ✓ config_generate 已更新"
fi

# 2.2 base-files 静态 config/system（部分镜像直接使用此文件）
if [ -f "$SYSTEM_FILE" ]; then
  sed -i "s/option hostname.*/option hostname '${HOSTNAME}'/" "$SYSTEM_FILE"
  sed -i "s/option timezone.*/option timezone '${TIMEZONE_STRING}'/" "$SYSTEM_FILE"
  sed -i "s|option zonename.*|option zonename '${TIMEZONE_NAME}'|" "$SYSTEM_FILE"
  echo "    ✓ config/system 已更新"
fi

# 2.3 lean 专属 default-settings（若存在，须同步覆盖其开机脚本）
if [ -f "$LEDE_DEFAULT_SETTINGS" ]; then
  sed -i "s/192\.168\.1\.1/${DEFAULT_IP}/g" "$LEDE_DEFAULT_SETTINGS"
  sed -i "s/192\.168\.5\.1/${DEFAULT_IP}/g" "$LEDE_DEFAULT_SETTINGS"
  sed -i "s/hostname='[^']*'/hostname='${HOSTNAME}'/g" "$LEDE_DEFAULT_SETTINGS"
  echo "    ✓ lean default-settings 已更新"
fi

# ---------------------------------------------------------------------
# 3) 兜底 uci-defaults（zzz9 前缀保证在 zzz-default-settings 之后执行）
# ---------------------------------------------------------------------
echo "==> 写入兜底 uci-defaults（时区 / 主题 Argon / 语言中文）"
mkdir -p "$DEFAULTS_DIR"
cat > "$DEFAULTS_DIR/zzz9-custom-settings" <<EOF
#!/bin/sh
# 由 customize-config.sh 生成：最终覆盖时区 / 主题 / 语言
uci -q batch <<-UCI
	set system.@system[0].hostname='${HOSTNAME}'
	set network.lan.ipaddr='${DEFAULT_IP}'
	set system.@system[0].timezone='${TIMEZONE_STRING}'
	set system.@system[0].zonename='${TIMEZONE_NAME}'
	set luci.main.mediaurlbase='/luci-static/argon'
	set luci.main.lang='zh_cn'
	commit
UCI
exit 0
EOF
chmod +x "$DEFAULTS_DIR/zzz9-custom-settings"
echo "    ✓ uci-defaults/zzz9-custom-settings 已写入"

echo "==> [customize] 自定义配置完成 ✔"