import XCTest
@testable import FlashKit

/// 集成测试：真实启动 mihomo，经由本地代理端口发请求，验证控制器能观察到连接
@MainActor
final class CoreIntegrationTests: XCTestCase {
    var server: Process?

    override func tearDown() async throws {
        server?.terminate()
        server = nil
    }

    /// 启动一个慢速 HTTP 服务（每 0.1 秒吐 1 字节，共 10 秒），保证连接存活足够久
    private func startSlowServer(port: Int) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-www-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        import http.server, time
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', '100')
                self.end_headers()
                try:
                    for _ in range(100):
                        self.wfile.write(b'x'); self.wfile.flush(); time.sleep(0.1)
                except Exception:
                    pass
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', \(port)), H).serve_forever()
        """
        let file = dir.appendingPathComponent("slow.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
    }

    func testCoreLifecycleAndConnections() async throws {
        try XCTSkipIf(TestSupport.coreBinary == nil, "未找到内核，跳过")
        _ = TestSupport.isolateHome()

        let mixed = PortUtil.freePort()
        let ctl = PortUtil.freePort()
        let secret = "test-secret"
        let composed = ProfileComposer.compose(base: SurgeProfileParser.parse(DefaultProfile.text), overlay: nil, subscriptions: [])
        let yaml = try ConfigGenerator.yaml(profile: composed, options: RuntimeOptions(mixedPort: mixed, controllerPort: ctl, secret: secret))

        let core = CoreManager()
        await core.start(yaml: yaml, controllerPort: ctl, secret: secret)
        guard case .running(let version) = core.status else { return XCTFail("内核未启动: \(core.status) \(core.recentOutput)") }
        XCTAssertTrue(version.contains("v1"), "版本: \(version)")
        let client = try XCTUnwrap(core.client)

        // 基本接口
        let cfg = try await client.configs()
        XCTAssertEqual(cfg.mixedPort, mixed)
        XCTAssertEqual(cfg.mode, "rule")
        try await client.setMode("global")
        let changed = try await client.configs()
        XCTAssertEqual(changed.mode, "global")
        try await client.setMode("rule")
        let policies = try await client.policies()
        XCTAssertNotNil(policies["Proxy"])
        XCTAssertNotNil(policies["DIRECT"])
        let rules = try await client.rules()
        XCTAssertEqual(rules.last?.type.lowercased(), "match")

        // 经本地代理访问本机 HTTP 服务；用连接流捕获活动连接
        let webPort = PortUtil.freePort()
        try startSlowServer(port: webPort)
        try await Task.sleep(nanoseconds: 800_000_000)

        let stream = client.connectionsStream(interval: 200)
        // 用 curl 经本地代理访问慢速服务
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-x", "http://127.0.0.1:\(mixed)", "-o", "/dev/null",
                          "http://127.0.0.1:\(webPort)/slow"]
        try curl.run()
        defer { curl.terminate() }

        var tracker = ConnectionTracker()
        var sawConnection = false
        var record: ConnectionRecord?
        let deadline = Date().addingTimeInterval(8)
        for await snap in stream {
            _ = tracker.apply(snap)
            if let rec = tracker.active.values.first(where: { $0.host == "127.0.0.1" && $0.destinationPort == String(webPort) }) {
                sawConnection = true
                record = rec
                if !rec.process.isEmpty { break }
            }
            if Date() > deadline { break }
        }
        // 内核由 launchd 托管，进程识别必须可用
        XCTAssertEqual(record?.process, "curl", "内核没有识别出发起连接的进程")
        XCTAssertEqual(record?.policy, "DIRECT")
        XCTAssertTrue(sawConnection, "控制器没有观察到经过代理的连接")

        // 停止后控制器不再可达
        await core.stop()
        XCTAssertEqual(core.status, .stopped)
        let after = try? await client.version()
        XCTAssertNil(after)
    }

    func testPortUtil() {
        let p = PortUtil.freePort()
        XCTAssertTrue(PortUtil.isAvailable(p))
        XCTAssertGreaterThan(p, 1024)
    }
}
