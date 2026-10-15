import XCTest
@testable import FlashKit

/// 用本地 HTTP 服务模拟订阅源，验证订阅管理与受管配置的完整流程
@MainActor
final class SubscriptionManagerTests: XCTestCase {
    var server: Process?
    var port = 0

    override func setUp() async throws {
        _ = TestSupport.isolateHome()
        port = PortUtil.freePort()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [SubscriptionTests.ssSIP002, SubscriptionTests.trojan, SubscriptionTests.hy2].joined(separator: "\n")
        let b64 = Data(lines.utf8).base64EncodedString()
        let managed = """
        [General]
        loglevel = notify
        [Proxy Group]
        Proxy = select, DIRECT
        [Rule]
        DOMAIN-SUFFIX,managed.test,Proxy
        FINAL,DIRECT
        """
        let script = """
        import http.server
        SUB = \(String(reflecting: b64)).encode()
        MANAGED = \(String(reflecting: managed)).encode()
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith('/sub'):
                    if self.headers.get('If-None-Match') == '"v1"':
                        self.send_response(304); self.end_headers(); return
                    self.send_response(200)
                    self.send_header('subscription-userinfo', 'upload=100; download=200; total=1000; expire=1893456000')
                    self.send_header('ETag', '"v1"')
                    self.send_header('Content-Length', str(len(SUB))); self.end_headers(); self.wfile.write(SUB)
                elif self.path.startswith('/managed'):
                    self.send_response(200); self.send_header('Content-Length', str(len(MANAGED))); self.end_headers(); self.wfile.write(MANAGED)
                else:
                    self.send_response(500); self.end_headers()
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', \(port)), H).serve_forever()
        """
        let file = dir.appendingPathComponent("srv.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    override func tearDown() async throws { server?.terminate() }

    func testAddUpdateAndFailureKeepsNodes() async throws {
        let mgr = SubscriptionManager()
        var changes = 0
        mgr.onChange = { changes += 1 }

        let sub = try await mgr.add(name: "测试订阅", url: "http://127.0.0.1:\(port)/sub")
        XCTAssertEqual(sub.nodeCount, 3)
        XCTAssertEqual(sub.usage?.total, 1000)
        XCTAssertEqual(sub.usage?.used, 300)
        XCTAssertEqual(sub.format, .uriList)
        XCTAssertEqual(mgr.nodes(for: sub.id).count, 3)
        XCTAssertGreaterThan(changes, 0)

        // 带 ETag 的再次更新 → 304，节点保持不变
        let ok = await mgr.update(sub.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(mgr.nodes(for: sub.id).count, 3)

        // 地址失效 → 更新失败，保留旧节点并记录错误
        let bad = Subscription(name: "坏订阅", url: "http://127.0.0.1:\(port)/bad")
        do { _ = try await mgr.add(name: bad.name, url: bad.url); XCTFail("应当失败") } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(mgr.items.count, 1)   // 失败的订阅不会保留

        // 启停影响组合结果
        let nodes = mgr.enabledNodes()
        XCTAssertEqual(nodes.first?.nodes.count, 3)
        mgr.setEnabled(sub.id, false)
        XCTAssertTrue(mgr.enabledNodes().isEmpty)

        // 持久化：重新加载后仍在
        let reloaded = SubscriptionManager()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.nodes(for: sub.id).count, 3)

        mgr.remove(sub.id)
        XCTAssertTrue(mgr.items.isEmpty)
    }

    func testImportTextAsLocalSubscription() throws {
        let mgr = SubscriptionManager()
        let sub = try mgr.importText(name: "手动", text: [SubscriptionTests.ssLegacy, SubscriptionTests.vmess].joined(separator: "\n"))
        XCTAssertTrue(sub.isLocal)
        XCTAssertEqual(sub.nodeCount, 2)
        XCTAssertFalse(sub.isDue)
        XCTAssertThrowsError(try mgr.importText(name: "x", text: "not a subscription"))
    }

    func testManagedProfileImportAndDetach() async throws {
        let store = ProfileStore()
        XCTAssertFalse(store.isManaged)
        try await store.importManaged(url: "http://127.0.0.1:\(port)/managed", interval: 600)
        XCTAssertTrue(store.isManaged)
        XCTAssertEqual(store.managed?.interval, 600)
        XCTAssertTrue(store.mainText.contains("managed.test"))
        // 叠加本地覆盖层：前置一条规则
        store.saveOverlay("[Rule]\nDOMAIN,local.override,REJECT")
        let p = store.composed(subscriptions: [])
        XCTAssertEqual(p.rules.first?.text, "DOMAIN,local.override,REJECT")
        XCTAssertTrue(p.rules.contains { $0.text == "DOMAIN-SUFFIX,managed.test,Proxy" })

        await store.refreshManaged(force: true)
        XCTAssertNil(store.managedError)
        store.detachManaged()
        XCTAssertFalse(store.isManaged)
        XCTAssertFalse(store.mainText.contains("#!MANAGED-CONFIG"))
    }
}
