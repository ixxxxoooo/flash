import Foundation
import Yams

/// 运行期参数（由应用设置决定，与配置文本无关）
public struct RuntimeOptions: Sendable {
    public var mixedPort: Int
    public var controllerPort: Int
    public var secret: String
    public var allowLan: Bool
    public var mode: String
    public var logLevel: String
    public var ipv6: Bool

    public init(mixedPort: Int = 6152, controllerPort: Int = 9090, secret: String = "", allowLan: Bool = false,
                mode: String = "rule", logLevel: String = "info", ipv6: Bool = false) {
        self.mixedPort = mixedPort; self.controllerPort = controllerPort; self.secret = secret
        self.allowLan = allowLan; self.mode = mode; self.logLevel = logLevel; self.ipv6 = ipv6
    }
}

/// 将组合后的 Profile 生成为 mihomo 的 YAML 配置
public enum ConfigGenerator {
    public static let defaultTestURL = "http://cp.cloudflare.com/generate_204"
    static let defaultDNS = ["223.5.5.5", "119.29.29.29"]

    public static func yaml(profile: Profile, options: RuntimeOptions) throws -> String {
        let dict = dictionary(profile: profile, options: options)
        return try Yams.dump(object: dict, allowUnicode: true, sortKeys: true)
    }

    public static func dictionary(profile: Profile, options: RuntimeOptions) -> [String: Any] {
        var root: [String: Any] = [
            "mixed-port": options.mixedPort,
            "allow-lan": options.allowLan,
            "bind-address": options.allowLan ? "*" : "127.0.0.1",
            "mode": options.mode,
            "log-level": options.logLevel,
            "ipv6": options.ipv6,
            "external-controller": "127.0.0.1:\(options.controllerPort)",
            "secret": options.secret,
            "unified-delay": true,
            "tcp-concurrent": true,
            "find-process-mode": "always",
            "geo-auto-update": false,
            "profile": ["store-selected": true, "store-fake-ip": false],
        ]

        // DNS
        root["dns"] = dnsBlock(profile: profile, ipv6: options.ipv6)
        if !profile.hosts.isEmpty {
            var hosts: [String: Any] = [:]
            for (k, v) in profile.hosts {
                let items = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                hosts[k] = items.count == 1 ? items[0] : items
            }
            root["hosts"] = hosts
        }

        // 节点
        root["proxies"] = profile.nodes.map { $0.toDictionary() }

        // 策略组
        let testURL = profile.general["proxy-test-url"] ?? defaultTestURL
        root["proxy-groups"] = profile.groups.map { g -> [String: Any] in
            var d: [String: Any] = ["name": g.name, "type": g.type, "proxies": g.members]
            if g.type != "select" {
                d["url"] = g.url ?? testURL
                d["interval"] = g.interval ?? 300
                d["lazy"] = true
                if g.type == "url-test" { d["tolerance"] = g.tolerance ?? 50 }
                if let t = g.timeout { d["timeout"] = t * 1000 }
            }
            return d
        }

        // 规则集
        if !profile.ruleProviders.isEmpty {
            var providers: [String: Any] = [:]
            for rp in profile.ruleProviders {
                if let inline = rp.inlineRules {
                    var payload: [String] = []
                    var dummy: [ProfileDiagnostic] = []
                    for line in inline {
                        let parts = SurgeText.splitTopLevel(line)
                        guard parts.count >= 2,
                              let body = SurgeProfileParser.convertSimple(type: parts[0].uppercased(), value: parts[1], no: 0, diagnostics: &dummy) else { continue }
                        payload.append(body + (parts.dropFirst(2).contains("no-resolve") ? ",no-resolve" : ""))
                    }
                    providers[rp.name] = ["type": "inline", "behavior": "classical", "payload": payload] as [String: Any]
                } else if let url = rp.url {
                    providers[rp.name] = [
                        "type": "http", "behavior": rp.behavior, "format": "text", "url": url,
                        "path": "./providers/\(rp.name).txt", "interval": rp.interval,
                    ] as [String: Any]
                }
            }
            root["rule-providers"] = providers
        }

        root["rules"] = profile.rules.map(\.text)
        return root
    }

    static func dnsBlock(profile: Profile, ipv6: Bool) -> [String: Any] {
        var servers = (profile.general["dns-server"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "system" }
        if let enc = profile.general["encrypted-dns-server"] {
            let encList = enc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            servers = encList + servers
        }
        if servers.isEmpty { servers = defaultDNS }
        let ipOnly = servers.filter { $0.range(of: #"^[0-9a-fA-F:.]+$"#, options: .regularExpression) != nil }

        var dns: [String: Any] = [
            "enable": true,
            "ipv6": ipv6,
            "enhanced-mode": "normal",
            "use-hosts": true,
            "default-nameserver": ipOnly.isEmpty ? defaultDNS : ipOnly,
            "nameserver": servers,
        ]
        if !profile.nameserverPolicy.isEmpty {
            dns["nameserver-policy"] = profile.nameserverPolicy.mapValues { $0 as Any }
        }
        return dns
    }
}

/// 内置的默认配置文本（Surge 风格）
public enum DefaultProfile {
    public static let text = """
    # Flash 默认配置（Surge 风格，可在“配置”页直接编辑）
    # 订阅节点会自动并入 include-all-proxies 的策略组；
    # 手动添加节点示例：
    #   MyProxy = ss, 1.2.3.4, 8388, encrypt-method=aes-128-gcm, password=xxxx

    [General]
    loglevel = notify
    dns-server = 223.5.5.5, 119.29.29.29
    skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, localhost, *.local
    proxy-test-url = http://cp.cloudflare.com/generate_204

    [Proxy]

    [Proxy Group]
    Proxy = select, Auto, DIRECT, include-all-proxies=true
    Auto = url-test, include-all-proxies=true, interval=300, tolerance=50
    HK = url-test, include-all-proxies=true, policy-regex-filter=(?i)港|(^|[^A-Za-z])HK([^A-Za-z]|$)|Hong ?Kong|🇭🇰
    JP = url-test, include-all-proxies=true, policy-regex-filter=(?i)日本|(^|[^A-Za-z])JP([^A-Za-z]|$)|Japan|🇯🇵
    US = url-test, include-all-proxies=true, policy-regex-filter=(?i)美国|(^|[^A-Za-z])US([^A-Za-z]|$)|United States|🇺🇸
    SG = url-test, include-all-proxies=true, policy-regex-filter=(?i)新加坡|狮城|(^|[^A-Za-z])SG([^A-Za-z]|$)|Singapore|🇸🇬
    TW = url-test, include-all-proxies=true, policy-regex-filter=(?i)台湾|(^|[^A-Za-z])TW([^A-Za-z]|$)|Taiwan|🇹🇼

    [Rule]
    DOMAIN-SUFFIX,local,DIRECT
    IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
    IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
    IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
    IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
    IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
    DOMAIN-SUFFIX,cn,DIRECT
    GEOIP,CN,DIRECT
    FINAL,Proxy
    """
}
