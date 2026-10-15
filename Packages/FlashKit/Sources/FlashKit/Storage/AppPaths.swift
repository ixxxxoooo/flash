import Foundation

/// 应用数据目录管理。可通过环境变量 FLASH_HOME 覆盖（用于测试与冒烟脚本）。
public enum AppPaths {
    /// 应用支持目录：~/Library/Application Support/Flash
    public static var supportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["FLASH_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Flash", isDirectory: true)
    }

    /// 内核工作目录（mihomo -d），存放 runtime.yaml、缓存和 geo 数据
    public static var coreDir: URL { supportDir.appendingPathComponent("core", isDirectory: true) }
    /// 运行时配置文件
    public static var runtimeConfig: URL { coreDir.appendingPathComponent("runtime.yaml") }
    /// 订阅数据目录
    public static var subscriptionsDir: URL { supportDir.appendingPathComponent("subscriptions", isDirectory: true) }
    /// 订阅索引文件
    public static var subscriptionsIndex: URL { supportDir.appendingPathComponent("subscriptions.json") }
    /// 配置（Surge 风格文本）目录
    public static var profilesDir: URL { supportDir.appendingPathComponent("profiles", isDirectory: true) }
    /// 主配置文本
    public static var mainProfile: URL { profilesDir.appendingPathComponent("main.conf") }
    /// 本地覆盖层文本
    public static var overlayProfile: URL { profilesDir.appendingPathComponent("overlay.conf") }
    /// 受管配置（远程）缓存
    public static var managedCache: URL { profilesDir.appendingPathComponent("managed.cache.conf") }
    /// 日志目录
    public static var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
    /// 内核日志文件
    public static var coreLog: URL { logsDir.appendingPathComponent("core.log") }
    /// 统计数据库
    public static var statsDB: URL { supportDir.appendingPathComponent("stats.sqlite") }
    /// 系统代理备份（含脏标记）
    public static var proxyBackup: URL { supportDir.appendingPathComponent("system-proxy-backup.json") }
    /// 内核 PID 文件，用于清理残留进程
    public static var jobPlist: URL { coreDir.appendingPathComponent("com.flash.core.plist") }

    public static var corePID: URL { supportDir.appendingPathComponent("core.pid") }

    /// 确保所有目录存在
    public static func prepare() {
        let fm = FileManager.default
        for dir in [supportDir, coreDir, subscriptionsDir, profilesDir, logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// 简单的 JSON 文件读写工具
public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
