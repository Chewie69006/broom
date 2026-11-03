//
//  BrowserModel.swift
//  Broom
//

import Foundation
import Observation

/// State for browsing a finished scan: the focused folder, history, hover and selection, and the
/// collector.
///
/// Lives on the main actor (the project's default isolation). The scanned tree belongs to the main
/// actor once the scan hands it over, so every tree edit happens here.
@Observable
final class BrowserModel {
    static let maximumListRows = 400

    let target: ScanTarget
    let root: FileNode
    let rootPath: String
    let scanDuration: Duration
    let unreadableCount: Int

    private(set) var current: FileNode
    private(set) var layout: SunburstLayout
    private(set) var transition: SunburstTransition? = nil

    /// The item under the pointer, in the chart or the list.
    var hovered: FileNode? = nil
    /// The item picked with a click or the arrow keys.
    var selected: FileNode? = nil
    /// The file shown in Quick Look, if any.
    var quickLookURL: URL? = nil

    private(set) var collected: [FileNode] = []
    private(set) var isDeleting = false
    var deletionError: String? = nil
    /// Bumped whenever the tree changes, so views showing node data refresh.
    private(set) var treeVersion = 0

    @ObservationIgnored private var backStack: [FileNode] = []
    @ObservationIgnored private var forwardStack: [FileNode] = []
    @ObservationIgnored private var transitionCounter = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>? = nil
    /// Mirrors the history stacks so menus and buttons can observe them.
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    init(outcome: ScanOutcome, target: ScanTarget) {
        self.target = target
        self.root = outcome.root
        self.rootPath = outcome.rootPath
        self.scanDuration = outcome.duration
        self.unreadableCount = outcome.unreadableCount
        self.current = outcome.root
        self.layout = SunburstLayout(center: outcome.root)
        beginTransition(.reveal, duration: 0.7)
    }

    // MARK: - Derived state

    var canGoUp: Bool { current.parent != nil }

    /// Folders from the root down to the current one, for the path bar.
    var trail: [FileNode] {
        var nodes: [FileNode] = []
        var node: FileNode? = current
        while let folder = node {
            nodes.append(folder)
            node = folder.parent
        }
        return nodes.reversed()
    }

    /// Rows for the side list (the biggest children of the current folder).
    var listRows: ArraySlice<FileNode> {
        current.children.prefix(Self.maximumListRows)
    }

    var hiddenListRowCount: Int { max(current.children.count - Self.maximumListRows, 0) }

    var hiddenListRowSize: Int64 {
        current.children.dropFirst(Self.maximumListRows).reduce(0) { $0 + $1.size }
    }

    var collectedSize: Int64 { collected.reduce(0) { $0 + $1.size } }

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { $0 === node || node.isDescendant(of: $0) }
    }

    /// Whether `node` is still part of the scanned tree (it hasn't been deleted).
    func isAttached(_ node: FileNode) -> Bool {
        node === root || node.isDescendant(of: root)
    }

    // MARK: - Paths

    func path(for node: FileNode) -> String {
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

    func url(for node: FileNode) -> URL {
        URL(filePath: path(for: node), directoryHint: node.isDirectory ? .isDirectory : .notDirectory)
    }

    /// Finds the node for a file URL inside the scanned folder (used for drag and drop).
    func node(for url: URL) -> FileNode? {
        let path = PathUtilities.path(of: url)
        if path == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: - Navigation

    /// Clicking an item: folders zoom in, files get selected.
    func activate(_ node: FileNode) {
        if node.isDirectory && !node.children.isEmpty {
            open(node)
        } else {
            selected = node
        }
    }

    func open(_ folder: FileNode) {
        guard folder.isDirectory, folder !== current, isAttached(folder) else { return }
        navigate(to: folder, recordHistory: true)
    }

    func goUp() {
        guard let parent = current.parent else { return }
        let child = current
        navigate(to: parent, recordHistory: true)
        selected = child
    }

    func goToRoot() {
        guard current !== root else { return }
        navigate(to: root, recordHistory: true)
    }

    func goBack() {
        guard let destination = backStack.popLast() else { return }
        forwardStack.append(current)
        navigate(to: destination, recordHistory: false)
    }

    func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        backStack.append(current)
        navigate(to: destination, recordHistory: false)
    }

    func moveSelection(by offset: Int) {
        let rows = listRows
        guard !rows.isEmpty else { return }
        if let selected, let index = rows.firstIndex(where: { $0 === selected }) {
            let newIndex = min(max(index + offset, rows.startIndex), rows.endIndex - 1)
            self.selected = rows[newIndex]
        } else {
            self.selected = offset >= 0 ? rows.first : rows.last
        }
    }

    /// Return / → : zoom into the selected folder.
    func openSelection() {
        guard let selected else { return }
        if selected.isDirectory {
            open(selected)
        }
    }

    private func navigate(to destination: FileNode, recordHistory: Bool) {
        guard destination !== current else { return }
        if recordHistory {
            backStack.append(current)
            forwardStack.removeAll()
        }
        let previous = current
        current = destination
        selected = nil
        hovered = nil
        layout = SunburstLayout(center: destination)
        updateHistoryFlags()

        if let range = SunburstLayout.angularRange(of: destination, within: previous) {
            beginTransition(.zoomIn(start: range.start, end: range.end, levels: range.levels), duration: 0.5)
        } else if let range = SunburstLayout.angularRange(of: previous, within: destination) {
            beginTransition(.zoomOut(start: range.start, end: range.end, levels: range.levels), duration: 0.5)
        } else {
            beginTransition(.fade, duration: 0.3)
        }
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    private func beginTransition(_ kind: SunburstTransition.Kind, duration: TimeInterval) {
        transitionCounter += 1
        let transition = SunburstTransition(id: transitionCounter, kind: kind, startDate: .now, duration: duration)
        self.transition = transition
        transitionTask?.cancel()
        // Clearing the transition pauses the chart's animation timeline once it has finished.
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.transition?.id == transition.id else { return }
            self.transition = nil
        }
    }

    // MARK: - Collector

    func collect(_ nodes: [FileNode]) {
        for node in nodes {
            guard node !== root, isAttached(node), !isCollected(node) else { continue }
            // Collecting a folder replaces anything already collected inside it.
            collected.removeAll { $0.isDescendant(of: node) }
            collected.append(node)
        }
    }

    func collect(urls: [URL]) {
        collect(urls.compactMap { node(for: $0) })
    }

    func uncollect(_ node: FileNode) {
        collected.removeAll { $0 === node }
    }

    func clearCollector() {
        collected.removeAll()
    }

    /// Moves everything in the collector to the Trash, or deletes it outright.
    /// The file operations run off the main actor; the tree is updated here afterwards.
    func deleteCollected(permanently: Bool) {
        guard !collected.isEmpty, !isDeleting else { return }
        let items = collected
        let urls = items.map { url(for: $0) }
        isDeleting = true
        Task {
            let failure = await FileRemover.remove(urls, permanently: permanently)
            self.finishDeleting(items, urls: urls, failure: failure)
        }
    }

    private func finishDeleting(_ items: [FileNode], urls: [URL], failure: String?) {
        isDeleting = false
        var removed: [FileNode] = []
        for (node, url) in zip(items, urls) where !FileRemover.itemExists(at: url) {
            removed.append(node)
        }
        // If we're inside something that's gone, back out to the folder that held it.
        var focus = current
        for node in removed where focus === node || focus.isDescendant(of: node) {
            if let parent = node.parent { focus = parent }
        }
        for node in removed {
            node.parent?.removeChild(node)
        }
        if !removed.isEmpty {
            current = isAttached(focus) ? focus : root
            pruneDetachedReferences()
            treeVersion += 1
            layout = SunburstLayout(center: current)
            beginTransition(.fade, duration: 0.3)
        }
        if removed.count < items.count {
            deletionError = failure ?? "Some items couldn't be removed."
        }
    }

    /// After a deletion, drops every reference into the removed subtrees.
    private func pruneDetachedReferences() {
        backStack.removeAll { !isAttached($0) }
        forwardStack.removeAll { !isAttached($0) }
        updateHistoryFlags()
        collected.removeAll { !isAttached($0) }
        if let hovered, !isAttached(hovered) { self.hovered = nil }
        if let selected, !isAttached(selected) { self.selected = nil }
        quickLookURL = nil
    }
}

/// File operations for deleting items. They block, so they run off the main actor.
nonisolated enum FileRemover {
    /// Returns a description of the first failure, if any.
    @concurrent
    static func remove(_ urls: [URL], permanently: Bool) async -> String? {
        var firstFailure: String?
        for url in urls {
            do {
                if permanently {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = error.localizedDescription
                }
            }
        }
        return firstFailure
    }

    /// True if something exists at `url`. Symlinks aren't followed.
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }
}
