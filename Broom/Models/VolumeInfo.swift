//
//  VolumeInfo.swift
//  Broom
//

import Foundation

/// A mounted disk shown on the home screen.
nonisolated struct VolumeInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isInternal: Bool
    let isRemovable: Bool

    var id: URL { url }
    var usedCapacity: Int64 { max(totalCapacity - availableCapacity, 0) }
    var usedFraction: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0
    }
    var isStartupDisk: Bool { PathUtilities.path(of: url) == "/" }

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
    ]

    /// Reads the mounted volumes. This can block on slow or network disks, so call it off the main
    /// actor.
    static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
            if values.volumeIsBrowsable == false { return nil }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                url: url,
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                totalCapacity: total,
                availableCapacity: min(max(available, 0), total),
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isStartupDisk != rhs.isStartupDisk { return lhs.isStartupDisk }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Something the user asked to scan: a whole volume or a single folder.
nonisolated struct ScanTarget: Hashable, Sendable {
    let url: URL
    let name: String
    let volume: VolumeInfo?

    var path: String { PathUtilities.path(of: url) }

    init(url: URL, volume: VolumeInfo? = nil) {
        self.url = url
        self.volume = volume
        self.name = volume?.name ?? ScanTarget.displayName(for: url)
    }

    private static func displayName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeLocalizedNameKey, .localizedNameKey])
        if values?.isVolume == true, let name = values?.volumeLocalizedName {
            return name
        }
        if let name = values?.localizedName, !name.isEmpty {
            return name
        }
        let last = url.lastPathComponent
        return last.isEmpty ? PathUtilities.path(of: url) : last
    }
}
