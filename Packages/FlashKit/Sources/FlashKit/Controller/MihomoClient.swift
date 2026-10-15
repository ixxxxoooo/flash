import Foundation

public enum MihomoError: Error, LocalizedError {
    case http(Int, String)
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "内核返回错误 \(code): \(msg)"
        case .invalidResponse: return "内核返回了无法识别的响应"
        }
    }
}

/// mihomo 控制器客户端（REST + WebSocket）
public final class MihomoClient: @unchecked Sendable {
    public let baseURL: URL
    public let secret: String
    private let session: URLSession

    public init(host: String = "127.0.0.1", port: Int, secret: String) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:]   // 控制器请求不走系统代理
        self.session = URLSession(configuration: config)
    }

    // MARK: REST 基础

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    @discardableResult
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let (data, resp) = try await session.data(for: makeRequest(method, path, query: query, body: body))
        guard let http = resp as? HTTPURLResponse else { throw MihomoError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw MihomoError.http(http.statusCode, msg)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    // MARK: 状态 / 配置

    public func version() async throws -> VersionInfo { try await get("version") }
    public func configs() async throws -> CoreConfigInfo { try await get("configs") }

    /// 切换出站模式：rule / global / direct
    public func setMode(_ mode: String) async throws {
        try await send("PATCH", "configs", body: json(["mode": mode]))
    }

    /// 热重载配置文件
    public func reload(configPath: String) async throws {
        try await send("PUT", "configs", query: [URLQueryItem(name: "force", value: "true")], body: json(["path": configPath]))
    }

    public func flushDNS() async throws {
        try await send("POST", "cache/dns/flush")
        _ = try? await send("POST", "cache/fakeip/flush")
    }

    // MARK: 策略

    public func policies() async throws -> [String: PolicyInfo] {
        let resp: ProxiesResponse = try await get("proxies")
        return resp.proxies
    }

    public func select(group: String, policy: String) async throws {
        try await send("PUT", "proxies/\(encode(group))", body: json(["name": policy]))
    }

    /// 单个节点延迟（毫秒），失败抛出异常
    public func delay(of name: String, url: String, timeout: Int = 5000) async throws -> Int {
        struct R: Decodable { var delay: Int? }
        let data = try await send("GET", "proxies/\(encode(name))/delay",
                                  query: [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeout))])
        return (try? JSONDecoder().decode(R.self, from: data))?.delay ?? 0
    }

    /// 策略组整体延迟测试
    public func groupDelay(_ group: String, url: String, timeout: Int = 5000) async throws -> [String: Int] {
        let data = try await send("GET", "group/\(encode(group))/delay",
                                  query: [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeout))])
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    // MARK: 规则 / 连接

    public func rules() async throws -> [RuleInfo] {
        let resp: RulesResponse = try await get("rules")
        return resp.rules
    }

    public func connections() async throws -> ConnectionsSnapshot { try await get("connections") }

    public func closeConnection(id: String) async throws { try await send("DELETE", "connections/\(encode(id))") }
    public func closeAllConnections() async throws { try await send("DELETE", "connections") }

    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    // MARK: WebSocket 流

    /// 通用 WebSocket 流：断线后指数退避自动重连
    func stream<T: Decodable & Sendable>(path: String, query: [URLQueryItem] = [], as type: T.Type) -> AsyncStream<T> {
        let baseURL = self.baseURL
        let secret = self.secret
        let session = self.session
        return AsyncStream { continuation in
            let task = Task {
                var backoff: UInt64 = 500_000_000
                while !Task.isCancelled {
                    var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
                    comps.scheme = "ws"
                    var items = query
                    if !secret.isEmpty { items.append(URLQueryItem(name: "token", value: secret)) }
                    comps.queryItems = items
                    var req = URLRequest(url: comps.url!)
                    if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
                    let ws = session.webSocketTask(with: req)
                    ws.resume()
                    do {
                        while !Task.isCancelled {
                            let message = try await ws.receive()
                            backoff = 500_000_000
                            let data: Data
                            switch message {
                            case .data(let d): data = d
                            case .string(let s): data = Data(s.utf8)
                            @unknown default: continue
                            }
                            if let value = try? JSONDecoder().decode(T.self, from: data) {
                                continuation.yield(value)
                            }
                        }
                    } catch {
                        // 连接断开，退避后重连
                    }
                    ws.cancel(with: .goingAway, reason: nil)
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 5_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func trafficStream() -> AsyncStream<TrafficSample> {
        stream(path: "traffic", as: TrafficSample.self)
    }

    public func connectionsStream(interval: Int = 1000) -> AsyncStream<ConnectionsSnapshot> {
        stream(path: "connections", query: [URLQueryItem(name: "interval", value: String(interval))], as: ConnectionsSnapshot.self)
    }

    public func memoryStream() -> AsyncStream<MemorySample> {
        stream(path: "memory", as: MemorySample.self)
    }

    public func logStream(level: String = "info") -> AsyncStream<LogEntry> {
        let raw = stream(path: "logs", query: [URLQueryItem(name: "level", value: level)], as: RawLog.self)
        return AsyncStream { continuation in
            let task = Task {
                for await item in raw {
                    continuation.yield(LogEntry(level: item.type, message: item.payload))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
