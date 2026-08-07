import Foundation
import PDFKit
import Darwin

enum CourseSourceIngestionState: String, Codable, Sendable {
    case queued
    case running
    case ready
    case failed
}

struct CourseSourceIngestionRequest: Sendable {
    enum Kind: String, Codable, Sendable {
        case document
        case link
    }

    let kind: Kind
    let sourceName: String
    let localFileURL: URL?
    let remoteURL: URL?
}

struct CourseSourceIngestionReceipt: Codable, Equatable, Sendable {
    let id: String
    let sourceName: String
    let manifestRelativePath: String
    let expectedExtractedRelativePath: String

    var agentLine: String {
        // Only generated identifiers and paths cross the instruction boundary.
        // A learner-controlled filename must never be able to close the
        // surrounding protocol tag or inject a sibling instruction.
        "- process_id=\(id) manifest=\(manifestRelativePath) expected_output=\(expectedExtractedRelativePath)"
    }
}

struct CourseSourceIngestionManifest: Codable, Equatable, Sendable {
    let id: String
    let sourceName: String
    let sourceKind: CourseSourceIngestionRequest.Kind
    var state: CourseSourceIngestionState
    let createdAt: String
    var updatedAt: String
    /// Receipt-owned directory reserved before any remote bytes are written.
    /// This lets cancellation and cold-start recovery remove a partially
    /// committed original even if termination happened before the final
    /// filename could be journaled in `originalRelativePath`.
    var ownedOriginalDirectoryRelativePath: String? = nil
    var originalRelativePath: String?
    let remoteURL: String?
    let extractedRelativePath: String
    var mediaType: String?
    var byteCount: Int?
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceName
        case sourceKind
        case state
        case createdAt
        case updatedAt
        case ownedOriginalDirectoryRelativePath
        case originalRelativePath
        // JSONDecoder's snake-case strategy normalizes `remote_url` to
        // `remoteUrl`, not Swift's acronym-styled `remoteURL`.
        case remoteURL = "remoteUrl"
        case extractedRelativePath
        case mediaType
        case byteCount
        case error
    }
}

enum CourseSourceIngestionError: LocalizedError, Equatable {
    case invalidURL
    case blockedURL
    case badHTTPStatus(Int)
    case responseTooLarge
    case unsupportedDocument
    case unreadableDocument
    case emptyPDF
    case tooManySources
    case storageLimitExceeded
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The source URL is invalid."
        case .blockedURL:
            "Learnfold does not download loopback, local-network, or link-local URLs."
        case .badHTTPStatus(let status):
            "The source server returned HTTP \(status)."
        case .responseTooLarge:
            "The source exceeds Learnfold’s 20 MB ingestion limit."
        case .unsupportedDocument:
            "Learnfold cannot extract text from this document type yet."
        case .unreadableDocument:
            "The source could not be decoded as readable text."
        case .emptyPDF:
            "The PDF does not contain extractable text. A scanned-PDF OCR pass is not available yet."
        case .tooManySources:
            "Add at most 8 documents or links in one message."
        case .storageLimitExceeded:
            "The source batch or course source folder exceeds Learnfold’s storage limit."
        case .setupFailed(let detail):
            "Learnfold could not create the durable source-ingestion receipt: \(detail)"
        }
    }
}

final class CourseSourceRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url,
              await CourseSourceIngestionCoordinator.isAllowedResolvedRemoteURL(url) else {
            return nil
        }
        return request
    }
}

private actor CourseSourceDNSResolutionLimiter {
    static let shared = CourseSourceDNSResolutionLimiter()
    private var activeCount = 0

    func resolve(_ operation: @escaping @Sendable () -> [String]) async -> [String] {
        while activeCount >= 2 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !Task.isCancelled else { return [] }
        activeCount += 1
        let result = await Task.detached(priority: .utility, operation: operation).value
        activeCount -= 1
        return Task.isCancelled ? [] : result
    }
}

private final class CourseSourceBatchPredecessorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait(for predecessor: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
                Task.detached(priority: .utility) { [weak self] in
                    await predecessor.value
                    self?.finish()
                }
            }
        } onCancel: {
            finish()
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private actor CourseSourceIngestionBudget {
    private let workspaceFileSystem: CourseWorkspaceFileSystem
    private let maximumBatchBytes: Int
    private let maximumCourseBytes: Int
    private var consumedBytes = 0
    private var reservedCourseBytes: Int

    init(
        workspaceURL: URL,
        existingBytes: Int,
        maximumBatchBytes: Int,
        maximumCourseBytes: Int
    ) {
        self.workspaceFileSystem = CourseWorkspaceFileSystem(rootURL: workspaceURL)
        self.maximumBatchBytes = max(maximumBatchBytes, 0)
        self.maximumCourseBytes = max(maximumCourseBytes, 0)
        self.reservedCourseBytes = max(existingBytes, 0)
    }

    func consume(_ bytes: Int) throws {
        let observedBytes: Int
        do {
            observedBytes = try workspaceFileSystem.byteCount("sources")
        } catch {
            throw CourseSourceIngestionError.storageLimitExceeded
        }
        let courseBase = max(reservedCourseBytes, observedBytes)
        guard bytes >= 0,
              bytes <= maximumBatchBytes,
              consumedBytes <= maximumBatchBytes - bytes,
              courseBase <= maximumCourseBytes,
              bytes <= maximumCourseBytes - courseBase else {
            throw CourseSourceIngestionError.storageLimitExceeded
        }
        consumedBytes += bytes
        reservedCourseBytes = courseBase + bytes
    }

}

actor CourseSourceIngestionCoordinator {
    static let shared = CourseSourceIngestionCoordinator()

    static let maximumDownloadBytes = 20 * 1024 * 1024
    static let maximumExtractedTextBytes = 10 * 1024 * 1024
    static let maximumSourcesPerBatch = 8
    static let maximumConcurrentSources = 2
    static let maximumBatchStorageBytes = 128 * 1024 * 1024
    // Leave at least 128 MiB beneath course_bash's 512 MiB whole-workspace
    // ceiling for the native database, pages, manifests, and shell scratch.
    static let maximumCourseSourceStorageBytes = 384 * 1024 * 1024

    /// Non-nil only for deterministic URLProtocol-backed tests. Production
    /// downloads use PinnedHTTPDownloader so the validated address is the
    /// address that receives the connection.
    private let injectedSession: URLSession?
    private let initialManifestWriter: @Sendable (CourseSourceIngestionManifest, URL) throws -> Void
    private let remoteOriginalDidWrite: @Sendable (String, URL) throws -> Void
    private let maximumBatchBytes: Int
    private let maximumCourseBytes: Int
    private var tasks: [String: Task<Void, Never>] = [:]
    private var workspaceBatchTails: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    init(
        session: URLSession? = nil,
        initialManifestWriter: (@Sendable (CourseSourceIngestionManifest, URL) throws -> Void)? = nil,
        remoteOriginalDidWrite: (@Sendable (String, URL) throws -> Void)? = nil,
        maximumBatchBytes: Int = CourseSourceIngestionCoordinator.maximumBatchStorageBytes,
        maximumCourseBytes: Int = CourseSourceIngestionCoordinator.maximumCourseSourceStorageBytes
    ) {
        self.injectedSession = session
        self.maximumBatchBytes = maximumBatchBytes
        self.maximumCourseBytes = maximumCourseBytes
        self.remoteOriginalDidWrite = remoteOriginalDidWrite ?? { _, _ in }
        self.initialManifestWriter = initialManifestWriter ?? { manifest, workspaceURL in
            try Self.writeManifest(manifest, workspaceURL: workspaceURL)
        }
    }

    func start(
        _ requests: [CourseSourceIngestionRequest],
        workspaceURL: URL
    ) async throws -> [CourseSourceIngestionReceipt] {
        guard !requests.isEmpty else { return [] }
        guard requests.count <= Self.maximumSourcesPerBatch else {
            throw CourseSourceIngestionError.tooManySources
        }
        let workspaceFileSystem = CourseWorkspaceFileSystem(rootURL: workspaceURL)
        do {
            try workspaceFileSystem.ensureDirectory(".course/ingestion")
            try workspaceFileSystem.ensureDirectory("sources/extracted")
        } catch {
            throw CourseSourceIngestionError.setupFailed(error.localizedDescription)
        }

        var staged: [(
            request: CourseSourceIngestionRequest,
            receipt: CourseSourceIngestionReceipt,
            manifest: CourseSourceIngestionManifest
        )] = []
        for request in requests {
            let id = "ing_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let slug = Self.safeSlug(request.sourceName)
            let relativeDirectory = "sources/extracted/\(slug)-\(String(id.suffix(8)))"
            let extractedRelativePath = "\(relativeDirectory)/content.md"
            let receipt = CourseSourceIngestionReceipt(
                id: id,
                sourceName: request.sourceName,
                manifestRelativePath: ".course/ingestion/\(id).json",
                expectedExtractedRelativePath: extractedRelativePath
            )
            let now = Self.timestamp()
            let ownedOriginalDirectory = request.kind == .link
                ? "sources/originals/\(id)"
                : nil
            let manifest = CourseSourceIngestionManifest(
                id: id,
                sourceName: request.sourceName,
                sourceKind: request.kind,
                state: .queued,
                createdAt: now,
                updatedAt: now,
                ownedOriginalDirectoryRelativePath: ownedOriginalDirectory,
                originalRelativePath: Self.relativePath(
                    for: request.localFileURL,
                    workspaceURL: workspaceURL
                ),
                remoteURL: request.remoteURL?.absoluteString,
                extractedRelativePath: extractedRelativePath,
                mediaType: nil,
                byteCount: nil,
                error: nil
            )
            do {
                try initialManifestWriter(manifest, workspaceURL)
            } catch {
                for accepted in staged.map(\.receipt) {
                    Self.removeConfinedItem(
                        relativePath: accepted.manifestRelativePath,
                        workspaceURL: workspaceURL,
                        isDirectory: false
                    )
                }
                throw CourseSourceIngestionError.setupFailed(error.localizedDescription)
            }
            staged.append((request, receipt, manifest))
        }

        // Stage the full batch before launching work, serialize batches for a
        // course, and cap each batch at two in-flight extractors. This keeps
        // storage accounting atomic and bounds network/memory pressure.
        let workspaceKey = workspaceURL.standardizedFileURL.path
        let previousTask = workspaceBatchTails[workspaceKey]?.task
        let batchToken = UUID()
        let session = injectedSession
        let batchLimit = maximumBatchBytes
        let courseLimit = maximumCourseBytes
        let remoteOriginalDidWrite = remoteOriginalDidWrite
        let receiptIDs = staged.map(\.receipt.id)
        let task = Task.detached(priority: .utility) { [weak self] in
            if let previousTask {
                await CourseSourceBatchPredecessorGate().wait(for: previousTask)
            }
            guard !Task.isCancelled else {
                await self?.finishBatch(
                    receiptIDs: receiptIDs,
                    workspaceKey: workspaceKey,
                    token: batchToken
                )
                return
            }
            let existingBytes = (try? CourseWorkspaceFileSystem(rootURL: workspaceURL)
                .byteCount("sources")) ?? Int.max
            let budget = CourseSourceIngestionBudget(
                workspaceURL: workspaceURL,
                existingBytes: existingBytes,
                maximumBatchBytes: batchLimit,
                maximumCourseBytes: courseLimit
            )
            await Self.runBatch(
                staged,
                workspaceURL: workspaceURL,
                session: session,
                budget: budget,
                remoteOriginalDidWrite: remoteOriginalDidWrite
            )
            await self?.finishBatch(
                receiptIDs: receiptIDs,
                workspaceKey: workspaceKey,
                token: batchToken
            )
        }
        workspaceBatchTails[workspaceKey] = (batchToken, task)
        for id in receiptIDs { tasks[id] = task }
        return staged.map(\.receipt)
    }

    func waitForCompletion(id: String) async {
        await tasks[id]?.value
    }

    func cancelAndRollback(
        receipts: [CourseSourceIngestionReceipt],
        workspaceURL: URL
    ) async {
        let tasksToWait = receipts.compactMap { tasks[$0.id] }
        for task in tasksToWait { task.cancel() }
        for task in tasksToWait { await task.value }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for receipt in receipts {
            let workspaceFileSystem = CourseWorkspaceFileSystem(rootURL: workspaceURL)
            if let data = try? workspaceFileSystem.read(
                receipt.manifestRelativePath,
                maximumBytes: 1_048_576
            ),
               let manifest = try? decoder.decode(CourseSourceIngestionManifest.self, from: data) {
                if manifest.id == receipt.id, manifest.sourceKind == .link {
                    Self.removeReceiptOwnedOriginals(
                        manifest: manifest,
                        receipt: receipt,
                        workspaceURL: workspaceURL
                    )
                }
                Self.removeConfinedItem(
                    relativePath: receipt.expectedExtractedRelativePath,
                    workspaceURL: workspaceURL,
                    isDirectory: false
                )
                Self.removeConfinedItem(
                    relativePath: (receipt.expectedExtractedRelativePath as NSString)
                        .deletingLastPathComponent,
                    workspaceURL: workspaceURL,
                    isDirectory: true
                )
            } else {
                Self.removeConfinedItem(
                    relativePath: receipt.expectedExtractedRelativePath,
                    workspaceURL: workspaceURL,
                    isDirectory: false
                )
                Self.removeConfinedItem(
                    relativePath: (receipt.expectedExtractedRelativePath as NSString)
                        .deletingLastPathComponent,
                    workspaceURL: workspaceURL,
                    isDirectory: true
                )
            }
            Self.removeConfinedItem(
                relativePath: receipt.manifestRelativePath,
                workspaceURL: workspaceURL,
                isDirectory: false
            )
            tasks[receipt.id] = nil
        }
    }

    /// A process cannot survive app termination. On launch, turn any durable
    /// nonterminal receipt into an explicit failure so agents never poll a
    /// permanently "running" process. The original path/URL remains in the
    /// manifest so a later learner turn can intentionally retry it.
    func markInterruptedProcessesFailed(inCoursesRoot coursesRootURL: URL) {
        guard let workspaceURLs = try? FileManager.default.contentsOfDirectory(
            at: coursesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for workspaceURL in workspaceURLs {
            let workspaceFileSystem = CourseWorkspaceFileSystem(rootURL: workspaceURL)
            guard let manifestNames = try? workspaceFileSystem.contentsOfDirectory(
                ".course/ingestion"
            ) else { continue }
            for manifestName in manifestNames where manifestName.hasSuffix(".json") {
                let relativePath = ".course/ingestion/\(manifestName)"
                guard let data = try? workspaceFileSystem.read(
                    relativePath,
                    maximumBytes: 1_048_576
                ) else { continue }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard var manifest = try? decoder.decode(
                    CourseSourceIngestionManifest.self,
                    from: data
                ), manifest.state == .queued || manifest.state == .running,
                   tasks[manifest.id] == nil else { continue }
                if manifest.sourceKind == .link {
                    Self.removeReceiptOwnedOriginals(
                        manifest: manifest,
                        receipt: CourseSourceIngestionReceipt(
                            id: manifest.id,
                            sourceName: manifest.sourceName,
                            manifestRelativePath: relativePath,
                            expectedExtractedRelativePath: manifest.extractedRelativePath
                        ),
                        workspaceURL: workspaceURL
                    )
                    manifest.originalRelativePath = nil
                }
                manifest.state = .failed
                manifest.updatedAt = Self.timestamp()
                manifest.error = "Source ingestion was interrupted when Learnfold stopped. Start a new ingestion turn to retry it."
                try? Self.writeManifest(manifest, workspaceURL: workspaceURL)
            }
        }
    }

    private func finishBatch(
        receiptIDs: [String],
        workspaceKey: String,
        token: UUID
    ) {
        for id in receiptIDs { tasks[id] = nil }
        if workspaceBatchTails[workspaceKey]?.token == token {
            workspaceBatchTails[workspaceKey] = nil
        }
    }

    private static func runBatch(
        _ staged: [(request: CourseSourceIngestionRequest, receipt: CourseSourceIngestionReceipt, manifest: CourseSourceIngestionManifest)],
        workspaceURL: URL,
        session: URLSession?,
        budget: CourseSourceIngestionBudget,
        remoteOriginalDidWrite: @escaping @Sendable (String, URL) throws -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = staged.makeIterator()
            for _ in 0..<min(maximumConcurrentSources, staged.count) {
                guard let item = iterator.next() else { break }
                group.addTask {
                    await process(
                        item.request,
                        manifest: item.manifest,
                        workspaceURL: workspaceURL,
                        session: session,
                        budget: budget,
                        remoteOriginalDidWrite: remoteOriginalDidWrite
                    )
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let item = iterator.next() else { continue }
                group.addTask {
                    await process(
                        item.request,
                        manifest: item.manifest,
                        workspaceURL: workspaceURL,
                        session: session,
                        budget: budget,
                        remoteOriginalDidWrite: remoteOriginalDidWrite
                    )
                }
            }
        }
    }

    private static func process(
        _ request: CourseSourceIngestionRequest,
        manifest initialManifest: CourseSourceIngestionManifest,
        workspaceURL: URL,
        session: URLSession?,
        budget: CourseSourceIngestionBudget,
        remoteOriginalDidWrite: @escaping @Sendable (String, URL) throws -> Void
    ) async {
        var manifest = initialManifest
        manifest.state = .running
        manifest.updatedAt = Self.timestamp()
        try? Self.writeManifest(manifest, workspaceURL: workspaceURL)

        do {
            try Task.checkCancellation()
            let extracted: ExtractedSource
            switch request.kind {
            case .document:
                guard let fileURL = request.localFileURL else {
                    throw CourseSourceIngestionError.unreadableDocument
                }
                extracted = try Self.extractDocument(
                    at: fileURL,
                    workspaceURL: workspaceURL,
                    sourceName: request.sourceName,
                    ingestionID: manifest.id
                )
            case .link:
                guard let remoteURL = request.remoteURL,
                      Self.isAllowedRemoteURL(remoteURL) else {
                    throw CourseSourceIngestionError.blockedURL
                }
                extracted = try await downloadAndExtract(
                    remoteURL,
                    workspaceURL: workspaceURL,
                    sourceName: request.sourceName,
                    ingestionID: manifest.id,
                    originalDirectoryRelativePath: manifest.ownedOriginalDirectoryRelativePath,
                    session: session,
                    budget: budget,
                    remoteOriginalDidWrite: remoteOriginalDidWrite
                )
            }

            manifest.originalRelativePath = extracted.originalRelativePath
                ?? manifest.originalRelativePath
            manifest.mediaType = extracted.mediaType
            manifest.byteCount = extracted.byteCount
            manifest.updatedAt = Self.timestamp()
            try Task.checkCancellation()
            try Self.writeManifest(manifest, workspaceURL: workspaceURL)

            let markdown = Self.markdownDocument(
                sourceName: request.sourceName,
                originalPath: extracted.originalRelativePath ?? manifest.originalRelativePath,
                mediaType: extracted.mediaType,
                ingestionID: manifest.id,
                text: extracted.text
            )
            guard markdown.lengthOfBytes(using: .utf8) <= Self.maximumExtractedTextBytes else {
                throw CourseSourceIngestionError.responseTooLarge
            }
            try await budget.consume(markdown.lengthOfBytes(using: .utf8))
            try Task.checkCancellation()
            try CourseWorkspaceFileSystem(rootURL: workspaceURL).write(
                Data(markdown.utf8),
                to: manifest.extractedRelativePath
            )

            manifest.state = .ready
            manifest.updatedAt = Self.timestamp()
            manifest.error = nil
            try Self.writeManifest(manifest, workspaceURL: workspaceURL)
        } catch {
            if request.kind == .link {
                Self.removeReceiptOwnedOriginals(
                    manifest: manifest,
                    receipt: CourseSourceIngestionReceipt(
                        id: manifest.id,
                        sourceName: manifest.sourceName,
                        manifestRelativePath: ".course/ingestion/\(manifest.id).json",
                        expectedExtractedRelativePath: manifest.extractedRelativePath
                    ),
                    workspaceURL: workspaceURL
                )
                manifest.originalRelativePath = nil
            }
            Self.removeConfinedItem(
                relativePath: manifest.extractedRelativePath,
                workspaceURL: workspaceURL,
                isDirectory: false
            )
            Self.removeConfinedItem(
                relativePath: (manifest.extractedRelativePath as NSString)
                    .deletingLastPathComponent,
                workspaceURL: workspaceURL,
                isDirectory: true
            )
            manifest.state = .failed
            manifest.updatedAt = Self.timestamp()
            manifest.error = error.localizedDescription
            do {
                try Self.writeManifest(manifest, workspaceURL: workspaceURL)
            } catch {
                // The generated artifacts were already removed above. A
                // missing failed manifest is surfaced by the caller's receipt
                // rather than leaving unexplained source bytes behind.
            }
        }
    }

    private struct ExtractedSource: Sendable {
        let text: String
        let mediaType: String
        let byteCount: Int
        let originalRelativePath: String?
    }

    private static func downloadAndExtract(
        _ url: URL,
        workspaceURL: URL,
        sourceName: String,
        ingestionID: String,
        originalDirectoryRelativePath: String?,
        session: URLSession?,
        budget: CourseSourceIngestionBudget,
        remoteOriginalDidWrite: @escaping @Sendable (String, URL) throws -> Void
    ) async throws -> ExtractedSource {
        let data: Data
        let finalURL: URL
        let statusCode: Int
        let responseHeaders: [String: String]
        if let session {
            var request = URLRequest(url: url)
            request.setValue("Learnfold/1.0 Source Ingestion", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,text/plain,text/markdown,application/pdf;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: CourseSourceRedirectGuard()
            )
            guard let http = response as? HTTPURLResponse, let responseURL = http.url else {
                throw CourseSourceIngestionError.invalidURL
            }
            if http.expectedContentLength > Int64(Self.maximumDownloadBytes) {
                throw CourseSourceIngestionError.responseTooLarge
            }
            var received = Data()
            for try await byte in bytes {
                guard received.count < Self.maximumDownloadBytes else {
                    throw CourseSourceIngestionError.responseTooLarge
                }
                received.append(byte)
            }
            data = received
            finalURL = responseURL
            statusCode = http.statusCode
            responseHeaders = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap {
                key, value in
                guard let key = key as? String else { return nil }
                return (key.lowercased(), String(describing: value))
            })
        } else {
            let download = try await PinnedHTTPDownloader.download(
                url,
                maximumBytes: Self.maximumDownloadBytes
            )
            data = download.data
            finalURL = download.finalURL
            statusCode = download.statusCode
            responseHeaders = download.headers
        }
        guard (200...299).contains(statusCode) else {
            throw CourseSourceIngestionError.badHTTPStatus(statusCode)
        }

        let contentType = responseHeaders["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first.map(String.init)?.lowercased()
            ?? Self.mediaType(for: finalURL)
        let ext = Self.fileExtension(mediaType: contentType, url: finalURL)
        let text: String
        if contentType == "application/pdf" || ext == "pdf" {
            text = try Self.extractPDF(data: data)
        } else if contentType == "text/html"
                    || contentType == "application/xhtml+xml"
                    || ext == "html" {
            text = try Self.extractHTML(data: data)
        } else if Self.isSupportedRemoteTextType(contentType) {
            text = try Self.decodeText(data)
        } else {
            throw CourseSourceIngestionError.unsupportedDocument
        }
        // Validate and extract before committing the remote original. A bad
        // PDF/HTML response therefore leaves no unexplained source artifact.
        try await budget.consume(data.count)
        try Task.checkCancellation()
        guard let originalDirectory = originalDirectoryRelativePath,
              Self.isReceiptOwnedDirectory(originalDirectory, ingestionID: ingestionID) else {
            throw CourseSourceIngestionError.setupFailed("The remote-original ownership journal is invalid.")
        }
        let relativeOriginal = "\(originalDirectory)/original.\(ext)"
        try CourseWorkspaceFileSystem(rootURL: workspaceURL).write(
            data,
            to: relativeOriginal
        )
        try remoteOriginalDidWrite(relativeOriginal, workspaceURL)
        return ExtractedSource(
            text: text,
            mediaType: contentType,
            byteCount: data.count,
            originalRelativePath: relativeOriginal
        )
    }

    private static func extractDocument(
        at url: URL,
        workspaceURL: URL,
        sourceName: String,
        ingestionID: String
    ) throws -> ExtractedSource {
        guard let relativePath = relativePath(for: url, workspaceURL: workspaceURL) else {
            throw CourseSourceIngestionError.unreadableDocument
        }
        let data: Data
        do {
            data = try CourseWorkspaceFileSystem(rootURL: workspaceURL).read(
                relativePath,
                maximumBytes: maximumDownloadBytes
            )
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(EFBIG) {
            throw CourseSourceIngestionError.responseTooLarge
        } catch {
            throw CourseSourceIngestionError.unreadableDocument
        }
        let ext = url.pathExtension.lowercased()
        let mediaType = mediaType(for: url)
        let text: String
        switch ext {
        case "pdf":
            text = try extractPDF(data: data)
        case "html", "htm":
            text = try extractHTML(data: data)
        case "txt", "text", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "toml",
             "swift", "py", "js", "ts", "tsx", "jsx", "rs", "kt", "java", "c", "h", "cpp", "sh", "rb":
            text = try decodeText(data)
        default:
            throw CourseSourceIngestionError.unsupportedDocument
        }
        return ExtractedSource(
            text: text,
            mediaType: mediaType,
            byteCount: data.count,
            originalRelativePath: nil
        )
    }

    private static func extractPDF(data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw CourseSourceIngestionError.unreadableDocument
        }
        guard document.pageCount <= 500 else {
            throw CourseSourceIngestionError.responseTooLarge
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        var byteCount = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let pageText = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageText.isEmpty else { continue }
            let section = "## Page \(index + 1)\n\n\(pageText)"
            byteCount += section.lengthOfBytes(using: .utf8)
            guard byteCount <= maximumExtractedTextBytes else {
                throw CourseSourceIngestionError.responseTooLarge
            }
            pages.append(section)
        }
        guard !pages.isEmpty else { throw CourseSourceIngestionError.emptyPDF }
        return pages.joined(separator: "\n\n")
    }

    private static func extractHTML(data: Data) throws -> String {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw CourseSourceIngestionError.unreadableDocument
        }
        // NSAttributedString's HTML importer may fetch linked resources. This
        // deliberately small offline parser only transforms bytes already in
        // memory and therefore cannot initiate secondary requests.
        for pattern in [
            "(?is)<!--.*?-->",
            "(?is)<script\\b[^>]*>.*?</script\\s*>",
            "(?is)<style\\b[^>]*>.*?</style\\s*>",
            "(?is)<noscript\\b[^>]*>.*?</noscript\\s*>",
            "(?is)<svg\\b[^>]*>.*?</svg\\s*>",
        ] {
            html = html.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        html = html.replacingOccurrences(
            of: "(?i)</?(?:p|div|section|article|main|header|footer|h[1-6]|li|br|tr|table|blockquote)\\b[^>]*>",
            with: "\n",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: "(?s)<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let text = decodeHTMLEntities(html)
        let normalized = text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !normalized.isEmpty else { throw CourseSourceIngestionError.unreadableDocument }
        return normalized
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        for (entity, replacement) in [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        guard let regex = try? NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));") else {
            return result
        }
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        for match in matches.reversed() {
            let hex = Range(match.range(at: 1), in: result).map { String(result[$0]) }
            let decimal = Range(match.range(at: 2), in: result).map { String(result[$0]) }
            let scalarValue = hex.flatMap { UInt32($0, radix: 16) }
                ?? decimal.flatMap { UInt32($0, radix: 10) }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: String(Character(scalar)))
        }
        return result
    }

    private static func decodeText(_ data: Data) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let unicode = String(data: data, encoding: .unicode) { return unicode }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        throw CourseSourceIngestionError.unreadableDocument
    }

    private static func markdownDocument(
        sourceName: String,
        originalPath: String?,
        mediaType: String,
        ingestionID: String,
        text: String
    ) -> String {
        """
        # \(sourceName)

        - Ingestion process: `\(ingestionID)`
        - Original: `\(originalPath ?? "external source")`
        - Media type: `\(mediaType)`

        \(text)
        """
    }

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return false }
        if host == "localhost"
            || host == "localhost.localdomain"
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa") {
            return false
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_aton(normalized, &ipv4) == 1 {
            return isGlobalIPv4(UInt32(bigEndian: ipv4.s_addr))
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return isGlobalIPv6(bytes)
        }
        return true
    }

    static func isAllowedResolvedRemoteURL(_ url: URL) async -> Bool {
        guard isAllowedRemoteURL(url), let host = url.host else { return false }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_aton(host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1 {
            return true
        }
        return !(await resolvedGlobalAddressStrings(host: host)).isEmpty
    }

    static func resolvedGlobalAddressStrings(host: String) async -> [String] {
        await CourseSourceDNSResolutionLimiter.shared.resolve {
            globalAddressStrings(host: host)
        }
    }

    private static func globalAddressStrings(host: String) -> [String] {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var literal4 = in_addr()
        if inet_aton(normalized, &literal4) == 1 {
            return isGlobalIPv4(UInt32(bigEndian: literal4.s_addr)) ? [normalized] : []
        }
        var literal6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &literal6) == 1 {
            let bytes = withUnsafeBytes(of: &literal6) { Array($0) }
            return isGlobalIPv6(bytes) ? [normalized] : []
        }
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return []
        }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let node = cursor {
            let info = node.pointee
            if info.ai_family == AF_INET,
               let address = info.ai_addr?.withMemoryRebound(
                   to: sockaddr_in.self,
                   capacity: 1,
                   { $0.pointee.sin_addr }
               ) {
                guard isGlobalIPv4(UInt32(bigEndian: address.s_addr)) else { return [] }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var copy = address
                if inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.append(String(cString: buffer))
                }
            } else if info.ai_family == AF_INET6,
                      var address = info.ai_addr?.withMemoryRebound(
                          to: sockaddr_in6.self,
                          capacity: 1,
                          { $0.pointee.sin6_addr }
                      ) {
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                guard isGlobalIPv6(bytes) else { return [] }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.append(String(cString: buffer))
                }
            }
            cursor = info.ai_next
        }
        var seen = Set<String>()
        return addresses.filter { seen.insert($0).inserted }
    }

    private static func isGlobalIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xff)
        let second = UInt8((address >> 16) & 0xff)
        let third = UInt8((address >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && third == 0 { return false }
        if first == 192 && second == 0 && third == 2 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        return true
    }

    private static func isGlobalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) || bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return false
        }
        if bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return false
        }
        let isMappedIPv4 = bytes.prefix(10).allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff && bytes[11] == 0xff
        if isMappedIPv4 {
            let address = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isGlobalIPv4(address)
        }
        // RFC 6052's well-known NAT64 prefix sits outside 2000::/3. Treat it
        // as public only when the embedded IPv4 destination is itself public;
        // this preserves SSRF blocking for synthesized loopback/private IPv4.
        let isWellKnownNAT64 = bytes[0] == 0x00
            && bytes[1] == 0x64
            && bytes[2] == 0xff
            && bytes[3] == 0x9b
            && bytes[4..<12].allSatisfy({ $0 == 0 })
        if isWellKnownNAT64 {
            let address = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isGlobalIPv4(address)
        }
        return (bytes[0] & 0xe0) == 0x20
    }

    private static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "html", "htm": "text/html"
        case "md", "markdown": "text/markdown"
        case "json": "application/json"
        case "csv": "text/csv"
        case "xml": "application/xml"
        case "yaml", "yml": "application/yaml"
        case "js", "mjs": "application/javascript"
        case "txt", "text", "toml", "swift", "py", "ts", "tsx", "jsx", "rs",
             "kt", "java", "c", "h", "cpp", "sh", "rb": "text/plain"
        default: "application/octet-stream"
        }
    }

    private static func isSupportedRemoteTextType(_ mediaType: String) -> Bool {
        mediaType.hasPrefix("text/") || [
            "application/json",
            "application/ld+json",
            "application/xml",
            "application/yaml",
            "application/x-yaml",
            "application/javascript",
            "application/x-javascript",
        ].contains(mediaType)
    }

    private static func fileExtension(mediaType: String, url: URL) -> String {
        switch mediaType {
        case "application/pdf": "pdf"
        case "text/html", "application/xhtml+xml": "html"
        case "text/markdown": "md"
        case "application/json": "json"
        case "text/csv": "csv"
        default:
            url.pathExtension.isEmpty ? "txt" : safeSlug(url.pathExtension)
        }
    }

    private static func safeSlug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let pieces = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
        let joined = pieces.joined(separator: "-")
        return String((joined.isEmpty ? "source" : joined).prefix(64))
    }

    /// Delete only through directory descriptors rooted at the course. This
    /// makes rollback safe even if a writable manifest or an intermediate
    /// course path was replaced by a symlink before cleanup.
    private static func removeConfinedItem(
        relativePath: String,
        workspaceURL: URL,
        isDirectory: Bool
    ) {
        CourseWorkspaceFileSystem(rootURL: workspaceURL).remove(
            relativePath,
            isDirectory: isDirectory
        )
    }

    private static func isReceiptOwnedOriginal(
        _ relativePath: String,
        receipt: CourseSourceIngestionReceipt
    ) -> Bool {
        let suffix = String(receipt.id.suffix(8))
        let expectedDirectory = "sources/originals/\(safeSlug(receipt.sourceName))-\(suffix)"
        let path = relativePath as NSString
        let filename = path.lastPathComponent
        let ext = (filename as NSString).pathExtension
        return path.deletingLastPathComponent == expectedDirectory
            && filename == "original.\(ext)"
            && !ext.isEmpty
            && ext.utf8.count <= 64
            && ext.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
    }

    private static func isReceiptOwnedDirectory(
        _ relativePath: String,
        ingestionID: String
    ) -> Bool {
        relativePath == "sources/originals/\(ingestionID)"
            && ingestionID.hasPrefix("ing_")
            && ingestionID.dropFirst(4).unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
    }

    private static func removeReceiptOwnedOriginals(
        manifest: CourseSourceIngestionManifest,
        receipt: CourseSourceIngestionReceipt,
        workspaceURL: URL
    ) {
        if let directory = manifest.ownedOriginalDirectoryRelativePath,
           isReceiptOwnedDirectory(directory, ingestionID: receipt.id) {
            try? CourseWorkspaceFileSystem(rootURL: workspaceURL)
                .removeRecursively(directory)
            return
        }

        // Backward-compatible cleanup for manifests created before the
        // directory ownership field existed.
        if let relative = manifest.originalRelativePath,
           isReceiptOwnedOriginal(relative, receipt: receipt) {
            try? CourseWorkspaceFileSystem(rootURL: workspaceURL)
                .removeRecursively((relative as NSString).deletingLastPathComponent)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func relativePath(for url: URL?, workspaceURL: URL) -> String? {
        guard let url else { return nil }
        let root = workspaceURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        let relative = String(candidate.path.dropFirst(prefix.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return relative
    }

    private static func writeManifest(
        _ manifest: CourseSourceIngestionManifest,
        workspaceURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try CourseWorkspaceFileSystem(rootURL: workspaceURL).write(
            encoder.encode(manifest),
            to: ".course/ingestion/\(manifest.id).json"
        )
    }
}
