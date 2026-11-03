//
//  ItemListView.swift
//  Broom
//

import AppKit
import Foundation
import SwiftUI

/// The list beside the chart: the current folder's contents, biggest first. Hover and selection
/// are shared with the chart.
struct ItemListView: View {
    let browser: BrowserModel

    var body: some View {
        // Reading treeVersion makes the list refresh after deletions.
        let _ = browser.treeVersion
        let folder = browser.current
        let rows = browser.listRows

        VStack(spacing: 0) {
            header(for: folder)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            if rows.isEmpty {
                emptyState(for: folder)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { node in
                                row(for: node, in: folder)
                                    .id(node.id)
                            }
                            if browser.hiddenListRowCount > 0 {
                                hiddenRowsFooter
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: browser.selected) {
                        if let selected = browser.selected {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(selected.id)
                            }
                        }
                    }
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            footer
        }
        .background(Theme.panel)
    }

    private func header(for folder: FileNode) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: folder, path: browser.path(for: folder)))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder.size.byteString) · \(folder.descendantCount.formatted()) items")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(for node: FileNode, in folder: FileNode) -> some View {
        let isHovered = browser.hovered === node
        let isSelected = browser.selected === node
        let url = browser.url(for: node)
        return ItemRow(
            node: node,
            icon: FileIcons.icon(for: node, path: browser.path(for: node)),
            swatch: swatchColor(for: node),
            fraction: folder.size > 0 ? Double(node.size) / Double(folder.size) : 0,
            isHovered: isHovered,
            isSelected: isSelected,
            isCollected: browser.isCollected(node)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                browser.hovered = node
            } else if browser.hovered === node {
                browser.hovered = nil
            }
        }
        .onTapGesture {
            browser.activate(node)
        }
        .draggable(url) {
            DragPreview(node: node, browser: browser)
        }
        .contextMenu {
            ItemMenuItems(node: node, browser: browser)
        }
    }

    /// The same color as the item's wedge in the chart's inner ring.
    private func swatchColor(for node: FileNode) -> Color {
        let layout = browser.layout
        guard let position = layout.position(of: node), position.ring == 0,
              let segment = layout.segment(ring: position.ring, index: position.index)
        else {
            return Theme.smallerItems
        }
        return SunburstPalette.color(for: segment)
    }

    private var hiddenRowsFooter: some View {
        HStack {
            Text("\(browser.hiddenListRowCount.formatted()) smaller items")
            Spacer()
            Text(browser.hiddenListRowSize.byteString)
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func emptyState(for folder: FileNode) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: folder.isUnreadable ? "lock.fill" : "tray")
                .font(.system(size: 28))
                .foregroundStyle(Theme.tertiaryText)
            Text(folder.isUnreadable ? "Broom couldn't read this folder." : "This folder is empty.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            if folder.isUnreadable {
                Button("Open Full Disk Access Settings") {
                    browser.openFullDiskAccessSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        let seconds = Double(browser.scanDuration.components.seconds)
            + Double(browser.scanDuration.components.attoseconds) / 1e18
        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.accent)
            Text("\(browser.root.descendantCount.formatted()) items scanned in \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

struct ItemRow: View {
    let node: FileNode
    let icon: NSImage
    let swatch: Color
    let fraction: Double
    let isHovered: Bool
    let isSelected: Bool
    let isCollected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A thin bar showing the item's share of the folder.
                GeometryReader { proxy in
                    Capsule()
                        .fill(swatch.opacity(0.55))
                        .frame(width: max(proxy.size.width * fraction, 2))
                }
                .frame(height: 2)
            }
            Spacer(minLength: 6)
            if isCollected {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .help("In the collector")
            }
            Text(node.size.byteString)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .opacity(node.isDirectory && !node.children.isEmpty ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.accent.opacity(0.32) : (isHovered ? Theme.hover : Color.clear))
        )
    }
}
