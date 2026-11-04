//
//  DiskScanner.swift
//  Broom
//

import Darwin
import Foundation
import Synchronization

/// What a finished (or cancelled) scan produced.
nonisolated struct ScanOutcome: Sendable {
    let root: FileNode
    let rootPath: String
    let wasCancelled: Bool
    let duration: Duration
    let fileCount: Int
    let directoryCount: Int
    let unreadableCount: Int
}

/// Scans a folder tree in parallel.
///
/// How it works:
/// - A pool of dedicated threads pulls folders from a shared LIFO queue, lists each with
///   `getattrlistbulk`, and pushes the subfolders it finds. A worker keeps one subfolder for itself,
///   so most folders never touch the shared queue.
/// - Folder totals are added up during the scan, not in a separate pass afterwards. Each folder
///   counts the subfolders it is waiting on. The worker that finishes the last one finalizes the
///   parent (sums sizes, sorts children) and carries on up the tree.
/// - The tree is complete the moment the last worker goes idle, and it is then handed to the
///   caller.
/// - Like `fts`, folders are opened relative to their parent (`openat`), so the kernel doesn't
///   re-walk the whole path for every folder. A parent stays open only until its last subfolder
///   has been opened.
/// - On APFS and HFS+, each folder's entry count comes back with its parent's listing, so reading
///   stops without the final empty `getattrlistbulk` call.
///
/// Blocking file-system calls run on these dedicated threads only, never on the main thread and
/// never on Swift's cooperative thread pool.
nonisolated final class DiskScanner: @unchecked Sendable {
    /// Tuning switches, mostly so the benchmark can compare strategies.
    nonisolated struct Options: Sendable {
        nonisolated enum EntryCounts: Sendable {
            /// Use entry counts on APFS and HFS+, whose counts are exact.
            case automatic
            case always
            case never
        }

        /// Open folders relative to their parent (`openat`) instead of by full path.
        var opensRelativeToParent = true
        var entryCounts = EntryCounts.automatic
        /// Most parent folders kept open at once for relative opens. Beyond that, folders are
        /// opened by full path.
        var maximumOpenFolders = 4096
        /// Worker threads; nil picks a number from the CPU count.
        var workerCount: Int?
    }

    let rootPath: String
    let progress = ScanProgress()

    private let root: FileNode
    private let workerCount: Int
    private let options: Options
    private let usesEntryCounts: Bool
    private let openFolders: OpenFolderBudget
    /// Devices we're willing to descend into. Read-only once `init` returns.
    private let allowedDevices: [dev_t]
    /// Folders to skip even though they live on an allowed device. Read-only once `init` returns.
    private let skippedFolders: [InodeKey]
    private let isCancelled = Atomic<Bool>(false)
    private let hardLinks = Mutex<Set<InodeKey>>([])

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    private var queue: [WorkItem] = []
    private var busyWorkers = 0
    private var idleWorkers = 0
    private var liveWorkers = 0
    private var hasStarted = false
    private var startTime = ContinuousClock.now
    private var onFinish: (@Sendable (ScanOutcome) -> Void)?

    private nonisolated struct WorkItem {
        let node: FileNode
        /// The open parent folder to open this one relative to. Nil for the root, or when too many
        /// folders are open already; the folder is then opened by full path.
        var parent: DirectoryHandle?
        /// The parent's device. An entry count is only trusted when the folder turns out to be on
        /// the same device: a firmlink such as /Users reports the count of the wrong folder.
        let parentDevice: dev_t
        /// The folder's entry count from its parent's listing, if the file system gave one.
        let expectedEntries: Int?
        var topLevel: TopLevelCounter?
        let isRoot: Bool
    }

    convenience init(rootPath: String, rootName: String, workerCount: Int? = nil) {
        var options = Options()
        options.workerCount = workerCount
        self.init(rootPath: rootPath, rootName: rootName, options: options)
    }

    init(rootPath: String, rootName: String, options: Options) {
        self.rootPath = rootPath
        self.root = FileNode(name: rootName, kind: .directory, parent: nil)
        self.options = options
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Extra threads keep the SSD busy while others wait on I/O.
        let workers = max(1, options.workerCount ?? min(max(cores * 2, 4), 24))
        self.workerCount = workers

        // Relative opens keep parent folders open, so make room for them. The default limit for
        // apps can be as low as 256 descriptors.
        let descriptorLimit = Self.raiseDescriptorLimit()
        let spare = max(descriptorLimit - 64 - workers * 2, 0)
        self.openFolders = OpenFolderBudget(limit: options.opensRelativeToParent ? min(options.maximumOpenFolders, spare) : 0)

        switch options.entryCounts {
        case .always:
            self.usesEntryCounts = true
        case .never:
            self.usesEntryCounts = false
        case .automatic:
            let values = try? URL(filePath: rootPath).resourceValues(forKeys: [.volumeTypeNameKey])
            let type = values?.volumeTypeName?.lowercased()
            self.usesEntryCounts = type == "apfs" || type == "hfs"
        }

        var devices: [dev_t] = []
        var skipped: [InodeKey] = []
        var rootInfo = stat()
        if stat(rootPath, &rootInfo) == 0 {
            devices.append(rootInfo.st_dev)
        }
        if rootPath == "/" {
            // "/" is the read-only System volume. User data lives on the Data volume, reached
            // through firmlinks such as /Users and /Applications, so allow that device too. But
            // skip its mount point (/System/Volumes/Data) so nothing is counted twice.
            var dataInfo = stat()
            if stat("/System/Volumes/Data", &dataInfo) == 0 {
                devices.append(dataInfo.st_dev)
                skipped.append(InodeKey(device: dataInfo.st_dev, inode: UInt64(dataInfo.st_ino)))
            }
        }
        self.allowedDevices = devices
        self.skippedFolders = skipped
    }

    /// Scans the tree and returns when every worker has stopped. The calling actor is never blocked:
    /// the work runs on the scanner's own threads while this function is suspended.
    func run() async -> ScanOutcome {
        await withCheckedContinuation { continuation in
            start { outcome in continuation.resume(returning: outcome) }
        }
    }

    /// Starts the worker threads. `completion` is called exactly once, on a scanner thread.
    func start(completion: @escaping @Sendable (ScanOutcome) -> Void) {
        condition.lock()
        precondition(!hasStarted, "A DiskScanner can only run once")
        hasStarted = true
        onFinish = completion
        startTime = ContinuousClock.now
        queue.append(WorkItem(node: root, parent: nil, parentDevice: 0, expectedEntries: nil, topLevel: nil, isRoot: true))
        liveWorkers = workerCount
        condition.unlock()

        for index in 0..<workerCount {
            let thread = Thread { [self] in
                self.workerMain()
            }
            thread.name = "Broom scanner \(index + 1)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Asks the workers to stop. The completion handler still runs, with `wasCancelled == true`.
    func cancel() {
        isCancelled.store(true, ordering: .relaxed)
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Workers

    private func workerMain() {
        let reader = BulkDirectoryReader()
        var discovered: [WorkItem] = []
        var next: WorkItem?
        var foldersSinceReport = 0

        while true {
            if next == nil {
                next = takeWork()
            }
            guard let item = next else { break }

            discovered.removeAll(keepingCapacity: true)
            scanFolder(item, with: reader, discovered: &discovered)

            foldersSinceReport += 1
            if foldersSinceReport >= 64 {
                foldersSinceReport = 0
                progress.setCurrentPath(path(of: item.node))
            }

            // Keep going depth-first with one subfolder and share the rest.
            next = discovered.popLast()
            if !discovered.isEmpty || next == nil {
                handOff(discovered, isDoneWithOwnWork: next == nil)
            }
        }
        workerExited()
    }

    /// Blocks until a folder is available. Returns nil once the scan is over or cancelled.
    private func takeWork() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if isCancelled.load(ordering: .relaxed) { return nil }
            if let item = queue.popLast() {
                busyWorkers += 1
                return item
            }
            // Nothing is queued and nobody is working, so nothing more can turn up.
            if busyWorkers == 0 { return nil }
            idleWorkers += 1
            condition.wait()
            idleWorkers -= 1
        }
    }

    private func handOff(_ items: [WorkItem], isDoneWithOwnWork: Bool) {
        condition.lock()
        queue.append(contentsOf: items)
        if isDoneWithOwnWork {
            busyWorkers -= 1
        }
        let isFinished = busyWorkers == 0 && queue.isEmpty
        if idleWorkers > 0 && (!items.isEmpty || isFinished) {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func workerExited() {
        condition.lock()
        liveWorkers -= 1
        var finish: (@Sendable (ScanOutcome) -> Void)?
        if liveWorkers == 0 {
            finish = onFinish
            onFinish = nil
        }
        let elapsed = ContinuousClock.now - startTime
        condition.unlock()

        // The last worker out reports the result. Every other worker has finished touching the
        // tree, and the lock above orders their writes before this read.
        if let finish {
            let snapshot = progress.snapshot()
            finish(ScanOutcome(
                root: root,
                rootPath: rootPath,
                wasCancelled: isCancelled.load(ordering: .relaxed),
                duration: elapsed,
                fileCount: snapshot.files,
                directoryCount: snapshot.directories,
                unreadableCount: snapshot.unreadable
            ))
        }
    }

    // MARK: - Scanning one folder

    private func scanFolder(_ item: WorkItem, with reader: BulkDirectoryReader, discovered: inout [WorkItem]) {
        if isCancelled.load(ordering: .relaxed) { return }
        let node = item.node

        let fd = openFolder(item)
        guard fd >= 0 else {
            node.insertFlags(.unreadable)
            progress.noteUnreadable()
            folderFinished(node, subfolderCount: 0)
            return
        }
        // Handed to the subfolders instead when they open relative to this folder.
        var closesDescriptor = true
        defer {
            if closesDescriptor { close(fd) }
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            node.insertFlags(.unreadable)
            progress.noteUnreadable()
            folderFinished(node, subfolderCount: 0)
            return
        }
        let device = info.st_dev
        if !item.isRoot {
            let identity = InodeKey(device: device, inode: UInt64(info.st_ino))
            if !allowedDevices.contains(device) || skippedFolders.contains(identity) {
                node.insertFlags(.otherVolume)
                folderFinished(node, subfolderCount: 0)
                return
            }
        }

        var children: [FileNode] = []
        var fileBytes: Int64 = 0
        var fileCount = 0
        let expectedEntries = item.isRoot || device != item.parentDevice ? nil : item.expectedEntries

        let error = reader.forEachEntry(in: fd, expectedCount: expectedEntries) { entry in
            if entry.isDirectory {
                // Other volumes and automount triggers are left out (and never opened).
                if entry.isMountPoint { return }
                let name = String(decoding: entry.name, as: UTF8.self)
                let child = FileNode(name: name, kind: .directory, parent: node)
                children.append(child)
                discovered.append(WorkItem(
                    node: child,
                    parent: nil,
                    parentDevice: device,
                    expectedEntries: usesEntryCounts ? entry.entryCount.map { Int($0) } : nil,
                    topLevel: item.topLevel,
                    isRoot: false
                ))
            } else {
                var size = entry.allocatedSize
                if entry.linkCount > 1 && entry.objectType == ObjectType.regular {
                    // Count a hard-linked file once. The other links stay listed, at zero bytes.
                    let key = InodeKey(device: device, inode: entry.fileID)
                    let isFirstLink = hardLinks.withLock { $0.insert(key).inserted }
                    if !isFirstLink { size = 0 }
                }
                let kind: FileNode.Kind
                switch entry.objectType {
                case ObjectType.regular: kind = .file
                case ObjectType.symlink: kind = .symlink
                default: kind = .other
                }
                let name = String(decoding: entry.name, as: UTF8.self)
                children.append(FileNode(name: name, kind: kind, size: size, parent: node))
                fileBytes &+= size
                fileCount += 1
            }
        }

        if error != 0 {
            node.insertFlags(children.isEmpty ? .unreadable : .incomplete)
            if children.isEmpty { progress.noteUnreadable() }
        }
        node.setScannedChildren(children)

        // Keep this folder open so its subfolders can be opened relative to it.
        if !discovered.isEmpty, openFolders.tryAcquire() {
            let handle = DirectoryHandle(fd: fd, budget: openFolders)
            closesDescriptor = false
            for index in discovered.indices {
                discovered[index].parent = handle
            }
        }

        if item.isRoot {
            // Give each top-level folder its own counter so the scanning screen can draw a live ring.
            var counters: [TopLevelCounter] = []
            counters.reserveCapacity(discovered.count)
            for index in discovered.indices {
                let counter = TopLevelCounter(name: discovered[index].node.name)
                counters.append(counter)
                discovered[index].topLevel = counter
            }
            progress.publishTopLevel(counters, rootFileBytes: fileBytes)
        }

        progress.add(files: fileCount, bytes: fileBytes)
        item.topLevel?.add(fileBytes)
        folderFinished(node, subfolderCount: discovered.count)
    }

    private func openFolder(_ item: WorkItem) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (item.isRoot ? 0 : O_NOFOLLOW)
        if item.isRoot {
            return open(rootPath, flags)
        }
        if let parent = item.parent {
            let fd = openat(parent.fd, item.node.name, flags)
            let error = errno
            // Out of descriptors: fall through and try by path rather than give up on the folder.
            if fd >= 0 || (error != EMFILE && error != ENFILE) {
                return fd
            }
        }
        return open(path(of: item.node), flags)
    }

    /// The full path of a node in the tree being scanned. Node names and parents never change
    /// during a scan, so any worker can read them.
    private func path(of node: FileNode) -> String {
        var names: [String] = []
        var cursor = node
        while let parent = cursor.parent {
            names.append(cursor.name)
            cursor = parent
        }
        var path = rootPath
        for name in names.reversed() {
            path = PathUtilities.join(path, name)
        }
        return path
    }

    /// Raises the soft limit on open descriptors as far as allowed (at most 10,240, the macOS
    /// maximum) and returns the limit in effect.
    private static func raiseDescriptorLimit() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        let target = min(limit.rlim_max, 10_240)
        if limit.rlim_cur < target {
            var raised = limit
            raised.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 {
                return Int(target)
            }
        }
        return Int(min(limit.rlim_cur, 10_240))
    }

    /// Records that `node` has been listed. When it has no subfolders left to wait for, it's
    /// finalized, and so is each ancestor whose last outstanding subfolder this was.
    private func folderFinished(_ node: FileNode, subfolderCount: Int) {
        if subfolderCount > 0 {
            // Published to the child workers by the queue lock (or program order for the
            // subfolder this worker keeps).
            node.pendingSubfolders.store(Int32(subfolderCount), ordering: .relaxed)
            return
        }

        var current = node
        while true {
            current.finalizeScannedSubtree()
            guard let parent = current.parent else { return }
            // Release our writes to whoever finalizes the parent, and acquire our siblings' writes
            // in case that's us.
            let remaining = parent.pendingSubfolders.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue
            if remaining != 0 { return }
            current = parent
        }
    }
}

/// An open folder that its subfolders are opened relative to. It's closed when the last
/// reference goes away, which is once the last of those subfolders has been opened.
nonisolated final class DirectoryHandle: Sendable {
    let fd: Int32
    private let budget: OpenFolderBudget

    init(fd: Int32, budget: OpenFolderBudget) {
        self.fd = fd
        self.budget = budget
    }

    deinit {
        close(fd)
        budget.release()
    }
}

/// Caps how many folders stay open at once for relative opens.
nonisolated final class OpenFolderBudget: Sendable {
    let limit: Int
    private let inUse = Atomic<Int>(0)

    init(limit: Int) {
        self.limit = limit
    }

    func tryAcquire() -> Bool {
        if inUse.wrappingAdd(1, ordering: .relaxed).newValue <= limit {
            return true
        }
        _ = inUse.wrappingSubtract(1, ordering: .relaxed)
        return false
    }

    func release() {
        _ = inUse.wrappingSubtract(1, ordering: .relaxed)
    }
}

/// Identifies a file across volumes. Used to spot hard links and to skip specific folders.
nonisolated struct InodeKey: Hashable, Sendable {
    let device: dev_t
    let inode: UInt64
}

nonisolated enum PathUtilities {
    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// A file URL's path without the trailing slash that `path(percentEncoded:)` keeps for folders.
    static func path(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }
}
