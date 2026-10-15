import Foundation

/// 增强模式（TUN）所需的特权内核管理。
///
/// 没有付费开发者账号时无法使用 Network Extension，因此改用 mihomo 自带的 TUN：
/// 1. 一次性安装：通过管理员授权，把内核拷贝到 root 所有的目录，并安装一个 LaunchDaemon；
/// 2. 日常启停：LaunchDaemon 的 KeepAlive 绑定一个「标记文件」，创建标记文件即启动，
///    删除标记文件即停止（包装脚本轮询标记文件），之后无需再次输入密码。
///
/// 内核二进制与包装脚本均为 root 所有且用户不可写，避免被普通进程替换；
/// 配置文件仍由用户目录提供，便于热重载。
///
/// @author ygw
public enum PrivilegedCore {
    /// LaunchDaemon 标签
    public static let label = "com.ixxxxoooo.flash.tun"
    /// 安装目录（root 所有）
    public static let installDir = "/Library/Application Support/Flash"
    /// 已安装的 root 级内核
    public static var installedBinary: String { installDir + "/mihomo" }
    /// 包装脚本
    public static var wrapperScript: String { installDir + "/run-core.sh" }
    /// LaunchDaemon 描述文件
    public static var daemonPlist: String { "/Library/LaunchDaemons/\(label).plist" }
    /// 启停标记文件：位于 /private/tmp，重启后自动清除，避免开机后意外拉起特权内核
    public static var flagFile: String { "/private/tmp/\(label).flag" }

    /// 特权内核使用独立的工作目录，避免 root 写出的缓存文件污染用户目录
    public static var workDir: URL { AppPaths.coreDir.appendingPathComponent("tun", isDirectory: true) }
    /// 特权内核日志（由用户预先创建，root 追加写入）
    public static var logFile: URL { AppPaths.logsDir.appendingPathComponent("core-tun.log") }

    // MARK: 状态

    /// 是否已安装（描述文件、内核、包装脚本都存在）
    public static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: daemonPlist) && fm.isExecutableFile(atPath: installedBinary) && fm.isExecutableFile(atPath: wrapperScript)
    }

    /// 已安装的内核是否与应用内置内核一致（不一致时提示重新安装以升级）
    public static var isUpToDate: Bool {
        guard let bundled = CoreLocator.binary() else { return true }
        return FileManager.default.contentsEqual(atPath: bundled.path, andPath: installedBinary)
    }

    // MARK: 脚本生成（便于单元测试）

    /// 生成包装脚本内容：以后台方式运行内核，并在标记文件消失或内核退出时结束
    /// - Returns: 脚本文本
    public static func wrapperScriptText() -> String {
        """
        #!/bin/sh
        # Flash 增强模式包装脚本（root 运行）。参数：$1 标记文件，其余为内核命令行
        FLAG="$1"
        shift
        "$@" &
        PID=$!
        while [ -e "$FLAG" ] && kill -0 "$PID" 2>/dev/null; do
          sleep 1
        done
        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
        exit 0
        """
    }

    /// 生成 LaunchDaemon 描述文件内容
    /// - Returns: plist 的 XML 数据
    public static func daemonPlistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                wrapperScript, flagFile,
                installedBinary, "-d", workDir.path, "-f", AppPaths.runtimeConfig.path,
            ],
            "WorkingDirectory": workDir.path,
            // 允许内核从用户目录读取配置（热重载接口只接受安全路径内的文件）
            "EnvironmentVariables": ["SAFE_PATHS": AppPaths.coreDir.path],
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "RunAtLoad": false,
            // 标记文件存在时保持运行；内核崩溃后由 launchd 重新拉起
            "KeepAlive": ["PathState": [flagFile: true]],
            "ThrottleInterval": 5,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// 生成安装脚本（以 root 执行）
    /// - Parameters:
    ///   - bundledBinary: 应用内置的内核路径
    ///   - wrapperTmp: 临时包装脚本路径
    ///   - plistTmp: 临时 plist 路径
    /// - Returns: shell 脚本文本
    static func installScript(bundledBinary: String, wrapperTmp: String, plistTmp: String) -> String {
        let q = SystemProxy.shellQuote
        return [
            "set -e",
            "mkdir -p \(q(installDir))",
            "cp -f \(q(bundledBinary)) \(q(installedBinary))",
            "cp -f \(q(wrapperTmp)) \(q(wrapperScript))",
            "chown -R root:wheel \(q(installDir))",
            "chmod 755 \(q(installDir)) \(q(installedBinary)) \(q(wrapperScript))",
            "cp -f \(q(plistTmp)) \(q(daemonPlist))",
            "chown root:wheel \(q(daemonPlist))",
            "chmod 644 \(q(daemonPlist))",
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "launchctl bootstrap system \(q(daemonPlist))",
        ].joined(separator: "\n")
    }

    /// 生成卸载脚本（以 root 执行）
    static func uninstallScript() -> String {
        let q = SystemProxy.shellQuote
        return [
            "rm -f \(q(flagFile))",
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "rm -f \(q(daemonPlist))",
            "rm -rf \(q(installDir))",
            "exit 0",
        ].joined(separator: "\n")
    }

    // MARK: 安装 / 卸载

    /// 安装增强模式组件（会弹出系统管理员授权对话框）
    /// - Throws: 内核缺失、写入临时文件失败或用户取消授权
    public static func install() async throws {
        guard let bundled = CoreLocator.binary() else {
            throw NSError(domain: "Flash.TUN", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到内置内核"])
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flash-tun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wrapperTmp = tmp.appendingPathComponent("run-core.sh")
        let plistTmp = tmp.appendingPathComponent("daemon.plist")
        try wrapperScriptText().write(to: wrapperTmp, atomically: true, encoding: .utf8)
        try daemonPlistData().write(to: plistTmp)
        // 预先创建特权内核需要的用户目录与日志
        AppPaths.prepare()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) { FileManager.default.createFile(atPath: logFile.path, contents: nil) }
        let script = installScript(bundledBinary: bundled.path, wrapperTmp: wrapperTmp.path, plistTmp: plistTmp.path)
        try await runAsAdmin(script)
    }

    /// 卸载增强模式组件
    public static func uninstall() async throws {
        try await runAsAdmin(uninstallScript())
    }

    /// 通过 osascript 以管理员权限执行脚本
    /// - Parameter script: shell 脚本
    /// - Throws: 用户取消或执行失败
    static func runAsAdmin(_ script: String) async throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", apple]
                let err = Pipe()
                p.standardError = err
                p.standardOutput = Pipe()
                do { try p.run() } catch { cont.resume(throwing: error); return }
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let text = msg.contains("-128") ? "已取消管理员授权" : msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: NSError(domain: "Flash.TUN", code: 2, userInfo: [NSLocalizedDescriptionKey: text]))
                }
            }
        }
    }

    // MARK: 启停（无需密码）

    /// 创建标记文件，让 LaunchDaemon 拉起特权内核
    public static func activate() {
        FileManager.default.createFile(atPath: flagFile, contents: nil)
    }

    /// 删除标记文件，包装脚本检测到后结束特权内核
    public static func deactivate() {
        try? FileManager.default.removeItem(atPath: flagFile)
    }
}
