# LEDE X86_64 全自动编译仓库

基于 **Ubuntu 24.04 LTS + GitHub Actions** 自动编译 lean 大雕 [LEDE](https://github.com/coolsnowwolf/lede)
（master 分支）的 X86_64 squashfs 固件，全程无人值守。

## 使用方法
1. Fork 本仓库 → **Actions** 页面选择「LEDE X86_64 固件编译」→ **Run workflow** 手动触发；
2. 首次编译约 4~6 小时（含工具链），二次编译命中 toolchain/DL 缓存后大幅提速；
3. 编译成功自动创建 Release，固件命名为 `时间戳_LEDE_x86_64_generic.img.gz`；
4. 编译失败仅上传 `ERROR-logs` 产物（缺失依赖 / 路径错误 / 分支异常 / 模块冲突定位信息）。

## 自定义
- **增删插件**：编辑 `config/X86_64.config`；
- **修改默认密码 / IP / 主机名**：调整工作流 `env` 中的 `DEFAULT_PASSWORD` 等变量；
- **第三方源映射**：编辑 `scripts/02-feeds-and-packages.sh` 的映射表。

## 默认信息
- 管理 IP：192.168.2.1 ｜ 密码：12345678 ｜ 主题：Argon ｜ 时区：Asia/Shanghai
- 根分区已扩容 2G（默认 104MB + 2048MB = 2152MB）

> ⚠️ 固件仅供个人学习研究，请遵守当地法律法规使用。
