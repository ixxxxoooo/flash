import Foundation

/// 报文体的展示格式化：JSON 美化、文本、十六进制
/// @author ygw
public enum BodyFormatter {
    public enum Mode: String, CaseIterable, Sendable {
        case auto = "自动", raw = "原文", hex = "十六进制"
    }

    /// 界面最多渲染的字节数，超出部分截断（避免超大文本拖慢界面）
    public static let renderLimit = 256 * 1024

    /// 格式化报文体
    /// - Parameters:
    ///   - data: 已按 Content-Encoding 解码的内容
    ///   - contentType: Content-Type 头（用于判断 JSON）
    ///   - mode: 展示模式
    /// - Returns: 可直接展示的文本
    public static func format(_ data: Data, contentType: String?, mode: Mode) -> String {
        if data.isEmpty { return "（空）" }
        let clipped = data.count > renderLimit ? data.prefix(renderLimit) : data
        let suffix = data.count > renderLimit ? "\n…（已截断，共 \(data.count) 字节）" : ""
        switch mode {
        case .hex:
            return hexDump(Data(clipped.prefix(16 * 1024))) + (data.count > 16 * 1024 ? "\n…（仅显示前 16 KB）" : "")
        case .raw:
            if let s = String(data: clipped, encoding: .utf8) { return s + suffix }
            return hexDump(Data(clipped.prefix(16 * 1024)))
        case .auto:
            let isJSON = (contentType ?? "").lowercased().contains("json")
            if isJSON || looksLikeJSON(clipped), data.count <= renderLimit,
               let obj = try? JSONSerialization.jsonObject(with: clipped, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: pretty, encoding: .utf8) {
                return s
            }
            if let s = String(data: clipped, encoding: .utf8) { return s + suffix }
            return hexDump(Data(clipped.prefix(16 * 1024))) + (data.count > 16 * 1024 ? "\n…（仅显示前 16 KB）" : "")
        }
    }

    private static func looksLikeJSON(_ d: Data) -> Bool {
        guard let first = d.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    /// 标准十六进制转储：偏移 + 16 字节 + ASCII
    public static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + padded + "  " + ascii)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }
}
