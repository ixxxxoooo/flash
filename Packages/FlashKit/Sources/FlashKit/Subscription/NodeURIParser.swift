import Foundation

/// 分享链接解析：ss / vmess / trojan / vless / hysteria2 / tuic → mihomo 节点
public enum NodeURIParser {
    public static func parse(_ raw: String) -> ProxyNode? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "://") else { return nil }
        switch line[..<range.lowerBound].lowercased() {
        case "ss": return parseSS(line)
        case "vmess": return parseVMess(line)
        case "trojan": return parseTrojan(line)
        case "vless": return parseVLESS(line)
        case "hysteria2", "hy2": return parseHysteria2(line)
        case "tuic": return parseTUIC(line)
        default: return nil
        }
    }

    // MARK: 工具

    /// 容错 Base64 解码（兼容 URL-safe 与缺失填充）
    public static func decodeBase64(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodePercent(_ s: String) -> String { s.removingPercentEncoding ?? s }

    private static func query(_ items: [URLQueryItem]?) -> [String: String] {
        var d: [String: String] = [:]
        for i in items ?? [] { if let v = i.value { d[i.name.lowercased()] = v } }
        return d
    }

    private static func truthy(_ s: String?) -> Bool { ["1", "true", "yes"].contains((s ?? "").lowercased()) }

    private static func displayName(_ comps: URLComponents?, fallback: String) -> String {
        if let f = comps?.fragment, !f.isEmpty { return decodePercent(f) }
        return fallback
    }

    /// 通用 `scheme://user[:pass]@host:port?query#name`
    private static func components(_ line: String) -> URLComponents? {
        if let c = URLComponents(string: line), c.host != nil { return c }
        // 名称含特殊字符导致解析失败时，先对 fragment 做编码
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let head = String(line[..<hash])
        let frag = String(line[line.index(after: hash)...]).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        return URLComponents(string: head + "#" + frag)
    }

    // MARK: 传输层公共参数

    private static func applyTransport(_ f: inout [String: JSONValue], q: [String: String]) {
        let net = (q["type"] ?? q["network"] ?? "tcp").lowercased()
        switch net {
        case "ws", "websocket":
            f["network"] = "ws"
            var opts: [String: JSONValue] = ["path": .string(decodePercent(q["path"] ?? "/"))]
            if let h = q["host"], !h.isEmpty { opts["headers"] = .object(["Host": .string(h)]) }
            f["ws-opts"] = .object(opts)
        case "grpc":
            f["network"] = "grpc"
            f["grpc-opts"] = .object(["grpc-service-name": .string(decodePercent(q["servicename"] ?? ""))])
        case "h2", "http":
            f["network"] = "h2"
            var opts: [String: JSONValue] = ["path": .string(decodePercent(q["path"] ?? "/"))]
            if let h = q["host"], !h.isEmpty { opts["host"] = .array([.string(h)]) }
            f["h2-opts"] = .object(opts)
        default: break
        }
    }

    // MARK: ss

    private static func parseSS(_ line: String) -> ProxyNode? {
        var body = String(line.dropFirst("ss://".count))
        var name = ""
        if let h = body.firstIndex(of: "#") {
            name = decodePercent(String(body[body.index(after: h)...]))
            body = String(body[..<h])
        }
        var queryString = ""
        if let q = body.firstIndex(of: "?") {
            queryString = String(body[body.index(after: q)...])
            body = String(body[..<q])
        }
        if body.hasSuffix("/") { body.removeLast() }

        var method = "", password = "", host = "", port = 0
        if let at = body.lastIndex(of: "@") {
            let userinfo = String(body[..<at])
            let hostport = String(body[body.index(after: at)...])
            let plain: String
            if userinfo.contains(":") { plain = decodePercent(userinfo) } else { plain = decodeBase64(userinfo) ?? "" }
            guard let colon = plain.firstIndex(of: ":") else { return nil }
            method = String(plain[..<colon]); password = String(plain[plain.index(after: colon)...])
            guard let hp = splitHostPort(hostport) else { return nil }
            host = hp.0; port = hp.1
        } else {
            guard let decoded = decodeBase64(body), let at = decoded.lastIndex(of: "@") else { return nil }
            let userinfo = String(decoded[..<at])
            guard let colon = userinfo.firstIndex(of: ":"), let hp = splitHostPort(String(decoded[decoded.index(after: at)...])) else { return nil }
            method = String(userinfo[..<colon]); password = String(userinfo[userinfo.index(after: colon)...])
            host = hp.0; port = hp.1
        }
        var f: [String: JSONValue] = [
            "type": "ss", "server": .string(host), "port": .int(port),
            "cipher": .string(method), "password": .string(password), "udp": true,
        ]
        // 插件
        let q = query(URLComponents(string: "x://h?\(queryString)")?.queryItems)
        if let plugin = q["plugin"] {
            let parts = decodePercent(plugin).split(separator: ";").map(String.init)
            var opts: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                opts[kv[0]] = kv.count > 1 ? kv[1] : "true"
            }
            if let p0 = parts.first {
                if p0.contains("obfs") {
                    f["plugin"] = "obfs"
                    var o: [String: JSONValue] = ["mode": .string(opts["obfs"] ?? "http")]
                    if let h = opts["obfs-host"] { o["host"] = .string(h) }
                    f["plugin-opts"] = .object(o)
                } else if p0.contains("v2ray-plugin") {
                    f["plugin"] = "v2ray-plugin"
                    var o: [String: JSONValue] = ["mode": .string(opts["mode"] ?? "websocket")]
                    if let h = opts["host"] { o["host"] = .string(h) }
                    if let p = opts["path"] { o["path"] = .string(p) }
                    if opts["tls"] != nil { o["tls"] = true }
                    f["plugin-opts"] = .object(o)
                }
            }
        }
        return ProxyNode(name: name.isEmpty ? "\(host):\(port)" : name, fields: f)
    }

    private static func splitHostPort(_ s: String) -> (String, Int)? {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { return nil }
            return (host, p)
        }
        guard let colon = s.lastIndex(of: ":"), let p = Int(s[s.index(after: colon)...]) else { return nil }
        return (String(s[..<colon]), p)
    }

    // MARK: vmess

    private static func parseVMess(_ line: String) -> ProxyNode? {
        let payload = String(line.dropFirst("vmess://".count))
        guard let json = decodeBase64(payload),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        func s(_ k: String) -> String { (obj[k] as? String) ?? (obj[k].map { "\($0)" } ?? "") }
        let host = s("add"), port = Int(s("port")) ?? 0
        guard !host.isEmpty, port > 0, !s("id").isEmpty else { return nil }
        var f: [String: JSONValue] = [
            "type": "vmess", "server": .string(host), "port": .int(port), "uuid": .string(s("id")),
            "alterId": .int(Int(s("aid")) ?? 0), "cipher": .string(s("scy").isEmpty ? "auto" : s("scy")), "udp": true,
        ]
        let net = s("net").lowercased()
        let hostHeader = s("host"), path = s("path")
        switch net {
        case "ws":
            f["network"] = "ws"
            var o: [String: JSONValue] = ["path": .string(path.isEmpty ? "/" : path)]
            if !hostHeader.isEmpty { o["headers"] = .object(["Host": .string(hostHeader)]) }
            f["ws-opts"] = .object(o)
        case "grpc":
            f["network"] = "grpc"
            f["grpc-opts"] = .object(["grpc-service-name": .string(path)])
        case "h2":
            f["network"] = "h2"
            var o: [String: JSONValue] = ["path": .string(path.isEmpty ? "/" : path)]
            if !hostHeader.isEmpty { o["host"] = .array([.string(hostHeader)]) }
            f["h2-opts"] = .object(o)
        default: break
        }
        if s("tls").lowercased() == "tls" {
            f["tls"] = true
            let sni = s("sni").isEmpty ? hostHeader : s("sni")
            if !sni.isEmpty { f["servername"] = .string(sni) }
        }
        let name = s("ps").isEmpty ? "\(host):\(port)" : s("ps")
        return ProxyNode(name: name, fields: f)
    }

    // MARK: trojan

    private static func parseTrojan(_ line: String) -> ProxyNode? {
        guard let c = components(line), let host = c.host, let port = c.port, let user = c.user else { return nil }
        let q = query(c.queryItems)
        var f: [String: JSONValue] = [
            "type": "trojan", "server": .string(host), "port": .int(port),
            "password": .string(decodePercent(user)), "udp": true,
        ]
        if let sni = q["sni"] ?? q["peer"], !sni.isEmpty { f["sni"] = .string(sni) }
        if truthy(q["allowinsecure"]) || truthy(q["insecure"]) { f["skip-cert-verify"] = true }
        if let alpn = q["alpn"] { f["alpn"] = .array(decodePercent(alpn).split(separator: ",").map { .string(String($0)) }) }
        applyTransport(&f, q: q)
        return ProxyNode(name: displayName(c, fallback: "\(host):\(port)"), fields: f)
    }

    // MARK: vless

    private static func parseVLESS(_ line: String) -> ProxyNode? {
        guard let c = components(line), let host = c.host, let port = c.port, let uuid = c.user else { return nil }
        let q = query(c.queryItems)
        var f: [String: JSONValue] = [
            "type": "vless", "server": .string(host), "port": .int(port), "uuid": .string(uuid), "udp": true,
        ]
        let security = (q["security"] ?? "").lowercased()
        if security == "tls" || security == "reality" { f["tls"] = true }
        if let sni = q["sni"], !sni.isEmpty { f["servername"] = .string(sni) }
        if let fp = q["fp"], !fp.isEmpty { f["client-fingerprint"] = .string(fp) }
        if let flow = q["flow"], !flow.isEmpty { f["flow"] = .string(flow) }
        if truthy(q["allowinsecure"]) || truthy(q["insecure"]) { f["skip-cert-verify"] = true }
        if security == "reality" {
            var o: [String: JSONValue] = [:]
            if let pbk = q["pbk"] { o["public-key"] = .string(pbk) }
            if let sid = q["sid"] { o["short-id"] = .string(sid) }
            f["reality-opts"] = .object(o)
        }
        if let alpn = q["alpn"] { f["alpn"] = .array(decodePercent(alpn).split(separator: ",").map { .string(String($0)) }) }
        applyTransport(&f, q: q)
        return ProxyNode(name: displayName(c, fallback: "\(host):\(port)"), fields: f)
    }

    // MARK: hysteria2

    private static func parseHysteria2(_ line: String) -> ProxyNode? {
        var normalized = line
        if line.lowercased().hasPrefix("hy2://") { normalized = "hysteria2://" + line.dropFirst("hy2://".count) }
        guard let c = components(normalized), let host = c.host else { return nil }
        let port = c.port ?? 443
        let q = query(c.queryItems)
        let password = [c.user, c.password].compactMap { $0 }.map(decodePercent).joined(separator: ":")
        var f: [String: JSONValue] = [
            "type": "hysteria2", "server": .string(host), "port": .int(port), "password": .string(password),
        ]
        if let sni = q["sni"], !sni.isEmpty { f["sni"] = .string(sni) }
        if truthy(q["insecure"]) || truthy(q["allowinsecure"]) { f["skip-cert-verify"] = true }
        if let obfs = q["obfs"], !obfs.isEmpty { f["obfs"] = .string(obfs); f["obfs-password"] = .string(q["obfs-password"] ?? "") }
        if let mport = q["mport"] { f["ports"] = .string(mport) }
        return ProxyNode(name: displayName(c, fallback: "\(host):\(port)"), fields: f)
    }

    // MARK: tuic

    private static func parseTUIC(_ line: String) -> ProxyNode? {
        guard let c = components(line), let host = c.host, let port = c.port, let uuid = c.user else { return nil }
        let q = query(c.queryItems)
        var f: [String: JSONValue] = [
            "type": "tuic", "server": .string(host), "port": .int(port), "uuid": .string(uuid),
            "password": .string(decodePercent(c.password ?? "")),
            "congestion-controller": .string(q["congestion_control"] ?? "bbr"),
            "udp-relay-mode": .string(q["udp_relay_mode"] ?? "native"),
        ]
        if let sni = q["sni"], !sni.isEmpty { f["sni"] = .string(sni) }
        if let alpn = q["alpn"] { f["alpn"] = .array(decodePercent(alpn).split(separator: ",").map { .string(String($0)) }) }
        if truthy(q["allow_insecure"]) || truthy(q["insecure"]) { f["skip-cert-verify"] = true }
        return ProxyNode(name: displayName(c, fallback: "\(host):\(port)"), fields: f)
    }
}
