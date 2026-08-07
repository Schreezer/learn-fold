import Foundation
import Network
import Security

struct PinnedHTTPDownload: Sendable {
    let data: Data
    let finalURL: URL
    let statusCode: Int
    let headers: [String: String]
}

struct PinnedHTTPConnectionRequest: Sendable {
    let url: URL
    let tlsServerName: String
    let address: String
    let useTLS: Bool
    let requestBytes: Data
    let maximumBodyBytes: Int
    let timeoutSeconds: TimeInterval
}

enum PinnedHTTPDownloaderError: LocalizedError, Equatable {
    case invalidURL
    case blockedURL
    case connectionFailed(String)
    case malformedResponse
    case responseTooLarge
    case tooManyRedirects
    case insecureRedirect
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The source URL is invalid."
        case .blockedURL: "The source URL resolved to a non-public address."
        case .connectionFailed(let detail): "The source connection failed: \(detail)"
        case .malformedResponse: "The source server returned a malformed HTTP response."
        case .responseTooLarge: "The source exceeds Learnfold’s ingestion limit."
        case .tooManyRedirects: "The source redirected too many times."
        case .insecureRedirect: "The source redirected from HTTPS to insecure HTTP."
        case .timedOut: "The source server did not finish responding before the deadline."
        }
    }
}

/// HTTP/1.1 downloader that connects to the exact public address that was
/// validated while authenticating the original TLS hostname through SNI.
struct PinnedHTTPDownloader: Sendable {
    typealias Resolver = @Sendable (String) async -> [String]
    typealias Transport = @Sendable (PinnedHTTPConnectionRequest) async throws -> Data

    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumRedirects = 5

    private let resolver: Resolver
    private let transport: Transport
    private let perAttemptTimeoutSeconds: TimeInterval
    private let totalTimeoutSeconds: TimeInterval

    init(
        resolver: @escaping Resolver,
        transport: @escaping Transport,
        perAttemptTimeoutSeconds: TimeInterval = 30,
        totalTimeoutSeconds: TimeInterval = 120
    ) {
        self.resolver = resolver
        self.transport = transport
        self.perAttemptTimeoutSeconds = perAttemptTimeoutSeconds
        self.totalTimeoutSeconds = totalTimeoutSeconds
    }

    static let live = PinnedHTTPDownloader(
        resolver: { host in
            await CourseSourceIngestionCoordinator.resolvedGlobalAddressStrings(host: host)
        },
        transport: { request in
            try await liveTransport(request)
        }
    )

    static func download(_ url: URL, maximumBytes: Int) async throws -> PinnedHTTPDownload {
        try await live.download(url, maximumBytes: maximumBytes)
    }

    func download(_ url: URL, maximumBytes: Int) async throws -> PinnedHTTPDownload {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(max(totalTimeoutSeconds, 0.001))
        )
        return try await download(
            url,
            maximumBytes: maximumBytes,
            redirectsRemaining: Self.maximumRedirects,
            deadline: deadline
        )
    }

    private func download(
        _ url: URL,
        maximumBytes: Int,
        redirectsRemaining: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> PinnedHTTPDownload {
        try Task.checkCancellation()
        guard CourseSourceIngestionCoordinator.isAllowedRemoteURL(url),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              scheme == "http" || scheme == "https" else {
            throw PinnedHTTPDownloaderError.blockedURL
        }
        let remaining = Self.secondsRemaining(until: deadline)
        guard remaining > 0 else { throw PinnedHTTPDownloaderError.timedOut }
        let addresses = try await resolveWithDeadline(host, timeoutSeconds: remaining)
        guard !addresses.isEmpty else { throw PinnedHTTPDownloaderError.blockedURL }

        var lastError: Error?
        for address in addresses {
            try Task.checkCancellation()
            let attemptRemaining = Self.secondsRemaining(until: deadline)
            guard attemptRemaining > 0 else { throw PinnedHTTPDownloaderError.timedOut }
            do {
                let request = try Self.connectionRequest(
                    url: url,
                    host: host,
                    address: address,
                    useTLS: scheme == "https",
                    maximumBytes: maximumBytes,
                    timeoutSeconds: min(perAttemptTimeoutSeconds, attemptRemaining)
                )
                let wire = try await transportWithDeadline(request)
                let raw = try Self.parse(wire, maximumBytes: maximumBytes)
                if (300...399).contains(raw.statusCode),
                   let location = raw.headers["location"] {
                    guard redirectsRemaining > 0 else {
                        throw PinnedHTTPDownloaderError.tooManyRedirects
                    }
                    guard let redirected = URL(string: location, relativeTo: url)?.absoluteURL else {
                        throw PinnedHTTPDownloaderError.malformedResponse
                    }
                    guard CourseSourceIngestionCoordinator.isAllowedRemoteURL(redirected) else {
                        throw PinnedHTTPDownloaderError.blockedURL
                    }
                    if url.scheme?.lowercased() == "https",
                       redirected.scheme?.lowercased() == "http" {
                        throw PinnedHTTPDownloaderError.insecureRedirect
                    }
                    return try await download(
                        redirected,
                        maximumBytes: maximumBytes,
                        redirectsRemaining: redirectsRemaining - 1,
                        deadline: deadline
                    )
                }
                return PinnedHTTPDownload(
                    data: raw.body,
                    finalURL: url,
                    statusCode: raw.statusCode,
                    headers: raw.headers
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PinnedHTTPDownloaderError.connectionFailed(
            "No pinned public endpoint was reachable."
        )
    }

    private func transportWithDeadline(
        _ request: PinnedHTTPConnectionRequest
    ) async throws -> Data {
        try await Self.raceWithDeadline(timeoutSeconds: request.timeoutSeconds) {
            try await transport(request)
        }
    }

    private func resolveWithDeadline(
        _ host: String,
        timeoutSeconds: TimeInterval
    ) async throws -> [String] {
        try await Self.raceWithDeadline(timeoutSeconds: timeoutSeconds) {
            await resolver(host)
        }
    }

    /// Unlike a structured task group, this returns at the deadline even when
    /// a blocking resolver or injected transport ignores cooperative
    /// cancellation. The abandoned worker may finish later, but the one-shot
    /// continuation discards that late result.
    private static func raceWithDeadline<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = PinnedAsyncRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let operationTask = Task.detached(priority: .utility) {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timerTask = Task.detached(priority: .utility) {
                    let seconds = max(timeoutSeconds, 0.001)
                    let nanoseconds = UInt64(min(seconds, 86_400) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    race.finish(.failure(PinnedHTTPDownloaderError.timedOut))
                }
                race.installTasks(operation: operationTask, timer: timerTask)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private static func secondsRemaining(
        until deadline: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func connectionRequest(
        url: URL,
        host: String,
        address: String,
        useTLS: Bool,
        maximumBytes: Int,
        timeoutSeconds: TimeInterval
    ) throws -> PinnedHTTPConnectionRequest {
        let portValue = url.port ?? (useTLS ? 443 : 80)
        guard UInt16(exactly: portValue) != nil else {
            throw PinnedHTTPDownloaderError.invalidURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }
        let defaultPort = useTLS ? 443 : 80
        let unbracketedHost = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        let headerHost = unbracketedHost.contains(":")
            ? "[\(unbracketedHost)]"
            : unbracketedHost
        let hostHeader = portValue == defaultPort
            ? headerHost
            : "\(headerHost):\(portValue)"
        let requestBytes = Data("""
        GET \(target) HTTP/1.1\r
        Host: \(hostHeader)\r
        User-Agent: Learnfold/1.0 Source Ingestion\r
        Accept: text/html,text/plain,text/markdown,application/pdf;q=0.9,*/*;q=0.1\r
        Accept-Encoding: identity\r
        Connection: close\r
        \r

        """.utf8)
        return PinnedHTTPConnectionRequest(
            url: url,
            tlsServerName: host,
            address: address,
            useTLS: useTLS,
            requestBytes: requestBytes,
            maximumBodyBytes: maximumBytes,
            timeoutSeconds: timeoutSeconds
        )
    }

    private struct RawResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    static func parseForTesting(
        _ wire: Data,
        maximumBytes: Int
    ) throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let result = try parse(wire, maximumBytes: maximumBytes)
        return (result.statusCode, result.headers, result.body)
    }

    private static func parse(_ wire: Data, maximumBytes: Int) throws -> RawResponse {
        guard maximumBytes >= 0,
              let header = try finalHeader(wire, allowIncomplete: false) else {
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        let rawBody = Data(wire[header.bodyStart...])
        let body: Data
        switch try framing(for: header) {
        case .noBody:
            body = Data()
        case .chunked:
            body = try decodeChunked(rawBody, maximumBytes: maximumBytes)
        case .contentLength(let length):
            guard length <= maximumBytes else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            guard rawBody.count >= length else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            body = Data(rawBody.prefix(length))
        case .untilClose:
            guard rawBody.count <= maximumBytes else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            body = rawBody
        }
        let headers = flattenedHeaders(header.headers)
        if let encoding = headers["content-encoding"],
           !encoding.isEmpty,
           encoding.lowercased() != "identity" {
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        return RawResponse(
            statusCode: header.statusCode,
            headers: headers,
            body: body
        )
    }

    private struct ParsedHeader {
        let statusCode: Int
        let headers: [String: [String]]
        let bodyStart: Data.Index
    }

    private enum ResponseFraming {
        case noBody
        case contentLength(Int)
        case chunked
        case untilClose
    }

    private static func finalHeader(
        _ wire: Data,
        allowIncomplete: Bool
    ) throws -> ParsedHeader? {
        var start = wire.startIndex
        var informationalCount = 0
        while true {
            guard let header = try parsedHeader(
                wire,
                startingAt: start,
                allowIncomplete: allowIncomplete
            ) else { return nil }
            guard (100...599).contains(header.statusCode) else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            if (100...199).contains(header.statusCode) {
                guard header.statusCode != 101, informationalCount < 8 else {
                    throw PinnedHTTPDownloaderError.malformedResponse
                }
                _ = try framing(for: header)
                informationalCount += 1
                start = header.bodyStart
                continue
            }
            return header
        }
    }

    private static func parsedHeader(
        _ wire: Data,
        startingAt start: Data.Index,
        allowIncomplete: Bool
    ) throws -> ParsedHeader? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard start <= wire.endIndex,
              let headerRange = wire[start...].range(of: delimiter) else {
            if wire.distance(from: start, to: wire.endIndex) > maximumHeaderBytes {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            if allowIncomplete { return nil }
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        guard headerRange.upperBound <= maximumHeaderBytes,
              wire.distance(from: start, to: headerRange.lowerBound) <= maximumHeaderBytes,
              let headerText = String(
                data: wire[start..<headerRange.lowerBound],
                encoding: .isoLatin1
              ) else {
            throw PinnedHTTPDownloaderError.responseTooLarge
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        let statusPieces = statusLine.split(separator: " ", maxSplits: 2)
        guard statusPieces.count >= 2,
              statusPieces[0] == "HTTP/1.1" || statusPieces[0] == "HTTP/1.0",
              statusPieces[1].count == 3,
              let status = Int(statusPieces[1]) else {
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            headers[name, default: []].append(value)
        }
        return ParsedHeader(
            statusCode: status,
            headers: headers,
            bodyStart: headerRange.upperBound
        )
    }

    private static func framing(for header: ParsedHeader) throws -> ResponseFraming {
        let contentLengths = header.headers["content-length"] ?? []
        let transferEncodings = header.headers["transfer-encoding"] ?? []
        guard !(contentLengths.isEmpty == false && transferEncodings.isEmpty == false) else {
            throw PinnedHTTPDownloaderError.malformedResponse
        }
        let hasChunkedEncoding: Bool
        if !transferEncodings.isEmpty {
            guard transferEncodings.count == 1,
                  transferEncodings[0]
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) == ["chunked"] else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            hasChunkedEncoding = true
        } else {
            hasChunkedEncoding = false
        }
        var parsedContentLength: Int?
        if !contentLengths.isEmpty {
            guard contentLengths.count == 1,
                  let length = strictDecimalInt(contentLengths[0]) else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            parsedContentLength = length
        }
        if (100...199).contains(header.statusCode)
            || header.statusCode == 204
            || header.statusCode == 304 {
            return .noBody
        }
        if hasChunkedEncoding { return .chunked }
        if let parsedContentLength { return .contentLength(parsedContentLength) }
        return .untilClose
    }

    private static func strictDecimalInt(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(value)
    }

    private static func flattenedHeaders(_ headers: [String: [String]]) -> [String: String] {
        headers.mapValues { $0.joined(separator: ",") }
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PinnedHTTPDownloaderError.responseTooLarge }
        return sum
    }

    /// Returns the exact framed response length as soon as Content-Length or
    /// terminal chunk framing is complete. Nil means more bytes are needed.
    static func completedWireLength(
        _ wire: Data,
        maximumBodyBytes: Int
    ) throws -> Int? {
        guard maximumBodyBytes >= 0 else {
            throw PinnedHTTPDownloaderError.responseTooLarge
        }
        guard let header = try finalHeader(wire, allowIncomplete: true) else { return nil }
        switch try framing(for: header) {
        case .noBody:
            return header.bodyStart
        case .contentLength(let length):
            guard length <= maximumBodyBytes else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            let total = try checkedAdd(header.bodyStart, length)
            return wire.count >= total ? total : nil
        case .chunked:
            return try completedChunkedWireLength(
                wire,
                bodyStart: header.bodyStart,
                maximumBodyBytes: maximumBodyBytes
            )
        case .untilClose:
            let maximumWireLength = try checkedAdd(header.bodyStart, maximumBodyBytes)
            guard wire.count <= maximumWireLength else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            return nil
        }
    }

    private static func completedChunkedWireLength(
        _ wire: Data,
        bodyStart: Data.Index,
        maximumBodyBytes: Int
    ) throws -> Int? {
        let crlf = Data("\r\n".utf8)
        let trailerEnd = Data("\r\n\r\n".utf8)
        var cursor = bodyStart
        var decodedCount = 0
        while cursor < wire.endIndex {
            guard let lineRange = wire[cursor...].range(of: crlf) else { return nil }
            guard let line = String(data: wire[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            cursor = lineRange.upperBound
            if size == 0 {
                let immediateEnd = try checkedAdd(cursor, 2)
                if immediateEnd <= wire.endIndex,
                   wire[cursor..<immediateEnd] == crlf {
                    return immediateEnd
                }
                return wire[cursor...].range(of: trailerEnd)?.upperBound
            }
            guard size <= maximumBodyBytes,
                  decodedCount <= maximumBodyBytes - size else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            let payloadEnd = try checkedAdd(cursor, size)
            let framedEnd = try checkedAdd(payloadEnd, 2)
            guard framedEnd <= wire.endIndex else { return nil }
            guard wire[payloadEnd..<framedEnd] == crlf else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            decodedCount += size
            cursor = framedEnd
        }
        return nil
    }

    private static func decodeChunked(_ data: Data, maximumBytes: Int) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var cursor = data.startIndex
        var result = Data()
        while cursor < data.endIndex {
            guard let lineRange = data[cursor...].range(of: crlf),
                  let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            cursor = lineRange.upperBound
            if size == 0 { return result }
            guard size <= maximumBytes, result.count <= maximumBytes - size else {
                throw PinnedHTTPDownloaderError.responseTooLarge
            }
            let payloadEnd = try checkedAdd(cursor, size)
            let framedEnd = try checkedAdd(payloadEnd, 2)
            guard framedEnd <= data.endIndex,
                  data[payloadEnd..<framedEnd] == crlf else {
                throw PinnedHTTPDownloaderError.malformedResponse
            }
            result.append(data[cursor..<payloadEnd])
            cursor = framedEnd
        }
        throw PinnedHTTPDownloaderError.malformedResponse
    }

    private static func liveTransport(_ request: PinnedHTTPConnectionRequest) async throws -> Data {
        let portValue = request.url.port ?? (request.useTLS ? 443 : 80)
        guard let exactPort = UInt16(exactly: portValue),
              let port = NWEndpoint.Port(rawValue: exactPort) else {
            throw PinnedHTTPDownloaderError.invalidURL
        }
        let parameters: NWParameters
        if request.useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                request.tlsServerName
            )
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(request.address),
            port: port,
            using: parameters
        )
        return try await PinnedConnectionAttempt(
            connection: connection,
            request: request.requestBytes,
            maximumWireBytes: request.maximumBodyBytes + maximumHeaderBytes + 256 * 1024,
            maximumBodyBytes: request.maximumBodyBytes,
            timeoutSeconds: request.timeoutSeconds
        ).run()
    }
}

private final class PinnedAsyncRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func installTasks(
        operation: Task<Void, Never>,
        timer: Task<Void, Never>
    ) {
        lock.lock()
        if isFinished {
            lock.unlock()
            operation.cancel()
            timer.cancel()
            return
        }
        operationTask = operation
        timerTask = timer
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let operationTask = operationTask
        let timerTask = timerTask
        self.operationTask = nil
        self.timerTask = nil
        if let continuation {
            self.continuation = nil
            lock.unlock()
            operationTask?.cancel()
            timerTask?.cancel()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
            operationTask?.cancel()
            timerTask?.cancel()
        }
    }
}

private final class PinnedConnectionAttempt: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let maximumWireBytes: Int
    private let maximumBodyBytes: Int
    private let timeoutSeconds: TimeInterval
    private let queue = DispatchQueue(label: "com.learnfold.source-pinned-http")
    private var continuation: CheckedContinuation<Data, Error>?
    private var timer: DispatchSourceTimer?
    private var wire = Data()
    private var finished = false
    private var cancellationRequested = false

    init(
        connection: NWConnection,
        request: Data,
        maximumWireBytes: Int,
        maximumBodyBytes: Int,
        timeoutSeconds: TimeInterval
    ) {
        self.connection = connection
        self.request = request
        self.maximumWireBytes = maximumWireBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.timeoutSeconds = timeoutSeconds
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    guard !self.cancellationRequested else {
                        self.finish(.failure(CancellationError()))
                        return
                    }
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + self.timeoutSeconds)
                    timer.setEventHandler { [weak self] in
                        self?.finish(.failure(PinnedHTTPDownloaderError.timedOut))
                    }
                    self.timer = timer
                    timer.resume()
                    self.connection.stateUpdateHandler = { [weak self] state in
                        self?.handle(state)
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancellationRequested = true
                if self.continuation != nil {
                    self.finish(.failure(CancellationError()))
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(.failure(error)) } else { self?.receive() }
            })
        case .failed(let error): finish(.failure(error))
        case .cancelled: finish(.failure(CancellationError()))
        default: break
        }
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                guard self.wire.count <= self.maximumWireBytes - data.count else {
                    self.finish(.failure(PinnedHTTPDownloaderError.responseTooLarge))
                    return
                }
                self.wire.append(data)
                do {
                    if let length = try PinnedHTTPDownloader.completedWireLength(
                        self.wire,
                        maximumBodyBytes: self.maximumBodyBytes
                    ) {
                        self.finish(.success(Data(self.wire.prefix(length))))
                        return
                    }
                } catch {
                    self.finish(.failure(error))
                    return
                }
            }
            if let error {
                self.finish(.failure(error))
            } else if isComplete {
                self.finish(.success(self.wire))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
