// Stress test for Broom's scanner, meant to run under ThreadSanitizer (see run.sh).
//
// Usage: Stress [folder]
// The folder (default /usr/lib) is scanned with 1, 4 and 24 workers and compared against a simple
// single-threaded walk, then used for 60 randomly timed cancellations. /usr is scanned once more as
// a bigger tree. It also runs the collect-then-delete flow and checks that error entries are skipped.
import DarwinShim
import Foundation
import Synchronization
@testable import Broom

nonisolated final class Flag: Sendable {
    let isOn = Atomic<Bool>(true)
}

nonisolated func fail(_ message: String) -> Never {
    print("FAIL:", message)
    exit(1)
}

/// Independent single-threaded walk: allocated bytes (hard links once, other devices skipped) and
/// the number of entries below `path`.
nonisolated func referenceTotals(_ path: String) -> (bytes: Int64, count: Int) {
    var rootInfo = stat()
    guard lstat(path, &rootInfo) == 0 else { return (0, 0) }
    var seen = Set<UInt64>()
    var bytes: Int64 = 0
    var count = 0
    func walk(_ dirPath: String) {
        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let child = dirPath == "/" ? "/" + name : dirPath + "/" + name
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            let isDir = info.st_mode & 0o170000 == 0o040000
            if isDir {
                if info.st_dev != rootInfo.st_dev { continue }  // other volume: left out
                count += 1
                walk(child)
            } else {
                count += 1
                if info.st_nlink > 1 && info.st_mode & 0o170000 == 0o100000 {
                    if !seen.insert(UInt64(info.st_ino)).inserted { continue }
                }
                bytes += Int64(info.st_blocks) * 512
            }
        }
    }
    walk(path)
    return (bytes, count)
}

/// Checks every folder: size is the sum of children, children sorted, parent links, counts.
func verifyTree(_ node: FileNode) -> Int {
    var total: Int64 = 0
    var count = 0
    for (index, child) in node.children.enumerated() {
        if child.parent !== node { fail("bad parent link at \(child.name)") }
        if index > 0 && node.children[index - 1].size < child.size { fail("unsorted children in \(node.name)") }
        let below = child.isDirectory ? verifyTree(child) : 0
        if !child.isDirectory && !child.children.isEmpty { fail("file with children") }
        total += child.size
        count += below + 1
    }
    if node.size != total { fail("size mismatch in \(node.name): \(node.size) vs \(total)") }
    if node.descendantCount != count { fail("count mismatch in \(node.name)") }
    return count
}

func scanAndCheck(_ path: String, workers: Int) async {
    let reference = referenceTotals(path)
    let scanner = DiskScanner(rootPath: path, rootName: "root", workerCount: workers)

    // Poll progress from another thread while the workers run, like the UI does.
    let polling = Flag()
    let poller = Thread {
        var last = 0
        while polling.isOn.load(ordering: .relaxed) {
            let snapshot = scanner.progress.snapshot()
            if snapshot.files < last { fail("progress went backwards") }
            last = snapshot.files
            _ = snapshot.topFolders.reduce(0) { $0 + $1.bytes }
            usleep(200)
        }
    }
    poller.start()

    let start = ContinuousClock.now
    let outcome = await scanner.run()
    let elapsed = ContinuousClock.now - start
    polling.isOn.store(false, ordering: .relaxed)

    if outcome.wasCancelled { fail("unexpected cancellation") }
    let count = verifyTree(outcome.root)
    if outcome.root.size != reference.bytes || count != reference.count {
        fail("\(path) [\(workers) workers]: scanner \(outcome.root.size) B / \(count) items, reference \(reference.bytes) B / \(reference.count) items")
    }
    print("ok  \(path)  workers=\(workers)  items=\(count)  bytes=\(outcome.root.size)  \(elapsed)")
}

func cancellationStress(_ path: String, rounds: Int) async {
    for round in 0..<rounds {
        let scanner = DiskScanner(rootPath: path, rootName: "root", workerCount: 8)
        let delay = UInt32.random(in: 0...3000)
        let canceller = Thread {
            usleep(delay)
            scanner.cancel()
        }
        canceller.start()
        let outcome = await scanner.run()
        if round % 20 == 0 { print("cancel round \(round): cancelled=\(outcome.wasCancelled)") }
    }
    print("ok  cancellation stress (\(rounds) rounds)")
}

@MainActor
func deletionFlow() async {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: "BroomStress-\(UUID().uuidString)")
    let junk = root.appending(path: "junk")
    try! fileManager.createDirectory(at: junk.appending(path: "deep"), withIntermediateDirectories: true)
    try! Data(count: 200_000).write(to: junk.appending(path: "deep/big.bin"))
    try! Data(count: 50_000).write(to: root.appending(path: "keep.bin"))
    defer { try? fileManager.removeItem(at: root) }

    let path = PathUtilities.path(of: root)
    let outcome = await DiskScanner(rootPath: path, rootName: "root").run()
    let browser = BrowserModel(outcome: outcome, target: ScanTarget(url: root))
    let junkNode = browser.root.children.first { $0.name == "junk" }!
    let deepNode = junkNode.children.first { $0.name == "deep" }!
    browser.open(junkNode)
    browser.open(deepNode)
    let before = browser.root.size

    browser.collect([junkNode])
    browser.deleteCollected(permanently: true)
    while browser.isDeleting {
        try? await Task.sleep(for: .milliseconds(5))
    }
    if fileManager.fileExists(atPath: junk.path(percentEncoded: false)) { fail("junk still on disk") }
    if browser.root.children.contains(where: { $0.name == "junk" }) { fail("junk still in tree") }
    if !browser.collected.isEmpty { fail("collector not cleared") }
    if browser.current !== browser.root { fail("should have backed out of the deleted folder") }
    if browser.root.size != before - junkNode.size { fail("root size not updated") }
    _ = verifyTree(browser.root)
    print("ok  delete flow (backed out to \(browser.current.name), root now \(browser.root.size) B)")
}

/// Entries the kernel reports with ATTR_CMN_ERROR must be skipped without breaking the rest.
func errorEntriesAreSkipped() async {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: "BroomErrors-\(UUID().uuidString)")
    try! fileManager.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
    for name in ["a.bin", "zz_error_hidden", "sub/zz_error_also", "sub/b.bin"] {
        try! Data(count: 9_000).write(to: root.appending(path: name))
    }
    defer { try? fileManager.removeItem(at: root) }
    let before = shimErrorEntries.load(ordering: .relaxed)
    let outcome = await DiskScanner(rootPath: PathUtilities.path(of: root), rootName: "root").run()
    if shimErrorEntries.load(ordering: .relaxed) - before != 2 { fail("error entries not produced") }
    let names = outcome.root.children.map(\.name).sorted()
    if names != ["a.bin", "sub"] { fail("unexpected children \(names)") }
    if outcome.root.children.first(where: { $0.name == "sub" })?.children.map(\.name) != ["b.bin"] { fail("sub wrong") }
    _ = verifyTree(outcome.root)
    print("ok  error entries skipped (\(outcome.root.descendantCount) items kept)")
}

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/usr/lib"
for workers in [1, 4, 24] {
    await scanAndCheck(folder, workers: workers)
}
await scanAndCheck("/usr", workers: 8)
await cancellationStress(folder, rounds: 60)
await deletionFlow()
await errorEntriesAreSkipped()
print("shim: \(shimCalls.load(ordering: .relaxed)) getattrlistbulk calls, \(shimErrorEntries.load(ordering: .relaxed)) error entries")
print("ALL PASSED")
