#!/usr/bin/env bash
# 拉取并校验 mihomo 内核与 geo 数据，输出到 Resources/Core
# 用法：scripts/fetch-core.sh [--force]
set -euo pipefail

# 固定版本，保证可复现
MIHOMO_VERSION="v1.19.32"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/Core"
mkdir -p "$OUT"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PLAT="darwin-arm64" ;;
  x86_64) PLAT="darwin-amd64" ;;
  *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
esac

BIN="$OUT/mihomo"
if [[ $FORCE -eq 1 || ! -x "$BIN" ]]; then
  URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-${PLAT}-${MIHOMO_VERSION}.gz"
  echo "下载内核: $URL"
  curl -fL --retry 3 -o "$OUT/mihomo.gz" "$URL"
  gunzip -f "$OUT/mihomo.gz"
  chmod +x "$BIN"
  # 去掉隔离属性，避免 Gatekeeper 阻止子进程启动
  xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
fi

# geo 数据（避免首次启动联网下载失败）
GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
for f in geoip.metadb geosite.dat country.mmdb; do
  if [[ $FORCE -eq 1 || ! -s "$OUT/$f" ]]; then
    echo "下载 geo 数据: $f"
    curl -fL --retry 3 -o "$OUT/$f" "$GEO_BASE/$f" || echo "警告: $f 下载失败，运行时将由内核自行下载"
  fi
done

echo "$MIHOMO_VERSION" > "$OUT/VERSION"
echo "内核版本: $("$BIN" -v | head -1)"
echo "sha256: $(shasum -a 256 "$BIN" | awk '{print $1}')"
