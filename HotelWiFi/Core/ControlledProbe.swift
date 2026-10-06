import Foundation
import Darwin

public struct ProcessOutput { public var status: Int32; public var data: Data }
public enum BoundedProcess {
    /// Fixed executable + argv, no shell, no inherited proxy or credential environment.
    public static func run(_ executable: String, _ arguments: [String], timeout: Double = 5, maxBytes: Int = 65536) -> ProcessOutput {
        let process = Process(), pipe = Pipe(), lock = NSLock(), readers = DispatchGroup()
        var captured = Data()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .init(status: -1, data: Data()) }
        pipe.fileHandleForWriting.closeFile()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            while true {
                let data = pipe.fileHandleForReading.availableData; if data.isEmpty { break }
                let full = lock.withLock { () -> Bool in
                    captured.append(data.prefix(max(0, maxBytes - captured.count))); return captured.count >= maxBytes
                }
                if full && process.isRunning { process.terminate() }
            }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if !process.isRunning { done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        readers.wait()
        let data = lock.withLock { captured }
        return .init(status: process.terminationStatus, data: data)
    }
}

public enum CurlMetricsParser {
    public static func parse(_ data: Data, body: Data, endpoint: ProbeEndpoint, path: ProbePath, exit: Int32) -> ProbeSample {
        var sample = ProbeSample(endpoint: endpoint.id, provider: endpoint.provider, path: path, kind: endpoint.kind)
        sample.exitCode = exit; sample.bytes = body.count
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = o["http_code"] as? Int, let total = o["time_total"] as? Double else { sample.failure = .parse; return sample }
        func number(_ key: String) -> Double? { o[key] as? Double }
        let reused = (o["num_connects"] as? Int).map { $0 == 0 }
        func difference(_ end: Double?, _ start: Double?) -> Double? {
            guard let end, let start, end >= start, end > 0 else { return nil }; return end - start
        }
        sample.status = code; sample.originalStatus = code; sample.reused = reused
        sample.transportProtocol = o["http_version"] as? String; sample.viaProxy = false
        sample.times = .init(dns: reused == false ? number("time_namelookup") : nil,
                             tcp: reused == false ? difference(number("time_connect"), number("time_namelookup")) : nil,
                             tls: reused == false ? difference(number("time_appconnect"), number("time_connect")) : nil,
                             firstByte: number("time_starttransfer"), total: total)
        if exit != 0 { sample.failure = exit == 28 ? .timeout : exit == 6 ? .dns : exit == 60 ? .tls : .transport }
        else if code != endpoint.expectedStatus { sample.failure = (300...399).contains(code) ? .redirect : .http }
        else if !endpoint.body.accepts(body) { sample.failure = .body }
        else { sample.complete = true }
        return sample
    }
}

public final class ControlledProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationGeneration = 0
    public init() {}
    public func cancel() { lock.withLock { cancellationGeneration += 1; if process?.isRunning == true { process?.terminate() } } }
    public static func arguments(endpoint: ProbeEndpoint, path: ProbePath, timeout: Double, resolvedIPv4: String? = nil) -> [String] {
        var args = ["-q", "--silent", "--show-error", "--globoff", "--noproxy", "*", "--proxy", "", "--proto", "=https", "--proto-redir", "=https",
                    "--max-redirs", "0", "--connect-timeout", String(min(4, timeout)), "--max-time", String(timeout),
                    "--max-filesize", String(endpoint.maxBytes), "--header", "Cache-Control: no-cache, no-store", "--header", "Accept-Encoding: identity",
                    "--write-out", "%{stderr}HOTELWIFI_METRICS:%{json}"]
        if path == .ipv4 { args += ["--ipv4"] }
        if path == .ipv6 { args += ["--ipv6"] }
        if let resolvedIPv4, let host = endpoint.url.host { args += ["--resolve", "\(host):443:\(resolvedIPv4)"] }
        args += ["--url", endpoint.url.absoluteString]; return args
    }
    public func run(_ endpoint: ProbeEndpoint, path: ProbePath, budget: BudgetManager, resolvedIPv4: String? = nil) async throws -> ProbeSample {
        guard path != .system else { throw HWError.invalid("curl 不能代表系统实际代理路径。") }
        let timeout = try budget.startRequest()
        let generation = lock.withLock { cancellationGeneration }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let p = Process(), out = Pipe(), err = Pipe(), dataLock = NSLock(), readers = DispatchGroup()
                    var body = Data(), stderr = Data(), received = 0, limited = false
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    p.arguments = Self.arguments(endpoint: endpoint, path: path, timeout: timeout, resolvedIPv4: resolvedIPv4)
                    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
                    p.standardOutput = out; p.standardError = err
                    func collect(_ chunk: Data) {
                        let keep = budget.consume(chunk.count)
                        dataLock.withLock {
                            received += chunk.count
                            if keep && received <= endpoint.maxBytes { body.append(chunk) } else { limited = true }
                        }
                        if dataLock.withLock({ limited }), p.isRunning { p.terminate() }
                    }
                    let start = Date()
                    do { try self.lock.withLock {
                        guard self.cancellationGeneration == generation else { throw HWError.cancelled }
                        self.process = p; try p.run()
                    } } catch {
                        var s = ProbeSample(endpoint: endpoint.id, provider: endpoint.provider, path: path, kind: endpoint.kind); s.failure = .transport
                        continuation.resume(returning: s); return
                    }
                    out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile()
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readers.leave() }
                        while true { let d = out.fileHandleForReading.availableData; if d.isEmpty { break }; collect(d) }
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readers.leave() }
                        while true {
                            let d = err.fileHandleForReading.availableData; if d.isEmpty { break }
                            dataLock.withLock { stderr.append(d.prefix(max(0, 32768 - stderr.count))) }
                        }
                    }
                    let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }; if !p.isRunning { done.signal() }
                    if done.wait(timeout: .now() + timeout + 1) == .timedOut { p.terminate(); if done.wait(timeout: .now() + 0.5) == .timedOut { kill(p.processIdentifier, SIGKILL) } }
                    p.waitUntilExit(); readers.wait()
                    let result: ProbeSample = dataLock.withLock {
                        let text = String(decoding: stderr, as: UTF8.self)
                        let json = text.range(of: "HOTELWIFI_METRICS:").map { String(text[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                        var sample = CurlMetricsParser.parse(Data(json.utf8), body: body, endpoint: endpoint, path: path, exit: p.terminationStatus)
                        if path == .candidateDNS { sample.times.dns = nil } // --resolve skips the process resolver.
                        sample.started = start; sample.completed = Date(); sample.bytes = received
                        if limited { sample.complete = false; sample.failure = .byteLimit }
                        return sample
                    }
                    self.lock.withLock { self.process = nil }; continuation.resume(returning: result)
                }
            }
        }, onCancel: { self.cancel() })
    }
}
