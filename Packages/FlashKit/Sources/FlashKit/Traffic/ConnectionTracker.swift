import Foundation

/// 面向界面的连接记录
public struct ConnectionRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var startedAt: Date
    public var closedAt: Date?
    public var host: String
    public var destinationIP: String
    public var destinationPort: String
    public var sourceIP: String
    public var sourcePort: String
    public var network: String
    public var inboundType: String
    public var process: String
    public var processPath: String
    public var rule: String
    public var rulePayload: String
    /// 策略链，顺序与内核一致：出口节点在前，策略组在后
    public var chains: [String]
    public var upload: Int
    public var download: Int
    public var upSpeed: Int
    public var downSpeed: Int
    public var isActive: Bool

    public init(info: ConnectionInfo, now: Date) {
        let m = info.metadata
        id = info.id
        startedAt = info.start ?? now
        closedAt = nil
        host = !m.host.isEmpty ? m.host : (!m.sniffHost.isEmpty ? m.sniffHost : m.destinationIP)
        destinationIP = m.destinationIP
        destinationPort = m.destinationPort
        sourceIP = m.sourceIP
        sourcePort = m.sourcePort
        network = m.network
        inboundType = m.type
        process = m.process
        processPath = m.processPath
        rule = info.rule
        rulePayload = info.rulePayload
        chains = info.chains
        upload = info.upload
        download = info.download
        upSpeed = 0
        downSpeed = 0
        isActive = true
    }

    public init(id: String, startedAt: Date, closedAt: Date? = nil, host: String, destinationIP: String = "", destinationPort: String = "443",
                sourceIP: String = "127.0.0.1", sourcePort: String = "", network: String = "tcp", inboundType: String = "HTTPS",
                process: String = "", processPath: String = "", rule: String = "Match", rulePayload: String = "",
                chains: [String] = ["DIRECT"], upload: Int = 0, download: Int = 0, upSpeed: Int = 0, downSpeed: Int = 0, isActive: Bool = true) {
        self.id = id; self.startedAt = startedAt; self.closedAt = closedAt; self.host = host
        self.destinationIP = destinationIP; self.destinationPort = destinationPort
        self.sourceIP = sourceIP; self.sourcePort = sourcePort; self.network = network
        self.inboundType = inboundType; self.process = process; self.processPath = processPath
        self.rule = rule; self.rulePayload = rulePayload; self.chains = chains
        self.upload = upload; self.download = download; self.upSpeed = upSpeed; self.downSpeed = downSpeed
        self.isActive = isActive
    }

    /// 最终使用的出口（节点或 DIRECT）
    public var policy: String { chains.first ?? "DIRECT" }
    /// 命中规则的展示文本
    public var ruleText: String { rulePayload.isEmpty ? rule : "\(rule): \(rulePayload)" }
    /// 策略链的展示文本，从策略组指向出口节点
    public var chainText: String { chains.reversed().joined(separator: " → ") }
    public var displayProcess: String { process.isEmpty ? "未知" : process }
    public var duration: TimeInterval { (closedAt ?? Date()).timeIntervalSince(startedAt) }
    public var total: Int { upload + download }
    public var endpoint: String { destinationPort.isEmpty ? host : "\(host):\(destinationPort)" }
}

/// 一次快照对应的字节增量，用于统计聚合
public struct BytesDelta: Sendable {
    public var process: String
    public var host: String
    public var policy: String
    public var up: Int
    public var down: Int
    public var isNew: Bool
}

public struct TrackerUpdate: Sendable {
    public var opened: [ConnectionRecord] = []
    public var closed: [ConnectionRecord] = []
    public var deltas: [BytesDelta] = []
}

/// 连接差分器：把内核的“当前活动连接快照”转换为 新增/更新/关闭 事件，并计算速度
public struct ConnectionTracker: Sendable {
    public private(set) var active: [String: ConnectionRecord] = [:]
    private var lastTick: Date?

    public init() {}

    public mutating func apply(_ snapshot: ConnectionsSnapshot, now: Date = Date()) -> TrackerUpdate {
        var update = TrackerUpdate()
        let dt = max(0.2, lastTick.map { now.timeIntervalSince($0) } ?? 1)
        lastTick = now

        var seen = Set<String>()
        for info in snapshot.connections {
            seen.insert(info.id)
            if var rec = active[info.id] {
                let du = max(0, info.upload - rec.upload)
                let dd = max(0, info.download - rec.download)
                rec.upload = info.upload
                rec.download = info.download
                rec.upSpeed = Int(Double(du) / dt)
                rec.downSpeed = Int(Double(dd) / dt)
                // 内核会在规则匹配后补全进程与链路信息
                if rec.process.isEmpty, !info.metadata.process.isEmpty {
                    rec.process = info.metadata.process; rec.processPath = info.metadata.processPath
                }
                rec.chains = info.chains.isEmpty ? rec.chains : info.chains
                rec.rule = info.rule; rec.rulePayload = info.rulePayload
                active[info.id] = rec
                if du > 0 || dd > 0 {
                    update.deltas.append(BytesDelta(process: rec.displayProcess, host: rec.host, policy: rec.policy, up: du, down: dd, isNew: false))
                }
            } else {
                let rec = ConnectionRecord(info: info, now: now)
                active[info.id] = rec
                update.opened.append(rec)
                update.deltas.append(BytesDelta(process: rec.displayProcess, host: rec.host, policy: rec.policy,
                                                up: rec.upload, down: rec.download, isNew: true))
            }
        }

        for (id, var rec) in active where !seen.contains(id) {
            rec.isActive = false
            rec.closedAt = now
            rec.upSpeed = 0
            rec.downSpeed = 0
            update.closed.append(rec)
            active[id] = nil
        }
        return update
    }

    public mutating func reset() { active = [:]; lastTick = nil }
}

/// 把主机名归并到可注册域名（近似算法），用于统计页的“按域名”聚合
public func registrableDomain(_ host: String) -> String {
    let h = host.lowercased()
    if h.isEmpty { return "未知" }
    // IP 地址原样返回
    if h.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil || h.contains(":") { return h }
    let labels = h.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return h }
    let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac"]
    let tld = labels[labels.count - 1], sld = labels[labels.count - 2]
    if tld.count == 2, secondLevel.contains(sld), labels.count >= 3 {
        return labels.suffix(3).joined(separator: ".")
    }
    return labels.suffix(2).joined(separator: ".")
}
