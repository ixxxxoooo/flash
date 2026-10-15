import XCTest
@testable import FlashKit

final class SubscriptionTests: XCTestCase {
    // 夹具：各协议分享链接
    static let ssSIP002 = "ss://\(b64("aes-256-gcm:p@ss"))@1.2.3.4:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com#%F0%9F%87%AD%F0%9F%87%B0%20HK-01"
    static let ssLegacy = "ss://\(b64("chacha20-ietf-poly1305:pwd@5.6.7.8:443"))#Legacy"
    static let vmess = "vmess://" + b64(#"{"v":"2","ps":"JP-VM","add":"jp.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"jp.example.com"}"#)
    static let trojan = "trojan://secret@us.example.com:443?sni=us.example.com&type=ws&host=cdn.com&path=%2Ftj&allowInsecure=1#US%20TJ"
    static let vless = "vless://uuid-1@v.example.com:443?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY&sid=ab12&flow=xtls-rprx-vision&type=tcp#VL"
    static let hy2 = "hysteria2://pw@h.example.com:8443?sni=h.example.com&insecure=1&obfs=salamander&obfs-password=op#HY2"
    static let tuic = "tuic://uuid-2:pw2@t.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=t.example.com#TUIC"

    static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    func testShadowsocksSIP002() throws {
        let n = try XCTUnwrap(NodeURIParser.parse(Self.ssSIP002))
        XCTAssertEqual(n.name, "🇭🇰 HK-01")
        XCTAssertEqual(n.type, "ss")
        XCTAssertEqual(n.server, "1.2.3.4")
        XCTAssertEqual(n.port, 8388)
        XCTAssertEqual(n.fields["cipher"]?.stringValue, "aes-256-gcm")
        XCTAssertEqual(n.fields["password"]?.stringValue, "p@ss")
        XCTAssertEqual(n.fields["plugin"]?.stringValue, "obfs")
    }

    func testShadowsocksLegacy() throws {
        let n = try XCTUnwrap(NodeURIParser.parse(Self.ssLegacy))
        XCTAssertEqual(n.server, "5.6.7.8")
        XCTAssertEqual(n.port, 443)
        XCTAssertEqual(n.fields["cipher"]?.stringValue, "chacha20-ietf-poly1305")
        XCTAssertEqual(n.fields["password"]?.stringValue, "pwd")
    }

    func testVMess() throws {
        let n = try XCTUnwrap(NodeURIParser.parse(Self.vmess))
        XCTAssertEqual(n.name, "JP-VM")
        XCTAssertEqual(n.fields["uuid"]?.stringValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(n.fields["network"]?.stringValue, "ws")
        XCTAssertEqual(n.fields["tls"], .bool(true))
        XCTAssertEqual(n.fields["servername"]?.stringValue, "jp.example.com")
    }

    func testTrojan() throws {
        let n = try XCTUnwrap(NodeURIParser.parse(Self.trojan))
        XCTAssertEqual(n.name, "US TJ")
        XCTAssertEqual(n.fields["password"]?.stringValue, "secret")
        XCTAssertEqual(n.fields["skip-cert-verify"], .bool(true))
        XCTAssertEqual(n.fields["network"]?.stringValue, "ws")
    }

    func testVLESSReality() throws {
        let n = try XCTUnwrap(NodeURIParser.parse(Self.vless))
        XCTAssertEqual(n.type, "vless")
        XCTAssertEqual(n.fields["flow"]?.stringValue, "xtls-rprx-vision")
        XCTAssertEqual(n.fields["client-fingerprint"]?.stringValue, "chrome")
        if case .object(let o)? = n.fields["reality-opts"] {
            XCTAssertEqual(o["public-key"]?.stringValue, "PUBKEY")
            XCTAssertEqual(o["short-id"]?.stringValue, "ab12")
        } else { XCTFail("缺少 reality-opts") }
    }

    func testHysteria2AndTUIC() throws {
        let h = try XCTUnwrap(NodeURIParser.parse(Self.hy2))
        XCTAssertEqual(h.type, "hysteria2")
        XCTAssertEqual(h.port, 8443)
        XCTAssertEqual(h.fields["obfs"]?.stringValue, "salamander")
        let t = try XCTUnwrap(NodeURIParser.parse(Self.tuic))
        XCTAssertEqual(t.fields["uuid"]?.stringValue, "uuid-2")
        XCTAssertEqual(t.fields["password"]?.stringValue, "pw2")
    }

    func testDecodeBase64Subscription() throws {
        let lines = [Self.ssSIP002, Self.vmess, Self.trojan, "unknown://x"].joined(separator: "\n")
        let encoded = Data(lines.utf8).base64EncodedData()
        let d = try SubscriptionDecoder.decode(encoded)
        XCTAssertEqual(d.format, .uriList)
        XCTAssertEqual(d.nodes.count, 3)
        XCTAssertEqual(d.skipped, 1)
    }

    func testDecodePlainURIList() throws {
        let d = try SubscriptionDecoder.decode(Data([Self.ssLegacy, Self.hy2].joined(separator: "\r\n").utf8))
        XCTAssertEqual(d.nodes.count, 2)
    }

    func testDecodeClashYAML() throws {
        let yaml = """
        port: 7890
        proxies:
          - {name: "A-SS", type: ss, server: 1.1.1.1, port: 8388, cipher: aes-128-gcm, password: pw}
          - name: B-VM
            type: vmess
            server: 2.2.2.2
            port: "443"
            uuid: 11111111-2222-3333-4444-555555555555
            alterId: 0
            cipher: auto
            tls: true
        proxy-groups:
          - {name: X, type: select, proxies: [A-SS]}
        rules:
          - MATCH,DIRECT
        """
        let d = try SubscriptionDecoder.decode(Data(yaml.utf8))
        XCTAssertEqual(d.format, .clashYAML)
        XCTAssertEqual(d.nodes.map(\.name), ["A-SS", "B-VM"])
        XCTAssertEqual(d.nodes[1].port, 443)   // 字符串端口被规整为整数
    }

    func testDecodeSurgeConf() throws {
        let conf = "[Proxy]\nS1 = ss, 1.1.1.1, 8388, encrypt-method=aes-128-gcm, password=pw\n[Rule]\nFINAL,DIRECT"
        let d = try SubscriptionDecoder.decode(Data(conf.utf8))
        XCTAssertEqual(d.format, .surge)
        XCTAssertEqual(d.nodes.count, 1)
    }

    func testDecodeEmptyFails() {
        XCTAssertThrowsError(try SubscriptionDecoder.decode(Data()))
        XCTAssertThrowsError(try SubscriptionDecoder.decode(Data("hello world".utf8)))
    }

    func testUsageHeader() throws {
        let u = try XCTUnwrap(SubscriptionUsage.parse("upload=100; download=200; total=1000; expire=1893456000"))
        XCTAssertEqual(u.used, 300)
        XCTAssertEqual(u.remaining, 700)
        XCTAssertEqual(u.fraction, 0.3, accuracy: 0.001)
        XCTAssertNotNil(u.expire)
        XCTAssertNil(SubscriptionUsage.parse("garbage"))
    }
}
