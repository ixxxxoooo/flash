import XCTest
import Yams
@testable import FlashKit

final class ComposerTests: XCTestCase {
    func sampleSubscription() -> SubscriptionNodes {
        let mk = { (n: String) in ProxyNode(name: n, fields: ["type": "ss", "server": "1.1.1.1", "port": 8388, "cipher": "aes-128-gcm", "password": "pw"]) }
        return SubscriptionNodes(name: "my-sub", url: "https://example.com/sub",
                                 nodes: [mk("🇭🇰 HK-01"), mk("🇭🇰 HK-02"), mk("🇯🇵 JP-01"), mk("US-01"), mk("Other")])
    }

    func testDefaultProfileRegionGroups() {
        let base = SurgeProfileParser.parse(DefaultProfile.text)
        let p = ProfileComposer.compose(base: base, overlay: nil, subscriptions: [sampleSubscription()])
        let hk = p.groups.first { $0.name == "HK" }
        XCTAssertEqual(hk?.members, ["🇭🇰 HK-01", "🇭🇰 HK-02"])
        XCTAssertEqual(p.groups.first { $0.name == "JP" }?.members, ["🇯🇵 JP-01"])
        XCTAssertEqual(p.groups.first { $0.name == "US" }?.members, ["US-01"])
        // 没有匹配节点的地区组被省略
        XCTAssertNil(p.groups.first { $0.name == "SG" })
        XCTAssertNil(p.groups.first { $0.name == "TW" })
        let proxy = p.groups.first { $0.name == "Proxy" }
        XCTAssertEqual(proxy?.members.prefix(2), ["Auto", "DIRECT"])
        XCTAssertEqual(proxy?.members.count, 7)   // Auto + DIRECT + 5 个节点
        XCTAssertEqual(p.rules.last?.text, "MATCH,Proxy")
    }

    func testNoSubscriptionDegradesGracefully() {
        let p = ProfileComposer.compose(base: SurgeProfileParser.parse(DefaultProfile.text), overlay: nil, subscriptions: [])
        XCTAssertEqual(p.groups.map(\.name), ["Proxy"])
        XCTAssertEqual(p.groups[0].members, ["DIRECT"])
    }

    func testOverlayPrependsRulesAndOverridesGroup() {
        let base = SurgeProfileParser.parse("[Proxy Group]\nProxy = select, DIRECT\n[Rule]\nGEOIP,CN,DIRECT\nFINAL,Proxy")
        let overlay = SurgeProfileParser.parse("[Proxy Group]\nProxy = select, DIRECT, REJECT\n[Rule]\nDOMAIN,my.com,REJECT\nFINAL,DIRECT")
        let p = ProfileComposer.compose(base: base, overlay: overlay, subscriptions: [])
        XCTAssertEqual(p.rules.map(\.text), ["DOMAIN,my.com,REJECT", "GEOIP,CN,DIRECT", "MATCH,Proxy"])
        XCTAssertEqual(p.groups[0].members, ["DIRECT", "REJECT"])
    }

    func testUnknownPolicyAndRuleSetFallBack() {
        let base = SurgeProfileParser.parse("[Rule]\nDOMAIN,a.com,Nope\nRULE-SET,Missing,DIRECT\nRULE-SET,LAN,DIRECT")
        let p = ProfileComposer.compose(base: base, overlay: nil, subscriptions: [])
        XCTAssertEqual(p.rules.map(\.text), ["DOMAIN,a.com,DIRECT", "GEOIP,LAN,DIRECT,no-resolve", "MATCH,DIRECT"])
        XCTAssertFalse(p.diagnostics.filter { $0.severity == .warning }.isEmpty)
    }

    func testDuplicateNodeNamesAreRenamed() {
        let n = ProxyNode(name: "A", fields: ["type": "http", "server": "1.1.1.1", "port": 80])
        let sub = SubscriptionNodes(name: "s", url: "", nodes: [n, n])
        let p = ProfileComposer.compose(base: SurgeProfileParser.parse("[Rule]\nFINAL,DIRECT"), overlay: nil, subscriptions: [sub])
        XCTAssertEqual(p.nodes.map(\.name), ["A", "A 2"])
    }

    func testGeneratedYAMLStructure() throws {
        let p = ProfileComposer.compose(base: SurgeProfileParser.parse(DefaultProfile.text), overlay: nil, subscriptions: [sampleSubscription()])
        let yaml = try ConfigGenerator.yaml(profile: p, options: RuntimeOptions(mixedPort: 7000, controllerPort: 9999, secret: "s3"))
        let root = try XCTUnwrap(try Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(root["mixed-port"] as? Int, 7000)
        XCTAssertEqual(root["external-controller"] as? String, "127.0.0.1:9999")
        XCTAssertEqual((root["proxies"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual((root["rules"] as? [String])?.last, "MATCH,Proxy")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
    }

    /// 生成的配置必须能通过 mihomo 自身校验
    func testGeneratedConfigPassesMihomoValidation() async throws {
        try XCTSkipIf(TestSupport.coreBinary == nil, "未找到内核，跳过")
        _ = TestSupport.isolateHome()
        var base = SurgeProfileParser.parse(DefaultProfile.text + """

        DOMAIN-SUFFIX,x.com,Proxy
        """)
        // 追加一个带规则集、内联规则集、逻辑规则的复杂配置
        let extra = SurgeProfileParser.parse("""
        [Proxy]
        VM = vmess, jp.example.com, 443, username=11111111-2222-3333-4444-555555555555, ws=true, ws-path=/ws, tls=true, sni=jp.example.com
        TJ = trojan, us.example.com, 443, password=abc, sni=us.example.com
        HY = hysteria2, h.example.com, 8443, password=pp
        [Host]
        local.test = 192.168.1.2
        [Rule]
        RULE-SET,https://example.com/ads.list,REJECT
        RULE-SET,Mine,DIRECT
        AND,((DOMAIN-SUFFIX,a.com),(DST-PORT,443)),REJECT
        PROCESS-NAME,Safari,DIRECT
        [Ruleset Mine]
        DOMAIN-SUFFIX,mine.com
        IP-CIDR,9.9.9.0/24,no-resolve
        """)
        base.nodes += extra.nodes
        base.hosts = extra.hosts
        base.rules = extra.rules + base.rules
        base.ruleProviders = extra.ruleProviders
        let composed = ProfileComposer.compose(base: base, overlay: nil, subscriptions: [sampleSubscription()])
        let yaml = try ConfigGenerator.yaml(profile: composed, options: RuntimeOptions(controllerPort: PortUtil.freePort(), secret: "x"))
        let result = await CoreManager.validate(yaml: yaml)
        XCTAssertTrue(result.ok, "mihomo 校验失败:\n\(result.output)\n---\n\(yaml)")
    }
}
