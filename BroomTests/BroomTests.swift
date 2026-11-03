//
//  BroomTests.swift
//  BroomTests
//
//  Created by David Rodrigues on 03/11/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import Broom

// MARK: - Scanner

@MainActor
struct ScannerTests {
    /// Builds this tree in a temporary folder:
    ///
    ///     big.bin            1 MB
    ///     small.txt          100 B
    ///     link            -> big.bin (symlink)
    ///     empty/
    ///     docs/
    ///       a.txt            10 KB
    ///       b.txt            20 KB
    ///       hardlink.bin  == big.bin (hard link)
    ///       nested/
    ///         c.bin          300 KB
    private func makeFixture() throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "BroomTests-\(UUID().uuidString)")
        let docs = root.appending(path: "docs")
        let nested = docs.appending(path: "nested")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)

        func write(_ url: URL, bytes: Int) throws {
            try Data(repeating: 0x5A, count: bytes).write(to: url)
        }
        try write(root.appending(path: "big.bin"), bytes: 1_000_000)
        try write(root.appending(path: "small.txt"), bytes: 100)
        try write(docs.appending(path: "a.txt"), bytes: 10_000)
        try write(docs.appending(path: "b.txt"), bytes: 20_000)
        try write(nested.appending(path: "c.bin"), bytes: 300_000)
        try fileManager.linkItem(at: root.appending(path: "big.bin"), to: docs.appending(path: "hardlink.bin"))
        try fileManager.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "big.bin"))
        return root
    }

    private func child(_ node: FileNode, _ name: String) -> FileNode? {
        node.children.first { $0.name == name }
    }

    @Test func scanBuildsTheTreeWithCorrectTotals() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let scanner = DiskScanner(rootPath: PathUtilities.path(of: fixture), rootName: "fixture", workerCount: 4)
        let outcome = await scanner.run()
        let root = outcome.root

        #expect(!outcome.wasCancelled)
        #expect(Set(root.children.map(\.name)) == ["big.bin", "small.txt", "link", "empty", "docs"])
        #expect(root.descendantCount == 10)

        let docs = try #require(child(root, "docs"))
        let nested = try #require(child(docs, "nested"))
        let big = try #require(child(root, "big.bin"))
        let hardLink = try #require(child(docs, "hardlink.bin"))

        // Every folder's size is the sum of its children, and children are sorted biggest first.
        for folder in [root, docs, nested] {
            #expect(folder.size == folder.children.reduce(0) { $0 + $1.size })
            #expect(zip(folder.children, folder.children.dropFirst()).allSatisfy { $0.size >= $1.size })
            #expect(folder.children.allSatisfy { $0.parent === folder })
        }

        #expect(nested.size >= 300_000)
        // The hard-linked file is counted once.
        #expect((big.size == 0) != (hardLink.size == 0))
        #expect(max(big.size, hardLink.size) >= 1_000_000)

        #expect(child(root, "link")?.kind == .symlink)
        #expect(child(root, "empty")?.isDirectory == true)
        #expect(child(root, "empty")?.size == 0)
    }

    @Test func cancelledScanReportsCancellation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let scanner = DiskScanner(rootPath: PathUtilities.path(of: fixture), rootName: "fixture", workerCount: 2)
        scanner.cancel()
        let outcome = await scanner.run()
        #expect(outcome.wasCancelled)
    }

    @Test func unreadableRootIsFlagged() async {
        let scanner = DiskScanner(rootPath: "/this/path/does/not/exist-\(UUID().uuidString)", rootName: "missing")
        let outcome = await scanner.run()
        #expect(outcome.root.isUnreadable)
        #expect(outcome.root.size == 0)
        #expect(outcome.unreadableCount == 1)
    }
}

// MARK: - Synthetic trees

/// root (1000)
///   a (800): a1 600, a2 200
///   b 150
///   t0…t49, 1 byte each (too thin to draw)
@MainActor
private func makeTree() -> FileNode {
    let root = FileNode(name: "root", kind: .directory, parent: nil)
    let a = FileNode(name: "a", kind: .directory, parent: root)
    let a1 = FileNode(name: "a1", kind: .file, size: 600, parent: a)
    let a2 = FileNode(name: "a2", kind: .file, size: 200, parent: a)
    a.setScannedChildren([a2, a1])
    a.finalizeScannedSubtree()
    let b = FileNode(name: "b", kind: .file, size: 150, parent: root)
    let tiny = (0..<50).map { FileNode(name: "t\($0)", kind: .file, size: 1, parent: root) }
    root.setScannedChildren(tiny + [b, a])
    root.finalizeScannedSubtree()
    return root
}

@MainActor
private func makeBrowser() -> BrowserModel {
    let root = makeTree()
    let outcome = ScanOutcome(
        root: root, rootPath: "/tmp/root", wasCancelled: false, duration: .zero,
        fileCount: 0, directoryCount: 0, unreadableCount: 0
    )
    return BrowserModel(outcome: outcome, target: ScanTarget(url: URL(filePath: "/tmp/root")))
}

@MainActor
private func named(_ name: String, in folder: FileNode) -> FileNode {
    folder.children.first { $0.name == name }!
}

// MARK: - Layout

@MainActor
struct LayoutTests {
    @Test func finalizeSortsAndSums() {
        let root = makeTree()
        #expect(root.size == 1000)
        #expect(root.descendantCount == 54)
        #expect(root.children.first?.name == "a")
        #expect(named("a", in: root).children.map(\.name) == ["a1", "a2"])
    }

    @Test func innerRingCoversTheWholeCircle() {
        let layout = SunburstLayout(center: makeTree())
        let ring = layout.rings[0]
        #expect(ring.first?.startAngle == 0)
        #expect(abs((ring.last?.endAngle ?? 0) - SunburstLayout.fullCircle) < 1e-9)
        #expect(zip(ring, ring.dropFirst()).allSatisfy { abs($0.endAngle - $1.startAngle) < 1e-9 })
    }

    @Test func thinItemsAreMerged() throws {
        let layout = SunburstLayout(center: makeTree())
        let ring = layout.rings[0]
        #expect(ring.count == 3)
        let bucket = try #require(ring.last)
        #expect(bucket.isSmallerItems)
        #expect(bucket.hiddenCount == 50)
        #expect(bucket.hiddenSize == 50)
    }

    @Test func childWedgesSitInsideTheirParent() throws {
        let root = makeTree()
        let layout = SunburstLayout(center: root)
        let a = named("a", in: root)
        let aPosition = try #require(layout.position(of: a))
        let aSegment = try #require(layout.segment(ring: aPosition.ring, index: aPosition.index))
        for segment in layout.rings[1] {
            #expect(segment.startAngle >= aSegment.startAngle - 1e-9)
            #expect(segment.endAngle <= aSegment.endAngle + 1e-9)
        }
    }

    @Test func hitTestingFindsWedges() throws {
        let root = makeTree()
        let layout = SunburstLayout(center: root)
        let index = try #require(layout.hitTest(angle: 0.1, ring: 0))
        #expect(layout.rings[0][index].node === named("a", in: root))
        #expect(layout.hitTest(angle: 1, ring: 5) == nil)
    }

    @Test func angularRangeOfDescendant() throws {
        let root = makeTree()
        let a2 = named("a2", in: named("a", in: root))
        let range = try #require(SunburstLayout.angularRange(of: a2, within: root))
        #expect(range.levels == 2)
        #expect(abs(range.start - 0.6 * SunburstLayout.fullCircle) < 1e-9)
        #expect(abs(range.end - 0.8 * SunburstLayout.fullCircle) < 1e-9)
    }

    @Test func geometryRoundTripsRadius() throws {
        let geometry = SunburstGeometry(size: CGSize(width: 600, height: 600))
        for depth in [0.0, 0.5, 1.0, 2.25, 4.0, 5.5] {
            let radius = geometry.radius(atDepth: depth)
            let back = try #require(geometry.depth(atRadius: radius))
            #expect(abs(back - depth) < 1e-6)
        }
        let top = geometry.polar(of: CGPoint(x: 300, y: 100))
        #expect(abs(top.angle) < 1e-9)
        let right = geometry.polar(of: CGPoint(x: 500, y: 300))
        #expect(abs(right.angle - Double.pi / 2) < 1e-9)
    }
}

// MARK: - Browsing

@MainActor
struct BrowserTests {
    @Test func navigationKeepsHistory() {
        let browser = makeBrowser()
        let a = named("a", in: browser.root)

        browser.open(a)
        #expect(browser.current === a)
        #expect(browser.canGoBack)
        #expect(browser.trail.map(\.name) == ["root", "a"])

        browser.goBack()
        #expect(browser.current === browser.root)
        #expect(browser.canGoForward)

        browser.goForward()
        #expect(browser.current === a)

        browser.goUp()
        #expect(browser.current === browser.root)
        #expect(browser.selected === a)
    }

    @Test func filesAreSelectedNotOpened() {
        let browser = makeBrowser()
        let b = named("b", in: browser.root)
        browser.activate(b)
        #expect(browser.current === browser.root)
        #expect(browser.selected === b)
    }

    @Test func keyboardSelectionMovesThroughTheList() {
        let browser = makeBrowser()
        browser.moveSelection(by: 1)
        #expect(browser.selected?.name == "a")
        browser.moveSelection(by: 1)
        #expect(browser.selected?.name == "b")
        browser.moveSelection(by: -5)
        #expect(browser.selected?.name == "a")
    }

    @Test func pathsAndLookups() {
        let browser = makeBrowser()
        let a1 = named("a1", in: named("a", in: browser.root))
        #expect(browser.path(for: a1) == "/tmp/root/a/a1")
        #expect(browser.node(for: URL(filePath: "/tmp/root/a/a1")) === a1)
        #expect(browser.node(for: URL(filePath: "/tmp/root")) === browser.root)
        #expect(browser.node(for: URL(filePath: "/tmp/elsewhere")) == nil)
    }

    @Test func collectingAFolderReplacesItsContents() {
        let browser = makeBrowser()
        let a = named("a", in: browser.root)
        let a1 = named("a1", in: a)

        browser.collect([a1])
        #expect(browser.collected.map(\.name) == ["a1"])
        browser.collect([a])
        #expect(browser.collected.map(\.name) == ["a"])
        browser.collect([a1])
        #expect(browser.collected.count == 1)
        #expect(browser.isCollected(a1))
        #expect(browser.collectedSize == 800)

        browser.collect([browser.root])
        #expect(browser.collected.count == 1)
    }

    @Test func removingAChildUpdatesAncestors() {
        let root = makeTree()
        let a = named("a", in: root)
        let a1 = named("a1", in: a)

        a.removeChild(a1)
        #expect(a.size == 200)
        #expect(root.size == 400)
        #expect(root.descendantCount == 53)
        #expect(a1.parent == nil)

        a.removeChild(named("a2", in: a))
        #expect(a.size == 0)
        // "a" shrank below "b", so the order changes.
        #expect(root.children.first?.name == "b")
    }
}
