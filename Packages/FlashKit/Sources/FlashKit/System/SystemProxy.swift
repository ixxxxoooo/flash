import Foundation

/// 单个代理端点（HTTP / HTTPS / SOCKS）
public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var port: Int
    public init(enabled: Bool = false, server: String = "", port: Int = 0) {
        self.enabled = enabled; self.server = server; self.port = port
    }
}

/// 某个网络服务（如 Wi-Fi）的代理状态快照
public struct ServiceProxyState: Codable, Equatable, Sendable {
    public var service: String
    public var web: ProxyEndpoint
    public var secureWeb: ProxyEndpoint
    public var socks: ProxyEndpoint
    public var bypass: [String]
}

/// 备份文件：dirty 为真表示 Flash 正在接管系统代理，尚未恢复
public struct ProxyBackup: Codable, Sendable {
    public var dirty: Bool
    public var states: [ServiceProxyState]
}

public enum SystemProxyError: Error, LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? {
        switch self { case .commandFailed(let m): return "设置系统代理失败: \(m)" }
    }
}

/// 系统代理设置：通过 networksetup 修改，失败时一次性提权重试；设置前备份，退出时恢复
public final class SystemProxy: @unchecked Sendable {
    public static let shared = SystemProxy()
    private let lock = NSLock()

    public static let defaultBypass = [
        "localhost", "127.0.0.1", "*.local", "169.254.0.0/16",
        "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12",
    ]

    // MARK: 命令执行

    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 按服务分组：组间并发、组内串行；任一失败则整体用管理员权限重试一次
    func apply(groups: [[[String]]]) throws {
        let failures = FailureBox()
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            for cmd in groups[i] {
                let r = Self.run(cmd)
                if r.status != 0 { failures.record(r.output); break }
            }
        }
        guard failures.failed else { return }
        let commands = groups.flatMap { $0 }
        let script = commands
            .map { (["/usr/sbin/networksetup"] + $0).map { Self.shellQuote($0) }.joined(separator: " ") }
            .joined(separator: "; ")
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(data: data, encoding: .utf8) ?? ""
            throw SystemProxyError.commandFailed(out.isEmpty ? failures.output : out)
        }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failed = false
        private(set) var output = ""
        func record(_ out: String) { lock.lock(); failed = true; output = out; lock.unlock() }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: 查询

    /// 列出已启用的网络服务
    public static func listServices() -> [String] {
        let r = run(["-listallnetworkservices"])
        return r.output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// 解析 `networksetup -getwebproxy` 一类命令的输出
    public static func parseEndpoint(_ output: String) -> ProxyEndpoint {
        var ep = ProxyEndpoint()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": ep.enabled = parts[1].lowercased() == "yes"
            case "Server": ep.server = parts[1]
            case "Port": ep.port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return ep
    }

    static func parseBypass(_ output: String) -> [String] {
        if output.contains("aren't any") { return [] }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func capture(service: String) -> ServiceProxyState {
        ServiceProxyState(
            service: service,
            web: parseEndpoint(run(["-getwebproxy", service]).output),
            secureWeb: parseEndpoint(run(["-getsecurewebproxy", service]).output),
            socks: parseEndpoint(run(["-getsocksfirewallproxy", service]).output),
            bypass: parseBypass(run(["-getproxybypassdomains", service]).output)
        )
    }

    /// 当前系统代理是否已指向 Flash 的端口
    public static func isPointingTo(host: String, port: Int) -> Bool {
        let services = listServices()
        guard !services.isEmpty else { return false }
        return services.contains { svc in
            let s = capture(service: svc)
            return s.web.enabled && s.web.server == host && s.web.port == port
        }
    }

    // MARK: 启用 / 恢复

    /// 启用系统代理（HTTP/HTTPS/SOCKS 全部指向 host:port）
    public func enable(host: String = "127.0.0.1", port: Int, bypass: [String] = SystemProxy.defaultBypass) throws {
        lock.lock(); defer { lock.unlock() }
        let services = Self.listServices()
        guard !services.isEmpty else { throw SystemProxyError.commandFailed("未找到可用的网络服务") }

        // 已处于接管状态时保留原始备份，避免把自己的设置当作“原值”
        var backup = JSONFile.load(ProxyBackup.self, from: AppPaths.proxyBackup)
        if backup?.dirty != true {
            backup = ProxyBackup(dirty: true, states: services.map { Self.capture(service: $0) })
        }
        JSONFile.save(backup!, to: AppPaths.proxyBackup)

        let portText = String(port)
        let groups: [[[String]]] = services.map { svc in
            [["-setwebproxy", svc, host, portText],
             ["-setsecurewebproxy", svc, host, portText],
             ["-setsocksfirewallproxy", svc, host, portText],
             ["-setproxybypassdomains", svc] + bypass]
        }
        try apply(groups: groups)
    }

    /// 恢复备份中的原始设置
    public func restore() throws {
        lock.lock(); defer { lock.unlock() }
        guard var backup = JSONFile.load(ProxyBackup.self, from: AppPaths.proxyBackup), backup.dirty else { return }
        let current = Set(Self.listServices())
        let groups = backup.states.filter { current.contains($0.service) }.map { Self.restoreCommands($0) }
        try apply(groups: groups)
        backup.dirty = false
        JSONFile.save(backup, to: AppPaths.proxyBackup)
    }

    /// 启动时若上次异常退出未恢复，则先恢复
    public func restoreIfDirty() {
        if let b = JSONFile.load(ProxyBackup.self, from: AppPaths.proxyBackup), b.dirty {
            try? restore()
        }
    }

    static func restoreCommands(_ s: ServiceProxyState) -> [[String]] {
        func one(_ ep: ProxyEndpoint, set: String, state: String) -> [[String]] {
            if ep.enabled, !ep.server.isEmpty {
                return [[set, s.service, ep.server, String(ep.port)]]
            }
            // 原本未启用：先还原地址（通常为空），再关闭，保证与原状态完全一致
            return [[set, s.service, ep.server, String(ep.port)], [state, s.service, "off"]]
        }
        var cmds: [[String]] = []
        cmds += one(s.web, set: "-setwebproxy", state: "-setwebproxystate")
        cmds += one(s.secureWeb, set: "-setsecurewebproxy", state: "-setsecurewebproxystate")
        cmds += one(s.socks, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate")
        cmds.append(["-setproxybypassdomains", s.service] + (s.bypass.isEmpty ? ["Empty"] : s.bypass))
        return cmds
    }

    /// 同步版恢复（应用退出时使用，忽略错误）
    public func restoreSilently() { try? restore() }
}
