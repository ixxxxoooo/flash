import Foundation
import GRDB
import Observation

public enum StatKind: String, Sendable, CaseIterable {
    case process, host, policy
}

public struct StatRow: Identifiable, Hashable, Sendable {
    public var key: String
    public var up: Int
    public var down: Int
    public var connections: Int
    public var id: String { key }
    public var total: Int { up + down }
}

public struct DailyTotal: Identifiable, Hashable, Sendable {
    public var day: String
    public var up: Int
    public var down: Int
    public var id: String { day }
    public var total: Int { up + down }
}

/// 流量统计：内存累积 + 定时落盘到 SQLite（GRDB），支持按进程/域名/策略聚合
@MainActor
@Observable
public final class TrafficStats {
    private struct Key: Hashable { var kind: StatKind; var key: String }
    private struct Value { var up = 0; var down = 0; var conns = 0 }

    @ObservationIgnored private var pending: [Key: Value] = [:]
    @ObservationIgnored private var db: DatabaseQueue?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// 每次落盘后递增，界面据此刷新统计
    public private(set) var revision = 0

    public init(path: URL? = AppPaths.statsDB) {
        if let path {
            AppPaths.prepare()
            db = try? DatabaseQueue(path: path.path)
        } else {
            db = try? DatabaseQueue()   // 内存数据库（测试用）
        }
        try? db?.write { d in
            try d.execute(sql: """
                CREATE TABLE IF NOT EXISTS daily_stats (
                    day TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                    up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0, conns INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (day, kind, key))
                """)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    // MARK: 写入

    /// 累积一批字节增量
    public func record(_ deltas: [BytesDelta]) {
        for d in deltas {
            for (kind, key) in [(StatKind.process, d.process), (.host, registrableDomain(d.host)), (.policy, d.policy)] {
                var v = pending[Key(kind: kind, key: key)] ?? Value()
                v.up += d.up; v.down += d.down
                if d.isNew { v.conns += 1 }
                pending[Key(kind: kind, key: key)] = v
            }
        }
    }

    /// 将内存中的累积量写入数据库
    public func flush() async {
        guard let db, !pending.isEmpty else { return }
        let batch = pending
        pending = [:]
        let day = Self.dayString(Date())
        do {
            try await db.write { d in
                for (k, v) in batch {
                    try d.execute(sql: """
                        INSERT INTO daily_stats (day, kind, key, up, down, conns) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(day, kind, key) DO UPDATE SET
                          up = up + excluded.up, down = down + excluded.down, conns = conns + excluded.conns
                        """, arguments: [day, k.kind.rawValue, k.key, v.up, v.down, v.conns])
                }
            }
            revision += 1
        } catch {
            // 写入失败则放回待写入集合，下次重试
            for (k, v) in batch {
                var cur = pending[k] ?? Value()
                cur.up += v.up; cur.down += v.down; cur.conns += v.conns
                pending[k] = cur
            }
        }
    }

    public func startAutoFlush(interval: TimeInterval = 30) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.flush()
            }
        }
    }

    public func stopAutoFlush() { flushTask?.cancel(); flushTask = nil }

    // MARK: 查询

    /// 最近 days 天（含今天）按 kind 聚合的排行
    public func top(kind: StatKind, days: Int, limit: Int = 20) async -> [StatRow] {
        await flush()
        guard let db else { return [] }
        let cutoff = Self.dayString(Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: Date()) ?? Date())
        let rows: [StatRow] = (try? await db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT key, SUM(up) AS up, SUM(down) AS down, SUM(conns) AS conns
                FROM daily_stats WHERE kind = ? AND day >= ?
                GROUP BY key ORDER BY SUM(up) + SUM(down) DESC LIMIT ?
                """, arguments: [kind.rawValue, cutoff, limit]).map {
                StatRow(key: $0["key"], up: $0["up"], down: $0["down"], connections: $0["conns"])
            }
        }) ?? []
        return rows
    }

    /// 最近 days 天每天的总流量（以 policy 维度求和，每条连接恰好计入一个策略）
    public func dailyTotals(days: Int) async -> [DailyTotal] {
        await flush()
        guard let db else { return [] }
        let cal = Calendar.current
        let cutoff = Self.dayString(cal.date(byAdding: .day, value: -(max(1, days) - 1), to: Date()) ?? Date())
        let rows: [String: (Int, Int)] = (try? await db.read { d in
            var out: [String: (Int, Int)] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT day, SUM(up) AS up, SUM(down) AS down FROM daily_stats
                WHERE kind = 'policy' AND day >= ? GROUP BY day
                """, arguments: [cutoff]) {
                out[r["day"]] = (r["up"], r["down"])
            }
            return out
        }) ?? [:]
        // 补齐没有数据的日期，图表连续
        return (0..<max(1, days)).reversed().map { offset in
            let day = Self.dayString(cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date())
            let v = rows[day] ?? (0, 0)
            return DailyTotal(day: day, up: v.0, down: v.1)
        }
    }

    /// 写入过去若干天的演示数据（仅用于演示模式，调用方应使用独立的数据目录）
    public func seedDemo(days: Int = 14) async {
        let processes = ["Safari", "Google Chrome", "Slack", "Xcode", "Spotify", "Telegram", "curl", "Docker", "Cursor"]
        let hosts = ["apple.com", "google.com", "github.com", "youtube.com", "cloudflare.com", "openai.com", "netflix.com", "slack.com", "npmjs.org"]
        let policies = ["Proxy", "HK", "JP", "DIRECT", "US"]
        let cal = Calendar.current
        let dayList: [String] = (0..<days).compactMap { cal.date(byAdding: .day, value: -$0, to: Date()) }.map { Self.dayString($0) }
        try? await db?.write { d in
            for day in dayList {
                func put(_ kind: StatKind, _ keys: [String], scale: Int) throws {
                    for (i, key) in keys.enumerated() {
                        let weight = max(1, keys.count - i)
                        let down = Int.random(in: 20...400) * 1_000_000 * weight / scale
                        let up = down / Int.random(in: 6...20)
                        let conns = Int.random(in: 30...600) * weight
                        try d.execute(sql: """
                            INSERT INTO daily_stats (day, kind, key, up, down, conns) VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(day, kind, key) DO UPDATE SET up = excluded.up, down = excluded.down, conns = excluded.conns
                            """, arguments: [day, kind.rawValue, key, up, down, conns])
                    }
                }
                try put(.process, processes.shuffled(), scale: 3)
                try put(.host, hosts.shuffled(), scale: 3)
                try put(.policy, policies.shuffled(), scale: 2)
            }
        }
        revision += 1
    }

    /// 清空全部统计
    public func clear() async {
        pending = [:]
        try? await db?.write { d in try d.execute(sql: "DELETE FROM daily_stats") }
        revision += 1
    }
}
