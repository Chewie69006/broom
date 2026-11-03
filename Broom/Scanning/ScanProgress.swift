//
//  ScanProgress.swift
//  Broom
//

import Synchronization

/// Live counters that scanner threads update and the UI polls. Every member is thread-safe.
nonisolated final class ScanProgress: Sendable {
    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let unreadable = Atomic<Int>(0)
    private let shared = Mutex(Shared())

    private nonisolated struct Shared: Sendable {
        var topLevel: [TopLevelCounter] = []
        var rootFileBytes: Int64 = 0
        var currentPath = ""
    }

    func add(files fileCount: Int, bytes byteCount: Int64) {
        _ = directories.wrappingAdd(1, ordering: .relaxed)
        if fileCount != 0 { _ = files.wrappingAdd(fileCount, ordering: .relaxed) }
        if byteCount != 0 { _ = bytes.wrappingAdd(byteCount, ordering: .relaxed) }
    }

    func noteUnreadable() {
        _ = unreadable.wrappingAdd(1, ordering: .relaxed)
    }

    func publishTopLevel(_ counters: [TopLevelCounter], rootFileBytes: Int64) {
        shared.withLock {
            $0.topLevel = counters
            $0.rootFileBytes = rootFileBytes
        }
    }

    func setCurrentPath(_ path: String) {
        shared.withLock { $0.currentPath = path }
    }

    var unreadableCount: Int { unreadable.load(ordering: .relaxed) }

    func snapshot() -> ScanSnapshot {
        let (topLevel, rootFileBytes, currentPath) = shared.withLock { ($0.topLevel, $0.rootFileBytes, $0.currentPath) }
        var folders = topLevel.enumerated().map { index, counter in
            ScanSnapshot.TopFolder(id: index, name: counter.name, bytes: counter.bytes.load(ordering: .relaxed))
        }
        if rootFileBytes > 0 {
            folders.append(ScanSnapshot.TopFolder(id: folders.count, name: "Files", bytes: rootFileBytes))
        }
        return ScanSnapshot(
            files: files.load(ordering: .relaxed),
            directories: directories.load(ordering: .relaxed),
            bytes: bytes.load(ordering: .relaxed),
            unreadable: unreadable.load(ordering: .relaxed),
            currentPath: currentPath,
            topFolders: folders
        )
    }
}

/// Running byte total for one top-level folder, used to draw the live ring while scanning.
nonisolated final class TopLevelCounter: Sendable {
    let name: String
    let bytes = Atomic<Int64>(0)

    init(name: String) {
        self.name = name
    }

    func add(_ value: Int64) {
        if value != 0 { _ = bytes.wrappingAdd(value, ordering: .relaxed) }
    }
}

/// A copy of the progress counters at one moment, safe to hand to the UI.
nonisolated struct ScanSnapshot: Sendable {
    nonisolated struct TopFolder: Sendable, Identifiable {
        let id: Int
        let name: String
        let bytes: Int64
    }

    var files = 0
    var directories = 0
    var bytes: Int64 = 0
    var unreadable = 0
    var currentPath = ""
    var topFolders: [TopFolder] = []
}
