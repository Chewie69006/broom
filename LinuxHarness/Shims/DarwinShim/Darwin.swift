// Linux stand-in for the bits of Darwin that Broom's scanner uses.
// Implements getattrlistbulk(2) on top of readdir/fstatat, packing entries in the same layout the
// macOS kernel uses: length, returned attribute_set_t, [error], name ref, [devid], [objtype],
// [fileid], dir attrs, file attrs, then the name bytes. 64-bit fields deliberately land on
// non-8-byte-aligned offsets, and batches are small so the reader loops over many calls.
// Names starting with "zz_error_" come back as ATTR_CMN_ERROR entries. Folders report their entry
// count (ATTR_DIR_ENTRYCOUNT) when asked.
//
// Also provides fts (through CFTS) and the Darwin spelling of RLIMIT_NOFILE.

@_exported import CFTS
@_exported import Glibc
import Synchronization

/// Darwin declares this as an Int32; Glibc as an enum case. Shadows Glibc's for code that
/// imports Darwin (that is, this shim).
public let RLIMIT_NOFILE = Int32(Glibc.RLIMIT_NOFILE.rawValue)

public struct attrlist {
    public var bitmapcount: UInt16 = 0
    public var reserved: UInt16 = 0
    public var commonattr: UInt32 = 0
    public var volattr: UInt32 = 0
    public var dirattr: UInt32 = 0
    public var fileattr: UInt32 = 0
    public var forkattr: UInt32 = 0
    public init() {}
}

private let cmnName: UInt32 = 0x1
private let cmnDevID: UInt32 = 0x2
private let cmnObjType: UInt32 = 0x8
private let cmnFileID: UInt32 = 0x0200_0000
private let cmnError: UInt32 = 0x2000_0000
private let cmnReturned: UInt32 = 0x8000_0000
private let dirEntryCount: UInt32 = 0x2
private let dirMountStatus: UInt32 = 0x4
private let fileLinkCount: UInt32 = 0x1
private let fileAllocSize: UInt32 = 0x4

/// Entries returned per call, to exercise the reader's batching loop.
private let maxEntriesPerCall = 7

private struct Listing: Sendable {
    var entries: [[UInt8]]
    var next = 0
}

/// pthread-based so ThreadSanitizer understands it (Synchronization.Mutex uses raw futexes on Linux).
private final class LockedListings: @unchecked Sendable {
    private var storage: [Int32: Listing] = [:]
    private let lock: UnsafeMutablePointer<pthread_mutex_t> = .allocate(capacity: 1)
    init() { pthread_mutex_init(lock, nil) }
    func withLock<R>(_ body: (inout [Int32: Listing]) -> R) -> R {
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        return body(&storage)
    }
}

private let listings = LockedListings()

/// Counters the harness checks to make sure the interesting paths ran.
public let shimCalls = Atomic<Int>(0)
public let shimErrorEntries = Atomic<Int>(0)

public func getattrlistbulk(
    _ dirfd: Int32, _ attrList: UnsafeMutableRawPointer!, _ attrBuf: UnsafeMutableRawPointer!,
    _ attrBufSize: Int, _ options: UInt64
) -> Int32 {
    _ = shimCalls.wrappingAdd(1, ordering: .relaxed)
    let request = attrList.load(as: attrlist.self)
    guard request.bitmapcount == 5, request.commonattr & cmnReturned != 0 else {
        errno = EINVAL
        return -1
    }

    // The kernel ties a listing to the open file. Here it's keyed by descriptor number, so a folder
    // that was opened afresh (offset still 0) must not pick up a listing left by an earlier folder
    // that had the same number. The reader can stop before the end now, so leftovers happen.
    if lseek(dirfd, 0, SEEK_CUR) == 0 {
        listings.withLock { $0[dirfd] = nil }
    }

    var listing: Listing
    if let existing = listings.withLock({ $0[dirfd] }) {
        listing = existing
    } else {
        guard let entries = readAll(dirfd, request) else { return -1 }
        listing = Listing(entries: entries)
    }

    var offset = 0
    var count: Int32 = 0
    while listing.next < listing.entries.count, count < maxEntriesPerCall {
        let entry = listing.entries[listing.next]
        if offset + entry.count > attrBufSize { break }
        entry.withUnsafeBytes { bytes in
            (attrBuf + offset).copyMemory(from: bytes.baseAddress!, byteCount: entry.count)
        }
        offset += entry.count
        count += 1
        listing.next += 1
    }

    if count == 0 {
        listings.withLock { $0[dirfd] = nil }
        return 0
    }
    let updated = listing
    listings.withLock { $0[dirfd] = updated }
    return count
}

private func readAll(_ dirfd: Int32, _ request: attrlist) -> [[UInt8]]? {
    let copy = dup(dirfd)
    guard copy >= 0, let dir = fdopendir(copy) else { return nil }
    defer { closedir(dir) }
    var dirInfo = stat()
    guard fstat(dirfd, &dirInfo) == 0 else { return nil }

    var result: [[UInt8]] = []
    while let entry = readdir(dir) {
        let name = direntName(entry)
        if name == "." || name == ".." { continue }
        var info = stat()
        if name.hasPrefix("zz_error_") || fstatat(dirfd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            _ = shimErrorEntries.wrappingAdd(1, ordering: .relaxed)
            result.append(packError(name: name, request: request))
            continue
        }
        let isDirectory = info.st_mode & 0o170000 == 0o040000
        let entryCount = isDirectory && request.dirattr & dirEntryCount != 0 ? countEntries(dirfd, name) : nil
        result.append(pack(name: name, info: info, parentDevice: dirInfo.st_dev, entryCount: entryCount, request: request))
    }
    return result
}

private struct Writer {
    var bytes: [UInt8] = []
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func i32(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func i64(_ value: Int64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func patch32(at offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for i in 0..<4 { bytes[offset + i] = raw[i] }
        }
    }
    mutating func patchI32(at offset: Int, _ value: Int32) { patch32(at: offset, UInt32(bitPattern: value)) }
}

private func objectType(_ mode: mode_t) -> UInt32 {
    switch mode & 0o170000 {
    case 0o100000: return 1  // VREG
    case 0o040000: return 2  // VDIR
    case 0o060000: return 3  // VBLK
    case 0o020000: return 4  // VCHR
    case 0o120000: return 5  // VLNK
    case 0o140000: return 6  // VSOCK
    case 0o010000: return 7  // VFIFO
    default: return 0
    }
}

private func finish(_ writer: inout Writer, nameRefOffset: Int, name: String) -> [UInt8] {
    // Variable-length data goes after the fixed part; the ref's offset is relative to itself.
    let nameData = Array(name.utf8) + [0]
    writer.patchI32(at: nameRefOffset, Int32(writer.bytes.count - nameRefOffset))
    writer.patch32(at: nameRefOffset + 4, UInt32(nameData.count))
    writer.bytes += nameData
    while writer.bytes.count % 4 != 0 { writer.bytes.append(0) }
    writer.patch32(at: 0, UInt32(writer.bytes.count))
    return writer.bytes
}

/// The name in a `dirent` from readdir. Records are only as long as their name needs, so this reads
/// in place up to the NUL. Copying the whole 256-byte `d_name` can run past the end of the buffer.
public func direntName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    let offset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
    return String(cString: (UnsafeRawPointer(entry) + offset).assumingMemoryBound(to: CChar.self))
}

private func countEntries(_ dirfd: Int32, _ name: String) -> UInt32? {
    let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    guard let dir = fdopendir(fd) else {
        close(fd)
        return nil
    }
    defer { closedir(dir) }
    var count: UInt32 = 0
    while let entry = readdir(dir) {
        let child = direntName(entry)
        if child != "." && child != ".." { count += 1 }
    }
    return count
}

private func pack(name: String, info: stat, parentDevice: dev_t, entryCount: UInt32?, request: attrlist) -> [UInt8] {
    let type = objectType(info.st_mode)
    let isDirectory = type == 2
    var common = cmnReturned
    var dirBits: UInt32 = 0
    var fileBits: UInt32 = 0
    if request.commonattr & cmnName != 0 { common |= cmnName }
    if request.commonattr & cmnDevID != 0 { common |= cmnDevID }
    if request.commonattr & cmnObjType != 0 { common |= cmnObjType }
    if request.commonattr & cmnFileID != 0 { common |= cmnFileID }
    if isDirectory {
        dirBits = request.dirattr & dirMountStatus
        if entryCount != nil { dirBits |= request.dirattr & dirEntryCount }
    } else {
        fileBits = request.fileattr & (fileLinkCount | fileAllocSize)
    }

    var writer = Writer()
    writer.u32(0)  // length, patched later
    writer.u32(common)
    writer.u32(0)
    writer.u32(dirBits)
    writer.u32(fileBits)
    writer.u32(0)
    let nameRef = writer.bytes.count
    if common & cmnName != 0 { writer.i32(0); writer.u32(0) }
    if common & cmnDevID != 0 { writer.u32(UInt32(truncatingIfNeeded: info.st_dev)) }
    if common & cmnObjType != 0 { writer.u32(type) }
    if common & cmnFileID != 0 { writer.u64(UInt64(info.st_ino)) }
    if dirBits & dirEntryCount != 0 { writer.u32(entryCount ?? 0) }
    if dirBits & dirMountStatus != 0 { writer.u32(info.st_dev != parentDevice ? 1 : 0) }
    if fileBits & fileLinkCount != 0 { writer.u32(UInt32(info.st_nlink)) }
    if fileBits & fileAllocSize != 0 { writer.i64(Int64(info.st_blocks) * 512) }
    return finish(&writer, nameRefOffset: nameRef, name: name)
}

private func packError(name: String, request: attrlist) -> [UInt8] {
    var writer = Writer()
    writer.u32(0)
    writer.u32(cmnReturned | cmnName | cmnError)
    writer.u32(0)
    writer.u32(0)
    writer.u32(0)
    writer.u32(0)
    writer.u32(UInt32(EACCES))  // ATTR_CMN_ERROR comes right after the returned bitmap
    let nameRef = writer.bytes.count
    writer.i32(0)
    writer.u32(0)
    return finish(&writer, nameRefOffset: nameRef, name: name)
}
