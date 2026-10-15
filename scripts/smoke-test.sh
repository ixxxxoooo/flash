#!/usr/bin/env bash
# 冒烟测试：
#   1. 内核可执行并能通过 -t 校验最小配置
#   2. 经本地代理端口访问本机服务，控制器 /connections 能观察到连接
#   3. 运行 FlashKit 全部单元与集成测试
# 用法：scripts/smoke-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Resources/Core/mihomo"
[[ -x "$CORE" ]] || "$ROOT/scripts/fetch-core.sh"

WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

MIXED=$((20000 + RANDOM % 10000))
CTL=$((MIXED + 1))
WEB=$((MIXED + 2))
cp "$ROOT"/Resources/Core/*.metadb "$ROOT"/Resources/Core/*.dat "$ROOT"/Resources/Core/*.mmdb "$WORK"/ 2>/dev/null || true

cat > "$WORK/config.yaml" <<EOF
mixed-port: $MIXED
external-controller: 127.0.0.1:$CTL
secret: smoke
find-process-mode: always
mode: rule
rules:
  - MATCH,DIRECT
EOF

echo "[1/3] 校验最小配置"
"$CORE" -t -d "$WORK" -f "$WORK/config.yaml" >/dev/null
echo "  OK"

echo "[2/3] 经代理端口访问并观察连接"
cat > "$WORK/slow.py" <<EOF
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length','50'); self.end_headers()
        try:
            for _ in range(50):
                self.wfile.write(b'x'); self.wfile.flush(); time.sleep(0.1)
        except Exception: pass
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',$WEB),H).serve_forever()
EOF
python3 "$WORK/slow.py" &
"$CORE" -d "$WORK" -f "$WORK/config.yaml" >"$WORK/core.log" 2>&1 &
sleep 2
curl -s -x "http://127.0.0.1:$MIXED" -o /dev/null "http://127.0.0.1:$WEB/slow" &
sleep 1.2
OUT="$(curl -s -H 'Authorization: Bearer smoke' "http://127.0.0.1:$CTL/connections")"
if echo "$OUT" | grep -q "\"destinationPort\":\"$WEB\""; then
  echo "  OK：控制器观察到目标端口 $WEB 的连接"
else
  echo "  失败：未观察到连接"; echo "$OUT"; cat "$WORK/core.log"; exit 1
fi
kill $(jobs -p) 2>/dev/null || true

echo "[3/3] FlashKit 测试"
(cd "$ROOT/Packages/FlashKit" && swift test 2>&1 | rg "error:|Executed .* tests" | tail -3)
echo "冒烟测试通过"
