import XCTest
@testable import FlashKit

final class SurgeParserTests: XCTestCase {
    let sample = """
    #!MANAGED-CONFIG https://example.com/a.conf interval=3600 strict=true
    [General]
    loglevel = notify
    dns-server = 223.5.5.5, https://dns.alidns.com/dns-query
    proxy-test-url = http://cp.cloudflare.com/generate_204 // 注释

    [Proxy]
    Block = reject
    HK-SS = ss, 1.2.3.4, 8388, encrypt-method=aes-128-gcm, password=pwd, obfs=http, obfs-host=bing.com, udp-relay=true
    JP-VM = vmess, jp.example.com, 443, username=11111111-2222-3333-4444-555555555555, ws=true, ws-path=/ws, ws-headers=Host:cdn.example.com, tls=true, sni=jp.example.com
    US-TJ = trojan, us.example.com, 443, password=abc, sni=us.example.com, skip-cert-verify=true
    WEB = https, 5.6.7.8, 443, user, pass
    HY2 = hysteria2, h.example.com, 8443, password=pp, download-bandwidth=100
    WG = wireguard, section-name=x

    [Proxy Group]
    Proxy = select, Auto, DIRECT, include-all-proxies=true
    Auto = url-test, HK-SS, JP-VM, url=http://cp.cloudflare.com/generate_204, interval=300, tolerance=30
    Smart = smart, HK-SS
    Pick = select, policy-path=my-sub, policy-regex-filter=(?i)hk

    [Rule]
    DOMAIN-SUFFIX,apple.com,DIRECT
    DOMAIN,ad.example.com,Block
    IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
    GEOIP,cn,DIRECT
    PROCESS-NAME,/Applications/Foo.app/Contents/MacOS/foo,Proxy
    DEST-PORT,443,Proxy
    AND,((DOMAIN-SUFFIX,a.com),(DEST-PORT,443)),REJECT-TINYGIF
    NOT,((PROTOCOL,UDP)),Proxy
    RULE-SET,https://example.com/ads.list,REJECT,update-interval=3600
    DOMAIN-SET,https://example.com/d.txt,DIRECT
    USER-AGENT,Foo*,REJECT
    FINAL,Proxy,dns-failed

    [Host]
    local.test = 192.168.1.2
    *.corp.com = server:10.0.0.1
    """

    func testManagedHeader() {
        let p = SurgeProfileParser.parse(sample)
        XCTAssertEqual(p.managed?.url, "https://example.com/a.conf")
        XCTAssertEqual(p.managed?.interval, 3600)
        XCTAssertEqual(p.managed?.strict, true)
    }

    func testGeneralAndInlineComment() {
        let p = SurgeProfileParser.parse(sample)
        XCTAssertEqual(p.general["loglevel"], "notify")
        XCTAssertEqual(p.general["proxy-test-url"], "http://cp.cloudflare.com/generate_204")
    }

    func testProxies() {
        let p = SurgeProfileParser.parse(sample)
        XCTAssertEqual(p.nodes.map(\.name), ["HK-SS", "JP-VM", "US-TJ", "WEB", "HY2"])
        let ss = p.nodes[0]
        XCTAssertEqual(ss.fields["cipher"]?.stringValue, "aes-128-gcm")
        XCTAssertEqual(ss.fields["plugin"]?.stringValue, "obfs")
        XCTAssertEqual(ss.port, 8388)
        let vm = p.nodes[1]
        XCTAssertEqual(vm.fields["network"]?.stringValue, "ws")
        XCTAssertEqual(vm.fields["tls"], .bool(true))
        XCTAssertEqual(vm.fields["servername"]?.stringValue, "jp.example.com")
        XCTAssertEqual(p.nodes[3].fields["tls"], .bool(true))
        XCTAssertEqual(p.nodes[3].fields["username"]?.stringValue, "user")
        XCTAssertEqual(p.nodes[4].fields["down"]?.stringValue, "100 Mbps")
        XCTAssertEqual(p.policyAliases["Block"], "REJECT")
        XCTAssertTrue(p.diagnostics.contains { $0.message.contains("wireguard") })
    }

    func testGroups() {
        let p = SurgeProfileParser.parse(sample)
        XCTAssertEqual(p.groups.count, 4)
        XCTAssertTrue(p.groups[0].includeAllProxies)
        XCTAssertEqual(p.groups[1].tolerance, 30)
        XCTAssertEqual(p.groups[2].type, "url-test")   // smart 降级
        XCTAssertEqual(p.groups[3].policyPath, "my-sub")
        XCTAssertEqual(p.groups[3].regexFilter, "(?i)hk")
    }

    func testRules() {
        let p = SurgeProfileParser.parse(sample)
        let texts = p.rules.map(\.text)
        XCTAssertTrue(texts.contains("DOMAIN-SUFFIX,apple.com,DIRECT"))
        XCTAssertTrue(texts.contains("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"))
        XCTAssertTrue(texts.contains("GEOIP,CN,DIRECT"))
        XCTAssertTrue(texts.contains("PROCESS-PATH,/Applications/Foo.app/Contents/MacOS/foo,Proxy"))
        XCTAssertTrue(texts.contains("DST-PORT,443,Proxy"))
        XCTAssertTrue(texts.contains("AND,((DOMAIN-SUFFIX,a.com),(DST-PORT,443)),REJECT"))
        XCTAssertTrue(texts.contains("NOT,((NETWORK,udp)),Proxy"))
        XCTAssertEqual(texts.last, "MATCH,Proxy")
        XCTAssertEqual(p.ruleProviders.count, 2)
        XCTAssertEqual(p.ruleProviders.first { $0.url == "https://example.com/ads.list" }?.interval, 3600)
        XCTAssertEqual(p.ruleProviders.first { $0.url == "https://example.com/d.txt" }?.behavior, "domain")
        XCTAssertTrue(p.diagnostics.contains { $0.message.contains("USER-AGENT") })
    }

    func testHosts() {
        let p = SurgeProfileParser.parse(sample)
        XCTAssertEqual(p.hosts["local.test"], "192.168.1.2")
        XCTAssertEqual(p.nameserverPolicy["*.corp.com"], "10.0.0.1")
    }

    func testInclude() {
        let main = """
        [Rule]
        #!include shared.dconf
        FINAL,DIRECT
        """
        let shared = """
        [Rule]
        DOMAIN,a.com,DIRECT
        [Proxy]
        X = http, 1.1.1.1, 80
        """
        let p = SurgeProfileParser.parse(main) { $0 == "shared.dconf" ? shared : nil }
        XCTAssertEqual(p.rules.map(\.text), ["DOMAIN,a.com,DIRECT", "MATCH,DIRECT"])
        XCTAssertTrue(p.nodes.isEmpty)   // 只取与当前小节同名的内容
    }

    func testRuleSimulator() {
        let p = SurgeProfileParser.parse(sample)
        let r = RuleSimulator.match(rules: p.rules, query: .init(host: "www.apple.com", port: 443))
        XCTAssertEqual(r?.rule.text, "DOMAIN-SUFFIX,apple.com,DIRECT")
        let r2 = RuleSimulator.match(rules: p.rules, query: .init(host: "ad.example.com", port: 80))
        XCTAssertEqual(r2?.rule.policy, "Block")
        let r3 = RuleSimulator.match(rules: p.rules, query: .init(host: "x.com", ip: "10.1.2.3", port: 80))
        XCTAssertEqual(r3?.rule.body, "IP-CIDR,10.0.0.0/8")
    }
}
