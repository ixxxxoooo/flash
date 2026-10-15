import Foundation

/// MitM / 重写 / 脚本相关的配置模型与 Surge 语法解析
/// @author ygw

// MARK: 主机名匹配

/// `[MITM] hostname` 中的一项，支持通配符 `*` / `?`、`host:port`、前缀 `-` 表示排除
public struct MitMHostPattern: Sendable, Hashable {
    public var host: String
    public var port: Int?
    public var exclude: Bool

    public init(host: String, port: Int? = nil, exclude: Bool = false) {
        self.host = host.lowercased(); self.port = port; self.exclude = exclude
    }

    /// 解析单个条目，例如 `*.example.com`、`-api.example.com`、`example.com:8443`
    /// - Parameter text: 原始文本
    /// - Returns: 解析结果，空文本返回 nil
    public static func parse(_ text: String) -> MitMHostPattern? {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var exclude = false
        if t.hasPrefix("-") { exclude = true; t.removeFirst() }
        var port: Int?
        if let idx = t.lastIndex(of: ":"), let p = Int(t[t.index(after: idx)...]), !t.contains("]") {
            port = p
            t = String(t[..<idx])
        }
        guard !t.isEmpty else { return nil }
        return MitMHostPattern(host: t, port: port, exclude: exclude)
    }

    /// 是否匹配主机与端口（未指定端口时默认只匹配 443）
    /// - Parameters:
    ///   - host: 目标主机名
    ///   - port: 目标端口
    public func matches(host target: String, port targetPort: Int) -> Bool {
        if let port { if port != targetPort { return false } } else if targetPort != 443 && targetPort != 80 { return false }
        return Self.glob(host, target.lowercased())
    }

    /// 仅按主机名匹配（用于生成内核规则）
    func matchesHostOnly(_ target: String) -> Bool { Self.glob(host, target.lowercased()) }

    /// 简单通配匹配：`*` 匹配任意长度，`?` 匹配单个字符
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: 重写规则

/// URL 重写动作
public enum URLRewriteAction: Sendable, Hashable {
    public enum RejectKind: String, Sendable { case plain, ok200 = "reject-200", img = "reject-img", dict = "reject-dict", array = "reject-array", noContent = "reject-tinygif" }
    case reject(RejectKind)
    /// 302 / 307 重定向到新地址（`$1` 等捕获组在匹配时展开）
    case redirect(status: Int, to: String)
    /// 直接改写请求头中的 URL（不通知客户端）
    case header(to: String)
}

/// `[URL Rewrite]`：`regex replacement type`
public struct URLRewriteRule: Sendable, Hashable {
    public var pattern: String
    public var action: URLRewriteAction
    public init(pattern: String, action: URLRewriteAction) { self.pattern = pattern; self.action = action }
}

/// Header 重写作用方向
public enum RewriteDirection: String, Sendable { case request = "http-request", response = "http-response" }

/// Header 重写动作
public enum HeaderRewriteAction: Sendable, Hashable {
    case add(name: String, value: String)
    case del(name: String)
    case replace(name: String, value: String)
    case replaceRegex(name: String, regex: String, replacement: String)
}

/// `[Header Rewrite]`：`http-request|http-response regex header-xxx ...`
public struct HeaderRewriteRule: Sendable, Hashable {
    public var direction: RewriteDirection
    public var pattern: String
    public var action: HeaderRewriteAction
    public init(direction: RewriteDirection, pattern: String, action: HeaderRewriteAction) {
        self.direction = direction; self.pattern = pattern; self.action = action
    }
}

/// `[Map Local]`：用本地内容直接响应
public struct MapLocalRule: Sendable, Hashable {
    public enum DataType: String, Sendable { case file, text, base64, tinyGif = "tiny-gif" }
    public var pattern: String
    public var dataType: DataType
    public var data: String
    public var statusCode: Int
    public var headers: [String: String]
    public init(pattern: String, dataType: DataType, data: String, statusCode: Int = 200, headers: [String: String] = [:]) {
        self.pattern = pattern; self.dataType = dataType; self.data = data; self.statusCode = statusCode; self.headers = headers
    }
}

/// `[Script]`：脚本规则
public struct ScriptRule: Sendable, Hashable {
    public var name: String
    public var direction: RewriteDirection
    public var pattern: String
    /// 本地路径或 http(s) 地址
    public var scriptPath: String
    public var requiresBody: Bool
    public var maxSize: Int
    public var timeout: Int
    public var argument: String
    public var binaryBodyMode: Bool
    public init(name: String, direction: RewriteDirection, pattern: String, scriptPath: String, requiresBody: Bool = false,
                maxSize: Int = 131_072, timeout: Int = 10, argument: String = "", binaryBodyMode: Bool = false) {
        self.name = name; self.direction = direction; self.pattern = pattern; self.scriptPath = scriptPath
        self.requiresBody = requiresBody; self.maxSize = maxSize; self.timeout = timeout
        self.argument = argument; self.binaryBodyMode = binaryBodyMode
    }
}

// MARK: 汇总配置

/// 一份配置中与 MitM 相关的全部内容
public struct MitMConfig: Sendable, Hashable {
    public var hostPatterns: [MitMHostPattern] = []
    public var urlRewrites: [URLRewriteRule] = []
    public var headerRewrites: [HeaderRewriteRule] = []
    public var mapLocals: [MapLocalRule] = []
    public var scripts: [ScriptRule] = []
    public var skipServerCertVerify = false

    public init() {}

    /// 需要经过 MitM 引擎的主机名模式（排除项除外）
    public var includePatterns: [MitMHostPattern] { hostPatterns.filter { !$0.exclude } }

    /// 是否存在任何可生效的内容
    public var isEmpty: Bool {
        includePatterns.isEmpty && urlRewrites.isEmpty && headerRewrites.isEmpty && mapLocals.isEmpty && scripts.isEmpty
    }

    /// 判断某个连接是否应当被解密
    /// - Parameters:
    ///   - host: 目标主机
    ///   - port: 目标端口
    public func shouldIntercept(host: String, port: Int) -> Bool {
        if hostPatterns.contains(where: { $0.exclude && $0.matches(host: host, port: port) }) { return false }
        return hostPatterns.contains { !$0.exclude && $0.matches(host: host, port: port) }
    }

    /// 合并：`other` 的规则优先放在前面
    public func merged(with other: MitMConfig) -> MitMConfig {
        var r = self
        var seen = Set<MitMHostPattern>()
        r.hostPatterns = (other.hostPatterns + hostPatterns).filter { seen.insert($0).inserted }
        r.urlRewrites = other.urlRewrites + urlRewrites
        r.headerRewrites = other.headerRewrites + headerRewrites
        r.mapLocals = other.mapLocals + mapLocals
        r.scripts = other.scripts + scripts
        r.skipServerCertVerify = skipServerCertVerify || other.skipServerCertVerify
        return r
    }

    // MARK: 解析

    /// 解析 `[MITM]` 段的一行
    public mutating func parseMitMLine(_ line: String) {
        guard let (k, v) = SurgeText.keyValueLoose(line) else { return }
        switch k {
        case "hostname":
            let items = v.split(separator: ",").compactMap { MitMHostPattern.parse(String($0)) }
            hostPatterns += items
        case "skip-server-cert-verify":
            skipServerCertVerify = SurgeText.bool(v) ?? false
        default: break
        }
    }

    /// 解析 `[URL Rewrite]` 的一行，失败返回原因
    @discardableResult
    public mutating func parseURLRewriteLine(_ line: String) -> String? {
        let t = SurgeText.tokens(line)
        guard t.count >= 3 else { return "URL Rewrite 需要 3 段：正则 替换 类型" }
        let type = t[2].lowercased()
        switch type {
        case "reject": urlRewrites.append(.init(pattern: t[0], action: .reject(.plain)))
        case "reject-200": urlRewrites.append(.init(pattern: t[0], action: .reject(.ok200)))
        case "reject-img": urlRewrites.append(.init(pattern: t[0], action: .reject(.img)))
        case "reject-dict": urlRewrites.append(.init(pattern: t[0], action: .reject(.dict)))
        case "reject-array": urlRewrites.append(.init(pattern: t[0], action: .reject(.array)))
        case "reject-tinygif": urlRewrites.append(.init(pattern: t[0], action: .reject(.noContent)))
        case "302", "307": urlRewrites.append(.init(pattern: t[0], action: .redirect(status: Int(type) ?? 302, to: t[1])))
        case "header": urlRewrites.append(.init(pattern: t[0], action: .header(to: t[1])))
        default: return "未知的 URL Rewrite 类型：\(t[2])"
        }
        return nil
    }

    /// 解析 `[Header Rewrite]` 的一行
    @discardableResult
    public mutating func parseHeaderRewriteLine(_ line: String) -> String? {
        let t = SurgeText.tokens(line)
        guard t.count >= 4, let dir = RewriteDirection(rawValue: t[0].lowercased()) else {
            return "Header Rewrite 格式：http-request|http-response 正则 动作 参数"
        }
        let action: HeaderRewriteAction
        switch t[2].lowercased() {
        case "header-add" where t.count >= 5: action = .add(name: t[3], value: t[4...].joined(separator: " "))
        case "header-del": action = .del(name: t[3])
        case "header-replace" where t.count >= 5: action = .replace(name: t[3], value: t[4...].joined(separator: " "))
        case "header-replace-regex" where t.count >= 6: action = .replaceRegex(name: t[3], regex: t[4], replacement: t[5])
        default: return "未知或参数不足的 Header Rewrite 动作：\(t[2])"
        }
        headerRewrites.append(.init(direction: dir, pattern: t[1], action: action))
        return nil
    }

    /// 解析 `[Map Local]` 的一行：`正则 data="..." status-code=200 header="A:B|C:D" data-type=text`
    @discardableResult
    public mutating func parseMapLocalLine(_ line: String) -> String? {
        // data="..." 内部允许出现双引号（Surge 模块常见写法），先用正则整段取出
        var rest = line
        var quotedData: String?
        if let re = try? NSRegularExpression(pattern: #"\sdata="(.*?)"(?=\s+[A-Za-z-]+=|\s*$)"#, options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let whole = Range(m.range, in: rest), let inner = Range(m.range(at: 1), in: rest) {
            quotedData = String(rest[inner]).replacingOccurrences(of: "\\\"", with: "\"")
            rest.replaceSubrange(whole, with: "")
        }
        let t = SurgeText.tokens(rest)
        guard t.count >= 2 || quotedData != nil else { return "Map Local 需要 正则 与 data 参数" }
        var type = MapLocalRule.DataType.file
        var data = quotedData ?? "", status = 200
        var headers: [String: String] = [:]
        for item in t.dropFirst() {
            guard let (k, v) = SurgeText.keyValue(item) else { continue }
            switch k {
            case "data-type": type = MapLocalRule.DataType(rawValue: v.lowercased()) ?? .file
            case "data": if quotedData == nil { data = v }
            case "status-code": status = Int(v) ?? 200
            case "header":
                for pair in v.split(separator: "|") {
                    if let idx = pair.firstIndex(of: ":") {
                        headers[String(pair[..<idx]).trimmingCharacters(in: .whitespaces)] =
                            String(pair[pair.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            default: break
            }
        }
        if type != .tinyGif && data.isEmpty { return "Map Local 缺少 data 参数" }
        mapLocals.append(.init(pattern: t[0], dataType: type, data: data, statusCode: status, headers: headers))
        return nil
    }

    /// 解析 `[Script]` 的一行：`name = type=http-response, pattern=..., script-path=...`
    @discardableResult
    public mutating func parseScriptLine(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return "Script 缺少名称" }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces)
        var kv: [String: String] = [:]
        for part in SurgeText.splitTopLevel(String(line[line.index(after: eq)...])) {
            if let (k, v) = SurgeText.keyValue(part) { kv[k.lowercased()] = v }
        }
        guard let type = kv["type"], let dir = RewriteDirection(rawValue: type.lowercased()) else {
            return "脚本「\(name)」类型 \(kv["type"] ?? "?") 暂不支持（仅支持 http-request / http-response）"
        }
        guard let pattern = kv["pattern"], let path = kv["script-path"] else { return "脚本「\(name)」缺少 pattern 或 script-path" }
        scripts.append(.init(name: name, direction: dir, pattern: pattern, scriptPath: path,
                             requiresBody: SurgeText.bool(kv["requires-body"]) ?? false,
                             maxSize: Int(kv["max-size"] ?? "") ?? 131_072,
                             timeout: Int(kv["timeout"] ?? "") ?? 10,
                             argument: kv["argument"] ?? "",
                             binaryBodyMode: SurgeText.bool(kv["binary-body-mode"]) ?? false))
        return nil
    }
}

// MARK: 文本工具扩展

extension SurgeText {
    /// 按空白拆分并保留引号内的空格；`key="a b"` 这样的片段保持完整（引号保留，交给 keyValue 去引号）
    public static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for c in s {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == " " || c == "\t" {
                if !current.isEmpty { result.append(unquoteWhole(current)); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(unquoteWhole(current)) }
        return result
    }

    /// 仅当整段被引号包裹时去引号；`key="v"` 形式保持原样
    private static func unquoteWhole(_ s: String) -> String {
        if let f = s.first, f == "\"" || f == "'" { return unquote(s) }
        return s
    }

    /// 宽松的 `key = value` 解析（key 可含空格两侧）
    public static func keyValueLoose(_ s: String) -> (key: String, value: String)? {
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let key = s[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let value = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }
}
