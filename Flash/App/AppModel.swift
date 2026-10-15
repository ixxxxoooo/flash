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

    // MARK: 运行状态
    var outboundMode: OutboundMode = .rule
    var systemProxyOn = false
    var busy = false
    var errorMessage: String?
    var noticeMessage: String?
    var composed = Profile()
    var activePort: Int = 0
    var isDemo = false

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
        subscriptions.onChange = { [weak self] in self?.scheduleApply() }
        profiles.onChange = { [weak self] in self?.scheduleApply() }
        subscriptions.startAutoUpdate()
        profiles.startAutoUpdate()
        stats.startAutoFlush()
        refreshComposed()
        startWatcher()
        if settings.startCoreOnLaunch { await startCore() }
    }

    /// 重新合成配置（不触碰内核）
    func refreshComposed() {
        composed = profiles.composed(subscriptions: subscriptions.enabledNodes())
    }

    private func makeYAML() throws -> String {
        let options = RuntimeOptions(
            mixedPort: activePort, controllerPort: controllerPort, secret: secret,
            allowLan: settings.allowLan, mode: outboundMode.rawValue,
            logLevel: settings.logLevel, ipv6: settings.ipv6)
        return try ConfigGenerator.yaml(profile: composed, options: options)
    }

    func startCore() async {
        guard !isDemo, !busy, !core.status.isRunning else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        refreshComposed()

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

        do {
            let yaml = try makeYAML()
            await core.start(yaml: yaml, controllerPort: controllerPort, secret: secret)
        } catch {
            errorMessage = "生成配置失败：\(error.localizedDescription)"
            return
        }
        guard core.status.isRunning else {
            if case .failed(let m) = core.status { errorMessage = "内核启动失败：\(m)" }
            return
        }
        lastStatusRunning = true
        await onCoreRunning()
        if settings.autoSystemProxy { await setSystemProxy(true) }
    }

    func stopCore() async {
        guard !isDemo, !busy else { return }
        busy = true
        defer { busy = false }
        if systemProxyOn { await setSystemProxy(false) }
        stopStreams()
        await core.stop()
        lastStatusRunning = false
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

    private func checkCoreState() async {
        if isDemo || busy { return }
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
        case .success: systemProxyOn = on
        case .failure(let e): errorMessage = "设置系统代理失败：\(e.localizedDescription)"
        }
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
            errorMessage = "测速失败：\(error.localizedDescription)"
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
        let upd = tracker.apply(snapshot)
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
