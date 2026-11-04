//
//  FileNode.swift
//  Broom
//

import Foundation
import Synchronization

/// A file or folder in a scanned tree.
///
/// Threading contract:
/// - While a scan runs, a node's `children`, `size` and `descendantCount` are written only by the
///   scanner worker that owns the node. Results reach other workers through the acquire/release
///   counting on `pendingSubfolders` (see `DiskScanner`).
/// - When the scan finishes, the whole tree is handed to the main actor. After that it is only read
///   or changed there, which is why the editing methods below are `@MainActor`.
nonisolated final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    nonisolated enum Kind: UInt8, Sendable {
        case file
        case directory
        case symlink
        case other
    }

    nonisolated struct Flags: OptionSet, Sendable {
        let rawValue: UInt8

        /// The folder couldn't be opened or listed (usually a permissions issue).
        static let unreadable = Flags(rawValue: 1 << 0)
        /// The folder is on another volume. It is dropped from its parent when the parent is finalized.
        static let otherVolume = Flags(rawValue: 1 << 1)
        /// Listing stopped part-way through, so the folder may be missing some items.
        static let incomplete = Flags(rawValue: 1 << 2)
    }

    let name: String
    let kind: Kind
    private(set) weak var parent: FileNode?
    /// Bytes allocated on disk (for folders, everything inside them).
    private(set) var size: Int64
    /// Number of files and folders inside this one, at any depth.
    private(set) var descendantCount: Int
    /// Sorted biggest first once the scan has finished.
    private(set) var children: [FileNode]
    private(set) var flags: Flags

    /// Subfolders that are still being scanned. Only meaningful while a scan is running.
    let pendingSubfolders = Atomic<Int32>(0)

    init(name: String, kind: Kind, size: Int64 = 0, parent: FileNode?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.parent = parent
        self.descendantCount = 0
        self.children = []
        self.flags = []
    }

    var isDirectory: Bool { kind == .directory }

    /// Folders that macOS shows as a single item (apps, libraries, bundles…).
    var isPackage: Bool {
        guard isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return FileNode.packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    var isUnreadable: Bool { flags.contains(.unreadable) }

    func isDescendant(of ancestor: FileNode) -> Bool {
        var node = parent
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// Ordering used everywhere in the UI: biggest first, then by name so the order is stable.
    static func biggerFirst(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.name < rhs.name
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "xpc", "prefpane", "qlgenerator",
        "mdimporter", "saver", "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "rtfd", "playground", "xcodeproj",
        "xcworkspace", "xcarchive", "dsym", "sparsebundle", "pkg", "mpkg", "docarchive",
    ]

    // MARK: - Scanner only (called by the worker that owns the node)

    func setScannedChildren(_ newChildren: [FileNode]) {
        children = newChildren
    }

    func insertFlags(_ newFlags: Flags) {
        flags.formUnion(newFlags)
    }

    /// Adds up the children and sorts them biggest first. Call it once every subfolder is final.
    func finalizeScannedSubtree() {
        if children.contains(where: { $0.flags.contains(.otherVolume) }) {
            children.removeAll { $0.flags.contains(.otherVolume) }
        }
        var total: Int64 = 0
        var count = 0
        for child in children {
            total &+= child.size
            count &+= child.descendantCount &+ 1
        }
        size = total
        descendantCount = count
        children.sort(by: FileNode.biggerFirst)
    }

    // MARK: - Editing after the scan (main actor only)

    /// Removes `child` from this folder and updates the sizes and sort order of every ancestor.
    @MainActor
    func removeChild(_ child: FileNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        child.parent = nil

        let removedSize = child.size
        let removedCount = child.descendantCount + 1
        var node: FileNode? = self
        while let current = node {
            current.size -= removedSize
            current.descendantCount -= removedCount
            // This folder shrank, so it may need to move down among its siblings.
            current.parent?.children.sort(by: FileNode.biggerFirst)
            node = current.parent
        }
    }
}
