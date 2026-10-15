#!/bin/bash
# 以演示模式启动应用并对指定页面截图：scripts/shot.sh <section> [输出文件] [额外启动参数...]
# section: dashboard traffic stats policies subscriptions profile rules logs settings
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FLASH_APP:-$ROOT/build/Build/Products/Debug/Flash.app}"
SECTION="${1:-dashboard}"
OUT="${2:-$ROOT/dist/shots/$SECTION.png}"
shift 2 2>/dev/null || true
mkdir -p "$(dirname "$OUT")"

pkill -x Flash 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Flash >/dev/null || break; sleep 0.2; done
sleep 0.8
# FLASH_DARK=1 时使用深色外观
EXTRA=()
[ "${FLASH_DARK:-0}" = "1" ] && EXTRA+=(--dark)
open "$APP" --args --demo "--section=$SECTION" ${EXTRA[@]+"${EXTRA[@]}"} "$@"

# 查找窗口号（最多等待 12 秒）；辅助程序按需编译
[ -x /tmp/flash-winid ] || swiftc -o /tmp/flash-winid "$ROOT/scripts/winid.swift"
WID=""
for i in $(seq 1 24); do
  sleep 0.5
  # 偶发启动后未创建窗口时，发送一次“重新打开”事件
  [ "$i" = "8" ] && ! /tmp/flash-winid | grep -q . && open "$APP" || true
  WID="$(/tmp/flash-winid | awk '$2==0 && $3>400 {print $1; exit}')"
  [ -n "$WID" ] && break
done
[ -n "$WID" ] || { echo "未找到 Flash 窗口"; exit 1; }
sleep 2.5
screencapture -x -o -l "$WID" "$OUT"
echo "已保存 $OUT"
