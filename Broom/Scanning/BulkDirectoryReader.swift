//
//  BulkDirectoryReader.swift
//  Broom
//

import Darwin

/// Lists directories with `getattrlistbulk(2)`, the fastest way to read a folder on macOS: one
/// system call returns hundreds of entries together with their type and allocated size, so files
/// never need a separate `stat`.
///
/// Each scanner thread owns one reader. A reader is not thread-safe.
nonisolated final class BulkDirectoryReader {
    static let bufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    /// Calls `body` for every entry of the open directory `fd`.
    /// Returns 0 when the whole folder was read, or the `errno` that stopped it.
    func forEachEntry(in fd: Int32, _ body: (DirectoryEntry) -> Void) -> Int32 {
        var request = attrlist()
        request.bitmapcount = AttributeBits.bitmapCount
        request.commonattr = AttributeBits.common
        request.dirattr = AttributeBits.directory
        request.fileattr = AttributeBits.file

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count == 0 { return 0 }
            if count < 0 {
                let error = errno
                if error == EINTR { continue }
                return error
            }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return EIO }
                if let entry = DirectoryEntry(parsing: cursor) {
                    body(entry)
                }
                cursor += length
            }
        }
    }
}

/// One entry from a `getattrlistbulk` buffer. `name` points into the reader's buffer and is only
/// valid inside the `forEachEntry` callback.
nonisolated struct DirectoryEntry {
    var name: UnsafeRawBufferPointer
    var objectType: UInt32
    var fileID: UInt64
    var mountStatus: UInt32
    var linkCount: UInt32
    var allocatedSize: Int64

    var isDirectory: Bool { objectType == ObjectType.directory }
    var isMountPoint: Bool {
        mountStatus & (AttributeBits.mountPoint | AttributeBits.mountTrigger) != 0
    }

    /// Reads one packed entry. Attributes appear in a fixed order (common, then directory, then
    /// file attributes, each in bit order) and only if the kernel set them in the returned bitmap.
    init?(parsing entry: UnsafeRawPointer) {
        var cursor = entry + 4  // skip the entry length

        // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr.
        let returnedCommon = cursor.loadUnaligned(as: UInt32.self)
        let returnedDirectory = cursor.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let returnedFile = cursor.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        cursor += 20

        // ATTR_CMN_ERROR is packed straight after the returned bitmap.
        if returnedCommon & AttributeBits.commonError != 0 {
            let error = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
            if error != 0 { return nil }
        }

        guard returnedCommon & AttributeBits.commonName != 0 else { return nil }
        let nameOffset = Int(cursor.loadUnaligned(as: Int32.self))
        let nameLength = Int(cursor.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        // The offset is relative to the attrreference_t itself; the length includes the NUL.
        name = UnsafeRawBufferPointer(start: cursor + nameOffset, count: max(nameLength - 1, 0))
        cursor += 8

        objectType = 0
        if returnedCommon & AttributeBits.commonObjectType != 0 {
            objectType = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }

        fileID = 0
        if returnedCommon & AttributeBits.commonFileID != 0 {
            fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }

        mountStatus = 0
        if returnedDirectory & AttributeBits.directoryMountStatus != 0 {
            mountStatus = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }

        linkCount = 1
        if returnedFile & AttributeBits.fileLinkCount != 0 {
            linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }

        allocatedSize = 0
        if returnedFile & AttributeBits.fileAllocatedSize != 0 {
            allocatedSize = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }
    }
}

/// Values from `<sys/attr.h>` and `<sys/vnode.h>`, spelled out so their Swift types are exact.
nonisolated enum AttributeBits {
    static let bitmapCount: UInt16 = 5  // ATTR_BIT_MAP_COUNT

    static let commonName: UInt32 = 0x0000_0001  // ATTR_CMN_NAME
    static let commonObjectType: UInt32 = 0x0000_0008  // ATTR_CMN_OBJTYPE
    static let commonFileID: UInt32 = 0x0200_0000  // ATTR_CMN_FILEID
    static let commonError: UInt32 = 0x2000_0000  // ATTR_CMN_ERROR
    static let commonReturnedAttributes: UInt32 = 0x8000_0000  // ATTR_CMN_RETURNED_ATTRS

    static let directoryMountStatus: UInt32 = 0x0000_0004  // ATTR_DIR_MOUNTSTATUS
    static let mountPoint: UInt32 = 0x0000_0001  // DIR_MNTSTATUS_MNTPOINT
    static let mountTrigger: UInt32 = 0x0000_0002  // DIR_MNTSTATUS_TRIGGER

    static let fileLinkCount: UInt32 = 0x0000_0001  // ATTR_FILE_LINKCOUNT
    static let fileAllocatedSize: UInt32 = 0x0000_0004  // ATTR_FILE_ALLOCSIZE

    static let common = commonReturnedAttributes | commonName | commonError | commonObjectType | commonFileID
    static let directory = directoryMountStatus
    static let file = fileLinkCount | fileAllocatedSize
}

/// `enum vtype` from `<sys/vnode.h>`.
nonisolated enum ObjectType {
    static let regular: UInt32 = 1  // VREG
    static let directory: UInt32 = 2  // VDIR
    static let symlink: UInt32 = 5  // VLNK
}
