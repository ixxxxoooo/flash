import XCTest
import Yams
@testable import FlashKit

/// 增强模式（TUN）配置与特权组件脚本的测试
/// @author ygw
@MainActor
final class TunConfigTests: XCTestCase {
    private func composed() -> Profile {
        ProfileComposer.compose(base: SurgeProfileParser.parse(DefaultProfile.text), overlay: nil, subscriptions: [])
    }

    func testTunDisabledHasNoTunBlock() {
        let d = ConfigGenerator.dictionary(profile: composed(), options: RuntimeOptions())
        XCTAssertNil(d["tun"])
        XCTAssertNil(d["sniffer"])
        XCTAssertEqual((d["dns"] as? [String: Any])?["enhanced-mode"] as? String, "normal")
    }

    func testTunEnabledGeneratesTunDnsAndSniffer() {
        let d = ConfigGenerator.dictionary(profile: composed(), options: RuntimeOptions(tunEnabled: true, tunStack: "gvisor"))
        let tun = d["tun"] as? [String: Any]
        XCTAssertEqual(tun?["enable"] as? Bool, true)
        XCTAssertEqual(tun?["stack"] as? String, "gvisor")
        XCTAssertEqual(tun?["auto-route"] as? Bool, true)
        XCTAssertEqual(tun?["auto-detect-interface"] as? Bool, true)
        let dns = d["dns"] as? [String: Any]
        XCTAssertEqual(dns?["enhanced-mode"] as? String, "fake-ip")
        XCTAssertNotNil(dns?["fake-ip-filter"])
        XCTAssertEqual((d["sniffer"] as? [String: Any])?["enable"] as? Bool, true)
    }

    func testInvalidStackFallsBackToMixed() {
        let d = ConfigGenerator.dictionary(profile: composed(), options: RuntimeOptions(tunEnabled: true, tunStack: "bogus"))
        XCTAssertEqual((d["tun"] as? [String: Any])?["stack"] as? String, "mixed")
    }

    /// TUN 配置必须能通过真实内核的 `-t` 校验
    func testTunConfigPassesCoreValidation() async throws {
        try XCTSkipIf(TestSupport.coreBinary == nil, "未找到内核，跳过")
        _ = TestSupport.isolateHome()
        for stack in ["system", "gvisor", "mixed"] {
            let yaml = try ConfigGenerator.yaml(profile: composed(), options: RuntimeOptions(secret: "x", tunEnabled: true, tunStack: stack))
            let r = await CoreManager.validate(yaml: yaml)
            XCTAssertTrue(r.ok, "stack=\(stack) 校验失败: \(r.output)")
        }
    }

    func testWrapperAndPlistAndScripts() throws {
        XCTAssertTrue(PrivilegedCore.wrapperScriptText().hasPrefix("#!/bin/sh"))
        let data = try PrivilegedCore.daemonPlistData()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, PrivilegedCore.label)
        let keep = plist["KeepAlive"] as? [String: Any]
        XCTAssertEqual((keep?["PathState"] as? [String: Bool])?[PrivilegedCore.flagFile], true)
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, PrivilegedCore.wrapperScript)
        XCTAssertTrue(args.contains(PrivilegedCore.installedBinary))

        let install = PrivilegedCore.installScript(bundledBinary: "/a b/mihomo", wrapperTmp: "/t/w.sh", plistTmp: "/t/p.plist")
        XCTAssertTrue(install.contains("'/a b/mihomo'"))
        XCTAssertTrue(install.contains("launchctl bootstrap system"))
        XCTAssertTrue(PrivilegedCore.uninstallScript().contains("rm -f"))
    }

    func testWrapperScriptStopsWhenFlagRemoved() throws {
        // 用 sleep 代替内核，验证包装脚本在标记文件消失后会结束子进程
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-wrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("run.sh")
        try PrivilegedCore.wrapperScriptText().write(to: script, atomically: true, encoding: .utf8)
        let flag = dir.appendingPathComponent("flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, flag.path, "/bin/sleep", "300"]
        try p.run()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(p.isRunning)
        try FileManager.default.removeItem(at: flag)
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(p.isRunning, "标记文件删除后包装脚本应当退出")
    }
}

/// MitM 与内核衔接的配置测试
@MainActor
final class MitMLinkTests: XCTestCase {
    private func profile() -> Profile {
        let base = SurgeProfileParser.parse(DefaultProfile.text + "\n[MITM]\nhostname = *.example.com, api.test.com:8443, -skip.example.com\n")
        return ProfileComposer.compose(base: base, overlay: nil, subscriptions: [])
    }

    func testRulesAndListenerGenerated() {
        let d = ConfigGenerator.dictionary(profile: profile(), options: RuntimeOptions(mitmServerPort: 7001, mitmUpstreamPort: 7002))
        let rules = d["rules"] as? [String] ?? []
        XCTAssertTrue(rules[0].hasPrefix("AND,((DOMAIN-WILDCARD,*.example.com)"), rules[0])
        XCTAssertTrue(rules[0].hasSuffix(",FlashMitM"))
        XCTAssertTrue(rules[1].contains("(DST-PORT,8443)"), rules[1])
        XCTAssertEqual(rules.count, (profile().rules.count) + 2)   // 排除项不生成规则
        let proxies = d["proxies"] as? [[String: Any]] ?? []
        XCTAssertTrue(proxies.contains { ($0["name"] as? String) == "FlashMitM" && ($0["port"] as? Int) == 7001 })
        XCTAssertEqual(((d["listeners"] as? [[String: Any]])?.first?["port"] as? Int), 7002)
    }

    func testNoMitmOptionsMeansNoChanges() {
        let d = ConfigGenerator.dictionary(profile: profile(), options: RuntimeOptions())
        XCTAssertNil(d["listeners"])
        XCTAssertEqual((d["rules"] as? [String])?.count, profile().rules.count)
    }

    func testMitmConfigPassesCoreValidation() async throws {
        try XCTSkipIf(TestSupport.coreBinary == nil, "未找到内核，跳过")
        _ = TestSupport.isolateHome()
        let yaml = try ConfigGenerator.yaml(profile: profile(), options: RuntimeOptions(secret: "x", mitmServerPort: 7001, mitmUpstreamPort: 7002))
        let r = await CoreManager.validate(yaml: yaml)
        XCTAssertTrue(r.ok, r.output)
    }

    func testMergeHopsHidesUpstreamAndCopiesChains() {
        let first = ConnectionInfo(id: "a", metadata: ConnectionMetadata(host: "x.example.com", process: "curl"), upload: 1, download: 2,
                                   start: Date(), chains: ["FlashMitM"], rule: "And", rulePayload: "")
        let hop = ConnectionInfo(id: "b", metadata: ConnectionMetadata(host: "x.example.com", process: "Flash", inboundName: "mitm-up"), upload: 1, download: 2,
                                 start: Date(), chains: ["香港 01", "Proxy"], rule: "Match", rulePayload: "")
        let other = ConnectionInfo(id: "c", metadata: ConnectionMetadata(host: "y.com"), upload: 0, download: 0, start: Date(), chains: ["DIRECT"], rule: "Match", rulePayload: "")
        let merged = MitMLink.mergeHops(ConnectionsSnapshot(connections: [first, hop, other]))
        XCTAssertEqual(merged.connections.map(\.id), ["a", "c"])
        XCTAssertEqual(merged.connections[0].chains, ["香港 01", "Proxy"])
        XCTAssertEqual(merged.connections[0].rule, "Match")
    }
}
