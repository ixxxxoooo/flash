import Foundation

// MARK: - 容错解码辅助

extension KeyedDecodingContainer {
    /// 字符串或数字都按字符串解码（mihomo 的端口字段会以字符串形式返回）
    func flexString(_ key: Key) -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return ""
    }

    func int(_ key: Key) -> Int {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        return 0
    }

    func string(_ key: Key) -> String { (try? decodeIfPresent(String.self, forKey: key)) ?? "" }
    func bool(_ key: Key) -> Bool { (try? decodeIfPresent(Bool.self, forKey: key)) ?? false }
    func strings(_ key: Key) -> [String] { (try? decodeIfPresent([String].self, forKey: key)) ?? [] }
}

/// 解析 mihomo 返回的时间字符串（纳秒级小数需截断到毫秒）
public enum MihomoDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        var text = raw
        // 将 “.123456789” 截断为 “.123”
        if let dot = text.firstIndex(of: ".") {
            let after = text.index(after: dot)
            var end = after
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            let digits = text[after..<end]
            let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<after]) + trimmed + String(text[end...])
        }
        return formatter.date(from: text) ?? plain.date(from: raw)
    }
}

// MARK: - 版本 / 配置

public struct VersionInfo: Codable, Sendable {
    public var version: String
    public var meta: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.string(.version)
        meta = c.bool(.meta)
    }
    enum CodingKeys: String, CodingKey { case version, meta }
}

public struct CoreConfigInfo: Codable, Sendable {
    public var mode: String
    public var mixedPort: Int
    public var port: Int
    public var socksPort: Int
    public var allowLan: Bool
    public var logLevel: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.string(.mode)
        mixedPort = c.int(.mixedPort)
        port = c.int(.port)
        socksPort = c.int(.socksPort)
        allowLan = c.bool(.allowLan)
        logLevel = c.string(.logLevel)
    }
    enum CodingKeys: String, CodingKey {
        case mode, port
        case mixedPort = "mixed-port"
        case socksPort = "socks-port"
        case allowLan = "allow-lan"
        case logLevel = "log-level"
    }
}

// MARK: - 流量 / 内存 / 日志

public struct TrafficSample: Codable, Sendable, Hashable {
    public var up: Int
    public var down: Int
    public var upTotal: Int
    public var downTotal: Int
    public var time: Date = Date()

    public init(up: Int = 0, down: Int = 0, upTotal: Int = 0, downTotal: Int = 0, time: Date = Date()) {
        self.up = up; self.down = down; self.upTotal = upTotal; self.downTotal = downTotal; self.time = time
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = c.int(.up); down = c.int(.down)
        upTotal = c.int(.upTotal); downTotal = c.int(.downTotal)
        time = Date()
    }
    enum CodingKeys: String, CodingKey { case up, down, upTotal, downTotal }
}

public struct MemorySample: Codable, Sendable {
    public var inuse: Int
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inuse = c.int(.inuse)
    }
    enum CodingKeys: String, CodingKey { case inuse }
}

public struct LogEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var time: Date
    public var level: String
    public var message: String
    public init(time: Date = Date(), level: String, message: String) {
        self.time = time; self.level = level; self.message = message
    }
}

struct RawLog: Decodable, Sendable {
    var type: String
    var payload: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.string(.type); payload = c.string(.payload)
    }
    enum CodingKeys: String, CodingKey { case type, payload }
}

// MARK: - 连接

public struct ConnectionMetadata: Codable, Hashable, Sendable {
    public var network: String
    public var type: String
    public var sourceIP: String
    public var destinationIP: String
    public var sourcePort: String
    public var destinationPort: String
    public var host: String
    public var process: String
    public var processPath: String
    public var dnsMode: String
    public var remoteDestination: String
    public var sniffHost: String
    public var inboundName: String

    public init(network: String = "tcp", type: String = "HTTPS", sourceIP: String = "", destinationIP: String = "",
                sourcePort: String = "", destinationPort: String = "443", host: String = "", process: String = "",
                processPath: String = "", dnsMode: String = "", remoteDestination: String = "",
                sniffHost: String = "", inboundName: String = "") {
        self.network = network; self.type = type; self.sourceIP = sourceIP; self.destinationIP = destinationIP
        self.sourcePort = sourcePort; self.destinationPort = destinationPort; self.host = host
        self.process = process; self.processPath = processPath; self.dnsMode = dnsMode
        self.remoteDestination = remoteDestination; self.sniffHost = sniffHost; self.inboundName = inboundName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = c.string(.network); type = c.string(.type)
        sourceIP = c.string(.sourceIP); destinationIP = c.string(.destinationIP)
        sourcePort = c.flexString(.sourcePort); destinationPort = c.flexString(.destinationPort)
        host = c.string(.host); process = c.string(.process); processPath = c.string(.processPath)
        dnsMode = c.string(.dnsMode); remoteDestination = c.string(.remoteDestination)
        sniffHost = c.string(.sniffHost); inboundName = c.string(.inboundName)
    }
}

public struct ConnectionInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var metadata: ConnectionMetadata
    public var upload: Int
    public var download: Int
    public var start: Date?
    public var chains: [String]
    public var rule: String
    public var rulePayload: String

    public init(id: String, metadata: ConnectionMetadata, upload: Int, download: Int, start: Date?,
                chains: [String], rule: String, rulePayload: String) {
        self.id = id; self.metadata = metadata; self.upload = upload; self.download = download
        self.start = start; self.chains = chains; self.rule = rule; self.rulePayload = rulePayload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        metadata = (try? c.decodeIfPresent(ConnectionMetadata.self, forKey: .metadata)) ?? ConnectionMetadata()
        upload = c.int(.upload); download = c.int(.download)
        start = MihomoDate.parse(c.string(.start))
        chains = c.strings(.chains)
        rule = c.string(.rule); rulePayload = c.string(.rulePayload)
    }

    enum CodingKeys: String, CodingKey { case id, metadata, upload, download, start, chains, rule, rulePayload }
}

public struct ConnectionsSnapshot: Decodable, Sendable {
    public var downloadTotal: Int
    public var uploadTotal: Int
    public var memory: Int
    public var connections: [ConnectionInfo]

    public init(downloadTotal: Int = 0, uploadTotal: Int = 0, memory: Int = 0, connections: [ConnectionInfo] = []) {
        self.downloadTotal = downloadTotal; self.uploadTotal = uploadTotal
        self.memory = memory; self.connections = connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = c.int(.downloadTotal); uploadTotal = c.int(.uploadTotal); memory = c.int(.memory)
        connections = (try? c.decodeIfPresent([ConnectionInfo].self, forKey: .connections)) ?? []
    }
    enum CodingKeys: String, CodingKey { case downloadTotal, uploadTotal, memory, connections }
}

// MARK: - 策略 / 规则

public struct DelayRecord: Codable, Hashable, Sendable {
    public var time: String
    public var delay: Int
    public init(time: String = "", delay: Int) { self.time = time; self.delay = delay }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = c.string(.time); delay = c.int(.delay)
    }
    enum CodingKeys: String, CodingKey { case time, delay }
}

public struct PolicyInfo: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var now: String
    public var all: [String]
    public var history: [DelayRecord]
    public var udp: Bool
    public var id: String { name }

    public init(name: String, type: String, now: String = "", all: [String] = [], history: [DelayRecord] = [], udp: Bool = false) {
        self.name = name; self.type = type; self.now = now; self.all = all; self.history = history; self.udp = udp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name); type = c.string(.type); now = c.string(.now)
        all = c.strings(.all)
        history = (try? c.decodeIfPresent([DelayRecord].self, forKey: .history)) ?? []
        udp = c.bool(.udp)
    }
    enum CodingKeys: String, CodingKey { case name, type, now, all, history, udp }

    /// 最近一次延迟（毫秒），0 表示超时或未测试
    public var lastDelay: Int { history.last?.delay ?? 0 }

    /// 是否为策略组
    public var isGroup: Bool {
        ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].contains(type)
    }
    public var isSelectable: Bool { type == "Selector" }
}

public struct ProxiesResponse: Decodable, Sendable {
    public var proxies: [String: PolicyInfo]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proxies = (try? c.decodeIfPresent([String: PolicyInfo].self, forKey: .proxies)) ?? [:]
    }
    enum CodingKeys: String, CodingKey { case proxies }
}

public struct RuleInfo: Codable, Identifiable, Hashable, Sendable {
    public var index: Int
    public var type: String
    public var payload: String
    public var proxy: String
    public var id: Int { index }
    public init(index: Int, type: String, payload: String, proxy: String) {
        self.index = index; self.type = type; self.payload = payload; self.proxy = proxy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.int(.index); type = c.string(.type); payload = c.string(.payload); proxy = c.string(.proxy)
    }
    enum CodingKeys: String, CodingKey { case index, type, payload, proxy }
}

struct RulesResponse: Decodable {
    var rules: [RuleInfo]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = (try? c.decodeIfPresent([RuleInfo].self, forKey: .rules)) ?? []
        // 索引缺失时按顺序补齐
        for i in list.indices where list[i].index == 0 && i != 0 { list[i].index = i }
        rules = list
    }
    enum CodingKeys: String, CodingKey { case rules }
}
