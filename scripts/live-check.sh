#!/bin/bash
# 真实模式验收：隔离数据目录启动应用（不改系统代理），经本地代理端口发起请求，
# 检查连接是否被捕获、进程是否被正确识别。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FLASH_APP:-$ROOT/build/Build/Products/Debug/Flash.app}"
HOME_DIR=/tmp/flash-live
PORT_MIXED=6199
WEB_PORT=28765

pkill -x Flash 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Flash >/dev/null || break; sleep 0.2; done
rm -rf "$HOME_DIR"

# 慢速本地服务：持续输出，保证连接在检查时仍然存活
cat > /tmp/flash-slow.py <<'PY'
import http.server, socketserver, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "6000"); self.end_headers()
        try:
            for _ in range(60):
                self.wfile.write(b"x" * 100); self.wfile.flush(); time.sleep(0.5)
        except Exception:
            pass
    def log_message(self, *a): pass
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", 28765), H).serve_forever()
PY
launchctl remove flash.slow 2>/dev/null || true
launchctl submit -l flash.slow -- /usr/bin/python3 /tmp/flash-slow.py
trap 'launchctl remove flash.slow 2>/dev/null || true' EXIT

open -n --env FLASH_HOME="$HOME_DIR" "$APP" --args -mixedPort $PORT_MIXED -autoSystemProxy NO "--section=${1:-traffic}"
for _ in $(seq 1 40); do
  nc -z 127.0.0.1 $PORT_MIXED 2>/dev/null && break
  sleep 0.5
done

curl -s -m 6 -x "http://127.0.0.1:$PORT_MIXED" -o /dev/null "http://127.0.0.1:$WEB_PORT/slow" &
CURL_PID=$!
sleep 2
SECRET="$(awk '/^secret:/{print $2}' "$HOME_DIR/core/runtime.yaml" | tr -d "'\"")"
CPORT="$(awk -F: '/external-controller/{print $3}' "$HOME_DIR/core/runtime.yaml")"
RESULT="$(curl -s -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$CPORT/connections" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for c in d['connections'] or []:
    m = c['metadata']
    print('%s|%s|%s' % (m['process'], m['host'] or m['destinationIP'], m['destinationPort']))
")"
# 可选：LIVE_SHOT=文件路径 时对真实窗口截图
if [ -n "${LIVE_SHOT:-}" ]; then
  [ -x /tmp/flash-winid ] || swiftc -o /tmp/flash-winid "$ROOT/scripts/winid.swift"
  WID="$(/tmp/flash-winid | awk '$2==0 && $3>400 {print $1; exit}')"
  [ -n "$WID" ] && screencapture -x -o -l "$WID" "$LIVE_SHOT"
fi
wait $CURL_PID 2>/dev/null || true
echo "捕获的连接：$RESULT"
if echo "$RESULT" | grep -q '^curl|'; then echo "进程识别：通过"; else echo "进程识别：失败"; exit 1; fi
