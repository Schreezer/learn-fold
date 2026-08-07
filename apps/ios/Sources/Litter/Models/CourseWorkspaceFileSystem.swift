import Darwin
import Foundation

/// Descriptor-confined file I/O for app-owned operations inside a course.
///
/// `course_bash` intentionally has full write access to ordinary course files.
/// The shell denies symlink creation, but app-side ingestion must still defend
/// against legacy, preexisting, or concurrently swapped hostile paths. Every
/// intermediate component here is therefore opened with `O_NOFOLLOW`.
struct CourseWorkspaceFileSystem: Sendable {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func ensureDirectory(_ relativePath: String) throws {
        let fd = try openDirectory(relativePath, create: true)
        Darwin.close(fd)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let (parentFD, leaf) = try openParent(of: relativePath, create: true)
        defer { Darwin.close(parentFD) }
        let temporaryName = ".learnfold-write-\(UUID().uuidString.lowercased())"
        let fd = openat(
            parentFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { throw Self.posixError() }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(fd)
            if shouldRemoveTemporary {
                _ = unlinkat(parentFD, temporaryName, 0)
            }
        }
        try Self.writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw Self.posixError() }
        guard renameat(parentFD, temporaryName, parentFD, leaf) == 0 else {
            throw Self.posixError()
        }
        shouldRemoveTemporary = false
    }

    func read(_ relativePath: String, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw Self.posixError(EFBIG) }
        let (parentFD, leaf) = try openParent(of: relativePath, create: false)
        defer { Darwin.close(parentFD) }
        // O_NONBLOCK prevents a hostile/preexisting FIFO from hanging before
        // readRegularFile can reject every non-regular inode.
        let fd = openat(
            parentFD,
            leaf,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw Self.posixError() }
        defer { Darwin.close(fd) }
        return try Self.readRegularFile(fd: fd, maximumBytes: maximumBytes)
    }

    func copyExternalFile(
        from sourceURL: URL,
        preferredFilename: String,
        into relativeDirectory: String,
        maximumBytes: Int
    ) throws -> String {
        let sourceFD = Darwin.open(sourceURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { throw Self.posixError() }
        defer { Darwin.close(sourceFD) }
        var metadata = stat()
        guard fstat(sourceFD, &metadata) == 0 else { throw Self.posixError() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw Self.posixError(EFBIG)
        }

        let directoryFD = try openDirectory(relativeDirectory, create: true)
        defer { Darwin.close(directoryFD) }
        let filename = try Self.availableFilename(preferredFilename, in: directoryFD)
        let destinationFD = openat(
            directoryFD,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationFD >= 0 else { throw Self.posixError() }
        var shouldRemove = true
        defer {
            Darwin.close(destinationFD)
            if shouldRemove { _ = unlinkat(directoryFD, filename, 0) }
        }
        try Self.copyRegularFile(
            from: sourceFD,
            to: destinationFD,
            maximumBytes: maximumBytes
        )
        guard fsync(destinationFD) == 0 else { throw Self.posixError() }
        shouldRemove = false
        return filename
    }

    func writeUnique(
        _ data: Data,
        preferredFilename: String,
        into relativeDirectory: String
    ) throws -> String {

        let directoryFD = try openDirectory(relativeDirectory, create: true)
        defer { Darwin.close(directoryFD) }
        let filename = try Self.availableFilename(
            preferredFilename,
            in: directoryFD
        )
        let destinationFD = openat(
            directoryFD,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationFD >= 0 else { throw Self.posixError() }
        var shouldRemove = true
        defer {
            Darwin.close(destinationFD)
            if shouldRemove { _ = unlinkat(directoryFD, filename, 0) }
        }
        try Self.writeAll(data, to: destinationFD)
        guard fsync(destinationFD) == 0 else { throw Self.posixError() }
        shouldRemove = false
        return filename
    }

    func contentsOfDirectory(_ relativePath: String) throws -> [String] {
        let fd = try openDirectory(relativePath, create: false)
        defer { Darwin.close(fd) }
        return try Self.directoryEntries(fd: fd)
    }

    func byteCount(_ relativePath: String) throws -> Int {
        let fd: Int32
        do {
            fd = try openDirectory(relativePath, create: false)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ENOENT) {
            return 0
        }
        defer { Darwin.close(fd) }
        return try Self.recursiveByteCount(fd: fd)
    }

    func containsSymbolicLink() throws -> Bool {
        let fd = try openRoot()
        defer { Darwin.close(fd) }
        return try Self.recursiveContainsSymbolicLink(fd: fd)
    }

    @discardableResult
    func removeSymbolicLinks() throws -> Int {
        let fd = try openRoot()
        defer { Darwin.close(fd) }
        return try Self.recursiveRemoveSymbolicLinks(fd: fd)
    }

    func remove(_ relativePath: String, isDirectory: Bool) {
        guard let opened = try? openParent(of: relativePath, create: false) else { return }
        defer { Darwin.close(opened.fd) }
        _ = unlinkat(opened.fd, opened.leaf, isDirectory ? AT_REMOVEDIR : 0)
    }

    /// Removes one exact descendant without following symlinks at any level.
    /// This is used for app-owned recovery and approval control planes, which
    /// can contain nested directories and must not survive workspace deletion.
    func removeRecursively(_ relativePath: String) throws {
        let opened: (fd: Int32, leaf: String)
        do {
            opened = try openParent(of: relativePath, create: false)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ENOENT) {
            return
        }
        defer { Darwin.close(opened.fd) }

        var metadata = stat()
        guard fstatat(opened.fd, opened.leaf, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        if metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            guard unlinkat(opened.fd, opened.leaf, 0) == 0 || errno == ENOENT else {
                throw Self.posixError()
            }
            return
        }

        let directoryFD = openat(
            opened.fd,
            opened.leaf,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        do {
            try Self.recursiveRemoveContents(fd: directoryFD)
        } catch {
            Darwin.close(directoryFD)
            throw error
        }
        Darwin.close(directoryFD)
        guard unlinkat(opened.fd, opened.leaf, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw Self.posixError()
        }
    }

    private func openRoot() throws -> Int32 {
        let fd = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw Self.posixError() }
        return fd
    }

    private func openDirectory(_ relativePath: String, create: Bool) throws -> Int32 {
        let components = try Self.components(relativePath, allowEmpty: true)
        var currentFD = try openRoot()
        do {
            for component in components {
                if create, mkdirat(currentFD, component, 0o700) != 0, errno != EEXIST {
                    throw Self.posixError()
                }
                let nextFD = openat(
                    currentFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard nextFD >= 0 else { throw Self.posixError() }
                Darwin.close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            Darwin.close(currentFD)
            throw error
        }
    }

    private func openParent(
        of relativePath: String,
        create: Bool
    ) throws -> (fd: Int32, leaf: String) {
        let components = try Self.components(relativePath, allowEmpty: false)
        guard let leaf = components.last else { throw Self.posixError(EINVAL) }
        let parent = components.dropLast().joined(separator: "/")
        return (try openDirectory(parent, create: create), leaf)
    }

    private static func components(
        _ relativePath: String,
        allowEmpty: Bool
    ) throws -> [String] {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
            throw posixError(EINVAL)
        }
        if relativePath.isEmpty {
            guard allowEmpty else { throw posixError(EINVAL) }
            return []
        }
        let result = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard result.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(NAME_MAX)
        }) else { throw posixError(EINVAL) }
        return result
    }

    private static func availableFilename(
        _ preferred: String,
        in directoryFD: Int32
    ) throws -> String {
        let last = URL(fileURLWithPath: preferred).lastPathComponent
        let safe = last.isEmpty || last == "." || last == ".." || last.contains("\0")
            ? "source"
            : String(last.prefix(180))
        let path = safe as NSString
        let base = path.deletingPathExtension.isEmpty ? "source" : path.deletingPathExtension
        let ext = path.pathExtension
        for index in 0..<10_000 {
            let stem = index == 0 ? base : "\(base)-\(index + 1)"
            let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
            guard candidate.utf8.count <= Int(NAME_MAX) else { continue }
            var metadata = stat()
            if fstatat(directoryFD, candidate, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return candidate }
                throw posixError()
            }
        }
        throw posixError(EEXIST)
    }

    private static func readRegularFile(fd: Int32, maximumBytes: Int) throws -> Data {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw posixError(EFBIG)
        }
        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard result.count <= maximumBytes - count else { throw posixError(EFBIG) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError(EIO) }
                offset += count
            }
        }
    }

    private static func copyRegularFile(
        from sourceFD: Int32,
        to destinationFD: Int32,
        maximumBytes: Int
    ) throws {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = Darwin.read(sourceFD, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard total <= maximumBytes - count else { throw posixError(EFBIG) }
            var written = 0
            while written < count {
                if Task.isCancelled { throw CancellationError() }
                let amount = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(
                        destinationFD,
                        rawBuffer.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard amount > 0 else { throw posixError(EIO) }
                written += amount
            }
            total += count
        }
    }

    private static func directoryEntries(fd: Int32) throws -> [String] {
        let iterationFD = dup(fd)
        guard iterationFD >= 0 else { throw posixError() }
        guard let directory = fdopendir(iterationFD) else {
            let error = posixError()
            Darwin.close(iterationFD)
            throw error
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    private static func recursiveByteCount(fd: Int32) throws -> Int {
        var total = 0
        for name in try directoryEntries(fd: fd) {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError()
            }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let childFD = openat(
                    fd,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard childFD >= 0 else { throw posixError() }
                let childBytes: Int
                do {
                    childBytes = try recursiveByteCount(fd: childFD)
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)
                let (next, overflow) = total.addingReportingOverflow(childBytes)
                guard !overflow else { throw posixError(EFBIG) }
                total = next
            } else if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                guard metadata.st_size >= 0,
                      let size = Int(exactly: metadata.st_size) else {
                    throw posixError(EFBIG)
                }
                let (next, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { throw posixError(EFBIG) }
                total = next
            }
        }
        return total
    }

    private static func recursiveContainsSymbolicLink(fd: Int32) throws -> Bool {
        for name in try directoryEntries(fd: fd) {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError()
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { return true }
            if kind == mode_t(S_IFDIR) {
                let childFD = openat(
                    fd,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard childFD >= 0 else { throw posixError() }
                let contains: Bool
                do {
                    contains = try recursiveContainsSymbolicLink(fd: childFD)
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)
                if contains { return true }
            }
        }
        return false
    }

    private static func recursiveRemoveSymbolicLinks(fd: Int32) throws -> Int {
        var removed = 0
        for name in try directoryEntries(fd: fd) {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError()
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else {
                    throw posixError()
                }
                removed += 1
            } else if kind == mode_t(S_IFDIR) {
                let childFD = openat(
                    fd,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard childFD >= 0 else {
                    if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { continue }
                    throw posixError()
                }
                do {
                    removed += try recursiveRemoveSymbolicLinks(fd: childFD)
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)
            }
        }
        return removed
    }

    private static func recursiveRemoveContents(fd: Int32) throws {
        for name in try directoryEntries(fd: fd) {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError()
            }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let childFD = openat(
                    fd,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard childFD >= 0 else {
                    if errno == ENOENT { continue }
                    throw posixError()
                }
                do {
                    try recursiveRemoveContents(fd: childFD)
                } catch {
                    Darwin.close(childFD)
                    throw error
                }
                Darwin.close(childFD)
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
                    throw posixError()
                }
            } else {
                guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else {
                    throw posixError()
                }
            }
        }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
