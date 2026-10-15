import Foundation
import Yams

public enum SubscriptionFormat: String, Codable, Sendable {
    case clashYAML = "Clash YAML"
    case uriList = "分享链接"
    case surge = "Surge 配置"
}

public struct DecodedSubscription: Sendable {
    public var nodes: [ProxyNode]
    public var format: SubscriptionFormat
    /// 无法识别而被跳过的条目数
    public var skipped: Int
}

public enum SubscriptionDecodeError: Error, LocalizedError {
    case empty
    case unrecognized
    case noNodes
    public var errorDescription: String? {
        switch self {
        case .empty: return "订阅内容为空"
        case .unrecognized: return "无法识别订阅格式"
        case .noNodes: return "订阅中没有可用节点"
        }
    }
}

/// 订阅内容解码：Clash YAML、Base64/明文分享链接、Surge 配置
public enum SubscriptionDecoder {
    public static func decode(_ data: Data) throws -> DecodedSubscription {
        guard var text = String(data: data, encoding: .utf8) else { throw SubscriptionDecodeError.unrecognized }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SubscriptionDecodeError.empty }
        return try decode(text: text, allowBase64: true)
    }

    static func decode(text: String, allowBase64: Bool) throws -> DecodedSubscription {
        // 1. Clash YAML
        if text.contains("proxies:") {
            if let result = decodeClash(text), !result.nodes.isEmpty { return result }
        }
        // 2. Surge 配置
        if text.contains("[Proxy]") {
            let profile = SurgeProfileParser.parse(text)
            if !profile.nodes.isEmpty {
                return DecodedSubscription(nodes: profile.nodes, format: .surge, skipped: 0)
            }
        }
        // 3. 分享链接（明文）
        if text.contains("://") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var nodes: [ProxyNode] = []
            var skipped = 0
            for l in lines {
                if let n = NodeURIParser.parse(l) { nodes.append(n) } else { skipped += 1 }
            }
            if !nodes.isEmpty { return DecodedSubscription(nodes: nodes, format: .uriList, skipped: skipped) }
        }
        // 4. Base64 包裹
        if allowBase64, let decoded = NodeURIParser.decodeBase64(text.replacingOccurrences(of: "\n", with: "")) {
            return try decode(text: decoded.trimmingCharacters(in: .whitespacesAndNewlines), allowBase64: false)
        }
        throw SubscriptionDecodeError.noNodes
    }

    private static func decodeClash(_ text: String) -> DecodedSubscription? {
        guard let root = try? Yams.load(yaml: text) as? [String: Any],
              let list = root["proxies"] as? [[String: Any]] else { return nil }
        var nodes: [ProxyNode] = []
        var skipped = 0
        for item in list {
            guard let name = item["name"] as? String, item["type"] != nil, item["server"] != nil else { skipped += 1; continue }
            var fields: [String: JSONValue] = [:]
            for (k, v) in item where k != "name" { fields[k] = JSONValue(any: v) }
            // 端口统一为整数
            if let p = fields["port"]?.intValue { fields["port"] = .int(p) }
            nodes.append(ProxyNode(name: name, fields: fields))
        }
        return DecodedSubscription(nodes: nodes, format: .clashYAML, skipped: skipped)
    }
}
