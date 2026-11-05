import Foundation

public struct UsageHTTPRequest: Equatable, Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }
    public let url: URL
    public let method: Method
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval
    public init(url: URL, method: Method, headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval) {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.timeout = timeout
    }
}

public struct UsageHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol UsageHTTPTransport: Sendable {
    func send(_ request: UsageHTTPRequest) -> UsageHTTPResponse?
}

public protocol UsageCredentialReading: Sendable {
    func read(_ url: URL) -> Data?
}

/// Bounded fail-closed credential reads: regular files only (a FIFO/device would hang a
/// collector forever), at most `limit` bytes + 1 sentinel, nil on oversize or any read error.
public struct UsageFileCredentialReader: UsageCredentialReading {
    private let limit: Int
    public init(limit: Int = 64 * 1024) { self.limit = limit }
    public func read(_ url: URL) -> Data? {
        guard limit > 0, limit < Int.max - 1 else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        return data.count <= limit ? data : nil
    }
}

/// Production transport: ephemeral URLSession, HTTPS allowlist, no redirects, no shared
/// cookies/cache/credential storage, bounded timeout, and a 1 MiB cap enforced WHILE
/// receiving — Content-Length is rejected up front and streaming data cancels the task
/// the moment it crosses the cap rather than after the whole body is allocated.
public struct SystemUsageHTTPTransport: UsageHTTPTransport {
    static let allowedHosts: Set<String> = [
        "api2.cursor.sh", "cli-chat-proxy.grok.com",
        "cloudcode-pa.googleapis.com", "server.codeium.com", "opencode.ai",
    ]
    static let maxBody = 1_048_576
    private let timeoutCap: TimeInterval
    /// Test seam: inject a configuration whose protocolClasses stub the network.
    /// nil uses the hardened ephemeral production configuration.
    private let configuration: URLSessionConfiguration?
    public init(timeoutCap: TimeInterval = 15,
                configuration: URLSessionConfiguration? = nil) {
        self.timeoutCap = timeoutCap; self.configuration = configuration
    }

    public func send(_ request: UsageHTTPRequest) -> UsageHTTPResponse? {
        let url = request.url
        guard url.scheme == "https",
              let host = url.host, Self.allowedHosts.contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              request.timeout.isFinite, request.timeout > 0,
              timeoutCap.isFinite, timeoutCap > 0,
              request.method == .get || request.method == .post else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = min(request.timeout, timeoutCap)
        for (name, value) in request.headers {
            // header values must never smuggle control characters
            guard !value.contains("\r"), !value.contains("\n") else { return nil }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        if let testConfig = configuration {
            config.protocolClasses = testConfig.protocolClasses
        }
        let gate = DispatchSemaphore(value: 0)
        let box = Box()
        box.arm(gate)
        let session = URLSession(configuration: config, delegate: box, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: urlRequest)
        task.resume()
        if gate.wait(timeout: .now() + min(request.timeout, timeoutCap) + 2) == .timedOut {
            task.cancel()
            box.finish(nil)
        }
        return box.result
    }

    /// Streaming accumulator under a lock: cancels on oversize DURING receive,
    /// refuses redirects, completes exactly once.
    private final class Box: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var done = false
        private var gate: DispatchSemaphore?
        var result: UsageHTTPResponse?
        private var status: Int?

        func arm(_ gate: DispatchSemaphore) { self.gate = gate }

        func finish(_ value: UsageHTTPResponse?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true; result = value
            let g = gate; gate = nil
            lock.unlock()
            g?.signal()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                if response.expectedContentLength > Int64(SystemUsageHTTPTransport.maxBody) {
                    completionHandler(.cancel)
                    finish(nil)
                    return
                }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            lock.lock()
            if done { lock.unlock(); return }
            let over = data.count > SystemUsageHTTPTransport.maxBody - buffer.count
            if !over { buffer.append(data) }
            lock.unlock()
            if over { dataTask.cancel(); finish(nil) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            lock.lock()
            let s = status
            let body = buffer.count <= SystemUsageHTTPTransport.maxBody ? buffer : nil
            lock.unlock()
            guard error == nil, let s, let body else { finish(nil); return }
            finish(UsageHTTPResponse(status: s, body: body))
        }
    }
}
