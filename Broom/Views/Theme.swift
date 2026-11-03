//
//  Theme.swift
//  Broom
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Broom's dark, DaisyDisk-style look.
enum Theme {
    static let backgroundTop = Color(red: 0.135, green: 0.140, blue: 0.160)
    static let backgroundBottom = Color(red: 0.075, green: 0.078, blue: 0.090)
    /// Thin lines between chart wedges. Close to the background so wedges read as separate.
    static let chartSeparator = Color(red: 0.085, green: 0.088, blue: 0.100)
    static let panel = Color.white.opacity(0.045)
    static let panelStrong = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.09)
    static let hover = Color.white.opacity(0.07)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
    static let accent = Color(red: 0.31, green: 0.60, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let smallerItems = Color(white: 0.34)

    static var background: some View {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
            .overlay(
                RadialGradient(
                    colors: [Color.white.opacity(0.045), .clear],
                    center: .center, startRadius: 0, endRadius: 700
                )
            )
            .ignoresSafeArea()
    }
}

/// Colors for chart wedges. Hue follows the wedge's position around the circle, and rings get
/// lighter and softer further out. Files are muted so folders stand out.
enum SunburstPalette {
    static func color(
        midAngle: Double, depth: Double, isDirectory: Bool, isHighlighted: Bool = false
    ) -> Color {
        let hue = (midAngle / SunburstLayout.fullCircle * 0.92 + 0.56).truncatingRemainder(dividingBy: 1)
        let ring = max(depth, 0)
        var saturation = 0.74 - 0.075 * ring
        var brightness = 0.84 + 0.03 * ring
        if !isDirectory {
            saturation *= 0.42
            brightness *= 0.90
        }
        if isHighlighted {
            saturation = min(saturation + 0.12, 1)
            brightness = min(brightness + 0.16, 1)
        }
        return Color(hue: hue, saturation: max(saturation, 0.12), brightness: min(brightness, 1))
    }

    static func color(for segment: SunburstSegment, isHighlighted: Bool = false) -> Color {
        guard let node = segment.node else {
            return isHighlighted ? Color(white: 0.48) : Theme.smallerItems
        }
        return color(
            midAngle: segment.midAngle, depth: Double(segment.depth),
            isDirectory: node.isDirectory, isHighlighted: isHighlighted
        )
    }
}

extension Int64 {
    /// "12.3 GB", Finder-style (powers of 1000).
    var byteString: String {
        formatted(.byteCount(style: .file))
    }
}

/// File icons, cached by type so long lists scroll smoothly.
enum FileIcons {
    private static var byType: [String: NSImage] = [:]
    private static var byPath: [String: NSImage] = [:]

    static func icon(for node: FileNode, path: @autoclosure () -> String) -> NSImage {
        let ext = (node.name as NSString).pathExtension.lowercased()
        if node.isDirectory {
            // Apps and other bundles have their own icons.
            if node.isPackage && (ext == "app" || ext == "prefpane" || ext == "appex") {
                let fullPath = path()
                if let cached = byPath[fullPath] { return cached }
                let image = NSWorkspace.shared.icon(forFile: fullPath)
                if byPath.count > 2_000 { byPath.removeAll() }
                byPath[fullPath] = image
                return image
            }
            let key = node.isPackage ? "dir." + ext : "dir"
            if let cached = byType[key] { return cached }
            let type = node.isPackage ? (UTType(filenameExtension: ext) ?? .package) : .folder
            let image = NSWorkspace.shared.icon(for: type)
            byType[key] = image
            return image
        }
        let key = node.kind == .symlink ? "link" : "file." + ext
        if let cached = byType[key] { return cached }
        let type: UTType
        if node.kind == .symlink {
            type = .symbolicLink
        } else {
            type = UTType(filenameExtension: ext) ?? .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        byType[key] = image
        return image
    }
}
