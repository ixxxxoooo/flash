import XCTest
@testable import FlashKit

/// 圈叉配置转换与默认路由解析测试（使用虚构的密码与订阅地址）
/// @author ygw
final class QuantumultXTests: XCTestCase {
    static let sample = """
    [server_remote]
    https://example.com/sub/abc, tag=机场A, update-interval=172800, opt-parser=false, enabled=true

    [server_local]
    vless=node.example.com:443, method=none, password=11111111-2222-3333-4444-555555555555, obfs=wss, obfs-host=node.example.com, obfs-uri=/ws, tls-verification=true, fast-open=true, udp-relay=true, tag=美国专线

    [general]
    excluded_routes = 192.168.0.0/16, 10.0.0.0/8

    [dns]
    no-ipv6
    server = 119.29.29.29
    server = /dl.google.com/223.5.5.5
    address = /mtalk.google.com/108.177.125.188

    [policy]
    static = 海外, 机场A, 美国专线, direct, img-url=https://example.com/a.png
    static = 机场A, server-tag-regex=机场A

    [filter_remote]
    作业帮.list, tag=作业帮, force-policy=direct, enabled=true
    https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/QuantumultX/Apple/Apple.list, tag=Apple, force-policy=direct, enabled=true
    https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/QuantumultX/Google/Google.list, tag=Google, force-policy=海外, enabled=true

    [filter_local]
    host-suffix, cursor.com, 海外
    ip-cidr, 10.0.0.0/8, direct
    geoip, cn, direct
    final, 海外

    [rewrite_local]
    ^https://ad\\.example\\.com/ url reject-200

    [mitm]
    hostname = ad.example.com
    """

    func testConvertFullProfile() {
        let r = QuantumultXConverter.convert(Self.sample) { name in
            name == "作业帮.list" ? "HOST-SUFFIX,zuoyebang.com,direct\nIP-CIDR,1.2.3.0/24,direct" : nil
        }
        XCTAssertEqual(r.nodeCount, 1)
        XCTAssertEqual(r.groupCount, 2)
        XCTAssertEqual(r.remoteServers.count, 1)
        // 节点
        XCTAssertTrue(r.text.contains("美国专线 = vless, node.example.com, 443, username=11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(r.text.contains("ws=true"))
        XCTAssertTrue(r.text.contains("ws-path=/ws"))
        // 策略组：server-tag-regex 映射为订阅地址
        XCTAssertTrue(r.text.contains("机场A = select, policy-path=https://example.com/sub/abc"))
        XCTAssertTrue(r.text.contains("海外 = select, 机场A, 美国专线, DIRECT"))
        // 规则顺序：本地(非 geoip) → 远程 → geoip → FINAL
        let rules = r.text.components(separatedBy: "\n")
        func idx(_ s: String) -> Int { rules.firstIndex { $0.hasPrefix(s) } ?? -1 }
        XCTAssertLessThan(idx("DOMAIN-SUFFIX,cursor.com,海外"), idx("RULE-SET,"))
        XCTAssertLessThan(idx("RULE-SET,"), idx("GEOIP,CN,DIRECT"))
        XCTAssertLessThan(idx("GEOIP,CN,DIRECT"), idx("FINAL,海外"))
        // 本地列表展开、远程列表改写为 Surge 版本
        XCTAssertTrue(r.text.contains("DOMAIN-SUFFIX,zuoyebang.com,DIRECT"))
        XCTAssertTrue(r.text.contains("RULE-SET,https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/QuantumultX/Apple/Apple.list,DIRECT,format=qx"))
        XCTAssertTrue(r.text.contains("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"))
        // DNS / General
        XCTAssertTrue(r.text.contains("dns-server = 119.29.29.29"))
        XCTAssertTrue(r.text.contains("+.dl.google.com = server:223.5.5.5"))
        XCTAssertTrue(r.text.contains("mtalk.google.com = 108.177.125.188"))
        XCTAssertTrue(r.text.contains("skip-proxy = 192.168.0.0/16,10.0.0.0/8"))
        // MitM
        XCTAssertTrue(r.text.contains("hostname = ad.example.com"))
        XCTAssertTrue(r.text.contains("- reject-200"))
    }

    /// 转换结果必须能被 Surge 解析器完整解析并组合成可用配置
    func testConvertedProfileParses() {
        let r = QuantumultXConverter.convert(Self.sample) { _ in "HOST-SUFFIX,zuoyebang.com,direct" }
        let p = SurgeProfileParser.parse(r.text)
        XCTAssertEqual(p.nodes.count, 1)
        XCTAssertEqual(p.nodes[0].type, "vless")
        XCTAssertEqual(p.nodes[0].fields["tls"], true)
        XCTAssertEqual(p.nodes[0].fields["network"], "ws")
        XCTAssertEqual(p.nodes[0].fields["servername"]?.stringValue, "node.example.com")
        XCTAssertEqual(p.nodes[0].fields["uuid"]?.stringValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(p.groups.map(\.name), ["海外", "机场A"])
        XCTAssertEqual(p.groups[1].policyPath, "https://example.com/sub/abc")
        XCTAssertTrue(p.rules.last?.isFinal ?? false)
        XCTAssertEqual(p.rules.last?.policy, "海外")
        XCTAssertEqual(p.nameserverPolicy["+.dl.google.com"], "223.5.5.5")
        XCTAssertEqual(p.hosts["mtalk.google.com"], "108.177.125.188")
        XCTAssertEqual(p.mitm.urlRewrites.count, 1)
        let errors = p.diagnostics.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "\(errors.map(\.message))")

        // 与订阅合并后，「机场A」组按订阅地址取到节点
        let sub = SubscriptionNodes(name: "随便起的名字", url: "https://example.com/sub/abc",
                                    nodes: [ProxyNode(name: "HK-1", fields: ["type": "ss", "server": "1.1.1.1", "port": 1])])
        let c = ProfileComposer.compose(base: p, overlay: nil, subscriptions: [sub])
        XCTAssertEqual(c.groups.first { $0.name == "机场A" }?.members, ["HK-1"])
        XCTAssertEqual(c.groups.first { $0.name == "海外" }?.members, ["机场A", "美国专线", "DIRECT"])
    }

    /// 圈叉列表转换：类型映射、丢弃策略列、USER-AGENT 不计入规则
    func testQXRuleListConversion() {
        let text = """
        # NAME: demo
        HOST,apps.apple.com,Apple
        HOST-SUFFIX,apple.com,Apple
        HOST-KEYWORD,icloud,Apple
        IP-CIDR,17.0.0.0/8,Apple,no-resolve
        IP6-CIDR,2620:149::/32,Apple,no-resolve
        IP-CIDR,1.1.1.0/24,Apple
        USER-AGENT,com.apple.*,Apple
        """
        let r = QXRuleSetCache.convert(text)
        XCTAssertEqual(r.lines, [
            "DOMAIN,apps.apple.com", "DOMAIN-SUFFIX,apple.com", "DOMAIN-KEYWORD,icloud",
            "IP-CIDR,17.0.0.0/8,no-resolve", "IP-CIDR6,2620:149::/32,no-resolve", "IP-CIDR,1.1.1.0/24",
        ])
        XCTAssertEqual(r.skipped, 1)
    }

    /// qx 规则集在内核配置里必须是 file 类型，且不带下载地址
    func testQXProviderGeneratedAsFile() {
        let r = QuantumultXConverter.convert(Self.sample) { _ in nil }
        let p = SurgeProfileParser.parse(r.text)
        let qx = p.ruleProviders.filter { $0.flavor == "qx" }
        XCTAssertEqual(qx.count, 2)
        let c = ProfileComposer.compose(base: p, overlay: nil, subscriptions: [])
        let dict = ConfigGenerator.dictionary(profile: c, options: RuntimeOptions())
        let providers = dict["rule-providers"] as? [String: Any] ?? [:]
        let first = providers[qx[0].name] as? [String: Any]
        XCTAssertEqual(first?["type"] as? String, "file")
        XCTAssertNil(first?["url"])
    }

    func testOtherServerTypes() {
        var notes: [String] = []
        let ss = QuantumultXConverter.convertServer("shadowsocks=1.2.3.4:8388, method=aes-128-gcm, password=pw, obfs=http, obfs-host=bing.com, tag=SS1", notes: &notes)
        XCTAssertEqual(ss?.1, "SS1 = ss, 1.2.3.4, 8388, encrypt-method=aes-128-gcm, password=pw, obfs=http, obfs-host=bing.com")
        let vm = QuantumultXConverter.convertServer("vmess=h.example.com:443, method=none, password=uuid-1, obfs=over-tls, tls-verification=false, tag=VM", notes: &notes)
        XCTAssertTrue(vm?.1.contains("tls=true") ?? false)
        XCTAssertTrue(vm?.1.contains("skip-cert-verify=true") ?? false)
        let tj = QuantumultXConverter.convertServer("trojan=t.example.com:443, password=pw, over-tls=true, tls-host=t.example.com, tag=TJ", notes: &notes)
        XCTAssertEqual(tj?.1, "TJ = trojan, t.example.com, 443, password=pw, sni=t.example.com")
    }

    func testDefaultRouteParsing() {
        let withQX = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            link#27            UCSg                utun6
        default            192.168.5.1        UGScIg                en1
        1                  link#27            UCS                 utun6
        """
        let r = NetworkRoute.parse(netstat: withQX)
        XCTAssertTrue(r.hasTunnel)
        XCTAssertEqual(r.physical, "en1")
        XCTAssertEqual(r.bypassInterface, "en1")

        let plain = "default            192.168.5.1        UGScg                 en0\n"
        let p = NetworkRoute.parse(netstat: plain)
        XCTAssertFalse(p.hasTunnel)
        XCTAssertNil(p.bypassInterface)
    }

    func testInterfaceNameOnlyWhenRequested() {
        var o = RuntimeOptions(); o.interfaceName = "en1"
        let on = ConfigGenerator.dictionary(profile: Profile(), options: o)
        XCTAssertEqual(on["interface-name"] as? String, "en1")
        let off = ConfigGenerator.dictionary(profile: Profile(), options: RuntimeOptions())
        XCTAssertNil(off["interface-name"])
        o.tunEnabled = true
        XCTAssertNil(ConfigGenerator.dictionary(profile: Profile(), options: o)["interface-name"])
    }
}

/// VPN 冲突检测的解析测试
final class VPNConflictTests: XCTestCase {
    func testParseNCList() {
        let out = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   8B993B6F-2DC4-4847-AC8D-D8C5783F5E3E VPN (com.liguangming.Shadowrocket) "Shadowrocket"                   [VPN:com.liguangming.Shadowrocket]
        * (Connected)      CC704328-9FB1-42E7-8AA8-FB624CEA4537 VPN (com.crossutility.quantumult-x) "Quantumult X"                   [VPN:com.crossutility.quantumult-x]
        """
        let list = VPNConflict.parseList(out)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.filter(\.isConnected).map(\.name), ["Quantumult X"])
        XCTAssertEqual(list[1].id, "CC704328-9FB1-42E7-8AA8-FB624CEA4537")
    }

    /// 只认全局字典；__SCOPED__ 里的代理不算数（这正是圈叉接管后应用读不到系统代理的原因）
    func testGlobalProxyIgnoresScoped() {
        let scopedOnly = """
        <dictionary> {
          FTPPassive : 1
          __SCOPED__ : <dictionary> {
            en1 : <dictionary> {
              HTTPEnable : 1
              HTTPPort : 6199
              HTTPProxy : 127.0.0.1
            }
          }
        }
        """
        XCTAssertFalse(VPNConflict.parseGlobalProxy(scopedOnly).points(to: 6199))
        let global = """
        <dictionary> {
          HTTPEnable : 1
          HTTPPort : 6199
          HTTPProxy : 127.0.0.1
          SOCKSEnable : 1
          SOCKSPort : 6199
        }
        """
        XCTAssertTrue(VPNConflict.parseGlobalProxy(global).points(to: 6199))
        XCTAssertFalse(VPNConflict.parseGlobalProxy(global).points(to: 7000))
    }
}

/// 增强模式（TUN）启动失败检测
final class TUNErrorTests: XCTestCase {
    func testDetectRouteConflictOnLatestStart() {
        let log = """
        time="a" level=info msg="Start initial configuration in progress"
        time="b" level=error msg="Start TUN listening error: configure tun interface: add route: 1.0.0.0/8: file exists"
        time="c" level=warning msg="Mihomo shutting down"
        """
        XCTAssertEqual(PrivilegedCore.parseTUNError(log: log), "configure tun interface: add route: 1.0.0.0/8: file exists")
    }

    /// 旧一次启动失败、最近一次启动成功时，不应误报
    func testOldFailureIgnoredAfterRestart() {
        let log = """
        time="a" level=info msg="Start initial configuration in progress"
        time="b" level=error msg="Start TUN listening error: configure tun interface: add route: 1.0.0.0/8: file exists"
        time="c" level=info msg="Start initial configuration in progress"
        time="d" level=info msg="Sniffer is loaded and working"
        """
        XCTAssertNil(PrivilegedCore.parseTUNError(log: log))
    }
}
