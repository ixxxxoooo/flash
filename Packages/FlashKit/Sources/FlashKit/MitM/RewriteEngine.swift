import Foundation

/// HTTP 头集合（保持顺序，允许重复，名称不区分大小写）
public typealias HeaderList = [(name: String, value: String)]

/// 重写引擎合成的响应
public struct SyntheticResponse: Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// 来源说明，用于报文记录
    public var note: String
}

/// URL 重写 / Header 重写 / Map Local 的执行器（纯逻辑，便于测试）。
/// @author ygw
public final class RewriteEngine: @unchecked Sendable {
    /// 请求阶段的处理结果
    public enum RequestOutcome {
        /// 不改变（headers 可能已被修改）
        case forward(url: String)
        /// 直接用合成响应结束请求
        case respond(SyntheticResponse)
    }

    private struct CompiledURL { var regex: NSRegularExpression; var rule: URLRewriteRule }
    private struct CompiledHeader { var regex: NSRegularExpression; var rule: HeaderRewriteRule }
    private struct CompiledMap { var regex: NSRegularExpression; var rule: MapLocalRule }

    private let urls: [CompiledURL]
    private let headerRules: [CompiledHeader]
    private let maps: [CompiledMap]
    private let resources: ResourceCache
    /// 无法编译的正则（用于界面提示）
    public let invalidPatterns: [String]

    public init(config: MitMConfig, resources: ResourceCache = .shared) {
        var bad: [String] = []
        func compile(_ p: String) -> NSRegularExpression? {
            if let r = try? NSRegularExpression(pattern: p) { return r }
            bad.append(p)
            return nil
        }
        urls = config.urlRewrites.compactMap { r in compile(r.pattern).map { CompiledURL(regex: $0, rule: r) } }
        headerRules = config.headerRewrites.compactMap { r in compile(r.pattern).map { CompiledHeader(regex: $0, rule: r) } }
        maps = config.mapLocals.compactMap { r in compile(r.pattern).map { CompiledMap(regex: $0, rule: r) } }
        invalidPatterns = bad
        self.resources = resources
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: 请求阶段

    /// 评估请求：依次尝试 Map Local、URL Rewrite，最后应用请求头重写
    /// - Parameters:
    ///   - url: 完整请求 URL
    ///   - headers: 请求头（会被原地修改）
    /// - Returns: 转发（可能带新 URL）或合成响应
    public func evaluateRequest(url: String, headers: inout HeaderList) -> RequestOutcome {
        for m in maps where Self.matches(m.regex, url) {
            return .respond(mapLocalResponse(m.rule))
        }
        var currentURL = url
        for u in urls where Self.matches(u.regex, currentURL) {
            switch u.rule.action {
            case .reject(let kind):
                return .respond(Self.rejectResponse(kind))
            case .redirect(let status, let to):
                let target = u.regex.stringByReplacingMatches(in: currentURL, range: NSRange(currentURL.startIndex..., in: currentURL), withTemplate: to)
                return .respond(SyntheticResponse(status: status, headers: [("Location", target), ("Content-Length", "0")], body: Data(),
                                                  note: "URL Rewrite \(status) → \(target)"))
            case .header(let to):
                currentURL = u.regex.stringByReplacingMatches(in: currentURL, range: NSRange(currentURL.startIndex..., in: currentURL), withTemplate: to)
            }
        }
        applyHeaderRules(.request, url: currentURL, headers: &headers)
        return .forward(url: currentURL)
    }

    // MARK: 响应阶段

    /// 应用响应头重写
    public func applyResponseHeaders(url: String, headers: inout HeaderList) {
        applyHeaderRules(.response, url: url, headers: &headers)
    }

    /// 是否存在作用于某方向、匹配该 URL 的 Header 重写（用于决定是否需要处理）
    public func hasHeaderRules(_ direction: RewriteDirection, url: String) -> Bool {
        headerRules.contains { $0.rule.direction == direction && Self.matches($0.regex, url) }
    }

    private func applyHeaderRules(_ direction: RewriteDirection, url: String, headers: inout HeaderList) {
        for h in headerRules where h.rule.direction == direction && Self.matches(h.regex, url) {
            switch h.rule.action {
            case .add(let name, let value):
                headers.append((name, value))
            case .del(let name):
                headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            case .replace(let name, let value):
                if let idx = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    headers[idx].value = value
                    // 其余同名头删除，保持唯一
                    var seen = false
                    headers = headers.filter { e in
                        guard e.name.caseInsensitiveCompare(name) == .orderedSame else { return true }
                        if !seen { seen = true; return true }
                        return false
                    }
                } else {
                    headers.append((name, value))
                }
            case .replaceRegex(let name, let pattern, let replacement):
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for i in headers.indices where headers[i].name.caseInsensitiveCompare(name) == .orderedSame {
                    let v = headers[i].value
                    headers[i].value = re.stringByReplacingMatches(in: v, range: NSRange(v.startIndex..., in: v), withTemplate: replacement)
                }
            }
        }
    }

    // MARK: 合成响应

    /// 1x1 透明 GIF
    public static let tinyGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    static func rejectResponse(_ kind: URLRewriteAction.RejectKind) -> SyntheticResponse {
        switch kind {
        case .plain:
            return SyntheticResponse(status: 404, headers: [("Content-Length", "0")], body: Data(), note: "URL Rewrite reject")
        case .ok200:
            return SyntheticResponse(status: 200, headers: [("Content-Length", "0")], body: Data(), note: "URL Rewrite reject-200")
        case .img, .noContent:
            return SyntheticResponse(status: 200, headers: [("Content-Type", "image/gif"), ("Content-Length", "\(tinyGIF.count)")],
                                     body: tinyGIF, note: "URL Rewrite reject-img")
        case .dict:
            let b = Data("{}".utf8)
            return SyntheticResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", "\(b.count)")],
                                     body: b, note: "URL Rewrite reject-dict")
        case .array:
            let b = Data("[]".utf8)
            return SyntheticResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", "\(b.count)")],
                                     body: b, note: "URL Rewrite reject-array")
        }
    }

    private func mapLocalResponse(_ rule: MapLocalRule) -> SyntheticResponse {
        var body = Data()
        var contentType = "text/plain; charset=utf-8"
        switch rule.dataType {
        case .text:
            body = Data(rule.data.utf8)
            let t = rule.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("[") { contentType = "application/json; charset=utf-8" }
        case .base64:
            body = Data(base64Encoded: rule.data) ?? Data()
            contentType = "application/octet-stream"
        case .tinyGif:
            body = Self.tinyGIF
            contentType = "image/gif"
        case .file:
            body = resources.cached(rule.data) ?? Data()
            let ext = (rule.data as NSString).pathExtension.lowercased()
            switch ext {
            case "json": contentType = "application/json; charset=utf-8"
            case "html", "htm": contentType = "text/html; charset=utf-8"
            case "js": contentType = "application/javascript; charset=utf-8"
            case "png": contentType = "image/png"
            case "jpg", "jpeg": contentType = "image/jpeg"
            case "gif": contentType = "image/gif"
            case "xml": contentType = "application/xml; charset=utf-8"
            default: contentType = "application/octet-stream"
            }
        }
        var headers: HeaderList = [("Content-Type", contentType)]
        for (k, v) in rule.headers.sorted(by: { $0.key < $1.key }) {
            headers.removeAll { $0.name.caseInsensitiveCompare(k) == .orderedSame }
            headers.append((k, v))
        }
        headers.removeAll { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        headers.append(("Content-Length", "\(body.count)"))
        return SyntheticResponse(status: rule.statusCode, headers: headers, body: body, note: "Map Local")
    }
}
