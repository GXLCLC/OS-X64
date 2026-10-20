#!/usr/bin/env bash
# ============================================================
# 脚本名称 : 01-customize-settings.sh
# 功能     : 向 LEDE 源码注入固件默认配置
#            （root 密码 / 主机名 / 管理 IP / 时区 / Argon 主题 / 中文界面）
# 原理     : 工作流拉取源码后，将配置块注入 default-settings 的
#            uci-defaults 脚本（exit 0 之前），首次开机自动生效
# 运行位置 : lede 源码根目录（由工作流调用）
# ============================================================
set -euo pipefail

# ---------- 可配置参数（可由工作流环境变量覆盖） ----------
DEFAULT_IP="${DEFAULT_IP:-192.168.2.1}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-12345678}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-LEDE-X86}"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Shanghai}"

# ---------- 目标文件：lean 默认配置脚本 ----------
TARGET_FILE="package/lean/default-settings/files/zzz-default-settings"

if [ ! -f "$TARGET_FILE" ]; then
  echo "ERROR: 未找到 $TARGET_FILE（上游目录结构可能已调整）"
  exit 1
fi

# 备份原始文件，便于回溯
cp "$TARGET_FILE" "${TARGET_FILE}.orig"

# ---------- 生成自定义配置块 ----------
BLOCK_FILE="$(mktemp)"
cat > "$BLOCK_FILE" <<EOF
# ================ CI 注入的自定义默认配置 ================
# ---- 默认登录密码（首次开机生效） ----
(echo "$DEFAULT_PASSWORD"; sleep 1; echo "$DEFAULT_PASSWORD") | passwd root >/dev/null 2>&1

# ---- 主机名 / 时区 ----
uci set system.@system[0].hostname='$DEFAULT_HOSTNAME'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='$DEFAULT_TIMEZONE'
uci commit system

# ---- 管理口默认 IP ----
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$DEFAULT_IP'
uci set network.lan.netmask='255.255.255.0'
uci commit network

# ---- LuCI 中文界面 + Argon 默认主题 ----
uci set luci.main.lang='zh_cn'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
# ================ 自定义默认配置结束 ================
EOF

# ---------- 在首个 exit 0 前插入（uci-defaults 脚本以 exit 0 结尾） ----------
awk -v block="$BLOCK_FILE" '
  /^exit 0$/ && !ins { while ((getline line < block) > 0) print line; close(block); ins=1 }
  { print }
' "${TARGET_FILE}.orig" > "$TARGET_FILE"

rm -f "$BLOCK_FILE"

# ---------- 注入结果校验，失败即终止 ----------
if ! grep -q "CI 注入的自定义默认配置" "$TARGET_FILE"; then
  echo "ERROR: 默认配置注入失败，请检查 zzz-default-settings 文件结构"
  exit 1
fi

echo "[OK] 固件默认配置注入完成：IP=${DEFAULT_IP} 密码=****** 主机名=${DEFAULT_HOSTNAME} 时区=${DEFAULT_TIMEZONE}"
