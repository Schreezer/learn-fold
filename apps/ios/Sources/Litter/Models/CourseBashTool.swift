import Foundation

struct CourseBashExecution: Equatable, Sendable {
    let exitCode: Int32
    let output: String
    let outputWasTruncated: Bool
    let changedPaths: [String]
    let changedPathsWereTruncated: Bool
    let workspaceWasReadOnly: Bool

    var jsonObject: [String: Any] {
        [
            "exit_code": Int(exitCode),
            "output": output,
            "output_truncated": outputWasTruncated,
            "changed_paths": changedPaths,
            "changed_paths_truncated": changedPathsWereTruncated,
            "workspace_root": "/workspace",
            "workspace_access": workspaceWasReadOnly ? "read_only" : "read_write",
        ]
    }
}

enum CourseBashError: LocalizedError, Equatable {
    case invalidWorkspace
    case workspaceUnavailable
    case emptyScript
    case scriptTooLarge
    case shellUnavailable(String)
    case executionOutcomeUnknown(String)
    case symbolicLinksUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            "The requested course workspace ID is invalid."
        case .workspaceUnavailable:
            "The requested course workspace is not available on this device."
        case .emptyScript:
            "course_bash requires a non-empty script."
        case .scriptTooLarge:
            "The course_bash script exceeds the 64 KiB limit."
        case .shellUnavailable(let message):
            "The course shell could not start: \(message)"
        case .executionOutcomeUnknown(let message):
            "The course shell was dispatched, but Learnfold could not confirm its final outcome. Some file changes may have committed. Inspect the course workspace before retrying. \(message)"
        case .symbolicLinksUnsupported:
            "This course contains a symbolic link. Remove it before using course_bash; Learnfold course workspaces do not support symlinks."
        }
    }
}

enum CourseBashWriteAccess: Equatable, Sendable {
    case approvalGated
    case unrestrictedForTesting
}

/// Serializes the authorization boundary for one course workspace. A plan
/// revision cannot replace the approved revision while a shell invocation is
/// waiting for iSH or executing with write access.
actor CourseWorkspaceSecurityGate {
    static let shared = CourseWorkspaceSecurityGate()

    private var lockedWorkspaceIDs: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withExclusiveAccess<T: Sendable>(
        workspaceID: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(workspaceID: workspaceID)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(workspaceID: workspaceID)
            return result
        } catch {
            release(workspaceID: workspaceID)
            throw error
        }
    }

    private func acquire(workspaceID: String) async {
        if lockedWorkspaceIDs.insert(workspaceID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[workspaceID, default: []].append(continuation)
        }
    }

    private func release(workspaceID: String) {
        guard var workspaceWaiters = waiters[workspaceID], !workspaceWaiters.isEmpty else {
            lockedWorkspaceIDs.remove(workspaceID)
            waiters[workspaceID] = nil
            return
        }
        let next = workspaceWaiters.removeFirst()
        waiters[workspaceID] = workspaceWaiters.isEmpty ? nil : workspaceWaiters
        next.resume()
    }
}

/// Runs an agent-authored shell script against the live course workspace.
///
/// The course is mounted directly at `/workspace` inside a minimal iSH chroot.
/// Mutations therefore commit to the real course immediately, while ordinary
/// absolute paths and `..` traversal cannot reach sibling courses or app data.
/// This is intentionally not a copy-on-write view.
enum CourseBashTool {
    typealias CourseScriptRunner = @Sendable (
        _ script: String,
        _ workspaceID: String,
        _ nativeWorkspacePath: String,
        _ timeoutSeconds: Int,
        _ workspaceReadOnly: Bool
    ) async -> IshFS.Result

    static let maximumScriptBytes = 64 * 1024
    static let maximumOutputBytes = 48 * 1024
    static let maximumReportedChangedPaths = 128
    static let maximumReportedChangedPathsJSONBytes = 8 * 1024
    static let maximumAmbiguousDiagnosticBytes = 8 * 1024
    static let defaultTimeoutSeconds = 30
    static let maximumTimeoutSeconds = 120
    static let supervisorStatusMarker = "\n[learnfold-supervisor-status]\n"

    static let workspaceDidChangeNotification = Notification.Name(
        "LearnfoldCourseBashWorkspaceDidChange"
    )
    static let workspaceIDUserInfoKey = "workspace_id"

    static func isValidWorkspaceID(_ workspaceID: String) -> Bool {
        !workspaceID.isEmpty
            && workspaceID.count <= 128
            && workspaceID.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    static func execute(
        workspaceID: String,
        workspaceURL: URL,
        script: String,
        timeoutSeconds: Int? = nil,
        writeAccess: CourseBashWriteAccess = .approvalGated,
        runCourseScript: @escaping CourseScriptRunner = { script, workspaceID, path, timeout, readOnly in
            await IshFS.runCourseScript(
                script,
                workspaceID: workspaceID,
                nativeWorkspacePath: path,
                timeoutSeconds: timeout,
                workspaceReadOnly: readOnly
            )
        },
        verifyAndRemoveSymbolicLinks: @Sendable (CourseWorkspaceFileSystem) throws -> Int = {
            try $0.removeSymbolicLinks()
        }
    ) async throws -> CourseBashExecution {
        guard isValidWorkspaceID(workspaceID) else { throw CourseBashError.invalidWorkspace }

        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScript.isEmpty else { throw CourseBashError.emptyScript }
        guard script.lengthOfBytes(using: .utf8) <= maximumScriptBytes else {
            throw CourseBashError.scriptTooLarge
        }

        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolvedWorkspace.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CourseBashError.workspaceUnavailable
        }
        let workspaceFileSystem = CourseWorkspaceFileSystem(rootURL: resolvedWorkspace)
        guard (try? workspaceFileSystem.containsSymbolicLink()) == false else {
            throw CourseBashError.symbolicLinksUnsupported
        }
        return try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
            workspaceID: workspaceID
        ) {
            // Re-read approval only after acquiring the same gate used to
            // present and approve plans. This closes the stale-authorization
            // window while a shell call is queued behind another iSH run.
            let workspaceReadOnly = writeAccess == .approvalGated
                && !AppleCourseApprovalPolicy.isLatestPlanApproved(
                    courseDirectory: resolvedWorkspace
                )

            let timeout = min(
                max(timeoutSeconds ?? defaultTimeoutSeconds, 1),
                maximumTimeoutSeconds
            )
            let before = workspaceFingerprint(rootURL: resolvedWorkspace)
            let result = await runCourseScript(
                script,
                workspaceID,
                resolvedWorkspace.path,
                timeout,
                workspaceReadOnly
            )
            let removedSymbolicLinks: Int
            do {
                removedSymbolicLinks = try verifyAndRemoveSymbolicLinks(workspaceFileSystem)
            } catch {
                let after = workspaceFingerprint(rootURL: resolvedWorkspace)
                let changedPaths = changedPaths(before: before, after: after)
                if result.courseScriptWasDispatched || !changedPaths.isEmpty {
                    NotificationCenter.default.post(
                        name: workspaceDidChangeNotification,
                        object: nil,
                        userInfo: [workspaceIDUserInfoKey: workspaceID]
                    )
                }
                if result.courseScriptWasDispatched {
                    throw CourseBashError.executionOutcomeUnknown(
                        ambiguousOutcomeDetail(
                            output: "Learnfold could not verify the workspace after execution: \(error.localizedDescription)",
                            changedPaths: changedPaths
                        )
                    )
                }
                throw CourseBashError.shellUnavailable(
                    "Learnfold could not verify the workspace after execution: \(error.localizedDescription)"
                )
            }
            let after = workspaceFingerprint(rootURL: resolvedWorkspace)
            let changedPaths = changedPaths(before: before, after: after)

            if result.courseScriptWasDispatched
                || !workspaceReadOnly
                || !changedPaths.isEmpty
                || removedSymbolicLinks > 0 {
                NotificationCenter.default.post(
                    name: workspaceDidChangeNotification,
                    object: nil,
                    userInfo: [workspaceIDUserInfoKey: workspaceID]
                )
            }

            if removedSymbolicLinks > 0 {
                throw CourseBashError.executionOutcomeUnknown(
                    "Learnfold removed \(removedSymbolicLinks) unsupported symbolic link(s) created during execution. Changed paths: \(changedPaths.joined(separator: ", "))."
                )
            }

            if result.exitCode == IshFS.courseShellSetupFailureExitCode {
                if result.courseScriptWasDispatched {
                    throw CourseBashError.executionOutcomeUnknown(
                        ambiguousOutcomeDetail(output: result.output, changedPaths: changedPaths)
                    )
                }
                throw CourseBashError.shellUnavailable(result.output)
            }
            guard let statusRange = result.output.range(
                of: supervisorStatusMarker,
                options: .backwards
            ) else {
                if result.courseScriptWasDispatched {
                    throw CourseBashError.executionOutcomeUnknown(
                        ambiguousOutcomeDetail(output: result.output, changedPaths: changedPaths)
                    )
                }
                throw CourseBashError.shellUnavailable(result.output)
            }
            let supervisorStatus = result.output[statusRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard supervisorStatus.hasPrefix("script\t") else {
                throw CourseBashError.executionOutcomeUnknown(
                    ambiguousOutcomeDetail(
                        output: String(supervisorStatus),
                        changedPaths: changedPaths
                    )
                )
            }

            let supervisorTruncated = supervisorStatus.contains("truncated=1")
            var cleanedOutput = String(result.output[..<statusRange.lowerBound])
            if supervisorTruncated {
                cleanedOutput += "\n[output truncated by Learnfold]\n"
            }
            let truncated = truncateUTF8(cleanedOutput, maximumBytes: maximumOutputBytes)
            let reportedChanges = reportChangedPaths(changedPaths)

            return CourseBashExecution(
                exitCode: result.exitCode,
                output: truncated.value,
                outputWasTruncated: supervisorTruncated || truncated.wasTruncated,
                changedPaths: reportedChanges.paths,
                changedPathsWereTruncated: reportedChanges.wasTruncated,
                workspaceWasReadOnly: workspaceReadOnly
            )
        }
    }

    private static func ambiguousOutcomeDetail(
        output: String,
        changedPaths: [String]
    ) -> String {
        let reported = reportChangedPaths(changedPaths)
        var paths = reported.paths.isEmpty ? "none detected" : reported.paths.joined(separator: ", ")
        if reported.wasTruncated {
            paths += ", [additional changed paths omitted]"
        }
        let diagnostic = truncateUTF8(
            output.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumBytes: maximumAmbiguousDiagnosticBytes
        ).value
        return "Changed paths: \(paths). Infrastructure diagnostic: \(diagnostic)"
    }

    private static func reportChangedPaths(
        _ changedPaths: [String]
    ) -> (paths: [String], wasTruncated: Bool) {
        var paths: [String] = []
        var encodedBytes = 2 // JSON array brackets.
        for path in changedPaths {
            guard paths.count < maximumReportedChangedPaths,
                  let encoded = try? JSONEncoder().encode(path) else {
                return (paths, true)
            }
            let separatorBytes = paths.isEmpty ? 0 : 1
            guard encodedBytes + separatorBytes + encoded.count
                    <= maximumReportedChangedPathsJSONBytes else {
                return (paths, true)
            }
            paths.append(path)
            encodedBytes += separatorBytes + encoded.count
        }
        return (paths, false)
    }

    private struct FileFingerprint: Equatable {
        let isDirectory: Bool
        let byteCount: Int64
        let modificationTime: TimeInterval
    }

    private static func workspaceFingerprint(rootURL: URL) -> [String: FileFingerprint] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        var result: [String: FileFingerprint] = [:]
        for case let url as URL in enumerator {
            guard let relative = CourseWorkspaceSnapshot.relativePath(
                for: url,
                rootURL: rootURL
            ), !relative.isEmpty,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            result[relative] = FileFingerprint(
                isDirectory: values.isDirectory == true,
                byteCount: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        return result
    }

    private static func changedPaths(
        before: [String: FileFingerprint],
        after: [String: FileFingerprint]
    ) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    private static func truncateUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> (value: String, wasTruncated: Bool) {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return (value, false) }
        var prefix = data.prefix(maximumBytes)
        while String(data: prefix, encoding: .utf8) == nil, !prefix.isEmpty {
            prefix = prefix.dropLast()
        }
        let text = String(data: prefix, encoding: .utf8) ?? ""
        return (text + "\n[output truncated by Learnfold]\n", true)
    }
}
