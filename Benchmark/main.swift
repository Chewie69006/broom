//
//  main.swift
//  broom-bench
//
//  Times Broom's scanner against fts on the same folders. Build and run it with Benchmark/run.sh.
//  It's compiled together with Broom/Scanning/*.swift, so it measures the app's real scanner.
//

import Darwin
import Foundation

// MARK: - Contenders

/// Totals in the same terms as Broom: items below the root, allocated bytes, hard links once,
/// other volumes left out.
struct Totals: Equatable {
    var items = 0
    var bytes: Int64 = 0
}

/// A single-threaded walk with fts(3), the classic way to do this. On macOS, fts lists folders with
/// getattrlistbulk too.
func ftsTotals(_ path: String, changesDirectory: Bool) -> Totals {
    var rootInfo = stat()
    guard lstat(path, &rootInfo) == 0, let rootCopy = strdup(path) else { return Totals() }
    defer { free(rootCopy) }

    var options = FTS_PHYSICAL | FTS_XDEV
    if !changesDirectory { options |= FTS_NOCHDIR }
    var arguments: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
    guard let stream = fts_open(&arguments, options, nil) else { return Totals() }
    defer { fts_close(stream) }

    var totals = Totals()
    var hardLinks = Set<InodeKey>()
    while let entry = fts_read(stream) {
        guard entry.pointee.fts_level > 0 else { continue }
        switch Int32(entry.pointee.fts_info) {
        case FTS_D:
            // FTS_XDEV still returns mount points without descending. Broom leaves them out.
            if entry.pointee.fts_statp.pointee.st_dev != rootInfo.st_dev {
                _ = fts_set(stream, entry, FTS_SKIP)
            } else {
                totals.items += 1
            }
        case FTS_DNR:
            totals.items += 1
        case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
            let info = entry.pointee.fts_statp.pointee
            var size = Int64(info.st_blocks) * 512
            if info.st_nlink > 1 && info.st_mode & 0o170000 == 0o100000 {
                let key = InodeKey(device: info.st_dev, inode: UInt64(info.st_ino))
                if !hardLinks.insert(key).inserted { size = 0 }
            }
            totals.items += 1
            totals.bytes += size
        default:
            break
        }
    }
    return totals
}

func broomTotals(_ path: String, options: DiskScanner.Options) async -> Totals {
    let outcome = await DiskScanner(rootPath: path, rootName: "root", options: options).run()
    return Totals(items: outcome.root.descendantCount, bytes: outcome.root.size)
}

struct Contender {
    let name: String
    let threads: Int
    let run: (String) async -> Totals
}

let cores = ProcessInfo.processInfo.activeProcessorCount
let defaultWorkers = min(max(cores * 2, 4), 24)

func broom(_ name: String, workers: Int, _ configure: (inout DiskScanner.Options) -> Void = { _ in }) -> Contender {
    var options = DiskScanner.Options()
    options.workerCount = workers
    configure(&options)
    let chosen = options
    return Contender(name: name, threads: workers) { await broomTotals($0, options: chosen) }
}

let contenders: [Contender] = [
    Contender(name: "fts", threads: 1) { ftsTotals($0, changesDirectory: false) },
    Contender(name: "fts (chdir)", threads: 1) { ftsTotals($0, changesDirectory: true) },
    broom("Broom", workers: 1),
    broom("Broom", workers: cores),
    broom("Broom (default)", workers: defaultWorkers),
    broom("Broom, full paths", workers: defaultWorkers) { $0.opensRelativeToParent = false },
    broom("Broom, no entry counts", workers: defaultWorkers) { $0.entryCounts = .never },
    broom("Broom, previous version", workers: defaultWorkers) {
        $0.opensRelativeToParent = false
        $0.entryCounts = .never
    },
]

// MARK: - Running

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let padding = String(repeating: " ", count: max(width - text.count, 0))
    return right ? padding + text : text + padding
}

var runs = 3
var paths: [String] = []
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--runs", let value = arguments.first.flatMap({ Int($0) }) {
        arguments.removeFirst()
        runs = max(value, 1)
    } else if argument == "--help" || argument == "-h" {
        print("usage: broom-bench [--runs N] [folder ...]   (default: your home folder, 3 runs)")
        exit(0)
    } else {
        paths.append(PathUtilities.path(of: URL(filePath: (argument as NSString).expandingTildeInPath)))
    }
}
if paths.isEmpty {
    paths = [NSHomeDirectory()]
}

print("\(cores) cores, \(runs) runs each, median shown. Caches are warm after the first pass;")
print("for cold-cache numbers, run `sudo purge` first and use --runs 1.\n")

for path in paths {
    print("▸ \(path)")
    // One untimed pass so every contender starts from the same warm cache.
    _ = await broomTotals(path, options: DiskScanner.Options())

    var times = Array(repeating: [Double](), count: contenders.count)
    var results = Array(repeating: Totals(), count: contenders.count)
    // Round-robin, so no contender always runs right after another.
    for _ in 0..<runs {
        for (index, contender) in contenders.enumerated() {
            let start = ContinuousClock.now
            results[index] = await contender.run(path)
            times[index].append(seconds(ContinuousClock.now - start))
        }
    }

    let baseline = median(times[0])
    print("  " + pad("method", 26) + pad("threads", 8, right: true) + pad("time", 10, right: true)
        + pad("vs fts", 9, right: true) + pad("items/s", 12, right: true))
    for (index, contender) in contenders.enumerated() {
        let time = median(times[index])
        let speedup = time > 0 ? baseline / time : 0
        let rate = time > 0 ? Double(results[index].items) / time : 0
        var line = "  " + pad(contender.name, 26)
            + pad("\(contender.threads)", 8, right: true)
            + pad(String(format: "%.3fs", time), 10, right: true)
            + pad(String(format: "%.2f×", speedup), 9, right: true)
            + pad(String(format: "%.0f", rate), 12, right: true)
        if results[index] != results[0] {
            line += "   ⚠︎ totals differ: \(results[index].items) items, \(results[index].bytes) B"
        }
        print(line)
    }
    print("  fts found \(results[0].items) items, \(results[0].bytes.formatted(.byteCount(style: .file)))\n")
}
