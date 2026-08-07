import Darwin
import Foundation

/// Thin Swift wrapper over UniFFI `ishRun` for filesystem operations that
/// the iOS-side `FileManager` can't do — the iSH fakefs is invisible to
/// host iOS APIs, so anything that needs to enumerate or mutate paths
/// inside the kernel's view (e.g. `/root`, `/etc`, `/usr`) has to go
/// through the persistent shell.
///
/// Keep this surface tiny. Most product logic should still happen Rust-side
/// via the exec hook — this is only for UI that has to read fakefs state
/// directly (the directory picker, primarily).
enum IshFS {
    // Process exit codes are always 0...255. Keep infrastructure failure out
    // of that range so a learner script may legitimately `exit 125`.
    static let courseShellSetupFailureExitCode: Int32 = -125

    struct Result {
        let exitCode: Int32
        let output: String
        let courseScriptWasDispatched: Bool

        init(
            exitCode: Int32,
            output: String,
            courseScriptWasDispatched: Bool = false
        ) {
            self.exitCode = exitCode
            self.output = output
            self.courseScriptWasDispatched = courseScriptWasDispatched
        }
    }

    /// POSIX single-quote a string for safe interpolation into a shell
    /// command: `'x'` stays `'x'`, `x's` becomes `'x'\''s'`.
    static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Run `cmd` through the persistent iSH shell. `ishRun` is thread-safe
    /// but serializes internally, so we hop to a background task to avoid
    /// blocking the caller (typically a SwiftUI MainActor path).
    static func run(
        _ cmd: String,
        cwd: String? = nil,
        timeoutMilliseconds: UInt64? = nil
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let res = if let timeoutMilliseconds {
                ishRunWithTimeout(
                    cmd: cmd,
                    cwd: cwd ?? "",
                    timeoutMs: timeoutMilliseconds
                )
            } else {
                ishRun(cmd: cmd, cwd: cwd ?? "")
            }
            let output = String(decoding: res.output, as: UTF8.self)
            return Result(exitCode: res.exitCode, output: output)
        }.value
    }

    /// Run a script in a minimal chroot whose only live host mount is the
    /// selected course folder at `/workspace`. The mount is read-write.
    static func runCourseScript(
        _ script: String,
        workspaceID: String,
        nativeWorkspacePath: String,
        timeoutSeconds: Int,
        workspaceReadOnly: Bool
    ) async -> Result {
        await CourseShellExecutionQueue.shared.run(
            script,
            workspaceID: workspaceID,
            nativeWorkspacePath: nativeWorkspacePath,
            timeoutSeconds: timeoutSeconds,
            workspaceReadOnly: workspaceReadOnly
        )
    }

    static func courseShellRoot(workspaceID: String) -> String {
        let sandboxID = workspaceID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "_"
        }
        return "/root/.learnfold-course-shell/\(String(sandboxID))"
    }
}

/// Serializes setup, execution, and cleanup as one critical section. iSH
/// serializes individual commands, but without this actor another course run
/// could otherwise start between an execution and its unmount cleanup.
private actor CourseShellExecutionQueue {
    static let shared = CourseShellExecutionQueue()

    func run(
        _ script: String,
        workspaceID: String,
        nativeWorkspacePath: String,
        timeoutSeconds: Int,
        workspaceReadOnly: Bool
    ) async -> IshFS.Result {
        let root = IshFS.courseShellRoot(workspaceID: workspaceID)
        let workspaceAttributes = try? FileManager.default.attributesOfItem(
            atPath: nativeWorkspacePath
        )
        let ownerID = (workspaceAttributes?[.ownerAccountID] as? NSNumber)?.intValue ?? 501
        let groupID = (workspaceAttributes?[.groupOwnerAccountID] as? NSNumber)?.intValue ?? ownerID
        // Never let unusual filesystem metadata turn the agent shell back into
        // root. App-owned course directories are normally 501 on device and
        // the signed-in macOS user's uid in Simulator.
        let shellUserID = ownerID > 0 ? ownerID : 501
        let shellGroupID = groupID > 0 ? groupID : shellUserID
        let shellTemporaryDirectory: ConfinedCourseShellTemporaryDirectory
        do {
            shellTemporaryDirectory = try ConfinedCourseShellTemporaryDirectory(
                workspacePath: nativeWorkspacePath
            )
        } catch {
            return IshFS.Result(
                exitCode: IshFS.courseShellSetupFailureExitCode,
                output: "Learnfold could not prepare quota-controlled temporary storage: \(error.localizedDescription)"
            )
        }
        guard let helperURL = Bundle.main.url(
            forResource: "learnfold-course-exec",
            withExtension: nil
        ) else {
            try? shellTemporaryDirectory.remove()
            return IshFS.Result(
                exitCode: IshFS.courseShellSetupFailureExitCode,
                output: "Learnfold course executor is missing from the app bundle."
            )
        }
        let helperMount = "\(root)/.helper-mount"
        let applets = [
            "awk", "base64", "basename", "cat", "chmod", "cmp", "cp", "cut", "date",
            "dd", "diff", "dirname", "du", "echo", "env", "expr", "false",
            "find", "grep", "head", "ln", "ls", "md5sum", "mkdir", "mktemp", "mv",
            "od", "paste", "printf", "pwd", "readlink", "realpath", "rm", "rmdir",
            "sed", "seq", "sha1sum", "sha256sum", "sh", "sleep", "sort", "split",
            "stat", "strings", "tail", "tar", "tee", "test", "timeout", "touch", "tr",
            "true", "uniq", "wc", "which", "xargs", "yes",
        ]
        let links = applets.map {
            "ln -f \(IshFS.shellQuote(root))/bin/busybox \(IshFS.shellQuote(root))/bin/\(IshFS.shellQuote($0))"
        }.joined(separator: " && ")
        let setup = """
        umount \(IshFS.shellQuote(root))/tmp >/dev/null 2>&1 || true
        umount \(IshFS.shellQuote(root))/workspace >/dev/null 2>&1 || true
        umount \(IshFS.shellQuote(helperMount)) >/dev/null 2>&1 || true
        rm -rf \(IshFS.shellQuote(root))/tmp
        mkdir -p \(IshFS.shellQuote(root))/bin \(IshFS.shellQuote(root))/etc \(IshFS.shellQuote(root))/lib \(IshFS.shellQuote(root))/dev \(IshFS.shellQuote(root))/tmp \(IshFS.shellQuote(root))/workspace \(IshFS.shellQuote(root))/control \(IshFS.shellQuote(helperMount)) && \
        cp /bin/busybox \(IshFS.shellQuote(root))/bin/busybox && \
        chmod 0755 \(IshFS.shellQuote(root))/bin/busybox && \
        cp /lib/ld-musl-aarch64.so.1 \(IshFS.shellQuote(root))/lib/ld-musl-aarch64.so.1 && \
        chmod 0755 \(IshFS.shellQuote(root))/lib/ld-musl-aarch64.so.1 && \
        printf 'root:x:0:0:root:/root:/bin/sh\nlearnfold:x:\(shellUserID):\(shellGroupID):Learnfold:/workspace:/bin/sh\n' > \(IshFS.shellQuote(root))/etc/passwd && \
        printf 'root:x:0:\nlearnfold:x:\(shellGroupID):\n' > \(IshFS.shellQuote(root))/etc/group && \
        \(links) && \
        chmod 0755 \(IshFS.shellQuote(root)) \(IshFS.shellQuote(root))/bin \(IshFS.shellQuote(root))/etc \(IshFS.shellQuote(root))/lib \(IshFS.shellQuote(root))/dev \(IshFS.shellQuote(root))/workspace && \
        chmod 0700 \(IshFS.shellQuote(root))/control && \
        chmod 1777 \(IshFS.shellQuote(root))/tmp && \
        { test -e \(IshFS.shellQuote(root))/dev/null || mknod \(IshFS.shellQuote(root))/dev/null c 1 3; } && \
        chmod 0666 \(IshFS.shellQuote(root))/dev/null && \
        mount -t real \(IshFS.shellQuote(helperURL.deletingLastPathComponent().path)) \(IshFS.shellQuote(helperMount)) && \
        cp \(IshFS.shellQuote(helperMount))/\(IshFS.shellQuote(helperURL.lastPathComponent)) \(IshFS.shellQuote(root))/bin/learnfold-course-exec && \
        chmod 0755 \(IshFS.shellQuote(root))/bin/learnfold-course-exec && \
        umount \(IshFS.shellQuote(helperMount)) && \
        mount -t real \(workspaceReadOnly ? "-o ro " : "")\(IshFS.shellQuote(nativeWorkspacePath)) \(IshFS.shellQuote(root))/workspace && \
        mount -t real \(IshFS.shellQuote(shellTemporaryDirectory.url.path)) \(IshFS.shellQuote(root))/tmp
        """
        let setupResult = await IshFS.run(setup, timeoutMilliseconds: 10_000)
        guard setupResult.exitCode == 0 else {
            _ = await IshFS.run(
                "umount \(IshFS.shellQuote(helperMount)) >/dev/null 2>&1 || true; umount \(IshFS.shellQuote(root))/tmp >/dev/null 2>&1 || true; umount \(IshFS.shellQuote(root))/workspace >/dev/null 2>&1 || true; rm -rf \(IshFS.shellQuote(root))",
                timeoutMilliseconds: 5_000
            )
            try? shellTemporaryDirectory.remove()
            return IshFS.Result(
                exitCode: IshFS.courseShellSetupFailureExitCode,
                output: setupResult.output
            )
        }
        let innerCommand = """
        umask 077
        : > /control/status
        /bin/learnfold-course-exec \(shellUserID) \(shellGroupID) \(timeoutSeconds) 9 \(IshFS.shellQuote(script)) 9>/control/status
        command_status=$?
        printf '\n[learnfold-supervisor-status]\n'
        cat /control/status
        exit "$command_status"
        """
        let command = "chroot \(IshFS.shellQuote(root)) /bin/sh -c \(IshFS.shellQuote(innerCommand))"
        let execution = await IshFS.run(
            command,
            // The bundled helper owns the learner-visible deadline. The
            // embedded supervisor is a final backstop if that helper wedges.
            timeoutMilliseconds: UInt64(timeoutSeconds) * 1_000 + 2_000
        )
        let cleanup = await IshFS.run(
            """
            cleanup_status=0
            umount \(IshFS.shellQuote(root))/tmp >/dev/null 2>&1 || cleanup_status=$?
            cleanup_attempts=0
            while ! umount \(IshFS.shellQuote(root))/workspace >/dev/null 2>&1; do
                cleanup_attempts=$((cleanup_attempts + 1))
                if [ "$cleanup_attempts" -ge 6 ]; then
                    umount \(IshFS.shellQuote(root))/workspace || cleanup_status=$?
                    break
                fi
                sleep 1
            done
            if [ "$cleanup_status" -eq 0 ]; then
                rm -rf \(IshFS.shellQuote(root)) || cleanup_status=$?
            fi
            exit "$cleanup_status"
            """,
            timeoutMilliseconds: 8_000
        )
        var temporaryCleanupError: Error?
        do {
            try shellTemporaryDirectory.remove()
        } catch {
            temporaryCleanupError = error
        }
        guard cleanup.exitCode == 0, temporaryCleanupError == nil else {
            return IshFS.Result(
                exitCode: IshFS.courseShellSetupFailureExitCode,
                output: execution.output
                    + "\nCourse shell cleanup failed: \(cleanup.output)"
                    + (temporaryCleanupError.map { "\nTemporary storage cleanup failed: \($0.localizedDescription)" } ?? ""),
                courseScriptWasDispatched: true
            )
        }
        return IshFS.Result(
            exitCode: execution.exitCode,
            output: execution.output,
            courseScriptWasDispatched: true
        )
    }
}

/// Owns the shell's quota-counted `/tmp` through directory descriptors.
///
/// The workspace is writable by the course agent, so fixed path-based cleanup
/// is unsafe: the agent could replace the temp directory with a symlink aimed
/// outside the workspace. A fresh unguessable child is created directly under
/// a retained workspace descriptor, and cleanup recursively unlinks through
/// that same descriptor.
private final class ConfinedCourseShellTemporaryDirectory: @unchecked Sendable {
    let url: URL

    private let workspaceDirectoryFD: Int32
    private let temporaryDirectoryFD: Int32
    private let name: String
    private var removed = false

    init(workspacePath: String) throws {
        let workspaceFD = Darwin.open(
            workspacePath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard workspaceFD >= 0 else { throw Self.posixError() }
        let createdName = ".learnfold-shell-tmp-\(UUID().uuidString.lowercased())"
        guard mkdirat(workspaceFD, createdName, 0o700) == 0 else {
            let error = Self.posixError()
            Darwin.close(workspaceFD)
            throw error
        }
        let openedTemporaryFD = openat(
            workspaceFD,
            createdName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard openedTemporaryFD >= 0 else {
            let error = Self.posixError()
            _ = unlinkat(workspaceFD, createdName, AT_REMOVEDIR)
            Darwin.close(workspaceFD)
            throw error
        }

        workspaceDirectoryFD = workspaceFD
        temporaryDirectoryFD = openedTemporaryFD
        name = createdName
        url = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(createdName, isDirectory: true)
    }

    deinit {
        Darwin.close(temporaryDirectoryFD)
        Darwin.close(workspaceDirectoryFD)
    }

    func remove() throws {
        guard !removed else { return }
        try Self.removeContents(directoryFD: temporaryDirectoryFD)

        var opened = stat()
        guard fstat(temporaryDirectoryFD, &opened) == 0 else {
            throw Self.posixError()
        }
        var linked = stat()
        guard fstatat(
            workspaceDirectoryFD,
            name,
            &linked,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            // Full course write access includes `.course`: the learner script
            // may unlink or rename the temp directory while `/tmp` still has
            // it mounted. Its retained descriptor has already been emptied,
            // so an absent original name is a successful cleanup.
            if errno == ENOENT {
                removed = true
                return
            }
            throw Self.posixError()
        }
        guard opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ESTALE),
                userInfo: [NSLocalizedDescriptionKey: "The course temporary directory changed during execution."]
            )
        }
        guard unlinkat(workspaceDirectoryFD, name, AT_REMOVEDIR) == 0 else {
            throw Self.posixError()
        }
        removed = true
    }

    private static func removeContents(directoryFD: Int32) throws {
        let iterationFD = dup(directoryFD)
        guard iterationFD >= 0 else { throw posixError() }
        guard let directory = fdopendir(iterationFD) else {
            let error = posixError()
            Darwin.close(iterationFD)
            throw error
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                return
            }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard entryName != ".", entryName != ".." else { continue }

            var metadata = stat()
            guard fstatat(
                directoryFD,
                entryName,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw posixError()
            }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let childFD = openat(
                    directoryFD,
                    entryName,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard childFD >= 0 else { throw posixError() }
                do {
                    try removeContents(directoryFD: childFD)
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)
                guard unlinkat(directoryFD, entryName, AT_REMOVEDIR) == 0 else {
                    throw posixError()
                }
            } else {
                guard unlinkat(directoryFD, entryName, 0) == 0 else {
                    throw posixError()
                }
            }
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
