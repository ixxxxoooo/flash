import Foundation

/// 圈叉（Quantumult X）语法规则集：下载并转换为 mihomo 可读的 classical 文本，缓存到内核目录
///
/// 内核不认识 `HOST-SUFFIX`、`USER-AGENT` 等圈叉语法，直接交给内核会丢规则并刷出大量警告，
/// 所以由 Flash 自己下载、转换，再以文件型规则集提供给内核。
/// @author ygw
public enum QXRuleSetCache {
    /// 规则集的缓存目录（内核工作目录下的 providers）
    public static var directory: URL { AppPaths.coreDir.appendingPathComponent("providers", isDirectory: true) }

    /// 规则集缓存文件
    public static func file(for providerName: String) -> URL { directory.appendingPathComponent("\(providerName).txt") }

    /// 圈叉规则类型 → mihomo 规则类型
    static let typeMap: [String: String] = [
        "HOST": "DOMAIN", "HOST-SUFFIX": "DOMAIN-SUFFIX", "HOST-KEYWORD": "DOMAIN-KEYWORD",
        "HOST-WILDCARD": "DOMAIN-WILDCARD", "IP-CIDR": "IP-CIDR", "IP6-CIDR": "IP-CIDR6", "IP-ASN": "IP-ASN",
        // 已经是 mihomo / Surge 写法的也放行，兼容混合列表
        "DOMAIN": "DOMAIN", "DOMAIN-SUFFIX": "DOMAIN-SUFFIX", "DOMAIN-KEYWORD": "DOMAIN-KEYWORD",
        "DOMAIN-WILDCARD": "DOMAIN-WILDCARD", "IP-CIDR6": "IP-CIDR6",
    ]

    /// 把圈叉列表文本转换为 classical 文本
    /// - Parameter text: 列表原文
    /// - Returns: 转换后的规则行，以及被丢弃的行数（USER-AGENT 等内核不支持的类型）
    public static func convert(_ text: String) -> (lines: [String], skipped: Int) {
        var out: [String] = []
        var skipped = 0
        out.reserveCapacity(1024)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let mapped = typeMap[parts[0].uppercased()] else { skipped += 1; continue }
            var rule = "\(mapped),\(parts[1])"
            // 圈叉列表的第 3 列是策略名，丢弃；仅保留 no-resolve
            if mapped.hasPrefix("IP-") , parts.dropFirst(2).contains(where: { $0.lowercased() == "no-resolve" }) {
                rule += ",no-resolve"
            }
            out.append(rule)
        }
        return (out, skipped)
    }

    /// 确保所有圈叉规则集的缓存文件存在且不过期
    /// - Parameters:
    ///   - providers: 组合后的规则集（只处理 flavor 为 qx 的）
    ///   - maxAge: 缓存有效期（秒）
    /// - Returns: changed 表示有文件被更新；warnings 为下载失败等提示
    public static func prepare(providers: [RuleProviderSpec], maxAge: TimeInterval = 86400) async -> (changed: Bool, warnings: [String]) {
        let targets = providers.filter { $0.flavor == "qx" && $0.url != nil }
        guard !targets.isEmpty else { return (false, []) }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var changed = false
        var warnings: [String] = []
        await withTaskGroup(of: (Bool, String?).self) { group in
            for p in targets {
                let url = p.url!, path = file(for: p.name)
                group.addTask {
                    let attrs = try? fm.attributesOfItem(atPath: path.path)
                    let fresh = (attrs?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) < maxAge } ?? false
                    if fresh { return (false, nil) }
                    do {
                        guard let u = URL(string: url) else { throw URLError(.badURL) }
                        let r = try await Downloader.fetch(url: u, userAgent: "Flash", timeout: 40)
                        guard (200..<300).contains(r.response.statusCode), let text = String(data: r.data, encoding: .utf8) else {
                            throw URLError(.badServerResponse)
                        }
                        let payload = convert(text).lines.joined(separator: "\n") + "\n"
                        let old = try? String(contentsOf: path, encoding: .utf8)
                        try payload.write(to: path, atomically: true, encoding: .utf8)
                        return (old != payload, nil)
                    } catch {
                        // 下载失败：有旧缓存就继续用，没有就写空文件，保证内核能启动
                        if !fm.fileExists(atPath: path.path) { try? "".write(to: path, atomically: true, encoding: .utf8) }
                        let host = URL(string: url)?.host ?? url
                        return (false, "规则集 \(p.name)（\(host)）下载失败，沿用旧缓存或暂为空：\(error.localizedDescription)")
                    }
                }
            }
            for await (c, w) in group {
                if c { changed = true }
                if let w { warnings.append(w) }
            }
        }
        return (changed, warnings)
    }
}
