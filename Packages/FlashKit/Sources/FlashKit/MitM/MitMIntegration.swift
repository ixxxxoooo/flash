import Foundation

/// MitM 与 mihomo 的衔接约定
/// @author ygw
public enum MitMLink {
    /// mihomo 中指向 MitM 引擎的出站名称
    public static let proxyName = "FlashMitM"
    /// mihomo 中供引擎上游使用的 SOCKS 入站名称
    public static let upstreamInboundName = "mitm-up"

    /// 生成 mihomo 规则：命中 MitM 主机名（且不是引擎自己的上游流量）的连接交给引擎
    /// - Parameter patterns: `[MITM] hostname` 的正向条目
    /// - Returns: 规则文本列表（应放在所有规则的最前面）
    public static func rules(for patterns: [MitMHostPattern]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for p in patterns where !p.exclude {
            let hostRule = (p.host.contains("*") || p.host.contains("?")) ? "DOMAIN-WILDCARD,\(p.host)" : "DOMAIN,\(p.host)"
            var parts = ["(\(hostRule))", "(NOT,((IN-NAME,\(upstreamInboundName))))"]
            if let port = p.port {
                parts.append("(DST-PORT,\(port))")
            } else {
                parts.append("(OR,((DST-PORT,443),(DST-PORT,80)))")
            }
            let rule = "AND,(\(parts.joined(separator: ","))),\(proxyName)"
            if seen.insert(rule).inserted { out.append(rule) }
        }
        return out
    }

    /// 合并引擎两跳连接：把上游（mitm-up 入站）连接的真实分流信息写回第一跳，并隐藏上游连接
    /// - Parameter snapshot: 内核连接快照
    /// - Returns: 处理后的快照；没有 MitM 连接时原样返回
    public static func mergeHops(_ snapshot: ConnectionsSnapshot) -> ConnectionsSnapshot {
        guard snapshot.connections.contains(where: { $0.metadata.inboundName == upstreamInboundName }) else { return snapshot }
        var upstream = snapshot.connections.filter { $0.metadata.inboundName == upstreamInboundName }
        var result = snapshot
        result.connections = snapshot.connections.compactMap { conn in
            if conn.metadata.inboundName == upstreamInboundName { return nil }
            guard conn.chains.first == proxyName || conn.chains.contains(proxyName) else { return conn }
            let host = !conn.metadata.host.isEmpty ? conn.metadata.host : conn.metadata.sniffHost
            let candidates = upstream.enumerated().filter { _, u in
                let h = !u.metadata.host.isEmpty ? u.metadata.host : u.metadata.sniffHost
                return h.caseInsensitiveCompare(host) == .orderedSame || u.metadata.destinationIP == conn.metadata.destinationIP
            }
            let start = conn.start ?? .distantPast
            guard let best = candidates.min(by: { abs(($0.element.start ?? .distantPast).timeIntervalSince(start)) < abs(($1.element.start ?? .distantPast).timeIntervalSince(start)) }) else {
                return conn
            }
            var merged = conn
            merged.chains = best.element.chains
            merged.rule = best.element.rule
            merged.rulePayload = best.element.rulePayload
            upstream.remove(at: best.offset)
            return merged
        }
        return result
    }
}
