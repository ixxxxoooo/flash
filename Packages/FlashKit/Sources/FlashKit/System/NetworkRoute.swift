import Foundation

/// 默认路由快照：用于识别圈叉 / Shadowrocket / 其他 VPN 是否接管了全部流量
public struct DefaultRouteInfo: Equatable, Sendable {
    /// 默认路由经过的所有网卡（按出现顺序）
    public var interfaces: [String]
    /// 第一个物理网卡（en0、en1 …），没有则为 nil
    public var physical: String?
    /// 默认路由里是否有隧道网卡（utun / ipsec / ppp）
    public var hasTunnel: Bool

    public init(interfaces: [String], physical: String?, hasTunnel: Bool) {
        self.interfaces = interfaces; self.physical = physical; self.hasTunnel = hasTunnel
    }

    /// 需要让内核绑定到物理网卡才能绕开其他隧道时返回网卡名
    public var bypassInterface: String? { hasTunnel ? physical : nil }
}

/// 读取系统路由表
/// @author ygw
public enum NetworkRoute {
    /// 解析 `netstat -rn -f inet` 的输出
    /// - Parameter netstat: 命令输出全文
    /// - Returns: 默认路由信息
    public static func parse(netstat: String) -> DefaultRouteInfo {
        var ifaces: [String] = []
        for line in netstat.components(separatedBy: .newlines) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Destination Gateway Flags Netif [Expire]
            guard cols.count >= 4, cols[0] == "default" else { continue }
            let netif = cols[3]
            if !ifaces.contains(netif) { ifaces.append(netif) }
        }
        let physical = ifaces.first { $0.hasPrefix("en") }
        let tunnel = ifaces.contains { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") }
        return DefaultRouteInfo(interfaces: ifaces, physical: physical, hasTunnel: tunnel)
    }

    /// 读取当前默认路由（同步调用 netstat，耗时几毫秒）
    public static func current() -> DefaultRouteInfo {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return DefaultRouteInfo(interfaces: [], physical: nil, hasTunnel: false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(netstat: String(data: data, encoding: .utf8) ?? "")
    }
}
