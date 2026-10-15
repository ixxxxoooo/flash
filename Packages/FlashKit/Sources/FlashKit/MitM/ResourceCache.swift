import Foundation

/// 脚本 / Map Local 数据文件的本地缓存。
///
/// 路径可以是本机文件、`file://` 地址或 http(s) 地址；远程资源会预先下载到
/// 应用数据目录（默认 24 小时刷新），引擎运行时只读缓存，避免在网络线程里做同步下载。
///
/// @author ygw
public final class ResourceCache: @unchecked Sendable {
    public static let shared = ResourceCache()

    private let lock = NSLock()
    private var memory: [String: Data] = [:]
    private let directory: URL
    private let ttl: TimeInterval = 86400

    public init(directory: URL = AppPaths.supportDir.appendingPathComponent("mitm/resources", isDirectory: true)) {
        self.directory = directory
    }

    private func cacheFile(_ key: String) -> URL { directory.appendingPathComponent(SurgeText.stableHash(key)) }

    /// 同步读取已缓存的资源（本地文件直接读取）
    /// - Parameter path: 路径或 URL
    /// - Returns: 资源内容，不可用返回 nil
    public func cached(_ path: String) -> Data? {
        if let local = Self.localURL(path) { return try? Data(contentsOf: local) }
        lock.lock()
        if let d = memory[path] { lock.unlock(); return d }
        lock.unlock()
        guard let d = try? Data(contentsOf: cacheFile(path)) else { return nil }
        lock.lock(); memory[path] = d; lock.unlock()
        return d
    }

    /// 预取远程资源（本地文件无需预取）
    /// - Parameters:
    ///   - paths: 路径集合
    ///   - force: 是否忽略缓存强制刷新
    public func prefetch(_ paths: [String], force: Bool = false) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in Set(paths) where Self.localURL(path) == nil {
            guard let url = URL(string: path), url.scheme?.hasPrefix("http") == true else { continue }
            let file = cacheFile(path)
            if !force, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < ttl { continue }
            do {
                let r = try await Downloader.fetch(url: url, userAgent: "Flash/1.0", timeout: 20)
                guard (200..<300).contains(r.response.statusCode) else { continue }
                try r.data.write(to: file, options: .atomic)
                remember(path, r.data)
            } catch {
                // 下载失败时沿用旧缓存（若有）
            }
        }
    }

    private func remember(_ path: String, _ data: Data) {
        lock.lock(); memory[path] = data; lock.unlock()
    }

    /// 本地路径解析：绝对路径、`~` 开头或 `file://`；其它返回 nil（视为远程）
    static func localURL(_ path: String) -> URL? {
        if path.hasPrefix("file://") { return URL(string: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return nil
    }
}
