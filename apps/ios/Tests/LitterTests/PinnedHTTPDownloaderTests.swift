import XCTest
@testable import Litter

private actor PinnedHTTPProbe {
    private var requests: [PinnedHTTPConnectionRequest] = []
    private var responses: [String: Data]

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func fetch(_ request: PinnedHTTPConnectionRequest) throws -> Data {
        requests.append(request)
        guard let response = responses[request.url.path] else {
            throw PinnedHTTPDownloaderError.connectionFailed("No fixture")
        }
        return response
    }

    func captured() -> [PinnedHTTPConnectionRequest] { requests }
}

final class PinnedHTTPDownloaderTests: XCTestCase {
    func testPinsExactAddressPreservesTLSHostnameAndFollowsRelativeRedirect() async throws {
        let probe = PinnedHTTPProbe(responses: [
            "/start": Self.response(
                status: 302,
                headers: ["Location": "/final", "Content-Length": "0"],
                body: ""
            ),
            "/final": Self.response(
                status: 200,
                headers: ["Content-Type": "text/plain", "Content-Length": "4"],
                body: "done"
            ),
        ])
        let downloader = PinnedHTTPDownloader(
            resolver: { host in host == "example.com" ? ["93.184.216.34"] : [] },
            transport: { request in try await probe.fetch(request) }
        )

        let result = try await downloader.download(
            URL(string: "https://example.com/start")!,
            maximumBytes: 1024
        )

        XCTAssertEqual(String(data: result.data, encoding: .utf8), "done")
        XCTAssertEqual(result.finalURL.path, "/final")
        let requests = await probe.captured()
        XCTAssertEqual(requests.map { $0.address }, ["93.184.216.34", "93.184.216.34"])
        XCTAssertTrue(requests.allSatisfy { $0.tlsServerName == "example.com" && $0.useTLS })
        XCTAssertTrue(requests[0].requestBytes.contains(Data("Host: example.com".utf8)))
    }

    func testAcceptsPublicNAT64LiteralAndBracketsIPv6HostHeader() async throws {
        let publicNAT64 = "64:ff9b::5db8:d822"
        XCTAssertTrue(CourseSourceIngestionCoordinator.isAllowedRemoteURL(
            URL(string: "https://[\(publicNAT64)]:8443/source")!
        ))
        XCTAssertFalse(CourseSourceIngestionCoordinator.isAllowedRemoteURL(
            URL(string: "https://[64:ff9b::7f00:1]/private")!
        ))
        let probe = PinnedHTTPProbe(responses: [
            "/source": Self.response(
                status: 200,
                headers: ["Content-Length": "2"],
                body: "ok"
            )
        ])
        let downloader = PinnedHTTPDownloader(
            resolver: { host in host.contains("64:ff9b") ? [publicNAT64] : [] },
            transport: { request in try await probe.fetch(request) }
        )

        _ = try await downloader.download(
            URL(string: "https://[\(publicNAT64)]:8443/source")!,
            maximumBytes: 32
        )

        let requests = await probe.captured()
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.requestBytes.contains(
            Data("Host: [\(publicNAT64)]:8443".utf8)
        ))
        XCTAssertEqual(request.tlsServerName, publicNAT64)
    }

    func testPrivateRedirectIsRejectedBeforeSecondConnection() async throws {
        let probe = PinnedHTTPProbe(responses: [
            "/start": Self.response(
                status: 302,
                headers: ["Location": "http://127.0.0.1/private", "Content-Length": "0"],
                body: ""
            ),
        ])
        let downloader = PinnedHTTPDownloader(
            resolver: { _ in ["93.184.216.34"] },
            transport: { request in try await probe.fetch(request) }
        )

        await XCTAssertThrowsErrorAsync(
            try await downloader.download(
                URL(string: "https://example.com/start")!,
                maximumBytes: 1024
            )
        ) { error in
            XCTAssertEqual(error as? PinnedHTTPDownloaderError, .blockedURL)
        }
        let requestCount = await probe.captured().count
        XCTAssertEqual(requestCount, 1)
    }

    func testHTTPSRedirectCannotDowngradeToHTTP() async throws {
        let probe = PinnedHTTPProbe(responses: [
            "/start": Self.response(
                status: 302,
                headers: [
                    "Location": "http://example.com/plain",
                    "Content-Length": "0",
                ],
                body: ""
            )
        ])
        let downloader = PinnedHTTPDownloader(
            resolver: { _ in ["93.184.216.34"] },
            transport: { request in try await probe.fetch(request) }
        )

        await XCTAssertThrowsErrorAsync(
            try await downloader.download(
                URL(string: "https://example.com/start")!,
                maximumBytes: 1024
            )
        ) { error in
            XCTAssertEqual(error as? PinnedHTTPDownloaderError, .insecureRedirect)
        }
        let requests = await probe.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testTLSHostnameFailureIsNotBypassed() async {
        let downloader = PinnedHTTPDownloader(
            resolver: { _ in ["93.184.216.34"] },
            transport: { request in
                XCTAssertEqual(request.tlsServerName, "example.com")
                throw PinnedHTTPDownloaderError.connectionFailed("TLS hostname verification failed")
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await downloader.download(
                URL(string: "https://example.com/")!,
                maximumBytes: 1024
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("TLS hostname"))
        }
    }

    func testContentLengthAndChunkedFramingCompleteWithoutPeerClose() throws {
        let contentLength = Self.response(
            status: 200,
            headers: ["Content-Length": "4"],
            body: "doneEXTRA"
        )
        let contentLengthEnd = try XCTUnwrap(
            PinnedHTTPDownloader.completedWireLength(contentLength, maximumBodyBytes: 32)
        )
        let parsedLength = try PinnedHTTPDownloader.parseForTesting(
            Data(contentLength.prefix(contentLengthEnd)),
            maximumBytes: 32
        )
        XCTAssertEqual(String(data: parsedLength.body, encoding: .utf8), "done")

        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ndone\r\n0\r\n\r\nKEEPALIVE".utf8)
        let chunkedEnd = try XCTUnwrap(
            PinnedHTTPDownloader.completedWireLength(chunked, maximumBodyBytes: 32)
        )
        let parsedChunked = try PinnedHTTPDownloader.parseForTesting(
            Data(chunked.prefix(chunkedEnd)),
            maximumBytes: 32
        )
        XCTAssertEqual(String(data: parsedChunked.body, encoding: .utf8), "done")
    }

    func testOversizedHeadersAndBodiesFailBeforeAllocationGrowth() {
        let hugeHeader = Data(("HTTP/1.1 200 OK\r\nX-Fill: " + String(repeating: "x", count: 70_000)).utf8)
        XCTAssertThrowsError(
            try PinnedHTTPDownloader.completedWireLength(hugeHeader, maximumBodyBytes: 32)
        )
        let oversizedBody = Self.response(
            status: 200,
            headers: ["Content-Length": "33"],
            body: String(repeating: "x", count: 33)
        )
        XCTAssertThrowsError(
            try PinnedHTTPDownloader.completedWireLength(oversizedBody, maximumBodyBytes: 32)
        )
    }

    func testRejectsAmbiguousOrInvalidResponseFramingWithoutTrapping() {
        for response in [
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999999999\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
        ] {
            XCTAssertThrowsError(
                try PinnedHTTPDownloader.completedWireLength(
                    Data(response.utf8),
                    maximumBodyBytes: 32
                ),
                response
            )
        }
    }

    func testConsumesBoundedInformationalResponsesBeforeFinalResponse() throws {
        let wire = Data("""
        HTTP/1.1 100 Continue\r
        \r
        HTTP/1.1 103 Early Hints\r
        Link: </style.css>; rel=preload\r
        \r
        HTTP/1.1 200 OK\r
        Content-Length: 4\r
        Content-Type: text/plain\r
        \r
        doneTRAILING
        """.utf8)
        let end = try XCTUnwrap(
            PinnedHTTPDownloader.completedWireLength(wire, maximumBodyBytes: 32)
        )
        let response = try PinnedHTTPDownloader.parseForTesting(
            Data(wire.prefix(end)),
            maximumBytes: 32
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "done")
    }

    func testResolverDeadlineDoesNotWaitForNoncooperativeResolver() async {
        let downloader = PinnedHTTPDownloader(
            resolver: { _ in
                await withUnsafeContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        continuation.resume(returning: ["93.184.216.34"])
                    }
                }
            },
            transport: { _ in Data() },
            perAttemptTimeoutSeconds: 0.02,
            totalTimeoutSeconds: 0.02
        )
        let clock = ContinuousClock()
        let started = clock.now
        await XCTAssertThrowsErrorAsync(
            try await downloader.download(URL(string: "https://example.com/")!, maximumBytes: 32)
        ) { error in
            XCTAssertEqual(error as? PinnedHTTPDownloaderError, .timedOut)
        }
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(250))
    }

    func testAttemptDeadlineAndCancellationAreTerminal() async {
        let downloader = PinnedHTTPDownloader(
            resolver: { _ in ["93.184.216.34"] },
            transport: { _ in
                try await Task.sleep(for: .seconds(5))
                return Data()
            },
            perAttemptTimeoutSeconds: 0.02,
            totalTimeoutSeconds: 0.05
        )
        await XCTAssertThrowsErrorAsync(
            try await downloader.download(URL(string: "https://example.com/")!, maximumBytes: 32)
        ) { error in
            XCTAssertEqual(error as? PinnedHTTPDownloaderError, .timedOut)
        }

        let task = Task {
            try await downloader.download(URL(string: "https://example.com/")!, maximumBytes: 32)
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private static func response(
        status: Int,
        headers: [String: String],
        body: String
    ) -> Data {
        var lines = ["HTTP/1.1 \(status) Test"]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}
