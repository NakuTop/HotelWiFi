import Foundation

public final class ApplicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: NativeProbeTask?
    public init() {}
    public func cancel() { lock.withLock { active?.cancel() } }
    public func run(_ endpoint: ProbeEndpoint, budget: BudgetManager, final: Bool = false,
                    configuration: URLSessionConfiguration? = nil, timeoutLimit: Double = 8) async throws -> ProbeSample {
        let timeout = min(max(1, timeoutLimit), try budget.startRequest(final: final))
        let task = NativeProbeTask(endpoint: endpoint, budget: budget, final: final, timeout: timeout, configuration: configuration)
        lock.withLock { active = task }
        defer { lock.withLock { active = nil } }
        return await withTaskCancellationHandler(operation: { await task.start() }, onCancel: { task.cancel() })
    }
}

private final class NativeProbeTask: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let endpoint: ProbeEndpoint
    let budget: BudgetManager
    let final: Bool
    let timeout: Double
    let customConfiguration: URLSessionConfiguration?
    var session: URLSession?
    var data = Data()
    var sample: ProbeSample
    var forcedFailure: ProbeFailure?
    var continuation: CheckedContinuation<ProbeSample, Never>?
    private let startLock = NSLock()
    private var cancelled = false
    init(endpoint: ProbeEndpoint, budget: BudgetManager, final: Bool, timeout: Double, configuration: URLSessionConfiguration?) {
        self.endpoint = endpoint; self.budget = budget; self.final = final; self.timeout = timeout; customConfiguration = configuration
        sample = ProbeSample(endpoint: endpoint.id, provider: endpoint.provider, kind: endpoint.kind)
        super.init()
    }
    func start() async -> ProbeSample {
        await withCheckedContinuation { c in
            startLock.withLock {
                if cancelled { sample.failure = .cancelled; c.resume(returning: sample); return }
                continuation = c
                let config = customConfiguration ?? .ephemeral
                config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                // Preserve the platform credential mechanism; never inspect, persist, or log credentials ourselves.
                config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
                config.httpMaximumConnectionsPerHost = 1; config.waitsForConnectivity = false
                // Leave connectionProxyDictionary nil: preserve system PAC/WPAD/manual proxy selection and VPN.
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let s = URLSession(configuration: config, delegate: self, delegateQueue: queue); session = s
                var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("HotelWiFi/1.0", forHTTPHeaderField: "User-Agent")
                sample.started = Date(); s.dataTask(with: request).resume()
            }
        }
    }
    func cancel() { startLock.withLock { cancelled = true; session?.invalidateAndCancel() } }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { forcedFailure = .transport; completionHandler(.cancel); return }
        sample.status = http.statusCode; if sample.originalStatus == nil { sample.originalStatus = http.statusCode }
        if response.expectedContentLength > Int64(endpoint.maxBytes) { forcedFailure = .byteLimit; completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        sample.bytes += chunk.count
        let allowed = budget.consume(chunk.count, final: final)
        guard allowed, sample.bytes <= endpoint.maxBytes else { forcedFailure = .byteLimit; dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if sample.originalStatus == nil { sample.originalStatus = response.statusCode }
        sample.redirectStatuses.append(response.statusCode)
        guard sample.redirectStatuses.count <= 3, request.url?.scheme == "https", request.url?.host == endpoint.url.host,
              request.url?.user == nil, request.url?.password == nil else {
            forcedFailure = .redirect; completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        sample.times.total = metrics.taskInterval.duration
        guard let m = metrics.transactionMetrics.last else { return }
        // CFNetwork can buffer a short, incomplete body until timeout and omit data/response callbacks.
        // Metrics still expose the actual response and bytes; account for those bytes as well.
        if sample.status == nil { sample.status = (m.response as? HTTPURLResponse)?.statusCode }
        if sample.originalStatus == nil { sample.originalStatus = (metrics.transactionMetrics.first?.response as? HTTPURLResponse)?.statusCode }
        let actual = metrics.transactionMetrics.reduce(0) { $0 + Int(max($1.countOfResponseBodyBytesReceived, $1.countOfResponseBodyBytesAfterDecoding)) }
        if actual > sample.bytes {
            if !budget.consume(actual - sample.bytes, final: final) { forcedFailure = .byteLimit }
            sample.bytes = actual
        }
        if sample.bytes > endpoint.maxBytes { forcedFailure = .byteLimit }
        func duration(_ start: Date?, _ end: Date?) -> Double? { guard let start, let end, end >= start else { return nil }; return end.timeIntervalSince(start) }
        sample.reused = m.isReusedConnection; sample.viaProxy = m.isProxyConnection
        sample.transportProtocol = m.networkProtocolName
        sample.addressFamily = m.localAddress.map { $0.contains(":") ? "IPv6" : "IPv4" }
        sample.interface = InterfaceResolver.name(for: m.localAddress)
        if !m.isReusedConnection {
            sample.times.dns = duration(m.domainLookupStartDate, m.domainLookupEndDate)
            // connectEnd includes TLS. TCP stops at secureConnectionStart when TLS exists.
            sample.times.tcp = duration(m.connectStartDate, m.secureConnectionStartDate ?? m.connectEndDate)
            sample.times.tls = duration(m.secureConnectionStartDate, m.secureConnectionEndDate)
        }
        sample.times.firstByte = duration(m.fetchStartDate, m.responseStartDate)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sample.completed = Date()
        if sample.times.total == nil { sample.times.total = sample.completed.timeIntervalSince(sample.started) }
        if let error = error as NSError? {
            sample.errorCode = error.code; sample.errorDomain = error.domain
            sample.failure = forcedFailure ?? Self.failure(error)
        } else if let forcedFailure { sample.failure = forcedFailure }
        else if sample.status != endpoint.expectedStatus { sample.failure = .http }
        else if !endpoint.body.accepts(data) { sample.failure = .body }
        else { sample.complete = true }
        let c = continuation; continuation = nil; c?.resume(returning: sample)
        session.finishTasksAndInvalidate(); self.session = nil
    }
    static func failure(_ error: NSError) -> ProbeFailure {
        guard error.domain == NSURLErrorDomain else { return .transport }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCancelled: return .cancelled
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet: return .connect
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid: return .tls
        default: return .transport
        }
    }
}
