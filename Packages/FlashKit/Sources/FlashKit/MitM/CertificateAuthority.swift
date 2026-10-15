import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

/// 本地根证书与叶子证书签发。
///
/// - 根证书为本机自签的 ECDSA P-256 CA，私钥仅保存在应用数据目录（权限 0600）。
/// - 叶子证书按域名即时签发并缓存，供 MitM 引擎终结 TLS 使用。
/// - 信任操作通过 `security` 命令写入当前用户的登录钥匙串，无需开发者账号。
///
/// @author ygw
public final class CertificateAuthority: @unchecked Sendable {
    /// 根证书通用名（用于在钥匙串中查找与删除）
    public static let commonName = "Flash MitM Root CA"

    public enum CAError: LocalizedError {
        case notReady
        case commandFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notReady: "根证书尚未生成"
            case .commandFailed(let m): m
            }
        }
    }

    private let directory: URL
    private let lock = NSLock()
    private var caCertificate: Certificate?
    private var caKey: Certificate.PrivateKey?
    private var caSubjectKeyID: SubjectKeyIdentifier?
    private let leafKey = P256.Signing.PrivateKey()
    private var contexts: [String: NIOSSLContext] = [:]
    var leafKeyPEM: String { (try? Certificate.PrivateKey(leafKey).serializeAsPEM().pemString) ?? "" }

    /// - Parameter directory: 证书存放目录（默认应用数据目录下的 mitm）
    public init(directory: URL = AppPaths.supportDir.appendingPathComponent("mitm", isDirectory: true)) {
        self.directory = directory
    }

    /// 根证书文件（PEM，可导入其他设备）
    public var certificateURL: URL { directory.appendingPathComponent("flash-ca.crt") }
    private var keyURL: URL { directory.appendingPathComponent("flash-ca.key") }

    /// 根证书是否已生成
    public var isGenerated: Bool {
        FileManager.default.fileExists(atPath: certificateURL.path) && FileManager.default.fileExists(atPath: keyURL.path)
    }

    // MARK: 根证书

    /// 加载已有根证书，不存在则生成
    /// - Throws: 证书生成或读写失败
    public func ensureCA() throws {
        lock.lock(); defer { lock.unlock() }
        if caCertificate != nil { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if isGenerated,
           let certPEM = try? String(contentsOf: certificateURL, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
           let cert = try? Certificate(pemEncoded: certPEM),
           let key = try? Certificate.PrivateKey(pemEncoded: keyPEM) {
            caCertificate = cert
            caKey = key
            caSubjectKeyID = SubjectKeyIdentifier(hash: key.publicKey)
            return
        }
        try generateLocked()
    }

    /// 重新生成根证书（旧证书失效，需要重新信任）
    public func regenerate() throws {
        lock.lock(); defer { lock.unlock() }
        contexts.removeAll()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try generateLocked()
    }

    private func generateLocked() throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName {
            CommonName(Self.commonName)
            OrganizationName("Flash")
        }
        let ski = SubjectKeyIdentifier(hash: key.publicKey)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            ski
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-86400), notValidAfter: now.addingTimeInterval(86400 * 3650),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions, issuerPrivateKey: key)
        try cert.serializeAsPEM().pemString.write(to: certificateURL, atomically: true, encoding: .utf8)
        try key.serializeAsPEM().pemString.write(to: keyURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        caCertificate = cert
        caKey = key
        caSubjectKeyID = ski
    }

    // MARK: 叶子证书

    /// 为主机签发（或取缓存的）服务端 TLS 上下文
    /// - Parameter host: 域名或 IP 字面量
    /// - Returns: 供 NIOSSLServerHandler 使用的上下文
    public func serverContext(for host: String) throws -> NIOSSLContext {
        let key = host.lowercased()
        lock.lock()
        if let ctx = contexts[key] { lock.unlock(); return ctx }
        lock.unlock()
        try ensureCA()
        let pem = try issueLeafPEM(host: key)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem)))
        config.applicationProtocols = ["http/1.1"]
        config.minimumTLSVersion = .tlsv12
        let ctx = try NIOSSLContext(configuration: config)
        lock.lock()
        if contexts.count > 800 { contexts.removeAll() }
        contexts[key] = ctx
        lock.unlock()
        return ctx
    }

    /// 签发叶子证书，返回 PEM
    /// - Parameter host: 域名或 IP
    func issueLeafPEM(host: String) throws -> String {
        guard let caCert = caCertificate, let caKey, let caSubjectKeyID else { throw CAError.notReady }
        let leaf = Certificate.PrivateKey(leafKey)
        let san: GeneralName
        if let ip = Self.ipv4Bytes(host) {
            san = .ipAddress(ASN1OctetString(contentBytes: ip[...]))
        } else {
            san = .dnsName(host)
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([san])
            AuthorityKeyIdentifier(keyIdentifier: caSubjectKeyID.keyIdentifier)
        }
        let subject = try DistinguishedName { CommonName(host.count > 60 ? String(host.prefix(60)) : host) }
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: leaf.publicKey,
            notValidBefore: now.addingTimeInterval(-86400), notValidAfter: now.addingTimeInterval(86400 * 365),
            issuer: caCert.subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions, issuerPrivateKey: caKey)
        return try cert.serializeAsPEM().pemString
    }

    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { UInt8($0) }
        return nums.count == 4 ? nums : nil
    }

    // MARK: 钥匙串信任

    /// 根证书是否已被当前用户信任（用于 TLS 的 SSL 策略）
    public func isTrusted() -> Bool {
        guard isGenerated else { return false }
        let r = Self.run("/usr/bin/security", ["verify-cert", "-c", certificateURL.path, "-p", "ssl", "-q"])
        return r.status == 0
    }

    /// 安装并信任根证书（会弹出系统授权对话框）
    /// - Throws: 用户取消或命令失败
    public func installAndTrust() throws {
        try ensureCA()
        let keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        let r = Self.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, certificateURL.path])
        guard r.status == 0 else { throw CAError.commandFailed(r.output.isEmpty ? "信任根证书失败（可能已取消授权）" : r.output) }
    }

    /// 从钥匙串移除根证书
    public func removeFromKeychain() throws {
        _ = Self.run("/usr/bin/security", ["remove-trusted-cert", certificateURL.path])
        let r = Self.run("/usr/bin/security", ["delete-certificate", "-c", Self.commonName])
        if r.status != 0, !r.output.contains("could not be found") {
            throw CAError.commandFailed(r.output)
        }
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
