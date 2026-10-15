import Foundation
import Observation

/// 通用下载工具
public enum Downloader {
    public struct Result: Sendable {
        public var data: Data
        public var response: HTTPURLResponse
    }

    public static func fetch(url: URL, userAgent: String, etag: String? = nil, timeout: TimeInterval = 30) async throws -> Result {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let (data, resp) = try await URLSession(configuration: config).data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return Result(data: data, response: http)
    }
}

/// 订阅用量信息（来自响应头 subscription-userinfo）
public struct SubscriptionUsage: Codable, Hashable, Sendable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Date?

    public init(upload: Int64, download: Int64, total: Int64, expire: Date? = nil) {
        self.upload = upload; self.download = download; self.total = total; self.expire = expire
    }

    public var used: Int64 { upload + download }
    public var remaining: Int64 { max(0, total - used) }
    public var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    /// 解析 `upload=123; download=456; total=789; expire=1700000000`
    public static func parse(_ header: String) -> SubscriptionUsage? {
        var up: Int64 = 0, down: Int64 = 0, total: Int64 = 0
        var expire: Date?
        var found = false
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let n = Double(kv[1]) else { continue }
            found = true
            switch kv[0].lowercased() {
            case "upload": up = Int64(n)
            case "download": down = Int64(n)
            case "total": total = Int64(n)
            case "expire": if n > 0 { expire = Date(timeIntervalSince1970: n) }
            default: break
            }
        }
        return found ? SubscriptionUsage(upload: up, download: down, total: total, expire: expire) : nil
    }
}

public struct Subscription: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 订阅地址；为空表示本地导入，不会自动更新
    public var url: String
    /// 更新间隔（小时）
    public var intervalHours: Int
    public var userAgent: String
    public var enabled: Bool
    public var lastUpdated: Date?
    public var nodeCount: Int
    public var format: SubscriptionFormat?
    public var usage: SubscriptionUsage?
    public var lastError: String?
    public var etag: String?

    public init(id: UUID = UUID(), name: String, url: String, intervalHours: Int = 24,
                userAgent: String = "clash.meta/1.19.0", enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.intervalHours = intervalHours
        self.userAgent = userAgent; self.enabled = enabled; self.nodeCount = 0
    }

    public var isLocal: Bool { url.isEmpty }

    public var isDue: Bool {
        guard !isLocal, enabled else { return false }
        guard let last = lastUpdated else { return true }
        return Date().timeIntervalSince(last) >= Double(max(1, intervalHours)) * 3600
    }
}

/// 订阅管理：增删、下载解码、定时更新、节点缓存
@MainActor
@Observable
public final class SubscriptionManager {
    public private(set) var items: [Subscription] = []
    public private(set) var updating: Set<UUID> = []
    /// 订阅内容变化（新增、更新、启停、删除）后回调，用于重新生成配置
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private var nodeCache: [UUID: [ProxyNode]] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init() {
        AppPaths.prepare()
        items = JSONFile.load([Subscription].self, from: AppPaths.subscriptionsIndex) ?? []
        for s in items { nodeCache[s.id] = JSONFile.load([ProxyNode].self, from: nodeFile(s.id)) ?? [] }
    }

    private func nodeFile(_ id: UUID) -> URL { AppPaths.subscriptionsDir.appendingPathComponent("\(id.uuidString).json") }
    private func persist() { JSONFile.save(items, to: AppPaths.subscriptionsIndex) }

    // MARK: 查询

    public func nodes(for id: UUID) -> [ProxyNode] { nodeCache[id] ?? [] }

    /// 已启用订阅的节点集合，供组合器使用
    public func enabledNodes() -> [SubscriptionNodes] {
        items.filter { $0.enabled }.map { SubscriptionNodes(name: $0.name, url: $0.url, nodes: nodes(for: $0.id)) }
    }

    // MARK: 增删改

    /// 添加订阅并立即拉取；失败时不保留
    @discardableResult
    public func add(name: String, url: String) async throws -> Subscription {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw URLError(.badURL)
        }
        var sub = Subscription(name: name.isEmpty ? (u.host ?? "订阅") : name, url: trimmed)
        items.append(sub)
        persist()
        let ok = await update(sub.id, force: true)
        if let i = items.firstIndex(where: { $0.id == sub.id }) {
            sub = items[i]
            if !ok {
                let message = sub.lastError ?? "更新失败"
                items.remove(at: i); nodeCache[sub.id] = nil; persist()
                throw NSError(domain: "Flash.Subscription", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        return sub
    }

    /// 从粘贴的文本（分享链接 / Clash YAML / Base64）直接导入为本地订阅
    @discardableResult
    public func importText(name: String, text: String) throws -> Subscription {
        let decoded = try SubscriptionDecoder.decode(Data(text.utf8))
        var sub = Subscription(name: name.isEmpty ? "本地导入" : name, url: "")
        sub.lastUpdated = Date(); sub.nodeCount = decoded.nodes.count; sub.format = decoded.format
        items.append(sub)
        nodeCache[sub.id] = decoded.nodes
        JSONFile.save(decoded.nodes, to: nodeFile(sub.id))
        persist()
        onChange?()
        return sub
    }

    /// 注入演示订阅（仅内存，不落盘，演示模式专用）
    public func injectDemo(_ sub: Subscription, nodes: [ProxyNode]) {
        items.append(sub)
        nodeCache[sub.id] = nodes
        onChange?()
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        nodeCache[id] = nil
        try? FileManager.default.removeItem(at: nodeFile(id))
        persist()
        onChange?()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].enabled = enabled
        persist()
        onChange?()
    }

    public func rename(_ id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = name
        persist()
        onChange?()
    }

    public func setInterval(_ id: UUID, hours: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].intervalHours = max(1, hours)
        persist()
    }

    // MARK: 更新

    /// 更新单个订阅，返回是否成功
    @discardableResult
    public func update(_ id: UUID, force: Bool = false) async -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }), !items[idx].isLocal,
              !updating.contains(id) else { return false }
        let sub = items[idx]
        updating.insert(id)
        defer { updating.remove(id) }

        do {
            guard let url = URL(string: sub.url) else { throw URLError(.badURL) }
            let result = try await Downloader.fetch(url: url, userAgent: sub.userAgent, etag: force ? nil : sub.etag)
            let code = result.response.statusCode
            if code == 304 {
                mutate(id) { $0.lastUpdated = Date(); $0.lastError = nil }
                return true
            }
            guard (200..<300).contains(code) else {
                throw NSError(domain: "Flash.Subscription", code: code,
                              userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(code)"])
            }
            let decoded = try SubscriptionDecoder.decode(result.data)
            let header = result.response.value(forHTTPHeaderField: "subscription-userinfo")
            let usage = header.flatMap(SubscriptionUsage.parse)
            let etag = result.response.value(forHTTPHeaderField: "ETag")
            let hours = result.response.value(forHTTPHeaderField: "profile-update-interval").flatMap { Int($0) }

            nodeCache[id] = decoded.nodes
            JSONFile.save(decoded.nodes, to: nodeFile(id))
            mutate(id) {
                $0.lastUpdated = Date(); $0.nodeCount = decoded.nodes.count; $0.format = decoded.format
                $0.usage = usage ?? $0.usage; $0.lastError = nil; $0.etag = etag
                if let hours, hours > 0 { $0.intervalHours = hours }
            }
            onChange?()
            return true
        } catch {
            // 失败时保留上一份可用节点，只记录错误
            mutate(id) { $0.lastError = error.localizedDescription }
            return false
        }
    }

    /// 更新所有订阅；onlyDue 为真时仅更新已到期的
    public func updateAll(onlyDue: Bool) async {
        let targets = items.filter { !$0.isLocal && $0.enabled && (!onlyDue || $0.isDue) }.map(\.id)
        for id in targets { await update(id, force: !onlyDue) }
    }

    private func mutate(_ id: UUID, _ change: (inout Subscription) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        persist()
    }

    // MARK: 定时

    /// 启动后台定时检查（每 5 分钟检查一次到期订阅）
    public func startAutoUpdate() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateAll(onlyDue: true)
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
    }

    public func stopAutoUpdate() { timer?.cancel(); timer = nil }
}
