#!/usr/bin/env bash
# =============================================================================
# Cloud Agent 安装/引导脚本
# 项目：爱普生 L805 ESC/P-R 打印（HarmonyOS NEXT / ArkTS 原生应用）
#
# 背景说明：
#   1. 本仓库是 HarmonyOS NEXT(ArkTS) 原生应用，最终产物是 .hap 安装包。
#      编译 .hap 需要 Huawei DevEco Studio / HarmonyOS SDK（API 24 / 6.1.1），
#      而该 SDK 必须登录 Huawei 开发者账号才能下载，且运行需要 HarmonyOS 真机，
#      因此无法在无头（headless）Linux 的 Cloud Agent 中完成整包编译与真机运行。
#   2. 但仓库自带“纯逻辑自测”脚本 tools/verify/verify.mjs：它把打印驱动里
#      “错一个字节就整页乱码”的核心逻辑（ESC/P-R 命令编码、DEFLATE 解压、
#      ZIP 目录解析、docx/xlsx 提取、RLE 压缩）从 .ets 直接以 Node 类型擦除方式加载，
#      用真实数据做端到端校验（生成 → 再解析回位图逐像素比对）。
#      这一层不依赖任何 @kit.* / HarmonyOS API，可在 Cloud Agent 中真实运行。
#
# 脚本职责：
#   仅保证 Node 版本满足自测脚本要求。脚本幂等、无副作用、可重复执行，
#   不安装任何依赖（verify.mjs 只用 Node 内置模块，仓库无 npm 依赖）。
# =============================================================================
set -euo pipefail

# 校验 Node 版本：verify.mjs 使用 --experimental-strip-types 直接加载 .ts，
# 该特性需要 Node >= 22.6。低于此版本时明确报错并退出，避免后续自测出现误导性失败。
node -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  if (maj < 22 || (maj === 22 && min < 6)) {
    console.error("需要 Node >= 22.6（--experimental-strip-types），当前为 " + process.versions.node);
    process.exit(1);
  }
  console.log("Node " + process.versions.node + " 满足 tools/verify/verify.mjs 的运行要求");
'

echo "环境准备完成：可执行 node --experimental-strip-types tools/verify/verify.mjs 运行核心逻辑自测。"
