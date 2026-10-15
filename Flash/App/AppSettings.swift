import Foundation
import Observation
import ServiceManagement

/// 应用设置，使用 UserDefaults 持久化
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var mixedPort: Int { didSet { defaults.set(mixedPort, forKey: "mixedPort") } }
    var allowLan: Bool { didSet { defaults.set(allowLan, forKey: "allowLan") } }
    var autoSystemProxy: Bool { didSet { defaults.set(autoSystemProxy, forKey: "autoSystemProxy") } }
    var startCoreOnLaunch: Bool { didSet { defaults.set(startCoreOnLaunch, forKey: "startCoreOnLaunch") } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    var logLevel: String { didSet { defaults.set(logLevel, forKey: "logLevel") } }
    var ipv6: Bool { didSet { defaults.set(ipv6, forKey: "ipv6") } }
    var showMenuBarSpeed: Bool { didSet { defaults.set(showMenuBarSpeed, forKey: "showMenuBarSpeed") } }
    var outboundMode: String { didSet { defaults.set(outboundMode, forKey: "outboundMode") } }
    /// 增强模式（TUN）开关与协议栈
    var tunEnabled: Bool { didSet { defaults.set(tunEnabled, forKey: "tunEnabled") } }
    var tunStack: String { didSet { defaults.set(tunStack, forKey: "tunStack") } }

    /// 检测到其他 VPN（圈叉等）接管默认路由时，让内核绑定物理网卡出站
    var bypassOtherTunnel: Bool { didSet { defaults.set(bypassOtherTunnel, forKey: "bypassOtherTunnel") } }

    /// 停止内核或退出时，自动重新连接被 Flash 断开的 VPN
    var reconnectVPNOnStop: Bool { didSet { defaults.set(reconnectVPNOnStop, forKey: "reconnectVPNOnStop") } }

    /// MitM（HTTPS 解密）总开关与报文记录开关
    var mitmEnabled: Bool { didSet { defaults.set(mitmEnabled, forKey: "mitmEnabled") } }
    var mitmRecord: Bool { didSet { defaults.set(mitmRecord, forKey: "mitmRecord") } }

    init() {
        defaults.register(defaults: [
            "mixedPort": 6152, "allowLan": false, "autoSystemProxy": true, "startCoreOnLaunch": true,
            "historyLimit": 5000, "logLevel": "info", "ipv6": false, "showMenuBarSpeed": true, "outboundMode": "rule",
            "tunEnabled": false, "tunStack": "mixed", "mitmEnabled": false, "mitmRecord": true, "bypassOtherTunnel": true, "reconnectVPNOnStop": true,
        ])
        mixedPort = defaults.integer(forKey: "mixedPort")
        allowLan = defaults.bool(forKey: "allowLan")
        autoSystemProxy = defaults.bool(forKey: "autoSystemProxy")
        startCoreOnLaunch = defaults.bool(forKey: "startCoreOnLaunch")
        historyLimit = defaults.integer(forKey: "historyLimit")
        logLevel = defaults.string(forKey: "logLevel") ?? "info"
        ipv6 = defaults.bool(forKey: "ipv6")
        showMenuBarSpeed = defaults.bool(forKey: "showMenuBarSpeed")
        outboundMode = defaults.string(forKey: "outboundMode") ?? "rule"
        tunEnabled = defaults.bool(forKey: "tunEnabled")
        tunStack = defaults.string(forKey: "tunStack") ?? "mixed"
        mitmEnabled = defaults.bool(forKey: "mitmEnabled")
        mitmRecord = defaults.bool(forKey: "mitmRecord")
        bypassOtherTunnel = defaults.bool(forKey: "bypassOtherTunnel")
        reconnectVPNOnStop = defaults.bool(forKey: "reconnectVPNOnStop")
    }

    // MARK: 开机启动

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
