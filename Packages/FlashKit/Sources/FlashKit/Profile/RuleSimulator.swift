import Foundation

/// 本地规则模拟：输入域名/IP/端口，查看会命中哪条规则（不依赖内核）
public enum RuleSimulator {
    public struct Query: Sendable {
        public var host: String
        public var ip: String?
        public var port: Int?
        public var process: String?
        public var network: String?
        public init(host: String, ip: String? = nil, port: Int? = nil, process: String? = nil, network: String? = nil) {
            self.host = host.lowercased(); self.ip = ip; self.port = port; self.process = process; self.network = network?.lowercased()
        }
    }

    public struct Result: Sendable {
        public var index: Int
        public var rule: RuleSpec
        /// 模拟过程中因缺少数据（GeoIP、规则集内容）而跳过的规则序号
        public var skipped: [Int]
    }

    private enum Outcome { case yes, no, unknown }

    public static func match(rules: [RuleSpec], query: Query) -> Result? {
        var skipped: [Int] = []
        for (i, r) in rules.enumerated() {
            switch evaluate(body: r.body, query: query) {
            case .yes: return Result(index: i, rule: r, skipped: skipped)
            case .unknown: skipped.append(i)
            case .no: continue
            }
        }
        return nil
    }

    private static func evaluate(body: String, query q: Query) -> Outcome {
        let parts = SurgeText.splitTopLevel(body)
        guard let type = parts.first?.uppercased() else { return .no }
        let value = parts.count > 1 ? parts[1] : ""
        switch type {
        case "MATCH": return .yes
        case "DOMAIN": return value.lowercased() == q.host ? .yes : .no
        case "DOMAIN-SUFFIX":
            let v = value.lowercased()
            return (q.host == v || q.host.hasSuffix("." + v)) ? .yes : .no
        case "DOMAIN-KEYWORD": return q.host.contains(value.lowercased()) ? .yes : .no
        case "DOMAIN-WILDCARD": return wildcard(value.lowercased(), q.host) ? .yes : .no
        case "IP-CIDR":
            guard let ip = q.ip else { return .unknown }
            return cidrContains(value, ip) ? .yes : .no
        case "IP-CIDR6", "GEOIP", "IP-ASN", "RULE-SET": return .unknown
        case "DST-PORT":
            guard let p = q.port else { return .unknown }
            return portMatches(value, p) ? .yes : .no
        case "PROCESS-NAME", "PROCESS-PATH":
            guard let proc = q.process else { return .unknown }
            return proc.lowercased() == value.lowercased() ? .yes : .no
        case "NETWORK":
            guard let n = q.network else { return .unknown }
            return n == value.lowercased() ? .yes : .no
        case "AND", "OR", "NOT":
            var inner = value
            guard inner.hasPrefix("("), inner.hasSuffix(")") else { return .unknown }
            inner = String(inner.dropFirst().dropLast())
            let subs = SurgeText.splitTopLevel(inner).map { s -> Outcome in
                let t = s.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("("), t.hasSuffix(")") else { return .unknown }
                return evaluate(body: String(t.dropFirst().dropLast()), query: q)
            }
            switch type {
            case "AND":
                if subs.contains(.no) { return .no }
                return subs.contains(.unknown) ? .unknown : .yes
            case "OR":
                if subs.contains(.yes) { return .yes }
                return subs.contains(.unknown) ? .unknown : .no
            default:
                switch subs.first ?? .unknown {
                case .yes: return .no
                case .no: return .yes
                case .unknown: return .unknown
                }
            }
        default: return .unknown
        }
    }

    private static func wildcard(_ pattern: String, _ text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return text.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }

    private static func portMatches(_ spec: String, _ port: Int) -> Bool {
        for item in spec.split(separator: "/") {
            if let dash = item.firstIndex(of: "-"),
               let lo = Int(item[..<dash]), let hi = Int(item[item.index(after: dash)...]) {
                if (lo...hi).contains(port) { return true }
            } else if Int(item) == port { return true }
        }
        return false
    }

    static func cidrContains(_ cidr: String, _ ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let net = ipv4(String(parts[0])), let addr = ipv4(ip) else { return false }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return (net & mask) == (addr & mask)
    }

    private static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
        return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }
}
