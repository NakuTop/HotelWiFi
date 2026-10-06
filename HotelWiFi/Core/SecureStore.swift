import Foundation
import Darwin
import CryptoKit

/// Directory-relative, no-follow IO. Private owner-only directory; flock covers every read/modify/write.
public final class SecureStore: @unchecked Sendable {
    public let directory: URL
    private let dirFD: Int32
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Validate every existing path component rather than following a substituted parent symlink.
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        // standardizedFileURL rewrites /private/var to the /var symlink on macOS; do not use it here.
        for part in directory.pathComponents.dropFirst() {
            component.appendPathComponent(part)
            var s = stat()
            guard lstat(component.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { throw HWError.storage("存储目录包含非目录或符号链接。") }
        }
        dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw HWError.storage("无法打开私有存储目录。") }
        var s = stat()
        guard fstat(dirFD, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
            close(dirFD); throw HWError.storage("存储目录所有者或权限不安全；需要当前用户所有、0700。")
        }
    }
    deinit { close(dirFD) }
    private func nameCheck(_ name: String) throws {
        guard !name.isEmpty, name.count <= 120, !name.contains("/"), name != ".", name != ".." else { throw HWError.storage("非法存储文件名。") }
    }
    public func read(_ name: String) throws -> Data? {
        try nameCheck(name)
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw HWError.storage("无法安全读取 \(name)。") }; defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0,
              (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1, s.st_size <= 8_000_000 else { throw HWError.storage("私有文件权限、类型或大小异常。") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw HWError.storage("文件读取失败。") }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
    public func write(_ data: Data, named name: String) throws {
        try nameCheck(name)
        let temporary = ".write-" + UUID().uuidString
        let fd = openat(dirFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HWError.storage("无法创建事务临时文件。") }
        defer { close(fd); unlinkat(dirFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw HWError.storage("写入失败，可能磁盘空间不足。") }; offset += n
            }
        }
        guard fsync(fd) == 0, renameat(dirFD, temporary, dirFD, name) == 0, fsync(dirFD) == 0 else { throw HWError.storage("原子持久化失败。") }
    }
    public func withExclusiveLock<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let lock = try acquireLock(name); defer { lock.release() }; return try body()
    }
    public func acquireLock(_ name: String) throws -> StoreLock {
        try nameCheck(name)
        let fd = openat(dirFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HWError.storage("无法创建独占锁。") }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1 else { close(fd); throw HWError.storage("独占锁不安全。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw HWError.busy }
        return StoreLock(fd)
    }
    public func delete(_ name: String) throws { try nameCheck(name); guard unlinkat(dirFD, name, 0) == 0 || errno == ENOENT else { throw HWError.storage("无法移除私有文件。") }; _ = fsync(dirFD) }
    public func identityKey() throws -> Data {
        try withExclusiveLock("identity.lock") {
            if let data = try read("identity.key") { guard data.count == 32 else { throw HWError.storage("本地身份密钥损坏。") }; return data }
            var data = Data(count: 32)
            let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard result == errSecSuccess else { throw HWError.storage("无法生成本地身份密钥。") }
            try write(data, named: "identity.key"); return data
        }
    }
    public static func user() throws -> SecureStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try .init(directory: base.appendingPathComponent("HotelWiFi", isDirectory: true))
    }
}
import Security
public final class StoreLock: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    fileprivate init(_ fd: Int32) { self.fd = fd }
    public func release() { lock.withLock { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd); fd = -1 } } }
    deinit { release() }
}
public struct PrivacyFilter: Sendable {
    private let key: SymmetricKey
    public init(key: Data) { self.key = SymmetricKey(data: key) }
    public func digest(_ components: [String]) -> String {
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return HMAC<SHA256>.authenticationCode(for: data, using: key).hex
    }
    public static func exported(_ report: SessionReport) -> SessionReport {
        var r = report
        func redact(_ c: NetworkContext) -> NetworkContext {
            var n = c; n.identity = nil; n.apIdentity = nil; n.serviceID = nil; n.serviceName = nil; n.configurationDigest = nil; return n
        }
        r.current = r.current.map(redact)
        r.windows = r.windows.map { var w = $0; w.context = redact(w.context); return w }
        if let index = r.capabilities?.capabilities.firstIndex(where: { $0.id == "networkService" }) {
            r.capabilities?.capabilities[index].detail = "网络服务名称和标识已移除"
        }
        // Reports never contain SSID, addresses, URL queries, PAC URLs, credentials, or response bodies.
        return r
    }
}
