import Foundation
@testable import FlashKit

enum TestSupport {
    /// 仓库根目录（由测试文件路径推导）
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 内核二进制路径，不存在时返回 nil（用于跳过集成测试）
    static var coreBinary: URL? {
        let url = repoRoot.appendingPathComponent("Resources/Core/mihomo")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// 为测试使用独立的数据目录，避免污染真实配置
    static func isolateHome() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FLASH_HOME", dir.path, 1)
        if let core = coreBinary { setenv("FLASH_CORE_PATH", core.path, 1) }
        return dir
    }
}
