import XCTest
@testable import FlashKit

final class TrafficTests: XCTestCase {
    func info(_ id: String, host: String = "a.com", up: Int, down: Int, process: String = "curl", chains: [String] = ["DIRECT"]) -> ConnectionInfo {
        ConnectionInfo(id: id, metadata: ConnectionMetadata(host: host, process: process), upload: up, download: down,
                       start: Date(), chains: chains, rule: "Match", rulePayload: "")
    }

    func testTrackerOpenUpdateClose() {
        var t = ConnectionTracker()
        let t0 = Date()
        var u = t.apply(ConnectionsSnapshot(connections: [info("1", up: 100, down: 1000)]), now: t0)
        XCTAssertEqual(u.opened.count, 1)
        XCTAssertEqual(u.deltas.first?.down, 1000)
        XCTAssertEqual(u.deltas.first?.isNew, true)

        // 1 秒后下载增加 4000 字节 → 速度 4000 B/s
        u = t.apply(ConnectionsSnapshot(connections: [info("1", up: 300, down: 5000), info("2", host: "b.com", up: 0, down: 0)]), now: t0.addingTimeInterval(1))
        XCTAssertEqual(u.opened.map(\.id), ["2"])
        XCTAssertEqual(t.active["1"]?.downSpeed, 4000)
        XCTAssertEqual(t.active["1"]?.upSpeed, 200)
        XCTAssertEqual(u.deltas.first { !$0.isNew }?.down, 4000)

        // 连接 1 消失 → 已关闭，保留最终字节数
        u = t.apply(ConnectionsSnapshot(connections: [info("2", host: "b.com", up: 0, down: 0)]), now: t0.addingTimeInterval(2))
        XCTAssertEqual(u.closed.map(\.id), ["1"])
        XCTAssertEqual(u.closed.first?.download, 5000)
        XCTAssertEqual(u.closed.first?.isActive, false)
        XCTAssertNil(t.active["1"])
    }

    func testCounterRegressionDoesNotGoNegative() {
        var t = ConnectionTracker()
        let t0 = Date()
        _ = t.apply(ConnectionsSnapshot(connections: [info("1", up: 500, down: 500)]), now: t0)
        let u = t.apply(ConnectionsSnapshot(connections: [info("1", up: 100, down: 100)]), now: t0.addingTimeInterval(1))
        XCTAssertEqual(t.active["1"]?.downSpeed, 0)
        XCTAssertTrue(u.deltas.isEmpty)
    }

    func testRecordChainsAndDisplay() {
        let r = ConnectionRecord(info: info("1", up: 0, down: 0, chains: ["HK-01", "Auto", "Proxy"]), now: Date())
        XCTAssertEqual(r.policy, "HK-01")
        XCTAssertEqual(r.chainText, "Proxy → Auto → HK-01")
    }

    func testRegistrableDomain() {
        XCTAssertEqual(registrableDomain("a.b.example.com"), "example.com")
        XCTAssertEqual(registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(registrableDomain("example.com"), "example.com")
        XCTAssertEqual(registrableDomain("1.2.3.4"), "1.2.3.4")
        XCTAssertEqual(registrableDomain(""), "未知")
    }

    func testDecodeRealisticConnectionsJSON() throws {
        let json = """
        {"downloadTotal":123,"uploadTotal":45,"memory":1000,"connections":[
          {"id":"abc","metadata":{"network":"tcp","type":"HTTPS","sourceIP":"127.0.0.1","destinationIP":"1.1.1.1","sourcePort":"54321","destinationPort":"443","host":"example.com","dnsMode":"normal","processPath":"/usr/bin/curl","process":"curl","specialProxy":"","inboundPort":"0"},
           "upload":10,"download":20,"start":"2026-10-15T20:50:00.123456789+08:00","chains":["DIRECT"],"providerChains":[],"rule":"Match","rulePayload":""}]}
        """
        let snap = try JSONDecoder().decode(ConnectionsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.connections.count, 1)
        let c = snap.connections[0]
        XCTAssertEqual(c.metadata.destinationPort, "443")
        XCTAssertEqual(c.metadata.process, "curl")
        XCTAssertNotNil(c.start)
        // 端口字段为整数时同样可解码
        let json2 = #"{"connections":[{"id":"x","metadata":{"sourcePort":5,"destinationPort":80}}]}"#
        let s2 = try JSONDecoder().decode(ConnectionsSnapshot.self, from: Data(json2.utf8))
        XCTAssertEqual(s2.connections[0].metadata.destinationPort, "80")
    }

    @MainActor
    func testStatsAggregationAndQuery() async {
        let stats = TrafficStats(path: nil)
        stats.record([
            BytesDelta(process: "curl", host: "api.example.com", policy: "DIRECT", up: 100, down: 900, isNew: true),
            BytesDelta(process: "curl", host: "cdn.example.com", policy: "HK-01", up: 50, down: 50, isNew: true),
            BytesDelta(process: "Safari", host: "www.apple.com", policy: "DIRECT", up: 10, down: 10, isNew: true),
        ])
        let procs = await stats.top(kind: .process, days: 1)
        XCTAssertEqual(procs.first?.key, "curl")
        XCTAssertEqual(procs.first?.total, 1100)
        XCTAssertEqual(procs.first?.connections, 2)
        let hosts = await stats.top(kind: .host, days: 7)
        XCTAssertEqual(hosts.first { $0.key == "example.com" }?.total, 1100)
        let daily = await stats.dailyTotals(days: 7)
        XCTAssertEqual(daily.count, 7)
        XCTAssertEqual(daily.last?.total, 1120)
        // 再次写入应累加
        stats.record([BytesDelta(process: "curl", host: "api.example.com", policy: "DIRECT", up: 1, down: 1, isNew: false)])
        let again = await stats.top(kind: .process, days: 1)
        XCTAssertEqual(again.first?.total, 1102)
        await stats.clear()
        let cleared = await stats.top(kind: .process, days: 1)
        XCTAssertTrue(cleared.isEmpty)
    }
}
