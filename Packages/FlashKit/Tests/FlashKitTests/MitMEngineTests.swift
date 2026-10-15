import XCTest
@testable import FlashKit

/// MitM 引擎集成测试：本地 HTTPS 上游 + 引擎（直连上游）+ curl 经 SOCKS5 访问
/// @author ygw
final class MitMEngineTests: XCTestCase {
    var tmp: URL!
    var upstream: Process?
    var server: MitMServer?
    var ca: CertificateAuthority!
    var webPort = 0

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flash-mitm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        ca = CertificateAuthority(directory: tmp.appendingPathComponent("ca"))
        try ca.ensureCA()
    }

    override func tearDown() async throws {
        upstream?.terminate()
        await server?.stop()
        server = nil
        // 清理临时目录（含大文件），避免测试反复运行占满磁盘
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: 工具

    /// 启动本地 HTTPS 上游：GET 返回固定文本并回显 X-Test 请求头；POST 回显请求体；/plain 返回 JSON
    private func startUpstream() throws {
        webPort = PortUtil.freePort()
        let leafPEM = try ca.issueLeafPEM(host: "localhost")
        let certFile = tmp.appendingPathComponent("up.crt")
        let keyFile = tmp.appendingPathComponent("up.key")
        try leafPEM.write(to: certFile, atomically: true, encoding: .utf8)
        try ca.leafKeyPEM.write(to: keyFile, atomically: true, encoding: .utf8)
        let script = """
        import http.server, ssl
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def _send(self, body, ctype='text/plain'):
                self.send_response(200)
                self.send_header('Content-Type', ctype)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('X-Echo', self.headers.get('X-Test', ''))
                self.end_headers()
                self.wfile.write(body)
            def do_GET(self):
                if self.path.startswith('/json'):
                    self._send(b'{"name":"hello","ads":true}', 'application/json')
                elif self.path.startswith('/big'):
                    data = open('\(tmp.path)/big.bin', 'rb').read()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    for i in range(0, len(data), 65536):
                        self.wfile.write(data[i:i+65536])
                elif self.path.startswith('/chunked'):
                    self.send_response(200)
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.end_headers()
                    for part in [b'alpha-', b'beta-', b'gamma' * 1000]:
                        self.wfile.write(('%x\\r\\n' % len(part)).encode() + part + b'\\r\\n')
                    self.wfile.write(b'0\\r\\n\\r\\n')
                elif self.path.startswith('/ws'):
                    self.send_response(101)
                    self.send_header('Upgrade', 'websocket')
                    self.send_header('Connection', 'Upgrade')
                    self.end_headers()
                    self.close_connection = True
                    while True:
                        d = self.connection.recv(4096)
                        if not d: break
                        self.connection.sendall(b'echo:' + d)
                else:
                    self._send(b'hello-from-upstream')
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0))
                self._send(b'echo:' + self.rfile.read(n))
            def log_message(self, *a): pass
        class S(http.server.ThreadingHTTPServer):
            request_queue_size = 256
        srv = S(('127.0.0.1', \(webPort)), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain('\(certFile.path)', '\(keyFile.path)')
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        srv.serve_forever()
        """
        let file = tmp.appendingPathComponent("up.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        upstream = p
        // 等待端口可连
        for _ in 0..<50 {
            if !PortUtil.isAvailable(webPort) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func makeServer(_ text: String) async throws -> MitMServer {
        let profile = SurgeProfileParser.parse(text)
        var config = profile.mitm
        config.skipServerCertVerify = true
        let resources = ResourceCache(directory: tmp.appendingPathComponent("res"))
        let scripts = ScriptEngine(resources: resources, storeURL: tmp.appendingPathComponent("store.json"))
        let s = MitMServer(ca: ca, recorder: HTTPRecorder(), scripts: scripts, config: config)
        _ = try await s.start()
        server = s
        return s
    }

    /// 用 curl 经引擎的 SOCKS5 访问，返回 (退出码, 输出)
    @discardableResult
    private func curl(_ s: MitMServer, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "15", "--socks5-hostname", "127.0.0.1:\(s.port)", "-k"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: 用例

    func testCertificateAuthorityIssuesVerifiableLeaf() throws {
        let leaf = try ca.issueLeafPEM(host: "example.com")
        let leafFile = tmp.appendingPathComponent("leaf.pem")
        try leaf.write(to: leafFile, atomically: true, encoding: .utf8)
        let r = CertificateAuthority.run("/usr/bin/openssl", ["verify", "-CAfile", ca.certificateURL.path, leafFile.path])
        XCTAssertTrue(r.output.contains("OK"), r.output)
        let text = CertificateAuthority.run("/usr/bin/openssl", ["x509", "-in", leafFile.path, "-noout", "-text"]).output
        XCTAssertTrue(text.contains("DNS:example.com"), text)
        // 重新加载应得到同一根证书
        let again = CertificateAuthority(directory: tmp.appendingPathComponent("ca"))
        try again.ensureCA()
        XCTAssertNoThrow(try again.serverContext(for: "a.example.com"))
        XCTAssertNoThrow(try again.serverContext(for: "127.0.0.1"))
    }

    func testInterceptRecordsAndKeepAlive() async throws {
        try startUpstream()
        let s = try await makeServer("[MITM]\nhostname = localhost:\(webPort)")
        // 一条连接上顺序发两个请求（连接复用）+ POST
        let (code, out) = curl(s, ["https://localhost:\(webPort)/a", "https://localhost:\(webPort)/b"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(out, "hello-from-upstreamhello-from-upstream")
        let (_, post) = curl(s, ["-d", "ping=1", "https://localhost:\(webPort)/p"])
        XCTAssertEqual(post, "echo:ping=1")
        try await Task.sleep(nanoseconds: 300_000_000)
        let recs = s.recorder.all()
        XCTAssertGreaterThanOrEqual(recs.count, 3)
        let postRec = try XCTUnwrap(recs.first { $0.method == "POST" })
        XCTAssertEqual(String(decoding: postRec.requestBody, as: UTF8.self), "ping=1")
        XCTAssertEqual(String(decoding: postRec.responseBody, as: UTF8.self), "echo:ping=1")
        XCTAssertEqual(postRec.statusCode, 200)
        XCTAssertTrue(postRec.finished)
    }

    func testUnlistedHostIsTunneledWithoutDecryption() async throws {
        try startUpstream()
        // 主机名不在 MITM 列表：引擎应原样转发，客户端看到的是上游真实证书
        let s = try await makeServer("[MITM]\nhostname = other.example.com")
        let (code, out) = curl(s, ["--cacert", ca.certificateURL.path, "https://localhost:\(webPort)/x"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(out, "hello-from-upstream")
        XCTAssertEqual(s.recorder.count, 0)
    }

    func testURLRewriteRejectAndRedirect() async throws {
        try startUpstream()
        let text = """
        [MITM]
        hostname = localhost:\(webPort)
        [URL Rewrite]
        ^https://localhost:\(webPort)/ads - reject-dict
        ^https://localhost:\(webPort)/old/(.*) https://localhost:\(webPort)/new/$1 302
        """
        let s = try await makeServer(text)
        XCTAssertEqual(curl(s, ["https://localhost:\(webPort)/ads/banner"]).1, "{}")
        let (_, head) = curl(s, ["-i", "https://localhost:\(webPort)/old/page"])
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 302"), head)
        XCTAssertTrue(head.lowercased().contains("location: https://localhost:\(webPort)/new/page"), head)
    }

    func testHeaderRewriteAndMapLocal() async throws {
        try startUpstream()
        let text = """
        [MITM]
        hostname = localhost:\(webPort)
        [Header Rewrite]
        http-request ^https://localhost:\(webPort)/h header-add X-Test injected
        http-response ^https://localhost:\(webPort)/h header-add X-Flash yes
        [Map Local]
        ^https://localhost:\(webPort)/mock data-type=text data="{\\"mock\\":true}" status-code=200 header="X-Mock:1"
        """
        let s = try await makeServer(text)
        let (_, h) = curl(s, ["-i", "https://localhost:\(webPort)/h"])
        XCTAssertTrue(h.lowercased().contains("x-echo: injected"), h)
        XCTAssertTrue(h.lowercased().contains("x-flash: yes"), h)
        let (_, m) = curl(s, ["-i", "https://localhost:\(webPort)/mock"])
        XCTAssertTrue(m.contains("{\"mock\":true}"), m)
        XCTAssertTrue(m.lowercased().contains("x-mock: 1"), m)
        XCTAssertEqual(s.recorder.all().filter { $0.notes.contains("Map Local") }.count, 1)
    }

    func testScriptsModifyRequestAndResponse() async throws {
        try startUpstream()
        let respJS = tmp.appendingPathComponent("resp.js")
        try """
        var obj = JSON.parse($response.body);
        obj.ads = false;
        obj.arg = $argument;
        console.log('响应脚本已执行');
        $done({ body: JSON.stringify(obj) });
        """.write(to: respJS, atomically: true, encoding: .utf8)
        let reqJS = tmp.appendingPathComponent("req.js")
        try """
        var h = $request.headers;
        h['X-Test'] = 'from-script';
        $done({ headers: h });
        """.write(to: reqJS, atomically: true, encoding: .utf8)
        let text = """
        [MITM]
        hostname = localhost:\(webPort)
        [Script]
        resp = type=http-response, pattern=^https://localhost:\(webPort)/json, requires-body=1, script-path=\(respJS.path), argument=ARG1
        req = type=http-request, pattern=^https://localhost:\(webPort)/json, script-path=\(reqJS.path)
        """
        let s = try await makeServer(text)
        let logs = LockedBox<[String]>([])
        s.scripts.logHandler = { _, m in logs.mutate { $0.append(m) } }
        let (_, out) = curl(s, ["-i", "https://localhost:\(webPort)/json"])
        XCTAssertTrue(out.contains("\"ads\":false"), out)
        XCTAssertTrue(out.contains("\"arg\":\"ARG1\""), out)
        XCTAssertTrue(out.lowercased().contains("x-echo: from-script"), out)
        XCTAssertTrue(logs.value.contains { $0.contains("响应脚本已执行") }, "\(logs.value)")
        // Content-Length 必须与新正文一致
        let body = out.components(separatedBy: "\r\n\r\n").last ?? ""
        let lenLine = out.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") } ?? ""
        XCTAssertEqual(Int(lenLine.replacingOccurrences(of: "content-length:", with: "").trimmingCharacters(in: .whitespaces)), body.utf8.count)
    }

    func testScriptTimeoutAndErrorPassThrough() async throws {
        try startUpstream()
        let bad = tmp.appendingPathComponent("bad.js")
        try "throw new Error('boom');".write(to: bad, atomically: true, encoding: .utf8)
        let slow = tmp.appendingPathComponent("slow.js")
        try "// 从不调用 $done".write(to: slow, atomically: true, encoding: .utf8)
        let text = """
        [MITM]
        hostname = localhost:\(webPort)
        [Script]
        bad = type=http-response, pattern=^https://localhost:\(webPort)/bad, requires-body=1, script-path=\(bad.path)
        slow = type=http-response, pattern=^https://localhost:\(webPort)/slow, requires-body=1, timeout=1, script-path=\(slow.path)
        """
        let s = try await makeServer(text)
        XCTAssertEqual(curl(s, ["https://localhost:\(webPort)/bad"]).1, "hello-from-upstream")
        XCTAssertEqual(curl(s, ["https://localhost:\(webPort)/slow"]).1, "hello-from-upstream")
    }

    /// 通过引擎 SOCKS5 + TLS 的 Python 客户端脚本（用于 curl 难以覆盖的场景）
    private func runPythonClient(_ s: MitMServer, _ body: String) throws -> (Int32, String) {
        let script = """
        import socket, ssl, sys, time, threading
        socket.setdefaulttimeout(10)
        SP = \(s.port)
        def conn(host, port):
            s = socket.create_connection(('127.0.0.1', SP))
            s.sendall(b'\\x05\\x01\\x00'); s.recv(2)
            h = host.encode()
            s.sendall(b'\\x05\\x01\\x00\\x03' + bytes([len(h)]) + h + port.to_bytes(2, 'big'))
            r = s.recv(10); assert r[1] == 0, r
            ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            return ctx.wrap_socket(s, server_hostname=host)
        def read_head(c):
            buf = b''
            while b'\\r\\n\\r\\n' not in buf:
                d = c.recv(4096)
                if not d: break
                buf += d
            return buf
        \(body)
        """
        let file = tmp.appendingPathComponent("client-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testWebSocketUpgradeRelaysRawBytes() async throws {
        try startUpstream()
        let s = try await makeServer("[MITM]\nhostname = localhost:\(webPort)")
        let (code, out) = try runPythonClient(s, """
        c = conn('localhost', \(webPort))
        c.sendall(b'GET /ws HTTP/1.1\\r\\nHost: localhost:\(webPort)\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Key: x\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n')
        head = read_head(c)
        assert b'101' in head.split(b'\\r\\n')[0], head
        for msg in [b'ping', b'second-message']:
            c.sendall(msg)
            got = c.recv(4096)
            assert got == b'echo:' + msg, got
        print('WS-OK')
        """)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("WS-OK"), out)
    }

    func testChunkedAndLargeBodyIntegrity() async throws {
        // 8 MB 随机数据，经引擎流式转发后必须与原文件逐字节一致；记录器只保留前 1 MB
        let big = tmp.appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 7) }
        try Data(bytes).write(to: big)
        try startUpstream()
        let s = try await makeServer("[MITM]\nhostname = localhost:\(webPort)")
        let out = tmp.appendingPathComponent("big.out")
        let (code, msg) = curl(s, ["-o", out.path, "https://localhost:\(webPort)/big"])
        XCTAssertEqual(code, 0, msg)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: big.path, andPath: out.path), "大文件内容不一致")
        let (_, chunked) = curl(s, ["https://localhost:\(webPort)/chunked"])
        XCTAssertEqual(chunked, "alpha-beta-" + String(repeating: "gamma", count: 1000))
        try await Task.sleep(nanoseconds: 300_000_000)
        let rec = try XCTUnwrap(s.recorder.all().first { $0.url.hasSuffix("/big") })
        XCTAssertTrue(rec.responseBodyTruncated)
        XCTAssertLessThanOrEqual(rec.responseBody.count, HTTPRecorder.bodyLimit)
    }

    /// 并发性能基线：多线程各发若干次新建连接的 HTTPS 请求，全部成功并输出吞吐
    func testConcurrentPerformanceBaseline() async throws {
        try startUpstream()
        let s = try await makeServer("[MITM]\nhostname = localhost:\(webPort)")
        let (code, out) = try runPythonClient(s, """
        N, T = 30, 8
        errors = []; lat = []
        lock = threading.Lock()
        def worker():
            for _ in range(N):
                t0 = time.time()
                try:
                    c = conn('localhost', \(webPort))
                    c.sendall(b'GET /a HTTP/1.1\\r\\nHost: localhost:\(webPort)\\r\\nConnection: close\\r\\n\\r\\n')
                    data = b''
                    while True:
                        d = c.recv(4096)
                        if not d: break
                        data += d
                    ok = data.endswith(b'hello-from-upstream')
                    with lock:
                        lat.append(time.time() - t0)
                        if not ok: errors.append(data[:80])
                except Exception as e:
                    with lock: errors.append(repr(e))
        t0 = time.time()
        ts = [threading.Thread(target=worker) for _ in range(T)]
        [t.start() for t in ts]; [t.join() for t in ts]
        dt = time.time() - t0
        lat.sort()
        print('PERF requests=%d errors=%d rps=%.1f p50=%.0fms p95=%.0fms' % (len(lat), len(errors), len(lat)/dt, lat[len(lat)//2]*1000, lat[int(len(lat)*0.95)]*1000))
        print('ERRORS', errors[:3])
        sys.exit(1 if errors else 0)
        """)
        print(out)
        XCTAssertEqual(code, 0, out)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThanOrEqual(s.recorder.count, 100)
    }

    func testBodyFormatter() {
        let json = Data(#"{"b":1,"a":[1,2]}"#.utf8)
        let pretty = BodyFormatter.format(json, contentType: "application/json", mode: .auto)
        XCTAssertTrue(pretty.contains("\n"), pretty)
        XCTAssertEqual(BodyFormatter.format(json, contentType: nil, mode: .raw), #"{"b":1,"a":[1,2]}"#)
        let hex = BodyFormatter.format(Data([0x41, 0x42, 0x00, 0xff]), contentType: nil, mode: .hex)
        XCTAssertTrue(hex.hasPrefix("00000000  41 42 00 ff"), hex)
        XCTAssertTrue(hex.hasSuffix("AB.."), hex)
        XCTAssertEqual(BodyFormatter.format(Data(), contentType: nil, mode: .auto), "（空）")
    }

    func testModelParsing() {
        let p = SurgeProfileParser.parse("""
        [MITM]
        hostname = *.example.com, -api.example.com, foo.com:8443
        [URL Rewrite]
        ^http://a\\.com - reject
        ^http://b\\.com https://b.com 307
        [Header Rewrite]
        http-response ^https://x\\.com header-del Set-Cookie
        [Map Local]
        ^https://m\\.com data-type=tiny-gif status-code=200
        [Script]
        s1 = type=http-response, pattern=^https://s\\.com, script-path=https://example.com/s.js, requires-body=true, max-size=0
        """)
        XCTAssertEqual(p.mitm.hostPatterns.count, 3)
        XCTAssertTrue(p.mitm.shouldIntercept(host: "www.example.com", port: 443))
        XCTAssertFalse(p.mitm.shouldIntercept(host: "api.example.com", port: 443))
        XCTAssertFalse(p.mitm.shouldIntercept(host: "example.com", port: 443))
        XCTAssertTrue(p.mitm.shouldIntercept(host: "foo.com", port: 8443))
        XCTAssertFalse(p.mitm.shouldIntercept(host: "foo.com", port: 443))
        XCTAssertEqual(p.mitm.urlRewrites.count, 2)
        XCTAssertEqual(p.mitm.headerRewrites.count, 1)
        XCTAssertEqual(p.mitm.mapLocals.first?.dataType, .tinyGif)
        XCTAssertEqual(p.mitm.scripts.first?.requiresBody, true)
        XCTAssertTrue(p.diagnostics.filter { $0.severity == .warning }.isEmpty, "\(p.diagnostics)")
    }

    func testContentDecoderGzip() throws {
        let src = Data(String(repeating: "flash-", count: 200).utf8)
        let f = tmp.appendingPathComponent("a.txt")
        try src.write(to: f)
        _ = CertificateAuthority.run("/usr/bin/gzip", ["-kf", f.path])
        let gz = try Data(contentsOf: tmp.appendingPathComponent("a.txt.gz"))
        XCTAssertEqual(ContentDecoder.decode(gz, encoding: "gzip"), src)
        XCTAssertEqual(ContentDecoder.decode(src, encoding: nil), src)
    }
}

/// 测试用线程安全盒子
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
