import Foundation
import Observation
import FlashKit
import AppKit

/// 出站模式
enum OutboundMode: String, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局代理"
        case .direct: "直连"
        }
    }
    var icon: String {
        switch self {
        case .rule: "arrow.triangle.branch"
        case .global: "globe"
        case .direct: "arrow.right"
        }
    }
}

/// 规则页展示用的统一条目
struct DisplayRule: Identifiable, Hashable {
    var id: Int
    var type: String
    var payload: String
    var policy: String
}

/// 应用的中枢：串联内核、配置、订阅、系统代理和流量引擎
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: 子系统
    let core = CoreManager()
    let subscriptions = SubscriptionManager()
    let profiles = ProfileStore()
    let stats: TrafficStats
    let settings = AppSettings()
    let mitm = MitMController()

    // MARK: 运行状态
    var outboundMode: OutboundMode = .rule
    var systemProxyOn = false
    var busy = false
    var errorMessage: String?
    var noticeMessage: String?
    var composed = Profile()
    var activePort: Int = 0
    var isDemo = false
    /// 增强模式组件是否已安装 / 当前内核是否以 TUN 运行
    var tunInstalled = PrivilegedCore.isInstalled
    var tunActive = false
    var tunBusy = false

    // MARK: 策略 / 规则
    var policies: [String: PolicyInfo] = [:]
    var coreRules: [RuleInfo] = []
    var delays: [String: Int] = [:]
    var testingGroups: Set<String> = []

    // MARK: 流量
    var active: [ConnectionRecord] = []
    var closed: [ConnectionRecord] = []
    var speed = TrafficSample()
    var speedHistory: [TrafficSample] = []
    var memoryBytes = 0
    var sessionUp = 0
    var sessionDown = 0
    var logs: [LogEntry] = []

    // MARK: 内部
    @ObservationIgnored private var tracker = ConnectionTracker()
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var streamClient: MihomoClient?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var demoFeed: DemoFeed?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var lastStatusRunning = false
    @ObservationIgnored private var controllerPort = 0
    @ObservationIgnored private var secret = ""
    @ObservationIgnored private let maxLogs = 2000
    @ObservationIgnored private let maxSpeedPoints = 120

    init() {
        stats = TrafficStats(path: ProcessInfo.processInfo.arguments.contains("--demo") ? nil : AppPaths.statsDB)
        outboundMode = OutboundMode(rawValue: settings.outboundMode) ?? .rule
        resetSpeedHistory()
    }

    var isRunning: Bool { isDemo || core.status.isRunning }

    var coreVersion: String {
        if isDemo { return "演示" }
        if case .running(let v) = core.status { return v }
        return "—"
    }

    var statusText: String {
        if isDemo { return "演示模式" }
        switch core.status {
        case .stopped: return "已停止"
        case .starting: return "正在启动…"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }

    // MARK: 启动与生命周期

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") {
            await startDemo()
            return
        }
        // 上次异常退出遗留的系统代理先恢复
        await Task.detached { SystemProxy.shared.restoreIfDirty() }.value
        // 清理可能残留的特权内核启动标记（未处于增强模式时不应有特权内核在运行）
        if !settings.tunEnabled { PrivilegedCore.deactivate() }
        mitm.onLog = { [weak self] level, text in self?.append(log: LogEntry(level: level, message: text)) }
        subscriptions.onChange = { [weak self] in self?.scheduleApply() }
        profiles.onChange = { [weak self] in self?.scheduleApply() }
        subscriptions.startAutoUpdate()
        profiles.startAutoUpdate()
        stats.startAutoFlush()
        // 调试入口：--import-qx <路径> 启动时直接导入圈叉配置（配合 FLASH_HOME 隔离实例做端到端测试）
        if let i = args.firstIndex(of: "--import-qx"), i + 1 < args.count {
            do {
                let r = try convertQuantumultX(at: URL(fileURLWithPath: args[i + 1]))
                _ = await applyQuantumultX(r, addSubscriptions: args.contains("--import-qx-subs"))
            } catch { errorMessage = "导入圈叉配置失败：\(error.localizedDescription)" }
        }
        refreshComposed()
        routeInfo = NetworkRoute.current()
        startWatcher()
        if settings.startCoreOnLaunch { await startCore() }
        // 调试入口：--auto-disconnect-vpn 启动后若检测到 VPN 冲突，自动执行一次“断开”（用于端到端验证）
        if args.contains("--auto-disconnect-vpn") {
            try? await Task.sleep(for: .seconds(4))
            await refreshVPNConflict()
            await disconnectConflictingVPNs()
        }
    }

    // MARK: 圈叉（Quantumult X）配置导入

    /// 读取圈叉配置并转换（不落盘），本地资源（如 xxx.list）从同目录读取
    /// - Parameter url: 圈叉 .conf 文件地址
    /// - Returns: 转换结果
    func convertQuantumultX(at url: URL) throws -> QXConversion {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dir = url.deletingLastPathComponent()
        return QuantumultXConverter.convert(text) { name in
            guard !name.contains("/") else { return nil }
            return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
    }

    /// 应用转换结果：备份并替换主配置，按需添加 server_remote 订阅
    /// - Parameters:
    ///   - result: 转换结果
    ///   - addSubscriptions: 是否把尚未添加的订阅一并加入
    /// - Returns: 订阅添加过程中的提示（失败原因等）
    func applyQuantumultX(_ result: QXConversion, addSubscriptions: Bool) async -> [String] {
        var messages: [String] = []
        let backup = AppPaths.profilesDir.appendingPathComponent("main-backup-\(Int(Date().timeIntervalSince1970)).conf")
        try? profiles.mainText.write(to: backup, atomically: true, encoding: .utf8)
        messages.append("原主配置已备份到 \(backup.lastPathComponent)")
        if addSubscriptions {
            for r in result.remoteServers where !subscriptions.items.contains(where: { $0.url == r.url }) {
                do { try await subscriptions.add(name: r.tag, url: r.url); messages.append("已添加订阅「\(r.tag)」") }
                catch { messages.append("订阅「\(r.tag)」添加失败：\(error.localizedDescription)") }
            }
        }
        profiles.saveMain(result.text)
        return messages
    }

    // MARK: 增强模式（TUN）

    /// 安装增强模式组件（弹出管理员授权）
    func installTun() async {
        guard !tunBusy else { return }
        tunBusy = true
        defer { tunBusy = false }
        do {
            try await PrivilegedCore.install()
            tunInstalled = PrivilegedCore.isInstalled
            noticeMessage = "增强模式组件已安装，开启开关后重启内核即可生效"
        } catch {
            errorMessage = "安装增强模式失败：\(error.localizedDescription)"
        }
    }

    /// 卸载增强模式组件（需先停止特权内核）
    func uninstallTun() async {
        guard !tunBusy else { return }
        tunBusy = true
        defer { tunBusy = false }
        if tunActive { await stopCore() }
        settings.tunEnabled = false
        do {
            try await PrivilegedCore.uninstall()
            tunInstalled = PrivilegedCore.isInstalled
            noticeMessage = "增强模式组件已卸载"
        } catch {
            errorMessage = "卸载增强模式失败：\(error.localizedDescription)"
        }
    }

    /// 重新合成配置（不触碰内核）
    func refreshComposed() {
        composed = profiles.composed(subscriptions: subscriptions.enabledNodes())
    }

    /// 是否应以增强模式（TUN）运行：设置开启且组件已安装
    private var wantsTun: Bool { settings.tunEnabled && PrivilegedCore.isInstalled }

    /// MitM 引擎当前对内核暴露的端口；未启用时为 nil
    @ObservationIgnored private var mitmPorts: (Int, Int)?

    /// 准备 MitM 引擎并刷新端口（需在生成内核配置之前调用）
    private func prepareMitM() async {
        mitmPorts = await mitm.prepare(config: composed.mitm, enabled: settings.mitmEnabled, recordEnabled: settings.mitmRecord)
        if settings.mitmEnabled, !composed.mitm.hostPatterns.isEmpty, outboundMode != .rule {
            noticeMessage = "当前是「\(outboundMode.title)」模式，内核不会按规则分流，MitM 仅在「规则」模式下生效"
        } else if settings.mitmEnabled, !composed.mitm.hostPatterns.isEmpty, !mitm.caTrusted {
            noticeMessage = "MitM 已开启，但根证书尚未被系统信任，HTTPS 站点可能报证书错误（请在设置中信任）"
        }
    }

    /// 当前内核绑定的物理网卡（nil 表示未绑定）；界面据此提示用户
    private(set) var boundInterface: String?
    /// 最近一次检测到的默认路由（用于设置页展示其他 VPN 状态）
    private(set) var routeInfo = DefaultRouteInfo(interfaces: [], physical: nil, hasTunnel: false)

    /// 计算应绑定的物理网卡：开启开关、非增强模式、且默认路由被其他隧道接管时才绑定
    private func desiredInterface(_ route: DefaultRouteInfo) -> String? {
        guard settings.bypassOtherTunnel, !wantsTun else { return nil }
        return route.bypassInterface
    }

    /// 下载并转换圈叉语法的规则集（缓存 24 小时）；失败只提示，不阻止内核启动
    /// - Returns: 是否有缓存文件被更新
    @discardableResult
    private func prepareQXRuleSets() async -> Bool {
        let r = await QXRuleSetCache.prepare(providers: composed.ruleProviders)
        for w in r.warnings { append(log: LogEntry(level: "warning", message: w)) }
        if !r.warnings.isEmpty { noticeMessage = "\(r.warnings.count) 个圈叉规则集下载失败，已沿用旧缓存（详见日志）" }
        return r.changed
    }

    private func makeYAML() throws -> String {
        let route = NetworkRoute.current()
        routeInfo = route
        let iface = desiredInterface(route)
        boundInterface = iface
        let options = RuntimeOptions(
            mixedPort: activePort, controllerPort: controllerPort, secret: secret,
            allowLan: settings.allowLan, mode: outboundMode.rawValue,
            logLevel: settings.logLevel, ipv6: settings.ipv6,
            tunEnabled: wantsTun, tunStack: settings.tunStack,
            mitmServerPort: mitmPorts?.0, mitmUpstreamPort: mitmPorts?.1,
            interfaceName: iface)
        return try ConfigGenerator.yaml(profile: composed, options: options)
    }

    func startCore() async {
        guard !isDemo, !busy, !core.status.isRunning else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        refreshComposed()
        tunInstalled = PrivilegedCore.isInstalled
        if settings.tunEnabled && !tunInstalled {
            noticeMessage = "增强模式组件未安装，本次以普通模式启动（请在设置中安装）"
        }
        let useTun = wantsTun
        if useTun && !PrivilegedCore.isUpToDate {
            noticeMessage = "已安装的增强模式内核与内置内核版本不一致，可在设置中重新安装升级"
        }

        // 端口：优先使用设置值，被占用则顺延
        var port = settings.mixedPort
        if !PortUtil.isAvailable(port) {
            let fallback = PortUtil.freePort()
            noticeMessage = "端口 \(port) 已被占用，本次改用 \(fallback)"
            port = fallback
        }
        activePort = port
        controllerPort = PortUtil.freePort()
        secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        await prepareMitM()
        await prepareQXRuleSets()
        do {
            let yaml = try makeYAML()
            if let iface = boundInterface {
                noticeMessage = "检测到其他 VPN/代理软件（\(routeInfo.interfaces.filter { $0.hasPrefix("utun") }.joined(separator: "、"))）接管了默认路由，Flash 内核已绑定 \(iface) 出站，避免流量被它再次转发"
            }
            await core.start(yaml: yaml, controllerPort: controllerPort, secret: secret, privileged: useTun)
        } catch {
            errorMessage = "生成配置失败：\(error.localizedDescription)"
            return
        }
        guard core.status.isRunning else {
            if case .failed(let m) = core.status { errorMessage = "内核启动失败：\(m)" }
            return
        }
        lastStatusRunning = true
        tunActive = useTun
        tunFailed = false
        await onCoreRunning()
        // 内核不会因为 TUN 创建失败而退出，必须读日志确认：圈叉等 VPN 已占用路由时会失败
        var tunOK = useTun
        if useTun {
            try? await Task.sleep(for: .milliseconds(1500))
            if let reason = PrivilegedCore.lastStartTUNError() {
                tunOK = false
                tunFailed = true
                tunActive = false
                errorMessage = "增强模式没有生效：虚拟网卡创建失败（\(reason)）。通常是圈叉等 VPN 已占用路由，请先断开它；现已退回系统代理模式"
                await refreshVPNConflict()
            }
        }
        // TUN 已接管全部流量时不改写系统代理，避免重复经过本地代理端口；TUN 失败则退回系统代理
        if settings.autoSystemProxy && !tunOK { await setSystemProxy(true) }
    }

    func stopCore() async {
        guard !isDemo, !busy else { return }
        busy = true
        defer { busy = false }
        if systemProxyOn { await setSystemProxy(false) }
        stopStreams()
        await core.stop()
        if settings.reconnectVPNOnStop { await reconnectDisconnectedVPNs() }
        lastStatusRunning = false
        tunActive = false
        policies = [:]
        coreRules = []
        tracker.reset()
        active = []
        speed = TrafficSample()
        resetSpeedHistory()
    }

    func toggleCore() async {
        if isDemo { return }
        if core.status.isRunning { await stopCore() } else { await startCore() }
    }

    func restartCore() async {
        await stopCore()
        await startCore()
    }

    /// 内核（重新）运行后：拉取策略并启动数据流
    private func onCoreRunning() async {
        guard let client = core.client else { return }
        startStreams(client)
        await refreshPolicies()
        await refreshCoreRules()
    }

    /// 监视内核状态：崩溃后恢复系统代理，自动重启后重建数据流
    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.checkCoreState()
            }
        }
    }

    @ObservationIgnored private var routeTick = 0

    /// 每 5 秒检查一次默认路由：其他 VPN 开关或网卡切换后重新应用配置，保证绑定的网卡始终正确
    private func checkRouteChange() async {
        routeTick += 1
        if routeTick % 3600 == 0, core.status.isRunning, await prepareQXRuleSets() { scheduleApply() }
        guard routeTick % 5 == 0, core.status.isRunning, !applyingRoute else { return }
        let route = await Task.detached { NetworkRoute.current() }.value
        routeInfo = route
        if systemProxyOn || tunFailed { await refreshVPNConflict() }
        if desiredInterface(route) != boundInterface {
            applyingRoute = true
            await applyConfig()
            applyingRoute = false
        }
    }
    @ObservationIgnored private var applyingRoute = false

    private func checkCoreState() async {
        if isDemo || busy { return }
        await checkRouteChange()
        let running = core.status.isRunning
        if running, let client = core.client, client !== streamClient {
            // 内核被自动拉起，client 已更换
            lastStatusRunning = true
            await onCoreRunning()
        }
        if lastStatusRunning, !running {
            lastStatusRunning = false
            if case .failed(let m) = core.status { errorMessage = "内核异常退出：\(m)" }
            stopStreams()
            if systemProxyOn { await setSystemProxy(false) }
        }
    }

    // MARK: 配置应用

    /// 配置或订阅变化后防抖应用
    func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.applyConfig()
        }
    }

    func applyConfig() async {
        refreshComposed()
        guard !isDemo, core.status.isRunning else { return }
        await prepareMitM()
        await prepareQXRuleSets()
        do {
            let yaml = try makeYAML()
            let check = await CoreManager.validate(yaml: yaml)
            guard check.ok else {
                errorMessage = "配置校验未通过，已保留当前运行配置：\(check.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
                return
            }
            await core.reload(yaml: yaml)
            errorMessage = nil
            await refreshPolicies()
            await refreshCoreRules()
        } catch {
            errorMessage = "生成配置失败：\(error.localizedDescription)"
        }
    }

    func setMode(_ mode: OutboundMode) async {
        outboundMode = mode
        settings.outboundMode = mode.rawValue
        guard !isDemo, let client = core.client, core.status.isRunning else { return }
        do {
            try await client.setMode(mode.rawValue)
            await refreshPolicies()
        } catch { errorMessage = "切换模式失败：\(error.localizedDescription)" }
    }

    // MARK: 系统代理

    func setSystemProxy(_ on: Bool) async {
        if isDemo { systemProxyOn = on; return }
        if on && !core.status.isRunning {
            errorMessage = "请先启动内核再开启系统代理"
            return
        }
        let port = activePort
        let result: Result<Void, Error> = await Task.detached {
            do {
                if on { try SystemProxy.shared.enable(port: port) } else { try SystemProxy.shared.restore() }
                return .success(())
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success:
            systemProxyOn = on
            if on { await refreshVPNConflict(delay: 0.8) } else { conflictVPNs = [] }
        case .failure(let e): errorMessage = "设置系统代理失败：\(e.localizedDescription)"
        }
    }

    // MARK: VPN 冲突（圈叉等成为主网络服务时，系统代理对应用不生效）

    /// 导致系统代理不生效的 VPN（已连接且全局代理没有指向 Flash）；为空表示没有冲突
    private(set) var conflictVPNs: [VPNService] = []
    /// 被 Flash 断开的 VPN，停止内核时可自动重连
    @ObservationIgnored private var disconnectedVPNs: [VPNService] = []

    /// 重新检测冲突
    /// - Parameter delay: 系统刷新全局代理需要一点时间，先等待再读取
    func refreshVPNConflict(delay: Double = 0) async {
        let tunBroken = tunFailed
        guard systemProxyOn || tunBroken, !isDemo else { conflictVPNs = []; return }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let port = activePort
        let proxyOn = systemProxyOn
        let found: [VPNService] = await Task.detached {
            let vpns = VPNConflict.list().filter(\.isConnected)
            if vpns.isEmpty { return [] }
            if tunBroken { return vpns }
            if proxyOn, !VPNConflict.globalProxy().points(to: port) { return vpns }
            return []
        }.value
        if found.isEmpty { dismissedConflict = []; conflictVPNs = []; return }
        if Set(found.map(\.id)) == dismissedConflict { return }
        if found != conflictVPNs {
            conflictVPNs = found
            if !tunBroken {
                noticeMessage = "「\(found.map(\.name).joined(separator: "、"))」VPN 正在接管系统网络，应用不会读取 Flash 设置的系统代理，流量仍走它。可一键断开它，或改用增强模式"
            }
        }
    }

    /// 增强模式创建虚拟网卡失败（路由冲突）；断开冲突 VPN 后需重启内核
    private(set) var tunFailed = false

    /// 关闭冲突横幅（本次运行不再提示同一组 VPN）
    func dismissVPNConflict() {
        dismissedConflict = Set(conflictVPNs.map(\.id))
        conflictVPNs = []
    }
    @ObservationIgnored private var dismissedConflict: Set<String> = []

    /// 断开冲突的 VPN 并复查系统代理
    func disconnectConflictingVPNs() async {
        let targets = conflictVPNs
        guard !targets.isEmpty else { return }
        let ok: [VPNService] = await Task.detached { targets.filter { VPNConflict.disconnect($0) } }.value
        disconnectedVPNs += ok.filter { v in !disconnectedVPNs.contains(v) }
        if tunFailed && !ok.isEmpty {
            // 路由已腾出来，重启内核让增强模式重新创建虚拟网卡
            tunFailed = false
            conflictVPNs = []
            await restartCore()
            noticeMessage = "已断开「\(ok.map(\.name).joined(separator: "、"))」并重启内核，增强模式已重新接管流量；停止 Flash 时会自动重新连接"
            return
        }
        await refreshVPNConflict(delay: 1.5)
        if conflictVPNs.isEmpty {
            noticeMessage = "已断开「\(ok.map(\.name).joined(separator: "、"))」，系统代理已对应用生效；停止 Flash 时会自动重新连接"
        } else if ok.isEmpty {
            errorMessage = "断开 VPN 失败，请在对应 App 里手动断开"
        }
    }

    /// 重新连接此前被断开的 VPN
    func reconnectDisconnectedVPNs() async {
        let list = disconnectedVPNs
        disconnectedVPNs = []
        guard !list.isEmpty else { return }
        await Task.detached { for v in list { _ = VPNConflict.connect(v) } }.value
    }

    /// 退出前同步清理（由 AppDelegate 调用）
    func shutdown() async {
        if isDemo { return }
        stopStreams()
        subscriptions.stopAutoUpdate()
        profiles.stopAutoUpdate()
        await stats.flush()
        await Task.detached { SystemProxy.shared.restoreSilently() }.value
        await core.stop()
        if settings.reconnectVPNOnStop { await reconnectDisconnectedVPNs() }
        await mitm.shutdown()
    }

    // MARK: 策略与规则

    func refreshPolicies() async {
        if isDemo { return }
        guard let client = core.client else { return }
        if let map = try? await client.policies() { policies = map }
    }

    func refreshCoreRules() async {
        if isDemo { return }
        guard let client = core.client else { return }
        if let r = try? await client.rules() { coreRules = r }
    }

    /// 按配置顺序排列的策略组（GLOBAL 的成员顺序即配置顺序）
    var orderedGroups: [PolicyInfo] {
        let groups = policies.values.filter { $0.isGroup && $0.name != "GLOBAL" }
        guard let global = policies["GLOBAL"] else { return groups.sorted { $0.name < $1.name } }
        var index: [String: Int] = [:]
        for (i, n) in global.all.enumerated() { index[n] = i }
        return groups.sorted { (index[$0.name] ?? Int.max, $0.name) < (index[$1.name] ?? Int.max, $1.name) }
    }

    func select(group: String, policy: String) async {
        if isDemo {
            policies[group]?.now = policy
            return
        }
        guard let client = core.client else { return }
        policies[group]?.now = policy
        do {
            try await client.select(group: group, policy: policy)
            await refreshPolicies()
        } catch {
            errorMessage = "切换策略失败：\(error.localizedDescription)"
            await refreshPolicies()
        }
    }

    func delay(of name: String, in group: PolicyInfo? = nil) -> Int? {
        if let d = delays[name] { return d }
        if let p = policies[name], !p.isGroup, let last = p.history.last { return last.delay }
        return nil
    }

    func testGroup(_ name: String) async {
        guard !testingGroups.contains(name) else { return }
        testingGroups.insert(name)
        defer { testingGroups.remove(name) }
        if isDemo {
            try? await Task.sleep(for: .milliseconds(600))
            if let g = policies[name] {
                for m in g.all where policies[m]?.isGroup == false {
                    delays[m] = Int.random(in: 30...380)
                }
            }
            return
        }
        guard let client = core.client else { return }
        do {
            let result = try await client.groupDelay(name, url: ConfigGenerator.defaultTestURL)
            for (k, v) in result { delays[k] = v }
            await refreshPolicies()
        } catch {
            // 组内全部节点超时时内核返回 504，属于正常的测速结果而非错误：把成员标记为超时
            let msg = error.localizedDescription
            if msg.contains("504") || msg.lowercased().contains("timeout") {
                for m in policies[name]?.all ?? [] where policies[m]?.isGroup == false { delays[m] = 0 }
            } else {
                errorMessage = "测速失败：\(msg)"
            }
        }
    }

    func testAll() async {
        for g in orderedGroups where g.all.contains(where: { policies[$0]?.isGroup == false }) {
            await testGroup(g.name)
        }
    }

    // MARK: 规则展示与编辑

    var displayRules: [DisplayRule] {
        if !coreRules.isEmpty {
            return coreRules.map { DisplayRule(id: $0.index, type: $0.type, payload: $0.payload, policy: $0.proxy) }
        }
        return composed.rules.enumerated().map { i, r in
            let parts = r.body.split(separator: ",", maxSplits: 1).map(String.init)
            return DisplayRule(id: i, type: parts.first ?? r.body, payload: parts.count > 1 ? parts[1] : "", policy: r.policy)
        }
    }

    /// 在本地覆盖层顶部插入一条规则（高优先级）
    func addOverlayRule(type: String, value: String, policy: String) {
        var lines = profiles.overlayText.components(separatedBy: "\n")
        let rule = "\(type),\(value),\(policy)"
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[Rule]" }) {
            lines.insert(rule, at: idx + 1)
        } else {
            lines.append(contentsOf: ["", "[Rule]", rule])
        }
        profiles.saveOverlay(lines.joined(separator: "\n"))
        noticeMessage = "已添加规则：\(rule)"
    }

    // MARK: 数据流

    private func resetSpeedHistory() {
        let now = Date()
        speedHistory = (0..<maxSpeedPoints).map { i in
            TrafficSample(up: 0, down: 0, time: now.addingTimeInterval(Double(i - maxSpeedPoints)))
        }
    }

    private func startStreams(_ client: MihomoClient) {
        stopStreams()
        streamClient = client
        tracker.reset()
        streamTasks = [
            Task { [weak self] in
                for await s in client.trafficStream() { self?.ingest(sample: s) }
            },
            Task { [weak self] in
                for await snap in client.connectionsStream(interval: 1000) { self?.ingest(snapshot: snap) }
            },
            Task { [weak self] in
                for await m in client.memoryStream() { self?.memoryBytes = m.inuse }
            },
            Task { [weak self] in
                guard let self else { return }
                for await entry in client.logStream(level: "debug") { self.append(log: entry) }
            },
        ]
    }

    private func stopStreams() {
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        streamClient = nil
    }

    private func ingest(sample: TrafficSample) {
        var s = sample
        s.time = Date()
        speed = s
        speedHistory.append(s)
        if speedHistory.count > maxSpeedPoints { speedHistory.removeFirst(speedHistory.count - maxSpeedPoints) }
    }

    private func ingest(snapshot: ConnectionsSnapshot) {
        let upd = tracker.apply(mitmPorts == nil ? snapshot : MitMLink.mergeHops(snapshot))
        active = tracker.active.values.sorted { $0.startedAt > $1.startedAt }
        if !upd.closed.isEmpty {
            closed.insert(contentsOf: upd.closed.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }, at: 0)
            let limit = max(100, settings.historyLimit)
            if closed.count > limit { closed.removeLast(closed.count - limit) }
        }
        stats.record(upd.deltas)
        sessionUp = snapshot.uploadTotal
        sessionDown = snapshot.downloadTotal
        if snapshot.memory > 0 { memoryBytes = snapshot.memory }
    }

    private func append(log: LogEntry) {
        logs.append(log)
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
    }

    func clearLogs() { logs.removeAll() }

    func clearHistory() {
        closed.removeAll()
    }

    func closeConnection(_ id: String) async {
        if isDemo { return }
        try? await core.client?.closeConnection(id: id)
    }

    func closeAllConnections() async {
        if isDemo {
            closed.insert(contentsOf: active.map { var r = $0; r.isActive = false; r.closedAt = Date(); return r }, at: 0)
            active = []
            return
        }
        try? await core.client?.closeAllConnections()
    }

    // MARK: 演示模式

    private func startDemo() async {
        isDemo = true
        subscriptions.onChange = { [weak self] in self?.refreshComposed() }
        DemoFeed.injectSubscriptions(into: subscriptions)
        refreshComposed()
        policies = DemoFeed.policies()
        activePort = settings.mixedPort
        systemProxyOn = true
        await stats.seedDemo()
        let feed = DemoFeed()
        demoFeed = feed
        // 预热：生成一段历史，使图表和已关闭列表立即有内容
        for i in 0..<90 {
            let t = Date().addingTimeInterval(Double(i - 90))
            let (snap, sample) = feed.tick(now: t)
            ingest(snapshot: snap)
            var s = sample
            s.time = t
            speedHistory.append(s)
        }
        speedHistory = Array(speedHistory.suffix(maxSpeedPoints))
        speed = speedHistory.last ?? TrafficSample()
        for line in [
            ("info", "[TCP] 127.0.0.1:52118 --> github.com:443 match DomainSuffix(github.com) using Proxy[香港 01]"),
            ("info", "[TCP] 127.0.0.1:52130 --> www.youtube.com:443 match DomainKeyword(youtube) using Proxy[日本 03]"),
            ("warning", "[DNS] resolve rr3---sn-a5mlrn7s.googlevideo.com slow: 412ms"),
            ("info", "[Config] 订阅「示例机场」已更新，11 个节点"),
            ("error", "[TCP] dial 英国 01 timeout after 5000ms"),
            ("debug", "[Provider] rule provider LAN loaded, 12 rules"),
        ] {
            append(log: LogEntry(level: line.0, message: line.1))
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let feed = self.demoFeed else { return }
                let (snap, sample) = feed.tick()
                self.ingest(sample: sample)
                self.ingest(snapshot: snap)
            }
        }
    }
}
