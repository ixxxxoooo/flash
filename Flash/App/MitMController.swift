import Foundation
import Observation
import FlashKit
import AppKit

/// MitM 引擎的应用层控制器：管理根证书、引擎生命周期、配置热更新与报文记录
/// @author ygw
@MainActor
@Observable
final class MitMController {
    let ca = CertificateAuthority()
    let recorder = HTTPRecorder()
    private(set) var server: MitMServer?

    /// 引擎监听端口与内核上游入站端口（引擎运行时才有值）
    private(set) var serverPort: Int?
    private(set) var upstreamPort: Int?

    var caGenerated = false
    var caTrusted = false
    var busy = false
    /// 记录条数变化计数，用于驱动界面刷新
    var recordRevision = 0
    var bypassed: [String] = []

    /// 日志转发（级别, 内容），由 AppModel 设置
    @ObservationIgnored var onLog: (@MainActor (String, String) -> Void)?
    @ObservationIgnored private var lastConfig = MitMConfig()
    @ObservationIgnored private var refreshScheduled = false

    init() {
        refreshCAState()
        recorder.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRevisionBump() }
        }
    }

    /// 节流刷新界面：报文变化频繁，合并为约 4 次/秒
    private func scheduleRevisionBump() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.recordRevision &+= 1
            self?.refreshScheduled = false
        }
    }

    // MARK: 证书状态

    /// 刷新根证书的生成 / 信任状态（调用系统 security 命令，放到后台线程）
    func refreshCAState() {
        caGenerated = ca.isGenerated
        let ca = self.ca
        Task { [weak self] in
            let trusted = await Task.detached { ca.isTrusted() }.value
            self?.caTrusted = trusted
        }
    }

    /// 生成根证书（已存在则保持不变）
    func generateCA() async -> String? {
        do {
            try ca.ensureCA()
            refreshCAState()
            return nil
        } catch { return error.localizedDescription }
    }

    /// 重新生成根证书（旧证书失效，需要重新信任）
    func regenerateCA() async -> String? {
        let ca = self.ca
        do {
            try await Task.detached { try ca.regenerate() }.value
            refreshCAState()
            return nil
        } catch { return error.localizedDescription }
    }

    /// 安装并信任根证书（弹出系统授权）
    func trustCA() async -> String? {
        busy = true
        defer { busy = false }
        let ca = self.ca
        do {
            try await Task.detached { try ca.installAndTrust() }.value
            refreshCAState()
            return nil
        } catch { return error.localizedDescription }
    }

    /// 从钥匙串移除根证书
    func untrustCA() async -> String? {
        busy = true
        defer { busy = false }
        let ca = self.ca
        do {
            try await Task.detached { try ca.removeFromKeychain() }.value
            refreshCAState()
            return nil
        } catch { return error.localizedDescription }
    }

    /// 导出根证书到用户选择的位置
    func exportCA() -> String? {
        guard ca.isGenerated else { return "尚未生成根证书" }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Flash-MitM-CA.crt"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: ca.certificateURL, to: url)
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: 引擎生命周期

    /// 准备引擎：必要时启动并应用最新配置，返回需要写入内核配置的两个端口
    /// - Parameter config: 当前合成配置里的 MitM 部分
    /// - Returns: (引擎端口, 上游入站端口)；不满足启动条件返回 nil
    func prepare(config: MitMConfig, enabled: Bool, recordEnabled: Bool) async -> (Int, Int)? {
        recorder.enabled = recordEnabled
        guard enabled, !config.hostPatterns.isEmpty, ca.isGenerated || (try? ca.ensureCA()) != nil else {
            await shutdown()
            return nil
        }
        lastConfig = config
        if server == nil {
            let s = MitMServer(ca: ca, recorder: recorder, config: config)
            s.logHandler = { [weak self] level, text in
                Task { @MainActor in self?.onLog?(level, text) }
            }
            s.scripts.logHandler = s.logHandler
            do {
                serverPort = try await s.start()
                upstreamPort = PortUtil.freePort()
                s.upstreamSocksPort = upstreamPort
                s.scripts.socksProxyPort = upstreamPort
                server = s
            } catch {
                onLog?("error", "[MitM] 引擎启动失败：\(error.localizedDescription)")
                return nil
            }
        }
        server?.update(config: config)
        bypassed = server?.bypassedHosts ?? []
        // 后台预取远程脚本 / Map Local 资源
        let paths = config.scripts.map(\.scriptPath) + config.mapLocals.compactMap { $0.dataType == .file ? $0.data : nil }
        Task.detached { await ResourceCache.shared.prefetch(paths) }
        guard let sp = serverPort, let up = upstreamPort else { return nil }
        return (sp, up)
    }

    /// 停止引擎（关闭 MitM 或退出应用时）
    func shutdown() async {
        guard let s = server else { return }
        server = nil
        serverPort = nil
        upstreamPort = nil
        await s.stop()
    }

    /// 清除自动放行（证书固定）记录
    func clearBypass() {
        server?.clearBypass()
        bypassed = []
    }

    /// 读取最近的报文记录（新的在前）
    func exchanges() -> [HTTPExchange] { recorder.all().reversed() }
}
