import Foundation

/// 系统里的 VPN 服务（圈叉、小火箭等网络扩展型 VPN）
public struct VPNService: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    /// Connected / Disconnected / Connecting / Disconnecting
    public var status: String

    public var isConnected: Bool { status == "Connected" || status == "Connecting" }
    public init(id: String, name: String, bundleID: String, status: String) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.status = status
    }
}

/// 全局生效的系统代理（应用实际读取的值，等价于 `scutil --proxy`）
public struct GlobalProxyState: Equatable, Sendable {
    public var httpEnabled: Bool
    public var httpPort: Int
    public var socksEnabled: Bool
    public var socksPort: Int

    /// 是否指向给定的本地代理端口
    public func points(to port: Int) -> Bool {
        (httpEnabled && httpPort == port) || (socksEnabled && socksPort == port)
    }
}

/// VPN 冲突检测：当圈叉等 VPN 成为主网络服务时，`networksetup` 写入的系统代理不会被应用读取
/// @author ygw
public enum VPNConflict {

    // MARK: 解析

    /// 解析 `scutil --nc list`
    /// - Parameter output: 命令输出
    /// - Returns: VPN 服务列表
    public static func parseList(_ output: String) -> [VPNService] {
        let pattern = #"\((Connected|Disconnected|Connecting|Disconnecting|Invalid)\)\s+([0-9A-Fa-f-]{36})\s+VPN\s+\(([^)]*)\)\s+"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [VPNService] = []
        for line in output.components(separatedBy: .newlines) {
            guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 5 else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            result.append(VPNService(id: g(2), name: g(4), bundleID: g(3), status: g(1)))
        }
        return result
    }

    /// 解析 `scutil --proxy` 的全局部分（忽略 __SCOPED__ 子字典）
    public static func parseGlobalProxy(_ output: String) -> GlobalProxyState {
        var values: [String: Int] = [:]
        var depth = 0
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") { depth += 1; continue }
            if line.hasPrefix("}") { depth -= 1; continue }
            guard depth == 1, let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let n = Int(v) { values[k] = n }
        }
        return GlobalProxyState(httpEnabled: values["HTTPEnable"] == 1, httpPort: values["HTTPPort"] ?? 0,
                                socksEnabled: values["SOCKSEnable"] == 1, socksPort: values["SOCKSPort"] ?? 0)
    }

    // MARK: 系统调用

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 当前系统里的 VPN 服务
    public static func list() -> [VPNService] { parseList(run("/usr/sbin/scutil", ["--nc", "list"]).output) }

    /// 当前全局生效的系统代理
    public static func globalProxy() -> GlobalProxyState { parseGlobalProxy(run("/usr/sbin/scutil", ["--proxy"]).output) }

    /// 断开 VPN（等价于在其 App 里点“断开”）
    /// - Parameter service: VPN 服务
    /// - Returns: 命令是否执行成功
    public static func disconnect(_ service: VPNService) -> Bool {
        run("/usr/sbin/scutil", ["--nc", "stop", service.id]).status == 0
    }

    /// 重新连接 VPN
    public static func connect(_ service: VPNService) -> Bool {
        run("/usr/sbin/scutil", ["--nc", "start", service.id]).status == 0
    }
}
