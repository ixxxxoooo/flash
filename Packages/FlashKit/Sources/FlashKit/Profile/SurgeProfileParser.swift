import Foundation

/// `#!include` 解析回调：传入路径或 URL，返回文本内容
public typealias IncludeResolver = (String) -> String?

/// Surge 风格配置文本解析器（支持常用子集），输出统一的 Profile
public enum SurgeProfileParser {
    private struct Line { var no: Int; var text: String }

    public static func parse(_ text: String, resolver: IncludeResolver? = nil) -> Profile {
        var profile = Profile()
        let lines = expand(text, resolver: resolver, depth: 0, diagnostics: &profile.diagnostics)

        var section = ""
        var sectionTitle = ""
        var unsupportedReported = Set<String>()
        var ruleSetBuffer: [String: [String]] = [:]

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#!MANAGED-CONFIG") {
                profile.managed = parseManaged(trimmed)
                continue
            }
            if trimmed.hasPrefix("#!") || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") { continue }

            let body = SurgeText.stripInlineComment(trimmed)
            if body.isEmpty { continue }

            if body.hasPrefix("["), body.hasSuffix("]") {
                sectionTitle = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                section = sectionTitle.lowercased()
                continue
            }

            switch section {
            case "general":
                if let (k, v) = splitAssign(body) { profile.general[k] = v }
            case "proxy":
                parseProxyLine(body, no: line.no, into: &profile)
            case "proxy group":
                parseGroupLine(body, no: line.no, into: &profile)
            case "rule":
                parseRuleLine(body, no: line.no, into: &profile)
            case "host":
                parseHostLine(body, no: line.no, into: &profile)
            case "mitm":
                if let (k, v) = splitAssign(body), k == "hostname" {
                    profile.mitmHostnames = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                if unsupportedReported.insert("mitm").inserted {
                    profile.diagnostics.append(.init(line: line.no, severity: .info, message: "[MITM] 已记录主机名，HTTPS 解密将在后续版本提供"))
                }
            default:
                if section.hasPrefix("ruleset ") {
                    let name = String(sectionTitle.dropFirst("ruleset ".count)).trimmingCharacters(in: .whitespaces)
                    ruleSetBuffer[name, default: []].append(body)
                } else if !section.isEmpty, unsupportedReported.insert(section).inserted {
                    profile.diagnostics.append(.init(line: line.no, severity: .info,
                                                     message: "[\(sectionTitle)] 暂不支持，已保留但不会生效"))
                }
            }
        }

        for (name, rules) in ruleSetBuffer {
            profile.ruleProviders.append(RuleProviderSpec(name: name, behavior: "classical", inlineRules: rules))
        }
        return profile
    }

    // MARK: include 展开

    private static func expand(_ text: String, resolver: IncludeResolver?, depth: Int, diagnostics: inout [ProfileDiagnostic]) -> [Line] {
        var out: [Line] = []
        var currentSection = ""
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (idx, l) in raw.enumerated() {
            let no = idx + 1
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast()).lowercased()
            }
            if trimmed.lowercased().hasPrefix("#!include") {
                let rest = trimmed.dropFirst("#!include".count).trimmingCharacters(in: .whitespaces)
                guard depth < 4 else {
                    diagnostics.append(.init(line: no, severity: .warning, message: "#!include 嵌套过深，已忽略"))
                    continue
                }
                for target in rest.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !target.isEmpty {
                    guard let included = resolver?(target) else {
                        diagnostics.append(.init(line: no, severity: .warning, message: "无法读取 #!include 目标: \(target)"))
                        continue
                    }
                    let sub = expand(included, resolver: resolver, depth: depth + 1, diagnostics: &diagnostics)
                    out.append(contentsOf: filterSection(sub, section: currentSection, at: no))
                }
                continue
            }
            out.append(Line(no: no, text: l))
        }
        return out
    }

    /// 被引用文件若带有小节声明，则只取与当前小节同名的内容；否则整体采用
    private static func filterSection(_ lines: [Line], section: String, at no: Int) -> [Line] {
        let hasHeaders = lines.contains { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        guard hasHeaders else { return lines.map { Line(no: no, text: $0.text) } }
        var result: [Line] = []
        var active = false
        for l in lines {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]") {
                active = String(t.dropFirst().dropLast()).lowercased() == section
                continue
            }
            if active { result.append(Line(no: no, text: l.text)) }
        }
        return result
    }

    private static func parseManaged(_ line: String) -> ManagedConfigInfo? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var info = ManagedConfigInfo(url: parts[1], interval: 86400, strict: false)
        for p in parts.dropFirst(2) {
            if let (k, v) = SurgeText.keyValue(p) {
                if k == "interval" { info.interval = Int(v) ?? 86400 }
                if k == "strict" { info.strict = SurgeText.bool(v) ?? false }
            }
        }
        return info
    }

    private static func splitAssign(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : (k, v)
    }

    // MARK: [Proxy]

    private static func parseProxyLine(_ line: String, no: Int, into profile: inout Profile) {
        guard let (name, rest) = splitAssign(line) else {
            profile.diagnostics.append(.init(line: no, severity: .error, message: "节点格式错误，应为 `名称 = 类型, 服务器, 端口, ...`"))
            return
        }
        let parts = SurgeText.splitTopLevel(rest)
        let type = parts[0].lowercased()
        var positional: [String] = []
        var kv: [String: String] = [:]
        for p in parts.dropFirst() {
            if let (k, v) = SurgeText.keyValue(p) { kv[k] = v } else { positional.append(SurgeText.unquote(p)) }
        }

        // 内置策略别名
        if ["direct", "reject", "reject-drop", "reject-no-drop", "reject-tinygif"].contains(type) {
            profile.policyAliases[name] = type.hasPrefix("reject") ? "REJECT" : "DIRECT"
            return
        }

        guard let node = convertProxy(name: name, type: type, positional: positional, kv: kv, no: no, diagnostics: &profile.diagnostics) else { return }
        profile.nodes.append(node)
    }

    static func convertProxy(name: String, type: String, positional: [String], kv: [String: String],
                             no: Int, diagnostics: inout [ProfileDiagnostic]) -> ProxyNode? {
        func bad(_ msg: String) -> ProxyNode? {
            diagnostics.append(.init(line: no, severity: .error, message: "节点 \(name): \(msg)"))
            return nil
        }
        let supported: Set<String> = ["http", "https", "socks5", "socks5-tls", "ss", "vmess", "trojan", "hysteria2", "tuic", "tuic-v5", "snell", "anytls"]
        guard supported.contains(type) else {
            diagnostics.append(.init(line: no, severity: .warning, message: "节点 \(name): 暂不支持类型 \(type)，已跳过"))
            return nil
        }
        guard positional.count >= 2, let port = Int(positional[1]) else { return bad("缺少服务器或端口") }
        let server = positional[0]
        var f: [String: JSONValue] = ["server": .string(server), "port": .int(port)]

        func flag(_ key: String) -> Bool? { SurgeText.bool(kv[key]) }
        func applyCommon() {
            if let v = flag("skip-cert-verify") { f["skip-cert-verify"] = .bool(v) }
            if let v = kv["sni"], !v.isEmpty { f["sni"] = .string(v) }
            if let v = flag("tfo") { f["tfo"] = .bool(v) }
            if let v = kv["underlying-proxy"] { f["dialer-proxy"] = .string(v) }
            if let v = flag("udp-relay") { f["udp"] = .bool(v) }
        }
        func applyWebSocket() {
            guard flag("ws") == true else { return }
            f["network"] = "ws"
            var opts: [String: JSONValue] = ["path": .string(kv["ws-path"] ?? "/")]
            if let h = kv["ws-headers"], !h.isEmpty {
                var headers: [String: JSONValue] = [:]
                for item in h.split(separator: "|") {
                    let pair = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if pair.count == 2 { headers[pair[0]] = .string(pair[1]) }
                }
                if !headers.isEmpty { opts["headers"] = .object(headers) }
            }
            f["ws-opts"] = .object(opts)
        }

        switch type {
        case "http", "https":
            f["type"] = "http"
            if positional.count >= 4 { f["username"] = .string(positional[2]); f["password"] = .string(positional[3]) }
            if type == "https" { f["tls"] = true }
            applyCommon()
        case "socks5", "socks5-tls":
            f["type"] = "socks5"
            if positional.count >= 4 { f["username"] = .string(positional[2]); f["password"] = .string(positional[3]) }
            if type == "socks5-tls" { f["tls"] = true }
            applyCommon()
        case "ss":
            f["type"] = "ss"
            guard let method = kv["encrypt-method"], let pwd = kv["password"] else { return bad("Shadowsocks 缺少 encrypt-method 或 password") }
            f["cipher"] = .string(method); f["password"] = .string(pwd)
            if let obfs = kv["obfs"] {
                f["plugin"] = "obfs"
                var o: [String: JSONValue] = ["mode": .string(obfs)]
                if let h = kv["obfs-host"] { o["host"] = .string(h) }
                f["plugin-opts"] = .object(o)
            }
            if kv["shadow-tls-password"] != nil {
                diagnostics.append(.init(line: no, severity: .warning, message: "节点 \(name): 暂不支持 Shadow TLS，该参数已忽略"))
            }
            applyCommon()
        case "vmess":
            f["type"] = "vmess"
            guard let uuid = kv["username"] else { return bad("VMess 缺少 username(UUID)") }
            f["uuid"] = .string(uuid); f["alterId"] = 0
            f["cipher"] = .string(kv["encrypt-method"] ?? "auto")
            if flag("tls") == true { f["tls"] = true; if let sni = kv["sni"] { f["servername"] = .string(sni) } }
            applyWebSocket()
            applyCommon()
            f["sni"] = nil
        case "trojan":
            f["type"] = "trojan"
            guard let pwd = kv["password"] else { return bad("Trojan 缺少 password") }
            f["password"] = .string(pwd)
            applyWebSocket()
            applyCommon()
        case "hysteria2":
            f["type"] = "hysteria2"
            guard let pwd = kv["password"] else { return bad("Hysteria2 缺少 password") }
            f["password"] = .string(pwd)
            if let d = kv["download-bandwidth"] { f["down"] = .string("\(d) Mbps") }
            applyCommon()
        case "tuic", "tuic-v5":
            f["type"] = "tuic"
            if let token = kv["token"] { f["token"] = .string(token) }
            if let uuid = kv["uuid"] { f["uuid"] = .string(uuid) }
            if let pwd = kv["password"] { f["password"] = .string(pwd) }
            if let alpn = kv["alpn"] { f["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
            f["udp-relay-mode"] = "native"
            f["congestion-controller"] = "bbr"
            applyCommon()
        case "snell":
            f["type"] = "snell"
            guard let psk = kv["psk"] else { return bad("Snell 缺少 psk") }
            f["psk"] = .string(psk)
            if let v = kv["version"], let n = Int(v) { f["version"] = .int(n) }
            if let obfs = kv["obfs"] {
                var o: [String: JSONValue] = ["mode": .string(obfs)]
                if let h = kv["obfs-host"] { o["host"] = .string(h) }
                f["obfs-opts"] = .object(o)
            }
            applyCommon()
        case "anytls":
            f["type"] = "anytls"
            guard let pwd = kv["password"] else { return bad("AnyTLS 缺少 password") }
            f["password"] = .string(pwd)
            applyCommon()
        default:
            diagnostics.append(.init(line: no, severity: .warning, message: "节点 \(name): 暂不支持类型 \(type)，已跳过"))
            return nil
        }
        return ProxyNode(name: name, fields: f)
    }

    // MARK: [Proxy Group]

    private static func parseGroupLine(_ line: String, no: Int, into profile: inout Profile) {
        guard let (name, rest) = splitAssign(line) else {
            profile.diagnostics.append(.init(line: no, severity: .error, message: "策略组格式错误，应为 `名称 = 类型, 成员...`"))
            return
        }
        let parts = SurgeText.splitTopLevel(rest)
        var type = parts[0].lowercased()
        var spec = GroupSpec(name: name)
        switch type {
        case "select", "url-test", "fallback", "load-balance": break
        case "smart":
            type = "url-test"
            profile.diagnostics.append(.init(line: no, severity: .info, message: "策略组 \(name): smart 已降级为 url-test"))
        case "subnet", "ssid":
            type = "select"
            profile.diagnostics.append(.init(line: no, severity: .info, message: "策略组 \(name): subnet 已降级为 select"))
        default:
            profile.diagnostics.append(.init(line: no, severity: .warning, message: "策略组 \(name): 暂不支持类型 \(type)，按 select 处理"))
            type = "select"
        }
        spec.type = type
        for p in parts.dropFirst() {
            if let (k, v) = SurgeText.keyValue(p) {
                switch k {
                case "include-all-proxies": spec.includeAllProxies = SurgeText.bool(v) ?? false
                case "policy-regex-filter": spec.regexFilter = v
                case "policy-path": spec.policyPath = v
                case "url": spec.url = v
                case "interval", "update-interval": spec.interval = Int(v)
                case "tolerance": spec.tolerance = Int(v)
                case "timeout": spec.timeout = Int(v)
                default: break
                }
            } else if !p.isEmpty {
                spec.members.append(SurgeText.unquote(p))
            }
        }
        profile.groups.append(spec)
    }

    // MARK: [Rule]

    private static func parseRuleLine(_ line: String, no: Int, into profile: inout Profile) {
        let parts = SurgeText.splitTopLevel(line).map { SurgeText.unquote($0) }
        guard let first = parts.first else { return }
        let type = first.uppercased()

        if type == "FINAL" {
            guard parts.count >= 2 else {
                profile.diagnostics.append(.init(line: no, severity: .error, message: "FINAL 规则缺少策略"))
                return
            }
            profile.rules.append(RuleSpec(body: "MATCH", policy: normalizePolicy(parts[1], no: no, diagnostics: &profile.diagnostics), line: no))
            return
        }
        guard parts.count >= 3 else {
            profile.diagnostics.append(.init(line: no, severity: .error, message: "规则格式错误，应为 `类型,值,策略`"))
            return
        }
        let value = parts[1]
        let policy = normalizePolicy(parts[2], no: no, diagnostics: &profile.diagnostics)
        let flags = parts.dropFirst(3).map { $0.lowercased() }
        let noResolve = flags.contains("no-resolve")

        var body: String?
        switch type {
        case "RULE-SET", "DOMAIN-SET":
            let behavior = type == "DOMAIN-SET" ? "domain" : "classical"
            if value.hasPrefix("http://") || value.hasPrefix("https://") {
                let name = (type == "DOMAIN-SET" ? "ds-" : "rs-") + SurgeText.stableHash(value)
                if !profile.ruleProviders.contains(where: { $0.name == name }) {
                    var interval = 86400
                    for f in parts.dropFirst(3) { if let (k, v) = SurgeText.keyValue(f), k == "update-interval", let n = Int(v), n > 0 { interval = n } }
                    profile.ruleProviders.append(RuleProviderSpec(name: name, behavior: behavior, url: value, interval: interval))
                }
                body = "RULE-SET,\(name)"
            } else {
                body = "RULE-SET,\(value)"   // 引用 [Ruleset xxx] 或内置 LAN，生成阶段再校验
            }
        case "AND", "OR", "NOT":
            body = convertLogical(type: type, value: value, no: no, diagnostics: &profile.diagnostics)
        default:
            body = convertSimple(type: type, value: value, no: no, diagnostics: &profile.diagnostics)
        }
        guard let body else { return }
        profile.rules.append(RuleSpec(body: body, policy: policy, noResolve: noResolve, line: no))
    }

    private static func normalizePolicy(_ raw: String, no: Int, diagnostics: inout [ProfileDiagnostic]) -> String {
        switch raw.uppercased() {
        case "REJECT-TINYGIF", "REJECT-NO-DROP": return "REJECT"
        case "REJECT-DROP": return "REJECT-DROP"
        case "DIRECT", "REJECT": return raw.uppercased()
        default: return raw
        }
    }

    /// 将单个匹配条件转换为 mihomo 语法（不含策略）
    static func convertSimple(type: String, value: String, no: Int, diagnostics: inout [ProfileDiagnostic]) -> String? {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "IP-CIDR", "IP-CIDR6", "IP-ASN", "SRC-PORT", "IN-PORT":
            return "\(type),\(value)"
        case "GEOIP": return "GEOIP,\(value.uppercased())"
        case "DEST-PORT": return "DST-PORT,\(value)"
        case "PROCESS-NAME":
            let wildcard = value.contains("*")
            if value.contains("/") { return (wildcard ? "PROCESS-PATH-WILDCARD," : "PROCESS-PATH,") + value }
            return (wildcard ? "PROCESS-NAME-WILDCARD," : "PROCESS-NAME,") + value
        case "SRC-IP": return "SRC-IP-CIDR,\(value.contains("/") ? value : value + "/32")"
        case "PROTOCOL":
            let v = value.uppercased()
            if v == "TCP" || v == "UDP" { return "NETWORK,\(v.lowercased())" }
            diagnostics.append(.init(line: no, severity: .warning, message: "PROTOCOL,\(value) 暂不支持，已跳过该规则"))
            return nil
        default:
            diagnostics.append(.init(line: no, severity: .warning, message: "规则类型 \(type) 暂不支持，已跳过该规则"))
            return nil
        }
    }

    /// AND / OR / NOT：`((TYPE,value),(TYPE,value))`
    static func convertLogical(type: String, value: String, no: Int, diagnostics: inout [ProfileDiagnostic]) -> String? {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("("), inner.hasSuffix(")") else {
            diagnostics.append(.init(line: no, severity: .error, message: "\(type) 规则的条件必须以括号包裹"))
            return nil
        }
        inner = String(inner.dropFirst().dropLast())
        var converted: [String] = []
        for item in SurgeText.splitTopLevel(inner) {
            var t = item.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("("), t.hasSuffix(")") else { return nil }
            t = String(t.dropFirst().dropLast())
            let p = SurgeText.splitTopLevel(t).map { SurgeText.unquote($0) }
            guard p.count >= 2 else { return nil }
            let sub = p[0].uppercased()
            let c: String?
            if ["AND", "OR", "NOT"].contains(sub) {
                c = convertLogical(type: sub, value: p[1], no: no, diagnostics: &diagnostics)
            } else {
                c = convertSimple(type: sub, value: p[1], no: no, diagnostics: &diagnostics)
            }
            guard let c else { return nil }
            converted.append("(\(c))")
        }
        guard !converted.isEmpty else { return nil }
        return "\(type),(\(converted.joined(separator: ",")))"
    }

    // MARK: [Host]

    private static func parseHostLine(_ line: String, no: Int, into profile: inout Profile) {
        guard let (domain, value) = splitAssign(line) else { return }
        if value.lowercased().hasPrefix("server:") {
            profile.nameserverPolicy[domain] = String(value.dropFirst("server:".count)).trimmingCharacters(in: .whitespaces)
            return
        }
        profile.hosts[domain] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
    }
}
