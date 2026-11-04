// Harness only: macOS Foundation APIs that Linux's Foundation doesn't have.
import Foundation

nonisolated extension FileManager {
    func trashItem(at url: URL, resultingItemURL: UnsafeMutablePointer<NSURL?>?) throws {
        try removeItem(at: url)
    }
}

nonisolated extension URLResourceKey {
    static let volumeAvailableCapacityForImportantUsageKey = URLResourceKey(rawValue: "NSURLVolumeAvailableCapacityForImportantUsageKey")
}

nonisolated extension URLResourceValues {
    var volumeAvailableCapacityForImportantUsage: Int64? { nil }
}

nonisolated extension URLResourceKey {
    static let volumeTypeNameKey = URLResourceKey(rawValue: "NSURLVolumeTypeNameKey")
}

nonisolated extension URLResourceValues {
    /// Unknown on Linux, so the scanner's automatic mode leaves entry counts off.
    var volumeTypeName: String? { nil }
}
