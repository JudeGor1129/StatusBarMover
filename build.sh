#!/usr/bin/env bash
# StatusBarMover 一键打包脚本（在装了 Theos 的机器上运行：macOS / Linux / WSL）
set -e

if [ -z "$THEOS" ]; then
  echo "ERROR: 未设置 \$THEOS，请先安装 Theos：https://theos.dev/docs/installation"
  exit 1
fi

cd "$(dirname "$0")"

echo ">> 清理…"
make clean || true

echo ">> 以 rootless 方式打包（XinaA15 / xina2 必须）…"
make package FINALPACKAGE=1

echo
echo ">> 完成，产物："
ls -1 packages/*.deb
echo
echo "安装方式："
echo "  1) 把 packages/*.deb 传到手机，用 Sileo / Filza 安装"
echo "  2) 或直接：make do THEOS_DEVICE_IP=<手机IP> THEOS_DEVICE_PORT=22"
