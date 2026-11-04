//
//  TopBar.swift
//  Broom
//

import SwiftUI

/// The bar along the top of the results: back to the disks, history, the path, and Rescan.
struct TopBar: View {
    let browser: BrowserModel
    let onShowDisks: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 72, height: 1)

            BarButton(systemImage: "internaldrive", title: "Disks", help: "Back to the list of disks") { onShowDisks() }

            HStack(spacing: 2) {
                BarButton(systemImage: "chevron.left", help: "Back (⌘[)") { browser.goBack() }
                    .disabled(!browser.canGoBack)
                BarButton(systemImage: "chevron.right", help: "Forward (⌘])") { browser.goForward() }
                    .disabled(!browser.canGoForward)
                BarButton(systemImage: "arrow.up", help: "Enclosing folder (⌘↑)") { browser.goUp() }
                    .disabled(!browser.canGoUp)
            }

            PathBar(trail: browser.trail, onSelect: { browser.open($0) })
                .frame(maxWidth: .infinity, alignment: .leading)

            BarButton(systemImage: "arrow.clockwise", title: "Rescan", help: "Scan again (⌘R)") { onRescan() }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            Color.black.opacity(0.18)
                .gesture(WindowDragGesture())
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

/// Breadcrumbs from the scanned folder down to the current one. Click any of them to jump there.
struct PathBar: View {
    let trail: [FileNode]
    let onSelect: (FileNode) -> Void

    /// Long paths keep the first item and the last few.
    private var visibleItems: [FileNode?] {
        guard trail.count > 5 else { return trail.map { Optional($0) } }
        return [trail[0], nil] + trail.suffix(3).map { Optional($0) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                if let item {
                    let isLast = item === trail.last
                    Button {
                        onSelect(item)
                    } label: {
                        Text(item.name)
                            .font(.system(size: 12.5, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? Theme.primaryText : Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isLast ? Theme.panelStrong : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                } else {
                    Text("…")
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }
}

/// A small dark toolbar button.
struct BarButton: View {
    let systemImage: String
    var title: String?
    var help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(systemImage: String, title: String? = nil, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isEnabled ? Theme.primaryText : Theme.tertiaryText)
            .padding(.horizontal, title == nil ? 7 : 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered && isEnabled ? Theme.panelStrong : Theme.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
