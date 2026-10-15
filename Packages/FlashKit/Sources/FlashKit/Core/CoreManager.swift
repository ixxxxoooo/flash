import Foundation
import Observation

/// 端口工具：检测占用与获取空闲端口
public enum PortUtil {
    /// 检查端口是否可绑定（127.0.0.1）
    public static func isAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// 让系统分配一个空闲端口
    public static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 19090 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// 内核定位：优先环境变量，其次应用包内资源，最后仓库内的开发路径
public enum CoreLocator {
    public static func binary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FLASH_CORE_PATH"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Core/mihomo"))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Core/mihomo"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// geo 数据所在目录（与内核同目录）
    public static func resourceDir() -> URL? { binary()?.deletingLastPathComponent() }
}

/// 内核进程管理：启动、停止、崩溃自动重启
@MainActor
@Observable
public final class CoreManager {
    public enum Status: Equatable {
        case stopped
        case starting
        case running(version: String)
        case failed(String)

        public var isRunning: Bool { if case .running = self { return true } else { return false } }
        public var isBusy: Bool { if case .starting = self { return true } else { return false } }
    }

    public private(set) var status: Status = .stopped
    public private(set) var client: MihomoClient?
    public private(set) var controllerPort: Int = 0
    public private(set) var secret: String = ""
    /// 内核最近的输出行（用于错误提示）
    public private(set) var recentOutput: [String] = []

    /// 内核由 launchd 托管，这里只记录 PID
    private var corePID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    /// launchd 任务标签；使用自定义数据目录（FLASH_HOME，测试 / 演示用）时附加目录哈希，避免互相干扰
    static let jobLabel: String = {
        guard let home = ProcessInfo.processInfo.environment["FLASH_HOME"], !home.isEmpty else { return "com.flash.core" }
        var h: UInt32 = 5381
        for b in home.utf8 { h = h &* 33 &+ UInt32(b) }
        return "com.flash.core.\(String(h, radix: 16))"
    }()
    private var currentYAML: String = ""
    private var requestedStop = false
    private var restartAttempts: [Date] = []

    public init() {}

    // MARK: 启停

    /// 启动内核。`yaml` 必须已包含 external-controller 与 secret。
    public func start(yaml: String, controllerPort: Int, secret: String) async {
        await stop()
        AppPaths.prepare()
        guard let binary = CoreLocator.binary() else {
            status = .failed("未找到 mihomo 内核，请运行 scripts/fetch-core.sh")
            return
        }
        status = .starting
        requestedStop = false
        currentYAML = yaml
        self.controllerPort = controllerPort
        self.secret = secret
        client = MihomoClient(port: controllerPort, secret: secret)
        recentOutput = []
        Self.killStaleCore()
        seedGeoData()

        do {
            try yaml.write(to: AppPaths.runtimeConfig, atomically: true, encoding: .utf8)
            // 配置中含控制器密钥，仅当前用户可读
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.runtimeConfig.path)
        } catch {
            status = .failed("写入运行配置失败: \(error.localizedDescription)")
            return
        }

        // 通过 launchd 托管内核进程。
        // 原因：作为 Flash.app 的直接子进程时，macOS 会让内核读不到其他进程的套接字归属，
        // 导致无法识别发起连接的进程（PROCESS-NAME 规则、请求列表的进程列都会失效）；
        // 由 launchd 拉起则一切正常。
        FileManager.default.createFile(atPath: AppPaths.coreLog.path, contents: nil)
        do {
            try Self.writeJobPlist(binary: binary)
        } catch {
            status = .failed("写入内核启动项失败: \(error.localizedDescription)")
            return
        }
        _ = Self.launchctl(["bootout", Self.domainTarget])
        let boot = Self.launchctl(["bootstrap", Self.domain, AppPaths.jobPlist.path])
        guard boot.status == 0 else {
            status = .failed("启动内核失败: \(boot.output)")
            return
        }
        // 等待 launchd 报告 PID
        var pid: pid_t = 0
        for _ in 0..<30 {
            pid = Self.jobPID()
            if pid > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard pid > 0 else {
            refreshRecentOutput()
            status = .failed("内核未能启动\n" + recentOutput.suffix(5).joined(separator: "\n"))
            return
        }
        corePID = pid
        watchExit(of: pid)
        try? "\(pid)".write(to: AppPaths.corePID, atomically: true, encoding: .utf8)

        // 等待控制器就绪
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if corePID == 0 || kill(corePID, 0) != 0 { return }   // 已由退出监听设置失败状态
            if let v = try? await client?.version() {
                status = .running(version: v.version)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if status == .starting {
            refreshRecentOutput()
            status = .failed("内核启动超时\n" + recentOutput.suffix(5).joined(separator: "\n"))
        }
    }

    /// 停止内核
    public func stop() async {
        requestedStop = true
        exitSource?.cancel()
        exitSource = nil
        let pid = corePID
        corePID = 0
        guard pid > 0 else {
            if status != .stopped, !status.isBusy { status = .stopped }
            return
        }
        _ = Self.launchctl(["bootout", Self.domainTarget])
        // 最多等 2 秒，仍未退出则强杀
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: AppPaths.corePID)
        status = .stopped
    }

    /// 同步终止（应用退出时调用）
    public func terminateNow() {
        requestedStop = true
        exitSource?.cancel()
        exitSource = nil
        let pid = corePID
        corePID = 0
        if pid > 0 { kill(pid, SIGTERM) }
        _ = Self.launchctl(["bootout", Self.domainTarget])
        try? FileManager.default.removeItem(at: AppPaths.corePID)
    }

    /// 热重载；失败则整体重启
    public func reload(yaml: String) async {
        guard status.isRunning, let client else { return }
        currentYAML = yaml
        do {
            try yaml.write(to: AppPaths.runtimeConfig, atomically: true, encoding: .utf8)
            try await client.reload(configPath: AppPaths.runtimeConfig.path)
        } catch {
            await start(yaml: yaml, controllerPort: controllerPort, secret: secret)
        }
    }

    // MARK: 内部

    private func appendOutput(_ lines: [String]) {
        recentOutput.append(contentsOf: lines)
        if recentOutput.count > 200 { recentOutput.removeFirst(recentOutput.count - 200) }
    }

    private func handleTermination(code: Int32, pid: Int32) {
        // 忽略旧进程的退出回调
        guard corePID == pid else { return }
        if requestedStop { return }
        corePID = 0
        exitSource?.cancel()
        exitSource = nil
        refreshRecentOutput()
        let tail = recentOutput.suffix(6).joined(separator: "\n")
        status = .failed("内核意外退出（\(code)）\n\(tail)")

        // 60 秒内最多自动重启 3 次
        let now = Date()
        restartAttempts = restartAttempts.filter { now.timeIntervalSince($0) < 60 }
        guard restartAttempts.count < 3, !currentYAML.isEmpty else { return }
        restartAttempts.append(now)
        let yaml = currentYAML, port = controllerPort, sec = secret
        let delay = UInt64(restartAttempts.count) * 1_000_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !self.requestedStop else { return }
            await self.start(yaml: yaml, controllerPort: port, secret: sec)
        }
    }

    /// 监听内核进程退出（内核不是本进程的子进程，用 kqueue 事件监听）
    private func watchExit(of pid: pid_t) {
        exitSource?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleTermination(code: -1, pid: pid) }
        }
        exitSource = src
        src.resume()
        // 监听建立前进程可能已经退出
        if kill(pid, 0) != 0 { handleTermination(code: -1, pid: pid) }
    }

    /// 从日志文件末尾读取最近输出
    private func refreshRecentOutput() {
        guard let data = try? Data(contentsOf: AppPaths.coreLog), !data.isEmpty else { return }
        let tail = data.suffix(8192)
        let text = String(decoding: tail, as: UTF8.self)
        recentOutput = text.split(whereSeparator: \.isNewline).suffix(40).map(String.init)
    }

    // MARK: launchd 托管

    static var domain: String { "gui/\(getuid())" }
    static var domainTarget: String { "gui/\(getuid())/\(jobLabel)" }

    private static func writeJobPlist(binary: URL) throws {
        let plist: [String: Any] = [
            "Label": jobLabel,
            "ProgramArguments": [binary.path, "-d", AppPaths.coreDir.path, "-f", AppPaths.runtimeConfig.path],
            "WorkingDirectory": AppPaths.coreDir.path,
            "StandardOutPath": AppPaths.coreLog.path,
            "StandardErrorPath": AppPaths.coreLog.path,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: AppPaths.jobPlist, options: .atomic)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 读取 launchd 任务当前的 PID（未运行返回 0）
    static func jobPID() -> pid_t {
        let r = launchctl(["print", domainTarget])
        guard r.status == 0 else { return 0 }
        for line in r.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let v = Int32(t.dropFirst(6)) { return v }
        }
        return 0
    }

    /// 将 geo 数据拷贝到工作目录，避免首次启动联网下载
    private func seedGeoData() {
        guard let src = CoreLocator.resourceDir() else { return }
        let fm = FileManager.default
        for name in ["geoip.metadb", "geosite.dat", "country.mmdb"] {
            let from = src.appendingPathComponent(name)
            let to = AppPaths.coreDir.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.copyItem(at: from, to: to)
            }
        }
    }

    /// 清理上次遗留的内核进程（崩溃或强制退出后）
    static func killStaleCore() {
        guard let text = try? String(contentsOf: AppPaths.corePID, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        // 仅当该 PID 确实是 mihomo 时才终止
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "comm="]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let name = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if name.contains("mihomo") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: AppPaths.corePID)
    }

    // MARK: 配置校验

    /// 使用 `mihomo -t` 校验配置，返回（是否通过，输出）
    public static func validate(yaml: String) async -> (ok: Bool, output: String) {
        guard let binary = CoreLocator.binary() else { return (false, "未找到 mihomo 内核") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-validate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 复用 geo 数据，避免校验时联网下载
        if let src = CoreLocator.resourceDir() {
            for name in ["geoip.metadb", "geosite.dat", "country.mmdb"] {
                try? FileManager.default.copyItem(at: src.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
        }
        let file = dir.appendingPathComponent("config.yaml")
        do { try yaml.write(to: file, atomically: true, encoding: .utf8) } catch { return (false, error.localizedDescription) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = binary
                p.arguments = ["-t", "-d", dir.path, "-f", file.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
