import Foundation
import AppKit
import SwiftUI

/// 数值格式化工具
enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        return f
    }()

    static func bytes(_ n: Int) -> String {
        if n <= 0 { return "0 B" }
        if n < 1000 { return "\(n) B" }
        return byteFormatter.string(fromByteCount: Int64(n))
    }

    static func bytes64(_ n: Int64) -> String { bytes(Int(clamping: n)) }

    static func rate(_ n: Int) -> String {
        if n <= 0 { return "0 B/s" }
        return bytes(n) + "/s"
    }

    /// 紧凑速率，用于菜单栏，如 "1.2M"
    static func compactRate(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case ..<1000: return "\(n)B"
        case ..<1_000_000: return String(format: "%.0fK", v / 1000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.1fG", v / 1_000_000_000)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 时 \((s % 3600) / 60) 分"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String { relative.localizedString(for: date, relativeTo: Date()) }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func clock(_ date: Date) -> String { clock.string(from: date) }

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ date: Date) -> String { dateOnly.string(from: date) }
}

/// 进程图标缓存（按可执行文件路径解析所属 .app）
@MainActor
enum ProcessIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(path: String, name: String) -> NSImage {
        let key = path.isEmpty ? name : path
        if let hit = cache[key] { return hit }
        var image: NSImage?
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            image = NSWorkspace.shared.icon(forFile: appPath)
        } else if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        let result = image ?? NSWorkspace.shared.icon(for: .unixExecutable)
        result.size = NSSize(width: 32, height: 32)
        cache[key] = result
        return result
    }
}

extension Color {
    /// 品牌强调色
    static let flashAccent = Color(red: 0.13, green: 0.72, blue: 0.80)
    static let upColor = Color(red: 0.98, green: 0.55, blue: 0.20)
    static let downColor = Color(red: 0.20, green: 0.60, blue: 0.98)

    /// 根据延迟返回颜色
    static func delayColor(_ ms: Int) -> Color {
        switch ms {
        case ..<1: return .secondary
        case ..<200: return .green
        case ..<500: return .orange
        default: return .red
        }
    }
}
