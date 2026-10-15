import Foundation

/// Surge 文本处理的通用工具
public enum SurgeText {
    /// 去掉行内注释（`//`、`#`、`;` 前至少有一个空格）
    public static func stripInlineComment(_ line: String) -> String {
        var inQuote: Character?
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = inQuote {
                if c == q { inQuote = nil }
            } else if c == "\"" || c == "'" {
                inQuote = c
            } else if i > 0, chars[i - 1] == " " || chars[i - 1] == "\t" {
                if c == "#" || c == ";" { return String(chars[..<i]).trimmingCharacters(in: .whitespaces) }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    return String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                }
            }
            i += 1
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// 按分隔符拆分，忽略引号与括号内的分隔符
    public static func splitTopLevel(_ s: String, separator: Character = ",") -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inQuote: Character?
        for c in s {
            if let q = inQuote {
                current.append(c)
                if c == q { inQuote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                inQuote = c
                current.append(c)
            case "(":
                depth += 1
                current.append(c)
            case ")":
                depth = max(0, depth - 1)
                current.append(c)
            case separator where depth == 0:
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(c)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    public static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// 解析 `key=value`，key 仅允许字母数字、`_`、`-`
    public static func keyValue(_ s: String) -> (key: String, value: String)? {
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let key = s[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let value = unquote(String(s[s.index(after: eq)...]))
        return (key, value)
    }

    public static func bool(_ s: String?) -> Bool? {
        guard let s else { return nil }
        switch s.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// 稳定哈希（Swift 内置 hashValue 每次启动都不同，不能用于文件名）
    public static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
