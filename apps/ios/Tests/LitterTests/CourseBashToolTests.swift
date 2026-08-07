import XCTest
@testable import Litter

private typealias AppCourseBashTool = CourseBashTool

final class CourseBashToolTests: XCTestCase {
    /// Most low-level confinement/resource tests need to exercise the writable
    /// lane without manufacturing a learner approval receipt. Production call
    /// sites use the approval-gated default.
    private enum CourseBashTool {
        static let maximumOutputBytes = AppCourseBashTool.maximumOutputBytes

        static func isValidWorkspaceID(_ workspaceID: String) -> Bool {
            AppCourseBashTool.isValidWorkspaceID(workspaceID)
        }

        static func execute(
            workspaceID: String,
            workspaceURL: URL,
            script: String,
            timeoutSeconds: Int? = nil
        ) async throws -> CourseBashExecution {
            try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspaceURL,
                script: script,
                timeoutSeconds: timeoutSeconds,
                writeAccess: .unrestrictedForTesting
            )
        }
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testWorkspaceIDValidationRejectsPaths() {
        XCTAssertTrue(CourseBashTool.isValidWorkspaceID("course_123-alpha"))
        XCTAssertFalse(CourseBashTool.isValidWorkspaceID("../other-course"))
        XCTAssertFalse(CourseBashTool.isValidWorkspaceID("course/other"))
        XCTAssertFalse(CourseBashTool.isValidWorkspaceID(""))
    }

    func testCourseShellReadsAndWritesLiveWorkspaceAndCannotTraverseNormally() async throws {
        let workspaceID = "shell-test-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-shell-secret-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "must remain hidden".write(
            to: sibling.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        temporaryDirectories.append(contentsOf: [workspace, sibling])

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: """
            mkdir -p notes
            printf 'finite field\n' > notes/draft.txt
            cp notes/draft.txt notes/copy.txt
            mv notes/copy.txt notes/final.txt
            rm notes/draft.txt
            printf 'cwd=%s\n' "$PWD"
            test "$(/bin/busybox id -u)" != 0
            cd ..
            printf 'parent=%s\n' "$PWD"
            test ! -e /mnt/apps
            mkdir -p /tmp/escape
            if /bin/busybox mount -t real \(IshFS.shellQuote(sibling.path)) /tmp/escape 2>/dev/null; then
                exit 91
            fi
            test ! -e /tmp/escape/secret.txt
            cat /workspace/notes/final.txt
            """
        )

        XCTAssertEqual(execution.exitCode, 0, execution.output)
        XCTAssertTrue(execution.output.contains("cwd=/workspace"))
        XCTAssertTrue(execution.output.contains("parent=/"))
        XCTAssertTrue(execution.output.contains("finite field"))
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("notes/final.txt"), encoding: .utf8),
            "finite field\n"
        )
        XCTAssertTrue(execution.changedPaths.contains("notes/final.txt"))

        let root = IshFS.courseShellRoot(workspaceID: workspaceID)
        let cleanupProbe = await IshFS.run(
            "test ! -e \(IshFS.shellQuote(root))"
        )
        XCTAssertEqual(cleanupProbe.exitCode, 0, "The per-run chroot must not persist")
    }

    func testPostDispatchInfrastructureFailureReportsAmbiguousCommitAndRefreshesWorkspace() async throws {
        let workspaceID = "shell-ambiguous-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)
        let refresh = expectation(
            forNotification: AppCourseBashTool.workspaceDidChangeNotification,
            object: nil
        ) { notification in
            notification.userInfo?[AppCourseBashTool.workspaceIDUserInfoKey] as? String == workspaceID
        }

        do {
            _ = try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "printf committed > marker.txt",
                writeAccess: .unrestrictedForTesting,
                runCourseScript: { _, _, nativeWorkspacePath, _, _ in
                    try? Data("committed".utf8).write(
                        to: URL(fileURLWithPath: nativeWorkspacePath)
                            .appendingPathComponent("marker.txt")
                    )
                    return IshFS.Result(
                        exitCode: IshFS.courseShellSetupFailureExitCode,
                        output: "Course shell cleanup failed after execution.",
                        courseScriptWasDispatched: true
                    )
                }
            )
            XCTFail("Expected an ambiguous post-dispatch outcome")
        } catch let error as CourseBashError {
            guard case .executionOutcomeUnknown(let detail) = error else {
                return XCTFail("Unexpected course shell error: \(error)")
            }
            XCTAssertTrue(detail.contains("marker.txt"), detail)
            XCTAssertTrue(error.localizedDescription.contains("Inspect the course workspace before retrying"))
        }

        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertEqual(
            try String(
                contentsOf: workspace.appendingPathComponent("marker.txt"),
                encoding: .utf8
            ),
            "committed"
        )

        let verificationRefresh = expectation(
            forNotification: AppCourseBashTool.workspaceDidChangeNotification,
            object: nil
        ) { notification in
            notification.userInfo?[AppCourseBashTool.workspaceIDUserInfoKey] as? String == workspaceID
        }
        do {
            _ = try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "printf committed > verification-marker.txt",
                writeAccess: .unrestrictedForTesting,
                runCourseScript: { _, _, nativeWorkspacePath, _, _ in
                    try? Data("committed".utf8).write(
                        to: URL(fileURLWithPath: nativeWorkspacePath)
                            .appendingPathComponent("verification-marker.txt")
                    )
                    return IshFS.Result(
                        exitCode: 0,
                        output: "",
                        courseScriptWasDispatched: true
                    )
                },
                verifyAndRemoveSymbolicLinks: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
            )
            XCTFail("Expected an ambiguous post-dispatch verification outcome")
        } catch let error as CourseBashError {
            guard case .executionOutcomeUnknown(let detail) = error else {
                return XCTFail("Unexpected course shell error: \(error)")
            }
            XCTAssertTrue(detail.contains("verification-marker.txt"), detail)
        }
        await fulfillment(of: [verificationRefresh], timeout: 1)
    }

    func testChangedPathReportingIsBoundedForLargeWorkspaceMutation() async throws {
        let workspaceID = "shell-path-cap-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)
        let run: AppCourseBashTool.CourseScriptRunner = { _, _, nativeWorkspacePath, _, _ in
            let root = URL(fileURLWithPath: nativeWorkspacePath, isDirectory: true)
            for index in 0..<1_000 {
                let name = String(format: "changed-%04d-%@.txt", index, String(repeating: "x", count: 48))
                try? Data().write(to: root.appendingPathComponent(name))
            }
            return IshFS.Result(
                exitCode: 0,
                output: "\n\(AppCourseBashTool.supervisorStatusMarker)script\texit=0\ttruncated=0\n",
                courseScriptWasDispatched: true
            )
        }

        let execution = try await AppCourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "touch many files",
            writeAccess: .unrestrictedForTesting,
            runCourseScript: run
        )

        XCTAssertTrue(execution.changedPathsWereTruncated)
        XCTAssertLessThanOrEqual(
            execution.changedPaths.count,
            AppCourseBashTool.maximumReportedChangedPaths
        )
        let serialized = try JSONSerialization.data(withJSONObject: execution.jsonObject)
        XCTAssertLessThan(serialized.count, 16 * 1024)

        do {
            _ = try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "touch more files",
                writeAccess: .unrestrictedForTesting,
                runCourseScript: { _, _, nativeWorkspacePath, _, _ in
                    let root = URL(fileURLWithPath: nativeWorkspacePath, isDirectory: true)
                    for index in 1_000..<2_000 {
                        let name = String(format: "changed-%04d-%@.txt", index, String(repeating: "y", count: 48))
                        try? Data().write(to: root.appendingPathComponent(name))
                    }
                    return IshFS.Result(
                        exitCode: IshFS.courseShellSetupFailureExitCode,
                        output: String(repeating: "diagnostic-control-\u{0001}", count: 2_000),
                        courseScriptWasDispatched: true
                    )
                }
            )
            XCTFail("Expected an ambiguous outcome")
        } catch let error as CourseBashError {
            guard case .executionOutcomeUnknown = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertLessThan(error.localizedDescription.utf8.count, 20 * 1024)
            XCTAssertTrue(error.localizedDescription.contains("additional changed paths omitted"))
        }
    }

    func testCourseShellSanitizesEnvironmentAndDeniesNetworkAndSpecialNodes() async throws {
        let workspaceID = "shell-environment-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: """
            test "$HOME" = /workspace
            test "$USER" = learnfold
            test "$LOGNAME" = learnfold
            test "$PATH" = /bin
            test "$TMPDIR" = /tmp
            test -z "${CODEX_HOME:-}"
            if /bin/busybox wget -T 1 -O /tmp/network-body http://1.1.1.1/ 2>/tmp/network-error; then
                exit 91
            fi
            grep -qi 'permitted' /tmp/network-error
            if /bin/busybox mkfifo forbidden-fifo 2>/tmp/fifo-error; then
                exit 92
            fi
            test ! -e forbidden-fifo
            """
        )

        XCTAssertEqual(execution.exitCode, 0, execution.output)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("forbidden-fifo").path
        ))
    }

    func testCourseShellCannotCreateHostSymlinkDuringSwapRace() async throws {
        let workspaceID = "shell-symlink-race-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-shell-race-secret-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let secret = sibling.appendingPathComponent("secret.txt")
        try "host-secret".write(to: secret, atomically: true, encoding: .utf8)
        temporaryDirectories.append(contentsOf: [workspace, sibling])

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: """
            if ln -s \(IshFS.shellQuote(secret.path)) forbidden-link 2>/dev/null; then
                exit 92
            fi
            printf safe > victim
            (
                i=0
                while [ $i -lt 600 ]; do
                    rm -f victim
                    ln -s \(IshFS.shellQuote(secret.path)) victim 2>/dev/null || true
                    rm -f victim
                    printf safe > victim
                    i=$((i+1))
                done
            ) &
            swapper=$!
            i=0
            while [ $i -lt 600 ]; do
                value=$(cat victim 2>/dev/null || true)
                if [ "$value" = host-secret ]; then
                    touch escaped
                    break
                fi
                i=$((i+1))
            done
            wait "$swapper"
            test ! -e escaped
            """,
            timeoutSeconds: 15
        )

        XCTAssertEqual(execution.exitCode, 0, execution.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escaped").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("forbidden-link").path))
    }

    func testCourseShellRejectsPreexistingWorkspaceSymlink() async throws {
        let workspaceID = "shell-preexisting-symlink-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-shell-preexisting-secret-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let secret = sibling.appendingPathComponent("secret.txt")
        try "host-secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("unsafe-link"),
            withDestinationURL: secret
        )
        temporaryDirectories.append(contentsOf: [workspace, sibling])

        do {
            _ = try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "cat unsafe-link",
                writeAccess: .unrestrictedForTesting
            )
            XCTFail("Expected a symlink preflight failure")
        } catch {
            XCTAssertEqual(error as? CourseBashError, .symbolicLinksUnsupported)
        }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "host-secret")
    }

    func testCourseShellEnforcesDeadline() async throws {
        let workspaceID = "shell-timeout-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let startedAt = ContinuousClock.now
        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "sleep 5; printf late > should-not-exist.txt",
            timeoutSeconds: 1
        )
        let elapsed = startedAt.duration(to: .now)

        XCTAssertNotEqual(execution.exitCode, 0)
        XCTAssertLessThan(elapsed, .seconds(7), execution.output)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("should-not-exist.txt").path
            )
        )
    }

    func testCourseShellIsReadOnlyBeforeProtectedPlanApproval() async throws {
        let workspaceID = "shell-read-only-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "reference".write(
            to: workspace.appendingPathComponent("source.txt"),
            atomically: true,
            encoding: .utf8
        )
        temporaryDirectories.append(workspace)

        let execution = try await AppCourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "cat source.txt; printf forbidden > mutation.txt"
        )

        XCTAssertTrue(execution.workspaceWasReadOnly)
        XCTAssertNotEqual(execution.exitCode, 0)
        XCTAssertTrue(execution.output.contains("reference"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("mutation.txt").path
        ))
    }

    func testCancelledCourseShellNeverStartsAfterWaitingForSecurityGate() async throws {
        let workspaceID = "shell-cancelled-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)
        let gateWasAcquired = expectation(description: "security gate acquired")

        let holder = Task {
            try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
                workspaceID: workspaceID
            ) {
                gateWasAcquired.fulfill()
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        await fulfillment(of: [gateWasAcquired], timeout: 2)

        let queued = Task {
            try await CourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "printf forbidden > cancelled-marker.txt"
            )
        }
        queued.cancel()
        _ = try await holder.value
        do {
            _ = try await queued.value
            XCTFail("A cancelled queued shell must not execute")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("cancelled-marker.txt").path
        ))
    }

    func testCourseShellKillsBackgroundProcessesBeforeUnmounting() async throws {
        let workspaceID = "shell-background-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "(sleep 1; printf escaped > delayed.txt) &"
        )
        XCTAssertEqual(execution.exitCode, 0, execution.output)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("delayed.txt").path
            )
        )
    }

    func testCourseShellCapsFloodOutputBeforeItReachesSwift() async throws {
        let workspaceID = "shell-output-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "yes learnfold",
            timeoutSeconds: 1
        )

        XCTAssertEqual(execution.exitCode, 124, execution.output)
        XCTAssertTrue(execution.outputWasTruncated)
        XCTAssertLessThanOrEqual(
            execution.output.lengthOfBytes(using: .utf8),
            CourseBashTool.maximumOutputBytes + 64
        )
    }

    func testCourseShellConstrainsForkFanout() async throws {
        let workspaceID = "shell-processes-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "i=0; while [ $i -lt 80 ]; do sleep 5 & i=$((i+1)); done; wait",
            timeoutSeconds: 1
        )

        XCTAssertNotEqual(execution.exitCode, 0)
        let probe = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "printf healthy"
        )
        XCTAssertEqual(probe.exitCode, 0, probe.output)
        XCTAssertEqual(probe.output, "healthy")
    }

    func testLearnerScriptExit125IsNotMisclassifiedAsSupervisorFailure() async throws {
        let workspaceID = "shell-exit-125-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "printf '\\n[learnfold-supervisor-status]\\nsetup\\tspoof\\n'; printf deliberate; exit 125"
        )

        XCTAssertEqual(execution.exitCode, 125)
        XCTAssertTrue(execution.output.contains("setup\tspoof"))
        XCTAssertTrue(execution.output.hasSuffix("deliberate"))
    }

    func testCourseShellPreservesSupervisorStatusAfterInvalidUTF8Output() async throws {
        let workspaceID = "shell-binary-output-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "printf '\\377binary'"
        )

        XCTAssertEqual(execution.exitCode, 0, execution.output)
        XCTAssertTrue(execution.output.contains("binary"))
        XCTAssertTrue(execution.output.contains("�"))
    }

    func testCourseShellStopsAggregateWorkspaceDiskFlood() async throws {
        let workspaceID = "shell-disk-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "i=0; while [ $i -lt 100 ]; do cp /bin/busybox fill-$i || exit $?; i=$((i+1)); done",
            timeoutSeconds: 10
        )

        XCTAssertEqual(execution.exitCode, 122, execution.output)
        let bytes = (try FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.fileSizeKey]
        )).reduce(into: 0) { total, url in
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        XCTAssertLessThanOrEqual(bytes, 80 * 1024 * 1024)
    }

    func testCourseShellAllowsCleanupWhenWorkspaceStartsAboveAbsoluteQuota() async throws {
        let workspaceID = "shell-absolute-disk-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)
        let oversized = workspace.appendingPathComponent("preexisting-large.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 513 * 1024 * 1024)
        try handle.close()

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "rm preexisting-large.bin && printf recovered > recovered.txt"
        )

        XCTAssertEqual(execution.exitCode, 0, execution.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertEqual(
            try String(
                contentsOf: workspace.appendingPathComponent("recovered.txt"),
                encoding: .utf8
            ),
            "recovered"
        )
    }

    func testCourseShellTemporaryStorageIsQuotaControlledAndEphemeral() async throws {
        let workspaceID = "shell-temp-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        temporaryDirectories.append(workspace)

        let first = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "printf transient > /tmp/should-disappear"
        )
        XCTAssertEqual(first.exitCode, 0, first.output)
        let workspaceEntries = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(workspaceEntries.contains { $0.hasPrefix(".learnfold-shell-tmp-") })

        let second = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "test ! -e /tmp/should-disappear"
        )
        XCTAssertEqual(second.exitCode, 0, second.output)
    }

    func testCourseShellDoesNotFollowPreexistingTemporaryStorageSymlink() async throws {
        let workspaceID = "shell-temp-symlink-" + UUID().uuidString.lowercased()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(workspaceID, isDirectory: true)
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-shell-temp-victim-" + UUID().uuidString, isDirectory: true)
        let metadata = workspace.appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let victim = sibling.appendingPathComponent("must-survive.txt")
        try "safe".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: metadata.appendingPathComponent("shell-tmp"),
            withDestinationURL: sibling
        )
        temporaryDirectories.append(contentsOf: [workspace, sibling])

        do {
            _ = try await AppCourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: workspace,
                script: "printf transient > /tmp/value",
                writeAccess: .unrestrictedForTesting
            )
            XCTFail("Expected a symlink preflight failure")
        } catch {
            XCTAssertEqual(error as? CourseBashError, .symbolicLinksUnsupported)
        }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "safe")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: metadata.appendingPathComponent("shell-tmp").path
        ))
        let entries = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".learnfold-shell-tmp-") })
    }

    func testRealFSMountRejectsFinalSourceSymlink() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("realfs-target-" + UUID().uuidString, isDirectory: true)
        let sourceLink = FileManager.default.temporaryDirectory
            .appendingPathComponent("realfs-link-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: target)
        temporaryDirectories.append(contentsOf: [sourceLink, target])
        let mountPoint = "/root/realfs-symlink-test-\(UUID().uuidString.lowercased())"

        let result = await IshFS.run(
            "mkdir -p \(IshFS.shellQuote(mountPoint)); mount -t real \(IshFS.shellQuote(sourceLink.path)) \(IshFS.shellQuote(mountPoint)); mount_status=$?; umount \(IshFS.shellQuote(mountPoint)) >/dev/null 2>&1 || true; rmdir \(IshFS.shellQuote(mountPoint)); test $mount_status -ne 0"
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
    }

    @MainActor
    func testCourseShellCannotDeleteHermesRecoveryControlPlaneAndRefreshesStore() async throws {
        let suite = "CourseBashTool.control-plane." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-bash-control-" + UUID().uuidString, isDirectory: true)
        let coursesRoot = root.appendingPathComponent("Courses", isDirectory: true)
        let controlRoot = root.appendingPathComponent("Control", isDirectory: true)
        try FileManager.default.createDirectory(at: coursesRoot, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [:],
            coursesRootURL: coursesRoot,
            courseControlRootURL: controlRoot
        )
        let workspace = store.nativeCourseDirectory()
        let workspaceID = workspace.lastPathComponent
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".course", isDirectory: true),
            withIntermediateDirectories: true
        )
        let entry = RemoteHermesToolJournalEntry(
            id: "call-course-bash",
            workspaceID: workspaceID,
            threadID: "thread-1",
            sourceTurnID: "turn-1",
            toolName: CourseAgentTools.courseBash,
            argumentsJSON: "{}",
            selectionDiscussionID: nil,
            phase: .executing,
            success: nil,
            output: nil,
            resultTurnID: nil,
            updatedAt: Date()
        )
        try store.remoteHermesToolJournal(workspaceID: workspaceID).save(entry)
        await Task.yield()
        let refreshBefore = store.courseWorkspaceRefreshVersion

        let execution = try await CourseBashTool.execute(
            workspaceID: workspaceID,
            workspaceURL: workspace,
            script: "rm -rf .course && mkdir replacement"
        )
        XCTAssertEqual(execution.exitCode, 0)
        for _ in 0..<50 where store.courseWorkspaceRefreshVersion == refreshBefore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(store.courseWorkspaceRefreshVersion, refreshBefore)

        let recreatedStore = CourseExperienceStore(
            defaults: defaults,
            environment: [:],
            coursesRootURL: coursesRoot,
            courseControlRootURL: controlRoot
        )
        XCTAssertEqual(
            try recreatedStore.remoteHermesToolJournal(workspaceID: workspaceID).load(),
            [entry]
        )
        XCTAssertFalse(
            recreatedStore.courseControlDirectory(workspaceID: workspaceID)
                .path.hasPrefix(workspace.path + "/")
        )
    }
}
