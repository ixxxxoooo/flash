import Foundation

/// 代理节点：字段使用 mihomo 命名（type/server/port/...），可直接写入 proxies
public struct ProxyNode: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var fields: [String: JSONValue]
    /// 来源订阅名称（本地配置为 nil）
    public var source: String?

    public var id: String { name }
    public var type: String { fields["type"]?.stringValue ?? "unknown" }
    public var server: String { fields["server"]?.stringValue ?? "" }
    public var port: Int { fields["port"]?.intValue ?? 0 }

    public init(name: String, fields: [String: JSONValue], source: String? = nil) {
        self.name = name; self.fields = fields; self.source = source
    }

    /// 输出为 mihomo 的 proxies 条目
    public func toDictionary() -> [String: Any] {
        var d = fields.mapValues { $0.anyValue }
        d["name"] = name
        return d
    }
}

/// 策略组定义（Surge 语义，生成时再解析为 mihomo 的 proxy-groups）
public struct GroupSpec: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    /// select / url-test / fallback / load-balance
    public var type: String
    public var members: [String]
    public var includeAllProxies: Bool
    public var regexFilter: String?
    public var policyPath: String?
    public var url: String?
    public var interval: Int?
    public var tolerance: Int?
    public var timeout: Int?
    public var id: String { name }

    public init(name: String, type: String = "select", members: [String] = [], includeAllProxies: Bool = false,
                regexFilter: String? = nil, policyPath: String? = nil, url: String? = nil,
                interval: Int? = nil, tolerance: Int? = nil, timeout: Int? = nil) {
        self.name = name; self.type = type; self.members = members; self.includeAllProxies = includeAllProxies
        self.regexFilter = regexFilter; self.policyPath = policyPath; self.url = url
        self.interval = interval; self.tolerance = tolerance; self.timeout = timeout
    }
}

/// 规则集提供者（对应 mihomo 的 rule-providers）
public struct RuleProviderSpec: Codable, Hashable, Sendable {
    public var name: String
    /// domain / ipcidr / classical
    public var behavior: String
    public var url: String?
    public var interval: Int
    /// 内联规则（[Ruleset xxx] 小节）
    public var inlineRules: [String]?

    public init(name: String, behavior: String, url: String? = nil, interval: Int = 86400, inlineRules: [String]? = nil) {
        self.name = name; self.behavior = behavior; self.url = url; self.interval = interval; self.inlineRules = inlineRules
    }
}

/// 解析诊断信息
public struct ProfileDiagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable { case info, warning, error }
    public let id = UUID()
    public var line: Int
    public var severity: Severity
    public var message: String
    public init(line: Int, severity: Severity, message: String) {
        self.line = line; self.severity = severity; self.message = message
    }
}

/// #!MANAGED-CONFIG 头信息
public struct ManagedConfigInfo: Codable, Hashable, Sendable {
    public var url: String
    public var interval: Int
    public var strict: Bool
}

/// 单条规则：body 为 mihomo 语法的匹配部分（如 `DOMAIN-SUFFIX,apple.com`、`MATCH`）
public struct RuleSpec: Hashable, Sendable {
    public var body: String
    public var policy: String
    public var noResolve: Bool
    /// 原始行号（用于诊断）
    public var line: Int

    public init(body: String, policy: String, noResolve: Bool = false, line: Int = 0) {
        self.body = body; self.policy = policy; self.noResolve = noResolve; self.line = line
    }

    public var isFinal: Bool { body == "MATCH" }

    /// mihomo 规则文本
    public var text: String {
        if isFinal { return "MATCH,\(policy)" }
        return "\(body),\(policy)" + (noResolve ? ",no-resolve" : "")
    }
}

/// 统一的内部配置模型
public struct Profile: Sendable {
    public var general: [String: String] = [:]
    public var nodes: [ProxyNode] = []
    public var groups: [GroupSpec] = []
    public var rules: [RuleSpec] = []
    public var hosts: [String: String] = [:]
    public var nameserverPolicy: [String: String] = [:]
    public var ruleProviders: [RuleProviderSpec] = []
    /// 内置策略别名（如 `Block = reject`）
    public var policyAliases: [String: String] = [:]
    public var mitmHostnames: [String] = []
    public var managed: ManagedConfigInfo?
    public var diagnostics: [ProfileDiagnostic] = []

    public init() {}

    public var hasFinalRule: Bool { rules.last?.isFinal ?? false }
}

/// 订阅提供的节点集合（供组合器使用）
public struct SubscriptionNodes: Sendable {
    public var name: String
    public var url: String
    public var nodes: [ProxyNode]
    public init(name: String, url: String, nodes: [ProxyNode]) {
        self.name = name; self.url = url; self.nodes = nodes
    }
}
