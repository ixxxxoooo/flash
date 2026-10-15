import Foundation
import Observation

/// 配置存储：主配置文本、本地覆盖层、受管配置（#!MANAGED-CONFIG）与远程 include 缓存
@MainActor
@Observable
public final class ProfileStore {
    public var mainText: String
    public var overlayText: String
    public private(set) var managed: ManagedConfigInfo?
    public private(set) var managedUpdated: Date?
    public private(set) var managedError: String?

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?

    public var isManaged: Bool { managed != nil }

    private var includesDir: URL { AppPaths.profilesDir.appendingPathComponent("includes", isDirectory: true) }
    private var managedMeta: URL { AppPaths.profilesDir.appendingPathComponent("managed.meta.json") }

    private struct ManagedMeta: Codable { var updated: Date? }

    public init() {
        AppPaths.prepare()
        let text: String
        if let saved = try? String(contentsOf: AppPaths.mainProfile, encoding: .utf8), !saved.isEmpty {
            text = saved
        } else {
            text = DefaultProfile.text
            try? text.write(to: AppPaths.mainProfile, atomically: true, encoding: .utf8)
        }
        mainText = text
        overlayText = (try? String(contentsOf: AppPaths.overlayProfile, encoding: .utf8)) ?? ""
        managed = SurgeProfileParser.parse(text).managed
        managedUpdated = JSONFile.load(ManagedMeta.self, from: managedMeta)?.updated
    }

    // MARK: 保存

    public func saveMain(_ text: String) {
        mainText = text
        try? text.write(to: AppPaths.mainProfile, atomically: true, encoding: .utf8)
        managed = SurgeProfileParser.parse(text).managed
        onChange?()
    }

    public func saveOverlay(_ text: String) {
        overlayText = text
        try? text.write(to: AppPaths.overlayProfile, atomically: true, encoding: .utf8)
        onChange?()
    }

    public func resetToDefault() {
        try? FileManager.default.removeItem(at: managedMeta)
        managedUpdated = nil; managedError = nil
        saveMain(DefaultProfile.text)
    }

    // MARK: 解析与组合

    /// include 解析：远程 URL 读取本地缓存，本地路径相对配置目录
    private func resolve(_ target: String) -> String? {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return try? String(contentsOf: includesDir.appendingPathComponent(SurgeText.stableHash(target) + ".conf"), encoding: .utf8)
        }
        let url: URL
        if target.hasPrefix("/") { url = URL(fileURLWithPath: target) }
        else if target.hasPrefix("~") { url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath) }
        else { url = AppPaths.profilesDir.appendingPathComponent(target) }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func parseMain() -> Profile {
        SurgeProfileParser.parse(mainText) { [self] in resolve($0) }
    }

    public func parseOverlay() -> Profile? {
        let t = overlayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : SurgeProfileParser.parse(overlayText) { [self] in resolve($0) }
    }

    /// 解析并与订阅节点合并，得到最终配置
    public func composed(subscriptions: [SubscriptionNodes]) -> Profile {
        ProfileComposer.compose(base: parseMain(), overlay: parseOverlay(), subscriptions: subscriptions)
    }

    // MARK: 受管配置

    /// 导入受管配置（远程 URL），内容覆盖主配置
    public func importManaged(url: String, interval: Int = 86400) async throws {
        let text = try await fetchManagedText(url: url, interval: interval)
        saveMain(text)
        markUpdated()
    }

    private func fetchManagedText(url: String, interval: Int) async throws -> String {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        let result = try await Downloader.fetch(url: u, userAgent: "Surge Mac/1 Flash")
        guard (200..<300).contains(result.response.statusCode) else {
            throw NSError(domain: "Flash.Profile", code: result.response.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(result.response.statusCode)"])
        }
        guard var text = String(data: result.data, encoding: .utf8), !text.isEmpty else { throw SubscriptionDecodeError.empty }
        let parsed = SurgeProfileParser.parse(text)
        guard !parsed.rules.isEmpty || !parsed.groups.isEmpty || !parsed.nodes.isEmpty else {
            throw NSError(domain: "Flash.Profile", code: 2, userInfo: [NSLocalizedDescriptionKey: "配置中没有规则、策略组或节点"])
        }
        // 远程内容缺少头信息时补上，保证后续继续跟随更新
        if parsed.managed == nil {
            text = "#!MANAGED-CONFIG \(url) interval=\(interval) strict=false\n" + text
        }
        return text
    }

    /// 刷新受管配置；force 为 false 时仅在到期后更新
    public func refreshManaged(force: Bool) async {
        guard let m = managed else { return }
        if !force, let last = managedUpdated, Date().timeIntervalSince(last) < Double(m.interval) { return }
        do {
            let text = try await fetchManagedText(url: m.url, interval: m.interval)
            saveMain(text)
            managedError = nil
            markUpdated()
        } catch {
            managedError = error.localizedDescription   // 保留旧配置
        }
    }

    /// 转为本地副本：移除受管头信息
    public func detachManaged() {
        let lines = mainText.components(separatedBy: "\n").filter { !$0.hasPrefix("#!MANAGED-CONFIG") }
        saveMain(lines.joined(separator: "\n"))
    }

    private func markUpdated() {
        managedUpdated = Date()
        JSONFile.save(ManagedMeta(updated: managedUpdated), to: managedMeta)
    }

    // MARK: 远程 include

    /// 下载主配置与覆盖层中引用的远程 include
    public func refreshRemoteIncludes() async {
        var targets = Set<String>()
        for text in [mainText, overlayText] {
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.lowercased().hasPrefix("#!include") else { continue }
                for item in t.dropFirst("#!include".count).split(separator: ",") {
                    let s = item.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("http://") || s.hasPrefix("https://") { targets.insert(s) }
                }
            }
        }
        guard !targets.isEmpty else { return }
        try? FileManager.default.createDirectory(at: includesDir, withIntermediateDirectories: true)
        var changed = false
        for t in targets {
            guard let u = URL(string: t), let r = try? await Downloader.fetch(url: u, userAgent: "Flash"),
                  (200..<300).contains(r.response.statusCode) else { continue }
            let file = includesDir.appendingPathComponent(SurgeText.stableHash(t) + ".conf")
            if (try? Data(contentsOf: file)) != r.data {
                try? r.data.write(to: file, options: .atomic)
                changed = true
            }
        }
        if changed { onChange?() }
    }

    // MARK: 定时

    public func startAutoUpdate() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshManaged(force: false)
                await self?.refreshRemoteIncludes()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    public func stopAutoUpdate() { timer?.cancel(); timer = nil }
}
