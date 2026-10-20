#!/bin/bash
# =============================================================================
# personalize.sh —— LEDE-X64 固件个性化（默认 IP / 密码 / 主机名 / 主题 / 防火墙）
#
# 用户规范：无人值守；独立脚本负责改密码/主机名等；拉取源码后直接替换源代码
#           密码配置文件；默认 IP 192.168.2.1、密码 12345678。
#
# 双重保障设计：
#   A. 生成 files/etc/uci-defaults/zzz-lede-x64-defaults（首次启动兜底脚本）。
#      命名必须为 zzz-lede-x64-defaults：uci-defaults 按字母序执行，
#      LEDE 官方 zzz-default-settings（package/lean/default-settings）会先运行
#      写入官方默认密码哈希，本脚本随后运行才能覆盖成功。
#   B. 直接替换 LEDE 源码中的密码配置文件
#      package/lean/default-settings/files/zzz-default-settings，
#      把官方默认密码哈希改写为本次构建的密码哈希（用户规范「拉取源码后
#      直接替换源代码密码配置文件」）。
#
# 用法：personalize.sh [LEDE_DIR] [LAN_IP] [ROOT_PASSWORD] [HOSTNAME]
#   环境变量等价：LEDE_DIR / LAN_IP / ROOT_PASSWORD / HOSTNAME
# =============================================================================
set -euo pipefail

LEDE_DIR="${1:-${LEDE_DIR:-$(pwd)}}"
LAN_IP="${2:-${LAN_IP:-192.168.2.1}}"
ROOT_PASSWORD="${3:-${ROOT_PASSWORD:-12345678}}"
HOSTNAME="${4:-${HOSTNAME:-LEDE-X64}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[个性化]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ 警告 ]${NC} $*"; }
log_error() { echo -e "${RED}[ 错误 ]${NC} $*" >&2; }

# ---- 前置检查 ---------------------------------------------------------------
[[ -d "${LEDE_DIR}/package" ]] || { log_error "LEDE 源码树不存在：${LEDE_DIR}"; exit 1; }
cd "${LEDE_DIR}"

OUT_DIR="${LEDE_DIR}/files/etc/uci-defaults"
OUT_FILE="${OUT_DIR}/zzz-lede-x64-defaults"

# ---- 1. 生成密码哈希（MD5-crypt，与 LEDE 官方 zzz-default-settings 同格式） --
PASSWORD_HASH=""
if command -v openssl >/dev/null 2>&1; then
  PASSWORD_HASH="$(openssl passwd -1 -salt "Led3x64p" "${ROOT_PASSWORD}")"
fi
if [[ -z "${PASSWORD_HASH}" ]]; then
  # openssl 不可用时的兜底（12345678 + salt Led3x64p 的预计算值）
  PASSWORD_HASH='$1$Led3x64p$SgNpe1MoKk3WD7VN3NYpK.'
  log_warn "openssl 不可用，使用预计算密码哈希（仅适用于默认密码 12345678）"
fi
log_info "root 密码哈希已生成（MD5-crypt，salt=Led3x64p）"

# ---- 2. 生成首次启动兜底脚本 zzz-lede-x64-defaults ---------------------------
mkdir -p "${OUT_DIR}"
cat > "${OUT_FILE}" <<UCI
#!/bin/sh
# =============================================================================
# LEDE-X64 云编译首次启动默认值（二次兜底，幂等）
# 运行时机：首启 uci-defaults 阶段，位于 LEDE 官方 zzz-default-settings 之后，
#           因此可覆盖官方默认密码 / 时区 / distfeeds 等设置。
# =============================================================================
# 1. 时区（与官方 zzz-default-settings 一致，兜底再写一次）
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
# 2. 主机名
uci -q set system.@system[0].hostname='${HOSTNAME}'
uci -q commit system

# 3. LAN 默认地址 192.168.2.1
uci -q set network.lan.ipaddr='${LAN_IP}'
uci -q commit network

# 4. AdGuardHome 开机自启兜底：
#    LEDE 官方 packages feed 提供 adguardhome（含核心二进制 /usr/bin/AdGuardHome）
#    与 luci-app-adguardhome；init 脚本读取 UCI 段 adguardhome.config，
#    enabled=1 时经 procd 拉起。这里兜底写入 enabled=1。
if uci -q get adguardhome.config >/dev/null 2>&1; then
  uci -q set adguardhome.config.enabled='1'
  uci -q commit adguardhome
fi

# 5. dnsmasq DNS 端口基准值 53：
#    dnsmasq 与 AGH 的 DNS 端口分工为 dnsmasq 53 / AGH 5553，
#    luci-app-adguardhome 的端口判断依赖 dhcp.@dnsmasq[0].port 有值可读。
if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
  uci -q set dhcp.@dnsmasq[0].port='53'
  uci -q commit dhcp
fi

# 6. 防火墙默认值：软件流量卸载开、硬件卸载关、全锥形 NAT 开：
#    X86_64 平台无硬件 NAT 引擎，硬件流量卸载（flow_offloading_hw）无效；
#    fw4 上游默认两开关均为 0，这里显式写为软件卸载开、硬件卸载关。
#    全锥形 NAT（fullcone）由 TurboAcc 提供，kmod-nft-fullcone 已随固件打包。
#    注意：TurboAcc 的 init 脚本开机时会把 flow_offloading_hw 写回其配置值
#    （默认 1），故必须在此兜底脚本里再次强制写回 0。
if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
  uci -q set firewall.@defaults[0].flow_offloading='1'
  uci -q set firewall.@defaults[0].flow_offloading_hw='0'
  uci -q set firewall.@defaults[0].fullcone='1'
  uci -q commit firewall
fi

# 7. Argon 主题设为默认 + 登录界面展示 Bing 每日图片：
#    LuCI 默认主题由 luci.main.mediaurlbase 决定（luci-base ucode/runtime.uc
#    第 157 行优先读取该值），出厂默认为 /luci-static/bootstrap，
#    这里显式写为 /luci-static/argon（用户规范：默认主题 Argon）。
#    luci-theme-argon 自带 /etc/config/argon 默认 online_wallpaper='none'，
#    会覆盖 luci-app-argon-config 的 'bing'，这里显式写回 'bing'。
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
if uci -q get argon.@global[0] >/dev/null 2>&1; then
  uci -q set argon.@global[0].online_wallpaper='bing'
  uci -q commit argon
fi

# 8. opkg 软件源列表兜底：
#    正常流程由 base-files 在镜像打包时写入 /etc/opkg/distfeeds.conf；
#    若该文件缺失或为空，「软件包 - 更新列表」会失败。这里按 LEDE 官方源
#    结构（腾讯云 LEDE 镜像）重建，保证首次开机即可更新列表。
if [ ! -s /etc/opkg/distfeeds.conf ]; then
  mkdir -p /etc/opkg
  cat > /etc/opkg/distfeeds.conf <<'FEEDS'
src/gz lede_core https://mirrors.tencent.com/lede/snapshots/targets/x86/64/packages
src/gz lede_base https://mirrors.tencent.com/lede/snapshots/packages/x86_64/base
src/gz lede_luci https://mirrors.tencent.com/lede/snapshots/packages/x86_64/luci
src/gz lede_packages https://mirrors.tencent.com/lede/snapshots/packages/x86_64/packages
src/gz lede_routing https://mirrors.tencent.com/lede/snapshots/packages/x86_64/routing
src/gz lede_telephony https://mirrors.tencent.com/lede/snapshots/packages/x86_64/telephony
FEEDS
fi

# 9. mwan3：清空接口 / 成员 / 策略，仅保留默认规则（待用户自行配置）
if uci -q get mwan3.globals >/dev/null 2>&1; then
  for s in \$(uci -q show mwan3 | sed -n "s/^mwan3\.\([^.=]*\)=interface\$/\\1/p"); do
    uci -q delete "mwan3.\$s"
  done
  for s in \$(uci -q show mwan3 | sed -n "s/^mwan3\.\([^.=]*\)=member\$/\\1/p"); do
    uci -q delete "mwan3.\$s"
  done
  for s in \$(uci -q show mwan3 | sed -n "s/^mwan3\.\([^.=]*\)=policy\$/\\1/p"); do
    uci -q delete "mwan3.\$s"
  done
  uci -q commit mwan3
fi

# 10. root 默认密码：直接改写 /etc/shadow 的哈希字段（确定性 MD5-crypt）。
#     LEDE 官方 zzz-default-settings 先运行写入官方哈希，这里覆盖为本次密码。
sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" /etc/shadow
if ! grep -q "^root:${PASSWORD_HASH}:" /etc/shadow; then
  # sed 改写失败时用 chpasswd 兜底
  echo 'root:${ROOT_PASSWORD}' | chpasswd 2>/dev/null || \
    printf '%s\n%s\n' '${ROOT_PASSWORD}' '${ROOT_PASSWORD}' | passwd root >/dev/null 2>&1
fi

# 11. 清理 LuCI 缓存，自删本脚本（uci-defaults 约定）
rm -rf /tmp/luci-modulecache/ 2>/dev/null
rm -f /tmp/luci-indexcache 2>/dev/null
rm -f /etc/uci-defaults/zzz-lede-x64-defaults

exit 0
UCI

chmod 0755 "${OUT_FILE}"
log_ok "已生成 ${OUT_FILE}"

# ---- 3. 直接替换 LEDE 源码中的密码配置文件 ------------------------------------
# 用户规范：拉取源码后直接替换源代码密码配置文件。
# LEDE 官方默认密码哈希 $1$V4UetPzk$CYXluq4wUazHjmCDBCqXF. 写入于
# package/lean/default-settings/files/zzz-default-settings，替换为本次哈希。
LEDE_DEFAULT_SETTINGS="package/lean/default-settings/files/zzz-default-settings"
if [[ -f "${LEDE_DEFAULT_SETTINGS}" ]]; then
  if grep -qF '$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.' "${LEDE_DEFAULT_SETTINGS}"; then
    sed -i "s|\$1\$V4UetPzk\$CYXluq4wUazHjmCDBCqXF\.|${PASSWORD_HASH}|g" "${LEDE_DEFAULT_SETTINGS}"
    log_ok "已替换 ${LEDE_DEFAULT_SETTINGS} 中的官方默认密码哈希"
  else
    log_warn "${LEDE_DEFAULT_SETTINGS} 中未找到官方默认密码哈希（上游可能已调整），跳过源码级替换（首启兜底脚本仍会生效）"
  fi
else
  log_warn "${LEDE_DEFAULT_SETTINGS} 不存在（LEDE 源码结构可能变化），跳过源码级替换（首启兜底脚本仍会生效）"
fi

# ---- 4. 语法与内容自检 --------------------------------------------------------
if [[ ! -s "${OUT_FILE}" ]]; then
  log_error "uci-defaults 脚本生成失败或为空：${OUT_FILE}"; exit 1
fi
if ! head -1 "${OUT_FILE}" | grep -q '^#!/bin/sh'; then
  log_error "uci-defaults 脚本缺少 shebang"; exit 1
fi
if ! sh -n "${OUT_FILE}"; then
  log_error "uci-defaults 脚本语法校验失败：${OUT_FILE}"; exit 1
fi
# 关键定制项落位复核（防止 heredoc 内容被意外改动）
for check in "timezone='CST-8'" "zonename='Asia/Shanghai'" \
  "hostname='${HOSTNAME}'" "ipaddr='${LAN_IP}'" \
  "adguardhome.config.enabled='1'" \
  "dhcp.@dnsmasq[0].port='53'" \
  "flow_offloading='1'" "flow_offloading_hw='0'" \
  "fullcone='1'" "mediaurlbase='/luci-static/argon'" \
  "online_wallpaper='bing'" \
  "src/gz lede_core" "mwan3" "${PASSWORD_HASH}"; do
  if ! grep -qF "${check}" "${OUT_FILE}"; then
    log_error "uci-defaults 脚本缺少关键定制项：${check}"; exit 1
  fi
done

echo ""
echo "个性化配置完成："
echo "  默认 LAN IP : ${LAN_IP}"
echo "  root 密码   : 已按入参设置（哈希 ${PASSWORD_HASH}，明文不打印以防日志泄露）"
echo "  主机名      : ${HOSTNAME}"
echo "  兜底脚本    : files/etc/uci-defaults/zzz-lede-x64-defaults"
find "${OUT_DIR}" -type f -printf '  %p (%s 字节)\n' | sort
