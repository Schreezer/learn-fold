import Foundation
import Security

/// Transient presentation of a Hosted request, never persisted as runtime state.
struct HostedReplyProgress: Equatable {
    var id = UUID()
    var lastProgressAt = Date()
    var isRecovering = false

    func label(at date: Date) -> String? {
        if isRecovering { return "Hosted is retrying…" }
        if date.timeIntervalSince(lastProgressAt) >= 30 { return "Waiting for Hosted…" }
        return nil
    }
}

struct HostedCourseAgentAvailability: Equatable {
    let available: Bool
    let reason: String
}

struct HostedCourseAgentStoredMessage: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case learner
        case agent
    }

    let role: Role
    let text: String
}

@MainActor
protocol HostedCourseAgentRuntime: AnyObject {
    func availability() -> HostedCourseAgentAvailability
    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage]
    func send(
        sessionID: UUID,
        workspaceID: String,
        courseDirectory: URL,
        prompt: String,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) async throws
    func cancel(sessionID: UUID)
}

@MainActor
final class SystemHostedCourseAgentRuntime: HostedCourseAgentRuntime {
    static let modelID = "muse-spark-1.3-contributor"

    private let baseURL: String?
    private let accessToken: String?
    private var activeTasks: [UUID: Task<HostedAgentTurnResult, Error>] = [:]
    private var activeClients: [UUID: HostedAgentClient] = [:]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        baseURL = Self.configurationValue(
            environmentKey: "LEARNFOLD_HOSTED_AGENT_URL",
            bundleKey: "LearnfoldHostedAgentURL",
            environment: environment,
            bundle: bundle
        )
        accessToken = Self.configurationValue(
            environmentKey: "LEARNFOLD_HOSTED_ACCESS_TOKEN",
            bundleKey: "LearnfoldHostedAccessToken",
            environment: environment,
            bundle: bundle
        )
    }

    func availability() -> HostedCourseAgentAvailability {
        guard baseURL != nil else {
            return .init(
                available: false,
                reason: "Hosted isn't available in this build. Choose another agent."
            )
        }
        return .init(
            available: true,
            reason: accessToken == nil
                ? "Ready to use during the beta. No login needed."
                : "Cloud-hosted · \(Self.modelID) · durable session"
        )
    }

    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] {
        try await client().loadMessages(sessionId: sessionID.uuidString.lowercased()).compactMap {
            switch $0.role {
            case "user": .init(role: .learner, text: $0.text)
            case "assistant": .init(role: .agent, text: $0.text)
            default: nil
            }
        }
    }

    func send(
        sessionID: UUID,
        workspaceID: String,
        courseDirectory: URL,
        prompt: String,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) async throws {
        let definitions = try CourseAgentTools.mcpToolDefinitions().map { definition in
            let schema = try JSONSerialization.data(
                withJSONObject: definition.inputSchema,
                options: [.sortedKeys]
            )
            return HostedAgentToolDefinition(
                name: definition.name,
                description: definition.description,
                parametersJson: String(decoding: schema, as: UTF8.self)
            )
        }
        let handler = HostedCourseToolHandler(
            workspaceID: workspaceID,
            courseDirectory: courseDirectory,
            onCoursePlan: onCoursePlan
        )
        let listener = HostedCourseEventListener(
            onPartialResponse: onPartialResponse,
            onRecoveringChanged: onRecoveringChanged
        )
        let client = try client()
        let task = Task {
            try await client.send(
                sessionId: sessionID.uuidString.lowercased(),
                workspaceId: workspaceID,
                prompt: prompt,
                tools: definitions,
                toolHandler: handler,
                listener: listener
            )
        }
        activeClients[sessionID] = client
        activeTasks[sessionID] = task
        defer {
            activeTasks[sessionID] = nil
            activeClients[sessionID] = nil
        }
        do {
            _ = try await task.value
            await listener.finishDelivery()
        } catch {
            // Deliver received text before the caller decides whether the
            // request was accepted. The stream can fail right after a delta.
            await listener.finishDelivery()
            throw error
        }
    }

    func cancel(sessionID: UUID) {
        _ = try? activeClients[sessionID]?.cancel(
            sessionId: sessionID.uuidString.lowercased()
        )
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        activeClients[sessionID] = nil
    }

    private func client() throws -> HostedAgentClient {
        guard let baseURL else {
            throw HostedCourseAgentRuntimeError.unavailable(availability().reason)
        }
        if let accessToken {
            return try HostedAgentClient(baseUrl: baseURL, accessToken: accessToken)
        }
        return try HostedAgentClient.guest(
            baseUrl: baseURL,
            guestSecret: HostedGuestIdentity.loadOrCreate(serviceURL: baseURL)
        )
    }

    private static func configurationValue(
        environmentKey: String,
        bundleKey: String,
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        if let value = environment[environmentKey] {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return (bundle.object(forInfoDictionaryKey: bundleKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// Platform persistence only. Token minting and authentication stay in Rust.
enum HostedGuestIdentity {
    static func loadOrCreate(serviceURL: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.chirag.learnfold.hosted-guest",
            kSecAttrAccount as String: serviceURL,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new } as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let secret = String(data: data, encoding: .utf8), secret.count == 64 {
            return secret
        }
        guard status == errSecItemNotFound else {
            throw keychainError(status == errSecSuccess ? errSecDecode : status)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw keychainError(randomStatus) }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        let saved = SecItemAdd(query.merging([
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try loadOrCreate(serviceURL: serviceURL) }
        guard saved == errSecSuccess else { throw keychainError(saved) }
        return secret
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Couldn't access your Hosted guest identity. Please unlock your device and try again.",
        ])
    }
}

enum HostedCourseAgentRuntimeError: LocalizedError {
    case unavailable(String)
    case invalidTool(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidTool(let message), .toolFailed(let message):
            message
        }
    }
}

final class HostedCourseEventListener: HostedAgentEventListener, @unchecked Sendable {
    private let lock = NSLock()
    private var response = ""
    private var pendingDelivery: Task<Void, Never>?
    private let onPartialResponse: @MainActor (String) -> Void

    private let onRecoveringChanged: @MainActor (Bool) -> Void

    init(
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.onPartialResponse = onPartialResponse
        self.onRecoveringChanged = onRecoveringChanged
    }

    func onResponseDelta(delta: String) {
        lock.lock()
        response += delta
        let partial = response
        let previous = pendingDelivery
        pendingDelivery = Task { @MainActor [onPartialResponse] in
            await previous?.value
            onPartialResponse(partial)
        }
        lock.unlock()
    }

    func finishDelivery() async {
        await latestDelivery()?.value
    }

    private func latestDelivery() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingDelivery
    }

    func onRecoveringChanged(recovering: Bool) {
        lock.lock()
        let previous = pendingDelivery
        pendingDelivery = Task { @MainActor [onRecoveringChanged] in
            await previous?.value
            onRecoveringChanged(recovering)
        }
        lock.unlock()
    }
}

private final class HostedCourseToolHandler: HostedAgentToolHandler, @unchecked Sendable {
    private let workspaceID: String
    private let courseDirectory: URL
    private let onCoursePlan: @MainActor (CourseBrief) async throws -> Void

    init(
        workspaceID: String,
        courseDirectory: URL,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) {
        self.workspaceID = workspaceID
        self.courseDirectory = courseDirectory
        self.onCoursePlan = onCoursePlan
    }

    func executeHostedTool(invocation: HostedAgentToolInvocation) -> HostedAgentToolResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = HostedToolResultBox()
        Task.detached(priority: .userInitiated) { [self] in
            defer { semaphore.signal() }
            box.store(await execute(invocation))
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            return HostedAgentToolResult(
                success: false,
                output: "{}",
                errorMessage: "The native course tool timed out before returning a result."
            )
        }
        return box.load()
    }

    private func execute(_ invocation: HostedAgentToolInvocation) async -> HostedAgentToolResult {
        do {
            guard var arguments = try JSONSerialization.jsonObject(
                with: Data(invocation.argumentsJson.utf8)
            ) as? [String: Any],
            arguments.removeValue(forKey: CourseAgentTools.workspaceIDArgument) as? String == workspaceID else {
                throw HostedCourseAgentRuntimeError.invalidTool(
                    "The tool call did not target the active course workspace."
                )
            }

            if invocation.toolName == CourseAgentTools.presentPlan {
                let data = try JSONSerialization.data(withJSONObject: arguments)
                let plan = try JSONDecoder().decode(CourseBrief.self, from: data)
                if let issue = AppleCoursePlanValidator.issue(in: plan) {
                    throw HostedCourseAgentRuntimeError.invalidTool(issue)
                }
                try await onCoursePlan(plan)
                return success(arguments)
            }

            guard CourseAgentTools.isEditorTool(invocation.toolName) else {
                throw HostedCourseAgentRuntimeError.invalidTool(
                    "Unknown Learnfold course tool: \(invocation.toolName)"
                )
            }
            if CourseAgentTools.isMutatingEditorTool(invocation.toolName) {
                let approvedPlan = courseDirectory
                    .appendingPathComponent(".course", isDirectory: true)
                    .appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
                guard FileManager.default.fileExists(atPath: approvedPlan.path) else {
                    throw HostedCourseAgentRuntimeError.invalidTool(
                        "The course plan must be approved before native pages can be changed."
                    )
                }
            }

            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            guard let result = await CourseDocumentRegistry.shared.handle(
                workspaceID: workspaceID,
                tool: invocation.toolName,
                argumentsJSON: String(decoding: data, as: UTF8.self)
            ) else {
                throw HostedCourseAgentRuntimeError.toolFailed(
                    "The native course document is not open."
                )
            }
            let output = String(decoding: try JSONEncoder().encode(result.value), as: UTF8.self)
            return HostedAgentToolResult(
                success: !result.isError,
                output: output,
                errorMessage: result.isError ? "The native editor rejected the tool call." : nil
            )
        } catch {
            return HostedAgentToolResult(
                success: false,
                output: "{}",
                errorMessage: error.localizedDescription
            )
        }
    }

    private func success(_ object: [String: Any]) -> HostedAgentToolResult {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HostedAgentToolResult(
            success: true,
            output: data.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
            errorMessage: nil
        )
    }
}

private final class HostedToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = HostedAgentToolResult(
        success: false,
        output: "{}",
        errorMessage: "The native tool did not return a result."
    )

    func store(_ value: HostedAgentToolResult) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> HostedAgentToolResult {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
