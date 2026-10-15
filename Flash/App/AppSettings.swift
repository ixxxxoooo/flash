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

    init() {
        defaults.register(defaults: [
            "mixedPort": 6152, "allowLan": false, "autoSystemProxy": true, "startCoreOnLaunch": true,
            "historyLimit": 5000, "logLevel": "info", "ipv6": false, "showMenuBarSpeed": true, "outboundMode": "rule",
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
    }

    // MARK: 开机启动

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
