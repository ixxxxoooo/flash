import Foundation
import Compression

/// 内容编码解码（gzip / deflate / br），用于脚本与报文查看。
/// @author ygw
public enum ContentDecoder {
    /// 按 Content-Encoding 解码
    /// - Parameters:
    ///   - data: 原始（可能压缩的）数据
    ///   - encoding: Content-Encoding 头的值
    /// - Returns: 解码后的数据；无编码或不支持时返回原数据；解码失败返回 nil
    public static func decode(_ data: Data, encoding: String?) -> Data? {
        guard let enc = encoding?.lowercased().trimmingCharacters(in: .whitespaces), !enc.isEmpty, enc != "identity" else { return data }
        switch enc {
        case "gzip", "x-gzip":
            guard let body = stripGzipHeader(data) else { return nil }
            return inflate(body, algorithm: COMPRESSION_ZLIB)
        case "deflate":
            // 带 zlib 头（0x78）的需要跳过 2 字节
            if data.count > 2, data[data.startIndex] & 0x0F == 8 { return inflate(data.dropFirst(2), algorithm: COMPRESSION_ZLIB) ?? inflate(data, algorithm: COMPRESSION_ZLIB) }
            return inflate(data, algorithm: COMPRESSION_ZLIB)
        case "br":
            return inflate(data, algorithm: COMPRESSION_BROTLI)
        default:
            return data
        }
    }

    /// 去掉 gzip 头部，返回原始 deflate 数据
    static func stripGzipHeader(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return Data(b[i..<(b.count - 8)])
    }

    private static func inflate(_ input: Data, algorithm: compression_algorithm) -> Data? {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = base
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - stream.dst_size)
                if output.count > 64 * 1024 * 1024 { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: continue
                default: return output.isEmpty ? nil : output
                }
            }
        }
    }
}

/// 一次完整的 HTTP 交换（用于请求页的「报文」标签）
public struct HTTPExchange: Identifiable, Sendable {
    public var id: UUID = UUID()
    public var startedAt = Date()
    public var duration: TimeInterval = 0
    public var scheme = "https"
    public var host = ""
    public var method = ""
    public var url = ""
    public var requestHeaders: HeaderList = []
    public var requestBody = Data()
    public var requestBodyTruncated = false
    public var statusCode = 0
    public var responseHeaders: HeaderList = []
    public var responseBody = Data()
    public var responseBodyTruncated = false
    /// 重写 / 脚本 / 错误等说明
    public var notes: [String] = []
    public var finished = false

    public init() {}

    /// 指定响应头的值
    public func responseHeader(_ name: String) -> String? {
        responseHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public func requestHeader(_ name: String) -> String? {
        requestHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// 解码后的响应体（按 Content-Encoding），截断时可能失败，失败返回原始数据
    public var decodedResponseBody: Data {
        ContentDecoder.decode(responseBody, encoding: responseHeader("Content-Encoding")) ?? responseBody
    }
    public var decodedRequestBody: Data {
        ContentDecoder.decode(requestBody, encoding: requestHeader("Content-Encoding")) ?? requestBody
    }

    /// 生成等价的 cURL 命令
    public var curlCommand: String {
        var parts = ["curl", "-X", method, Self.shellQuote(url)]
        for h in requestHeaders where !["host", "content-length", "connection", "accept-encoding"].contains(h.name.lowercased()) {
            parts += ["-H", Self.shellQuote("\(h.name): \(h.value)")]
        }
        if !requestBody.isEmpty, let s = String(data: requestBody, encoding: .utf8) {
            parts += ["--data-raw", Self.shellQuote(s)]
        }
        parts.append("--compressed")
        return parts.joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// 报文记录器：内存环形缓冲，限制条数与总字节数。
/// @author ygw
public final class HTTPRecorder: @unchecked Sendable {
    public static let bodyLimit = 1_048_576
    private let lock = NSLock()
    private var items: [HTTPExchange] = []
    private var bytes = 0
    private let maxItems: Int
    private let maxBytes: Int
    /// 有新记录或更新时回调（线程不确定，调用方自行切回主线程）
    public var onChange: (@Sendable () -> Void)?
    /// 是否记录（关闭后仍然处理流量，只是不保存）
    public var enabled = true

    public init(maxItems: Int = 500, maxBytes: Int = 96 * 1024 * 1024) {
        self.maxItems = maxItems; self.maxBytes = maxBytes
    }

    private static func size(_ e: HTTPExchange) -> Int { e.requestBody.count + e.responseBody.count + 2048 }

    /// 保存或更新一条记录
    public func upsert(_ e: HTTPExchange) {
        guard enabled else { return }
        lock.lock()
        if let idx = items.firstIndex(where: { $0.id == e.id }) {
            bytes -= Self.size(items[idx])
            items[idx] = e
        } else {
            items.append(e)
        }
        bytes += Self.size(e)
        while items.count > maxItems || bytes > maxBytes, !items.isEmpty {
            bytes -= Self.size(items.removeFirst())
        }
        lock.unlock()
        onChange?()
    }

    /// 全部记录（按开始时间升序）
    public func all() -> [HTTPExchange] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// 查询在时间窗内、主机相同的记录（用于把报文关联到连接）
    public func exchanges(host: String, from: Date, to: Date) -> [HTTPExchange] {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.host.lowercased() == h && $0.startedAt >= from.addingTimeInterval(-2) && $0.startedAt <= to.addingTimeInterval(2) }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    public func clear() {
        lock.lock(); items.removeAll(); bytes = 0; lock.unlock()
        onChange?()
    }
}
