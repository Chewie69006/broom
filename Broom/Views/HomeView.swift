//
//  HomeView.swift
//  Broom
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The first screen: the mounted disks, each with a Scan button, plus scanning any folder.
struct HomeView: View {
    let model: AppModel

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 40)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            VStack(spacing: 10) {
                BroomLogo()
                    .frame(width: 64, height: 64)
                Text("Broom")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text("See what's taking up space on your disks, and clean it up.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.bottom, 28)

            ScrollView {
                VStack(spacing: 10) {
                    if model.fullDiskAccess == .denied {
                        fullDiskAccessCard
                    }
                    if model.browser != nil {
                        lastScanCard
                    }
                    if model.volumes.isEmpty && model.hasLoadedVolumes {
                        Text("No disks found.")
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.vertical, 30)
                    } else if model.volumes.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 30)
                    }
                    ForEach(model.volumes) { volume in
                        VolumeCard(volume: volume) {
                            model.scanVolume(volume)
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)

            folderDropZone
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.scanDroppedItem(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var fullDiskAccessCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22))
                .foregroundStyle(Color.orange)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Scans will leave out protected folders, like Mail and other apps' data.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            PillButton(title: "Set Up…", isProminent: false) { model.showOnboarding() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3)))
    }

    private var lastScanCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Last scan: \(model.browser?.target.name ?? "")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(model.browser?.root.size.byteString ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            PillButton(title: "Show", isProminent: false) { model.showResults() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }

    private var folderDropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 22))
                .foregroundStyle(isDropTargeted ? Theme.accent : Theme.secondaryText)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Scan a folder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Drop a folder anywhere in this window, or choose one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            PillButton(title: "Choose…", isProminent: false) { model.chooseFolderToScan() }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isDropTargeted ? Theme.accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Theme.stroke,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 5])
                )
        )
    }
}

/// One disk: icon, name, a usage bar and a Scan button.
struct VolumeCard: View {
    let volume: VolumeInfo
    let onScan: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if volume.isStartupDisk {
                        Text("Startup disk")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.panelStrong))
                    }
                    Spacer()
                    Text("\(volume.availableCapacity.byteString) free of \(volume.totalCapacity.byteString)")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                UsageBar(fraction: volume.usedFraction)
                    .frame(height: 8)
                Text("\(volume.usedCapacity.byteString) used")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }

            PillButton(title: "Scan", isProminent: true, action: onScan)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHovered ? Theme.panelStrong : Theme.panel)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        .onHover { isHovered = $0 }
    }
}

/// Disk usage as a colorful bar.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            Color(hue: 0.58, saturation: 0.7, brightness: 0.95),
                            Color(hue: 0.78, saturation: 0.6, brightness: 0.95),
                            Color(hue: fraction > 0.9 ? 0.0 : 0.92, saturation: 0.65, brightness: 0.98),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 8))
            }
        }
    }
}

struct PillButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : Theme.primaryText)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(
                    Capsule().fill(
                        isProminent
                            ? Theme.accent.opacity(isHovered ? 1 : 0.88)
                            : (isHovered ? Theme.panelStrong : Theme.panel)
                    )
                )
                .overlay(Capsule().strokeBorder(isProminent ? Color.clear : Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A tiny sunburst used as the app's logo.
struct BroomLogo: View {
    var body: some View {
        Canvas { context, size in
            let geometry = SunburstGeometry(size: size, ringCount: 3)
            let wedges: [(depth: Int, start: Double, end: Double)] = [
                (0, 0.00, 0.42), (0, 0.42, 0.70), (0, 0.70, 0.88), (0, 0.88, 1.0),
                (1, 0.00, 0.25), (1, 0.25, 0.38), (1, 0.42, 0.62), (1, 0.70, 0.80),
                (2, 0.00, 0.14), (2, 0.42, 0.52),
            ]
            for wedge in wedges {
                let start = wedge.start * SunburstLayout.fullCircle
                let end = wedge.end * SunburstLayout.fullCircle
                let path = SunburstRenderer.sector(
                    center: geometry.center,
                    inner: geometry.radius(atDepth: Double(wedge.depth)),
                    outer: geometry.radius(atDepth: Double(wedge.depth + 1)),
                    start: start, end: end
                )
                let color = SunburstPalette.color(midAngle: (start + end) / 2, depth: Double(wedge.depth), isDirectory: true)
                context.fill(path, with: .color(color))
                context.stroke(path, with: .color(Theme.backgroundTop), lineWidth: 1.5)
            }
        }
    }
}
