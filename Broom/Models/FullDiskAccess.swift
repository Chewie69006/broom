//
//  FullDiskAccess.swift
//  Broom
//

import Darwin
import Foundation

/// Checks whether Broom has Full Disk Access.
///
/// macOS has no API to request Full Disk Access or to query it. Apps find out by trying to open
/// something it protects. Trying also helps the user: macOS then tends to list the app under
/// Full Disk Access in System Settings, so they only have to switch it on.
nonisolated enum FullDiskAccess {
    nonisolated enum Status: Sendable, Equatable {
        case granted
        case denied
        /// Can't tell yet, e.g. in the sandboxed build before the user has given access to the disk.
        case unknown
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    /// Runs the check off the main actor, since it touches the file system.
    @concurrent
    static func check() async -> Status {
        currentStatus()
    }

    static func currentStatus() -> Status {
        let home = realHomeDirectory()
        // Items only Full Disk Access can open, each with a folder above it that anyone can read.
        let probes = [
            (item: "/Library/Application Support/com.apple.TCC/TCC.db", readableParent: "/Library/Application Support"),
            (item: home + "/Library/Safari", readableParent: home + "/Library"),
            (item: home + "/Library/Mail", readableParent: home + "/Library"),
        ]
        var sawRefusal = false
        for probe in probes {
            let fd = open(probe.item, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            let error = errno
            // The sandbox refuses with the same errors, so a refusal only counts when the folder
            // around the item is readable.
            if (error == EPERM || error == EACCES) && canOpen(probe.readableParent) {
                sawRefusal = true
            }
        }
        return sawRefusal ? .denied : .unknown
    }

    private static func canOpen(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// The user's real home folder. In the sandbox, `NSHomeDirectory()` is the app's container.
    private static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }
}
