import Foundation

/// 圈叉（Quantumult X）配置转换结果
public struct QXConversion: Sendable {
    /// 转换后的 Surge 风格配置文本（可直接作为 Flash 主配置）
    public var text: String
    /// server_remote 中启用的订阅（tag, url）
    public var remoteServers: [(tag: String, url: String)]
    /// 转换说明与不支持项（面向用户展示，不含密码/订阅地址）
    public var notes: [String]
    public var nodeCount: Int
    public var groupCount: Int
    public var ruleCount: Int
    public var ruleSetCount: Int
}

/// 把圈叉配置（.conf）转换为 Flash 使用的 Surge 风格配置
///
/// 覆盖范围：`[server_local]` 节点、`[server_remote]` 订阅引用、`[policy]` 策略组、
/// `[filter_local]` / `[filter_remote]` 分流、`[dns]`、`[general]` 的 excluded_routes、
/// `[rewrite_local]` / `[mitm]`（基础子集）。
/// @author ygw
public enum QuantumultXConverter {

    // MARK: 入口

    /// 转换圈叉配置文本
    /// - Parameters:
    ///   - input: 圈叉配置全文
    ///   - localFile: 读取同目录下本地资源（如 `作业帮.list`）的回调，找不到返回 nil
    /// - Returns: 转换结果
    public static func convert(_ input: String, localFile: (String) -> String? = { _ in nil }) -> QXConversion {
        let sections = splitSections(input)
        var notes: [String] = []

        // 1. 订阅引用
        var remotes: [(tag: String, url: String)] = []
        for line in sections["server_remote"] ?? [] {
            let parts = SurgeText.splitTopLevel(line)
            guard let url = parts.first, url.hasPrefix("http") else { continue }
            var tag = "", enabled = true
            for p in parts.dropFirst() {
                if let (k, v) = SurgeText.keyValue(p) {
                    if k == "tag" { tag = v }
                    if k == "enabled" { enabled = SurgeText.bool(v) ?? true }
                }
            }
            if enabled { remotes.append((tag.isEmpty ? "QX订阅\(remotes.count + 1)" : tag, url)) }
        }

        // 2. 本地节点
        var nodeLines: [String] = []
        var nodeNames: [String] = []
        for line in sections["server_local"] ?? [] {
            if let (name, text) = convertServer(line, notes: &notes) { nodeNames.append(name); nodeLines.append(text) }
        }

        // 3. 策略组
        var groupLines: [String] = []
        var groupNames: [String] = []
        for line in sections["policy"] ?? [] {
            if let (name, text) = convertPolicy(line, remotes: remotes, notes: &notes) {
                groupNames.append(name); groupLines.append(text)
            }
        }
        let knownPolicies = Set(nodeNames + groupNames)

        // 4. 规则：本地（geoip 后置）→ 远程 → FINAL
        var localRules: [String] = []
        var deferredGeoip: [String] = []
        var finalRule: String?
        for line in sections["filter_local"] ?? [] {
            guard let r = convertLocalRule(line, known: knownPolicies, notes: &notes) else { continue }
            if r.hasPrefix("FINAL,") { finalRule = r } else if r.hasPrefix("GEOIP,") { deferredGeoip.append(r) } else { localRules.append(r) }
        }
        var remoteRules: [String] = []
        var ruleSets = 0
        for line in sections["filter_remote"] ?? [] {
            let r = convertRemoteFilter(line, known: knownPolicies, localFile: localFile, notes: &notes)
            remoteRules += r.rules
            ruleSets += r.isSet ? 1 : 0
        }
        let allRules = localRules + remoteRules + deferredGeoip
        if !deferredGeoip.isEmpty {
            notes.append("GEOIP 规则已后置到所有域名规则之后（内核按域名分流时需要先解析 IP，前置容易被污染的 DNS 结果误判为国内）")
        }

        // 5. DNS / General
        let (generalLines, hostLines) = convertDNSAndGeneral(sections["dns"] ?? [], general: sections["general"] ?? [], notes: &notes)

        // 6. MitM / 重写
        let mitm = convertMitM(mitm: sections["mitm"] ?? [], rewrites: sections["rewrite_local"] ?? [], notes: &notes)
        if !(sections["rewrite_remote"] ?? []).isEmpty {
            notes.append("[rewrite_remote] 远程重写暂未转换（\((sections["rewrite_remote"] ?? []).count) 条），可在配置页用 #!include 引入 Surge 格式模块")
        }
        if !(sections["task_local"] ?? []).isEmpty { notes.append("[task_local] 定时任务不支持，已忽略") }

        // 7. 拼装
        var out: [String] = ["# 由 Flash 从圈叉(Quantumult X)配置转换生成", ""]
        out += ["[General]"] + (generalLines.isEmpty ? ["# （无）"] : generalLines) + [""]
        out += ["[Proxy]"] + nodeLines + [""]
        out += ["[Proxy Group]"] + groupLines + [""]
        out += ["[Rule]"] + allRules
        let finalPolicy = finalRule.map { String($0.dropFirst("FINAL,".count)) } ?? "DIRECT"
        out += ["FINAL,\(finalPolicy)", ""]
        if !hostLines.isEmpty { out += ["[Host]"] + hostLines + [""] }
        out += mitm
        return QXConversion(text: out.joined(separator: "\n") + "\n", remoteServers: remotes, notes: notes,
                            nodeCount: nodeLines.count, groupCount: groupLines.count,
                            ruleCount: allRules.count + 1, ruleSetCount: ruleSets)
    }

    // MARK: 分段

    /// 按 `[section]` 拆分，去掉空行与注释，key 统一小写
    static func splitSections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            result[current, default: []].append(line)
        }
        return result
    }

    // MARK: 策略名

    /// 策略名映射：direct/reject 转大写内置策略，其余原样
    static func policyName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "direct": return "DIRECT"
        case "reject": return "REJECT"
        default: return t
        }
    }

    // MARK: [server_local]

    /// 转换一行本地节点，返回（节点名, Surge 节点行）
    static func convertServer(_ line: String, notes: inout [String]) -> (String, String)? {
        let parts = SurgeText.splitTopLevel(line)
        guard let head = parts.first, let eq = head.firstIndex(of: "=") else { return nil }
        let type = head[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let addr = head[head.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let colon = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: colon)...]) else { return nil }
        let host = String(addr[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var kv: [String: String] = [:]
        for p in parts.dropFirst() { if let (k, v) = SurgeText.keyValue(p) { kv[k.lowercased()] = v } }
        let name = (kv["tag"]?.isEmpty == false ? kv["tag"]! : "\(host):\(port)")
        let verify = SurgeText.bool(kv["tls-verification"]) ?? true
        let obfs = (kv["obfs"] ?? "").lowercased()
        let isWS = obfs == "ws" || obfs == "wss"
        let isTLS = obfs == "wss" || obfs == "over-tls" || SurgeText.bool(kv["over-tls"]) == true

        /// 通用传输层参数（TLS / WebSocket / 证书校验 / UDP）
        func transport(tlsKey: Bool, sniKey: String?) -> [String] {
            var o: [String] = []
            if tlsKey { o.append("tls=true") }
            let hostHeader = kv["obfs-host"] ?? kv["tls-host"]
            if let h = hostHeader, !h.isEmpty, tlsKey || isWS, sniKey != nil { o.append("sni=\(h)") }
            if isWS {
                o.append("ws=true")
                o.append("ws-path=\(kv["obfs-uri"] ?? "/")")
                if let h = hostHeader, !h.isEmpty { o.append("ws-headers=Host:\(h)") }
            }
            if tlsKey, !verify { o.append("skip-cert-verify=true") }
            if SurgeText.bool(kv["udp-relay"]) == true { o.append("udp-relay=true") }
            return o
        }
        let base = "\(name) = "
        switch type {
        case "vless":
            guard let id = kv["password"] ?? kv["username"] else { return nil }
            var o = ["username=\(id)"] + transport(tlsKey: isTLS, sniKey: "sni")
            if let flow = kv["flow"] { o.append("flow=\(flow)") }
            return (name, base + (["vless", host, "\(port)"] + o).joined(separator: ", "))
        case "vmess":
            guard let id = kv["password"] ?? kv["username"] else { return nil }
            let method = kv["method"] ?? "chacha20-ietf-poly1305"
            let o = ["username=\(id)", "encrypt-method=\(method)"] + transport(tlsKey: isTLS, sniKey: "sni")
            return (name, base + (["vmess", host, "\(port)"] + o).joined(separator: ", "))
        case "trojan":
            guard let pwd = kv["password"] else { return nil }
            let o = ["password=\(pwd)"] + transport(tlsKey: true, sniKey: "sni")
            return (name, base + (["trojan", host, "\(port)"] + o.filter { $0 != "tls=true" }).joined(separator: ", "))
        case "shadowsocks":
            guard let method = kv["method"], let pwd = kv["password"] else { return nil }
            var o = ["encrypt-method=\(method)", "password=\(pwd)"]
            if obfs == "http" || obfs == "tls" {
                o.append("obfs=\(obfs)")
                if let h = kv["obfs-host"] { o.append("obfs-host=\(h)") }
            } else if !obfs.isEmpty {
                notes.append("节点「\(name)」使用 \(obfs) 混淆（v2ray-plugin / ssr），暂不支持，已按无混淆处理")
            }
            if SurgeText.bool(kv["udp-relay"]) == true { o.append("udp-relay=true") }
            return (name, base + (["ss", host, "\(port)"] + o).joined(separator: ", "))
        case "http":
            var o: [String] = []
            if let u = kv["username"], let p = kv["password"] { o = [u, p] }
            let tls = SurgeText.bool(kv["over-tls"]) == true
            return (name, base + ([tls ? "https" : "http", host, "\(port)"] + o).joined(separator: ", "))
        case "socks5":
            var o: [String] = []
            if let u = kv["username"], let p = kv["password"] { o = [u, p] }
            let tls = SurgeText.bool(kv["over-tls"]) == true
            return (name, base + ([tls ? "socks5-tls" : "socks5", host, "\(port)"] + o).joined(separator: ", "))
        default:
            notes.append("节点「\(name)」类型 \(type) 暂不支持，已跳过")
            return nil
        }
    }

    // MARK: [policy]

    /// 转换策略组，返回（组名, Surge 策略组行）
    static func convertPolicy(_ line: String, remotes: [(tag: String, url: String)], notes: inout [String]) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let type = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let parts = SurgeText.splitTopLevel(String(line[line.index(after: eq)...]))
        guard let name = parts.first, !name.isEmpty else { return nil }

        var surgeType: String
        switch type {
        case "static": surgeType = "select"
        case "available": surgeType = "fallback"
        case "round-robin": surgeType = "load-balance"
        case "url-latency-benchmark", "dest-hash": surgeType = "url-test"
        case "ssid": surgeType = "select"
        default:
            notes.append("策略组「\(name)」类型 \(type) 暂不支持，已跳过")
            return nil
        }
        if type == "dest-hash" { notes.append("策略组「\(name)」dest-hash 已降级为 url-test") }
        if type == "ssid" { notes.append("策略组「\(name)」ssid 已降级为 select") }

        var members: [String] = []
        var extras: [String] = []
        for p in parts.dropFirst() {
            if let (k, v) = SurgeText.keyValue(p) {
                switch k.lowercased() {
                case "server-tag-regex":
                    let hits = remotes.filter { r in
                        (try? NSRegularExpression(pattern: v, options: [.caseInsensitive]))
                            .map { $0.firstMatch(in: r.tag, range: NSRange(r.tag.startIndex..., in: r.tag)) != nil } ?? false
                    }
                    if let first = hits.first {
                        extras.append("policy-path=\(first.url)")
                        if hits.count > 1 { notes.append("策略组「\(name)」匹配到多个订阅，仅使用第一个「\(first.tag)」") }
                    } else {
                        extras.append("include-all-proxies=true")
                        extras.append("policy-regex-filter=\(v)")
                        notes.append("策略组「\(name)」的 server-tag-regex 未匹配到订阅标签，改为按节点名正则过滤")
                    }
                case "check-interval": extras.append("interval=\(v)")
                case "tolerance": extras.append("tolerance=\(v)")
                default: break   // img-url、alive-checking 等无关项
                }
            } else if p.contains("="), p.lowercased().hasPrefix("ssid") {
                continue
            } else if !p.isEmpty {
                members.append(policyName(p))
            }
        }
        return (name, "\(name) = " + ([surgeType] + members + extras).joined(separator: ", "))
    }

    // MARK: [filter_local]

    /// QX 规则类型 → Surge 规则类型
    static let ruleTypeMap: [String: String] = [
        "host": "DOMAIN", "host-suffix": "DOMAIN-SUFFIX", "host-keyword": "DOMAIN-KEYWORD",
        "host-wildcard": "DOMAIN-WILDCARD", "ip-cidr": "IP-CIDR", "ip6-cidr": "IP-CIDR6",
        "geoip": "GEOIP", "ip-asn": "IP-ASN",
    ]

    /// 转换一条本地规则，返回 Surge 规则文本；FINAL 以 `FINAL,策略` 返回
    static func convertLocalRule(_ line: String, known: Set<String>, notes: inout [String]) -> String? {
        let p = SurgeText.splitTopLevel(line)
        guard let t = p.first?.lowercased() else { return nil }
        if t == "final" {
            guard p.count >= 2 else { return nil }
            return "FINAL,\(policyName(p[1]))"
        }
        guard p.count >= 3, let mapped = ruleTypeMap[t] else {
            notes.append("规则类型 \(t) 暂不支持，已跳过：\(p.prefix(2).joined(separator: ","))")
            return nil
        }
        let value = mapped == "GEOIP" ? p[1].uppercased() : p[1]
        var text = "\(mapped),\(value),\(policyName(p[2]))"
        // IP 段规则对域名请求不应触发 DNS 解析
        if mapped.hasPrefix("IP-CIDR") || mapped == "IP-ASN" || p.dropFirst(3).contains(where: { $0.lowercased() == "no-resolve" }) {
            text += ",no-resolve"
        }
        return text
    }

    // MARK: [filter_remote]

    /// 转换一条远程/本地规则集引用
    /// - Returns: 生成的规则行；isSet 表示作为 RULE-SET 引用（而非展开）
    static func convertRemoteFilter(_ line: String, known: Set<String>, localFile: (String) -> String?,
                                    notes: inout [String]) -> (rules: [String], isSet: Bool) {
        let parts = SurgeText.splitTopLevel(line)
        guard let source = parts.first, !source.isEmpty else { return ([], false) }
        var tag = source, policy: String?, enabled = true
        for p in parts.dropFirst() {
            guard let (k, v) = SurgeText.keyValue(p) else { continue }
            switch k.lowercased() {
            case "tag": tag = v
            case "force-policy": policy = policyName(v)
            case "enabled": enabled = SurgeText.bool(v) ?? true
            default: break
            }
        }
        guard enabled else { return ([], false) }
        let target = policy ?? "DIRECT"
        if policy == nil { notes.append("规则集「\(tag)」没有 force-policy，已默认使用 DIRECT") }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            // 圈叉语法的列表由 Flash 下载并转换后再交给内核（见 QXRuleSetCache）
            let url = source
            return (["RULE-SET,\(url),\(target),format=qx"], true)
        }

        // 本地文件：展开为普通规则
        guard let content = localFile(source) else {
            notes.append("规则集「\(tag)」是本地文件 \(source)，但没有在配置同目录找到，已跳过")
            return ([], false)
        }
        var out: [String] = []
        for raw in content.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix(";") { continue }
            let p = SurgeText.splitTopLevel(l)
            guard p.count >= 2, let mapped = ruleTypeMap[p[0].lowercased()] else { continue }
            var text = "\(mapped),\(mapped == "GEOIP" ? p[1].uppercased() : p[1]),\(target)"
            if mapped.hasPrefix("IP-CIDR") || mapped == "IP-ASN" { text += ",no-resolve" }
            out.append(text)
        }
        return (out, false)
    }

    // MARK: [dns] / [general]

    static func convertDNSAndGeneral(_ dns: [String], general: [String], notes: inout [String]) -> (general: [String], hosts: [String]) {
        var servers: [String] = []
        var hosts: [String] = []
        var generalLines: [String] = []
        for line in dns {
            if line.lowercased() == "no-ipv6" { generalLines.append("ipv6 = false"); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "server":
                if value.hasPrefix("/") {
                    let seg = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    if seg.count == 2 { hosts.append("+.\(seg[0]) = server:\(seg[1])") }
                } else if value.lowercased() == "system" {
                    continue
                } else {
                    servers.append(value)
                }
            case "address":
                let seg = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if seg.count == 2 { hosts.append("\(seg[0]) = \(seg[1])") }
            case "circumvent-ipv4-answer", "circumvent-ipv6-answer":
                notes.append("DNS 的 \(key)（过滤被污染的解析结果）内核不支持，已忽略；Flash 默认使用 fake-ip 之外的普通解析，必要时可在设置里开启增强模式")
            default: break
            }
        }
        if !servers.isEmpty { generalLines.append("dns-server = " + servers.joined(separator: ", ")) }

        for line in general {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "excluded_routes": generalLines.append("skip-proxy = " + value.replacingOccurrences(of: " ", with: ""))
            case "fallback_udp_policy", "udp_drop_list":
                notes.append("general.\(key) 属于圈叉隧道特性，不适用于 Flash，已忽略")
            default: break
            }
        }
        return (generalLines, hosts)
    }

    // MARK: [mitm] / [rewrite_local]

    static func convertMitM(mitm: [String], rewrites: [String], notes: inout [String]) -> [String] {
        var hostname = ""
        for line in mitm {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if k == "hostname" { hostname = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        var urlRewrites: [String] = []
        var scripts: [String] = []
        for (i, line) in rewrites.enumerated() {
            // 格式：<正则> url <动作> [目标]
            let t = SurgeText.tokens(line)
            guard t.count >= 3, t[1].lowercased() == "url" else {
                notes.append("rewrite_local 第 \(i + 1) 条格式无法识别，已跳过")
                continue
            }
            let pattern = t[0], action = t[2].lowercased()
            let target = t.count > 3 ? t[3] : ""
            switch action {
            case "reject", "reject-200", "reject-img", "reject-dict", "reject-array":
                urlRewrites.append("\(pattern) - \(action)")
            case "302", "307":
                urlRewrites.append("\(pattern) \(target) \(action)")
            case "script-response-body", "script-response-header", "script-request-body", "script-request-header":
                let dir = action.contains("response") ? "http-response" : "http-request"
                let body = action.hasSuffix("body")
                scripts.append("qx-\(i + 1) = type=\(dir), pattern=\(pattern), script-path=\(target), requires-body=\(body)")
            default:
                notes.append("rewrite_local「\(action)」暂不支持，已跳过")
            }
        }
        var out: [String] = []
        if !hostname.isEmpty { out += ["[MITM]", "hostname = \(hostname)", ""] }
        if !urlRewrites.isEmpty { out += ["[URL Rewrite]"] + urlRewrites + [""] }
        if !scripts.isEmpty { out += ["[Script]"] + scripts + [""] }
        return out
    }
}
