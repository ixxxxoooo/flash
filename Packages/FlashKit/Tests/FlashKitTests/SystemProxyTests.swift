import XCTest
@testable import FlashKit

final class SystemProxyTests: XCTestCase {
    func testParseEndpoint() {
        let on = SystemProxy.parseEndpoint("Enabled: Yes\nServer: 127.0.0.1\nPort: 6152\nAuthenticated Proxy Enabled: 0\n")
        XCTAssertEqual(on, ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 6152))
        let off = SystemProxy.parseEndpoint("Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0")
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.port, 0)
    }

    func testParseBypass() {
        XCTAssertEqual(SystemProxy.parseBypass("There aren't any bypass domains set on Wi-Fi."), [])
        XCTAssertEqual(SystemProxy.parseBypass("localhost\n*.local\n"), ["localhost", "*.local"])
    }

    func testRestoreCommands() {
        let state = ServiceProxyState(
            service: "Wi-Fi",
            web: ProxyEndpoint(enabled: true, server: "10.0.0.1", port: 8080),
            secureWeb: ProxyEndpoint(),
            socks: ProxyEndpoint(),
            bypass: [])
        let cmds = SystemProxy.restoreCommands(state)
        XCTAssertTrue(cmds.contains(["-setwebproxy", "Wi-Fi", "10.0.0.1", "8080"]))
        XCTAssertTrue(cmds.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(cmds.contains(["-setsecurewebproxy", "Wi-Fi", "", "0"]))
        XCTAssertTrue(cmds.contains(["-setsocksfirewallproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(cmds.contains(["-setproxybypassdomains", "Wi-Fi", "Empty"]))
    }

    func testShellQuote() {
        XCTAssertEqual(SystemProxy.shellQuote("a'b"), "'a'\\''b'")
    }

    /// 只读验证：真实 networksetup 能列出网络服务并解析代理状态
    func testLiveReadOnly() {
        let services = SystemProxy.listServices()
        XCTAssertFalse(services.isEmpty)
        let state = SystemProxy.capture(service: services[0])
        XCTAssertEqual(state.service, services[0])
    }
}

/// 真实修改系统代理的测试（默认跳过）：FLASH_LIVE_PROXY=1 swift test --filter LiveProxy
final class LiveProxyTests: XCTestCase {
    func testEnableAndRestoreRoundTrip() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FLASH_LIVE_PROXY"] != "1", "未设置 FLASH_LIVE_PROXY=1，跳过")
        _ = TestSupport.isolateHome()
        let services = SystemProxy.listServices()
        let before = services.map { SystemProxy.capture(service: $0) }
        let proxy = SystemProxy()
        defer { try? proxy.restore() }

        try proxy.enable(host: "127.0.0.1", port: 6199)
        XCTAssertTrue(SystemProxy.isPointingTo(host: "127.0.0.1", port: 6199))
        let backup = JSONFile.load(ProxyBackup.self, from: AppPaths.proxyBackup)
        XCTAssertEqual(backup?.dirty, true)

        try proxy.restore()
        XCTAssertFalse(SystemProxy.isPointingTo(host: "127.0.0.1", port: 6199))
        let after = services.map { SystemProxy.capture(service: $0) }
        XCTAssertEqual(before, after, "恢复后的代理设置应与原值一致")
        XCTAssertEqual(JSONFile.load(ProxyBackup.self, from: AppPaths.proxyBackup)?.dirty, false)
    }
}
