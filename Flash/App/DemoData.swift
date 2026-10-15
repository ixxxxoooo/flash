import Foundation
import FlashKit

/// 演示数据源：模拟内核输出的连接快照、速率和策略组，用于截图与离线演示
@MainActor
final class DemoFeed {
    private struct Template {
        var process: String; var path: String; var host: String; var port: String
        var network: String; var type: String; var rule: String; var payload: String
        var chains: [String]
        var downRate: Int; var upRate: Int
    }

    private struct Live {
        var id: String; var template: Template; var start: Date; var up: Int; var down: Int; var ttl: Int
    }

    private let templates: [Template] = {
        func t(_ p: String, _ path: String, _ h: String, _ port: String = "443", _ net: String = "tcp", _ type: String = "HTTPS",
               _ rule: String, _ payload: String, _ chains: [String], _ d: Int, _ u: Int) -> Template {
            Template(process: p, path: path, host: h, port: port, network: net, type: type, rule: rule, payload: payload,
                     chains: chains, downRate: d, upRate: u)
        }
        let safari = "/Applications/Safari.app/Contents/MacOS/Safari"
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let slack = "/Applications/Slack.app/Contents/MacOS/Slack"
        let spotify = "/Applications/Spotify.app/Contents/MacOS/Spotify"
        let xcode = "/Applications/Xcode.app/Contents/MacOS/Xcode"
        return [
            t("Safari", safari, "www.apple.com", "443", "tcp", "HTTPS", "DomainSuffix", "apple.com", ["DIRECT"], 180_000, 6_000),
            t("Safari", safari, "github.com", "443", "tcp", "HTTPS", "DomainSuffix", "github.com", ["香港 01", "Proxy"], 420_000, 20_000),
            t("Google Chrome", chrome, "www.youtube.com", "443", "tcp", "HTTPS", "DomainKeyword", "youtube", ["日本 03", "Auto", "Proxy"], 2_600_000, 40_000),
            t("Google Chrome", chrome, "rr3---sn-a5mlrn7s.googlevideo.com", "443", "udp", "HTTPS", "DomainSuffix", "googlevideo.com", ["日本 03", "Auto", "Proxy"], 1_800_000, 30_000),
            t("Google Chrome", chrome, "api.openai.com", "443", "tcp", "HTTPS", "DomainSuffix", "openai.com", ["美国 02", "Proxy"], 90_000, 12_000),
            t("Slack", slack, "wss-primary.slack.com", "443", "tcp", "HTTPS", "DomainSuffix", "slack.com", ["香港 01", "Proxy"], 14_000, 4_000),
            t("Spotify", spotify, "audio-ak-spotify-com.akamaized.net", "443", "tcp", "HTTPS", "DomainSuffix", "akamaized.net", ["DIRECT"], 320_000, 3_000),
            t("Xcode", xcode, "developer.apple.com", "443", "tcp", "HTTPS", "DomainSuffix", "apple.com", ["DIRECT"], 700_000, 18_000),
            t("curl", "/usr/bin/curl", "registry.npmjs.org", "443", "tcp", "HTTPS", "Match", "", ["Proxy"], 260_000, 8_000),
            t("Telegram", "/Applications/Telegram.app/Contents/MacOS/Telegram", "149.154.167.51", "443", "tcp", "HTTPS", "IPCIDR", "149.154.160.0/20", ["新加坡 01", "Proxy"], 55_000, 22_000),
            t("mDNSResponder", "/usr/sbin/mDNSResponder", "dns.alidns.com", "853", "tcp", "HTTPS", "RuleSet", "LAN", ["DIRECT"], 2_000, 1_000),
            t("Cursor", "/Applications/Cursor.app/Contents/MacOS/Cursor", "api2.cursor.sh", "443", "tcp", "HTTPS", "DomainSuffix", "cursor.sh", ["美国 02", "Proxy"], 120_000, 45_000),
            t("Safari", safari, "ads.tracker-example.com", "443", "tcp", "HTTPS", "DomainKeyword", "ads", ["REJECT"], 0, 0),
            t("Docker", "/Applications/Docker.app/Contents/MacOS/com.docker.backend", "registry-1.docker.io", "443", "tcp", "HTTPS", "DomainSuffix", "docker.io", ["香港 01", "Proxy"], 900_000, 12_000),
        ]
    }()

    private var live: [Live] = []
    private var counter = 0
    private var upTotal = 0
    private var downTotal = 0

    /// 前进一秒，返回连接快照和速率样本
    func tick(now: Date = Date()) -> (ConnectionsSnapshot, TrafficSample) {
        // 到期关闭
        live = live.filter { $0.ttl > 0 }
        for i in live.indices { live[i].ttl -= 1 }
        // 随机开启新连接
        let spawn = live.count < 9 ? Int.random(in: 1...3) : Int.random(in: 0...1)
        for _ in 0..<spawn {
            counter += 1
            let tpl = templates.randomElement()!
            live.append(Live(id: "demo-\(counter)", template: tpl, start: now, up: 0, down: 0, ttl: Int.random(in: 3...25)))
        }
        var sumUp = 0, sumDown = 0
        for i in live.indices {
            let jitter = Double.random(in: 0.4...1.4)
            let d = Int(Double(live[i].template.downRate) * jitter)
            let u = Int(Double(live[i].template.upRate) * jitter)
            live[i].down += d; live[i].up += u
            sumDown += d; sumUp += u
        }
        upTotal += sumUp; downTotal += sumDown
        let conns = live.map { l -> ConnectionInfo in
            let t = l.template
            let meta = ConnectionMetadata(network: t.network, type: "HTTPS", sourceIP: "127.0.0.1", destinationIP: "",
                                          sourcePort: String(50000 + (Int(l.id.dropFirst(5)) ?? 0) % 9000),
                                          destinationPort: t.port, host: t.host, process: t.process, processPath: t.path)
            return ConnectionInfo(id: l.id, metadata: meta, upload: l.up, download: l.down, start: l.start,
                                  chains: t.chains, rule: t.rule, rulePayload: t.payload)
        }
        let snapshot = ConnectionsSnapshot(downloadTotal: downTotal, uploadTotal: upTotal, memory: 62_000_000, connections: conns)
        let sample = TrafficSample(up: sumUp, down: sumDown, upTotal: upTotal, downTotal: downTotal, time: now)
        return (snapshot, sample)
    }

    // MARK: 策略组

    static func policies() -> [String: PolicyInfo] {
        func node(_ name: String, _ type: String, _ delay: Int) -> PolicyInfo {
            PolicyInfo(name: name, type: type, history: [DelayRecord(time: "", delay: delay)], udp: true)
        }
        let nodes: [(String, String, Int)] = [
            ("香港 01", "Shadowsocks", 38), ("香港 02", "Vmess", 52), ("香港 03", "Trojan", 71),
            ("日本 01", "Hysteria2", 88), ("日本 03", "Vmess", 94), ("美国 02", "Trojan", 168),
            ("美国 05", "Vless", 214), ("新加坡 01", "Shadowsocks", 120), ("台湾 01", "Trojan", 64),
            ("德国 01", "Vmess", 312), ("英国 01", "Vmess", 0),
        ]
        var map: [String: PolicyInfo] = [:]
        for n in nodes { map[n.0] = node(n.0, n.1, n.2) }
        map["DIRECT"] = PolicyInfo(name: "DIRECT", type: "Direct")
        map["REJECT"] = PolicyInfo(name: "REJECT", type: "Reject")
        let names = nodes.map(\.0)
        map["Auto"] = PolicyInfo(name: "Auto", type: "URLTest", now: "香港 01", all: names, history: [DelayRecord(time: "", delay: 38)])
        map["HK"] = PolicyInfo(name: "HK", type: "URLTest", now: "香港 01", all: ["香港 01", "香港 02", "香港 03"])
        map["JP"] = PolicyInfo(name: "JP", type: "URLTest", now: "日本 01", all: ["日本 01", "日本 03"])
        map["Streaming"] = PolicyInfo(name: "Streaming", type: "Selector", now: "日本 03", all: ["Proxy", "日本 01", "日本 03", "新加坡 01", "DIRECT"])
        map["Proxy"] = PolicyInfo(name: "Proxy", type: "Selector", now: "Auto", all: ["Auto", "HK", "JP"] + names + ["DIRECT"])
        map["GLOBAL"] = PolicyInfo(name: "GLOBAL", type: "Selector", now: "Proxy",
                                   all: ["Proxy", "Streaming", "Auto", "HK", "JP", "DIRECT", "REJECT"] + names)
        return map
    }

    // MARK: 订阅

    @MainActor
    static func injectSubscriptions(into manager: SubscriptionManager) {
        func node(_ name: String, _ type: String, _ server: String, _ source: String) -> ProxyNode {
            ProxyNode(name: name, fields: ["type": .string(type), "server": .string(server), "port": .int(443)], source: source)
        }
        let names = ["香港 01", "香港 02", "香港 03", "日本 01", "日本 03", "美国 02", "美国 05", "新加坡 01", "台湾 01", "德国 01", "英国 01"]
        let nodes = names.map { node($0, "trojan", "node.example.com", "示例机场") }
        var a = Subscription(name: "示例机场", url: "https://sub.example.com/api/v1/client/subscribe?token=demo", intervalHours: 24)
        a.lastUpdated = Date().addingTimeInterval(-3600 * 3)
        a.nodeCount = nodes.count
        a.format = .clashYAML
        a.usage = SubscriptionUsage(upload: 12_400_000_000, download: 188_000_000_000, total: 400_000_000_000,
                                    expire: Date().addingTimeInterval(86400 * 47))
        manager.injectDemo(a, nodes: nodes)

        var b = Subscription(name: "备用线路", url: "https://backup.example.org/sub?key=demo", intervalHours: 12)
        b.lastUpdated = Date().addingTimeInterval(-86400 * 2)
        b.nodeCount = 6
        b.format = .uriList
        b.usage = SubscriptionUsage(upload: 2_000_000_000, download: 91_000_000_000, total: 100_000_000_000,
                                    expire: Date().addingTimeInterval(86400 * 6))
        manager.injectDemo(b, nodes: (1...6).map { node("备用 0\($0)", "ss", "bk.example.org", "备用线路") })
    }
}
