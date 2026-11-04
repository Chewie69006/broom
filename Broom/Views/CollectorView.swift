//
//  CollectorView.swift
//  Broom
//

import AppKit
import Foundation
import SwiftUI

/// The collector along the bottom: drop items here, review them, then delete them in one go.
struct CollectorView: View {
    let browser: BrowserModel

    @State private var isDropTargeted = false
    @State private var isConfirmingDelete = false

    var body: some View {
        let items = browser.collected

        HStack(spacing: 14) {
            Image(systemName: items.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: 20))
                .foregroundStyle(isDropTargeted ? Theme.accent : Theme.secondaryText)
                .frame(width: 28)

            if items.isEmpty {
                Text("Drag files and folders here to collect them for deletion")
                    .font(.system(size: 12.5))
                    .foregroundStyle(isDropTargeted ? Theme.primaryText : Theme.tertiaryText)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(items) { node in
                            CollectedChip(node: node, browser: browser)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(browser.collectedSize.byteString)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                    Text(items.count == 1 ? "1 item" : "\(items.count.formatted()) items")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }

                Button("Clear") { browser.clearCollector() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)

                Button {
                    isConfirmingDelete = true
                } label: {
                    HStack(spacing: 6) {
                        if browser.isDeleting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text("Delete")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(Theme.danger))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(browser.isDeleting)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Theme.accent.opacity(0.12) : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Theme.stroke,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: items.isEmpty ? [5, 4] : [])
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .dropDestination(for: URL.self) { urls, _ in
            browser.collect(urls: urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .confirmationDialog(
            deleteTitle(count: items.count),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                browser.deleteCollected(permanently: false)
            }
            Button("Delete Immediately", role: .destructive) {
                browser.deleteCollected(permanently: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free up \(browser.collectedSize.byteString). Items moved to the Trash keep using space until you empty it. Deleting immediately can't be undone.")
        }
    }

    private func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete 1 item?" : "Delete \(count.formatted()) items?"
    }
}

/// One collected item, with a button to take it back out.
struct CollectedChip: View {
    let node: FileNode
    let browser: BrowserModel

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: node, path: browser.path(for: node)))
                .resizable()
                .frame(width: 16, height: 16)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Text(node.size.byteString)
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            Button {
                browser.uncollect(node)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isHovered ? Theme.primaryText : Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Remove from the collector")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.primaryText)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Theme.panelStrong))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") { browser.revealInFinder(node) }
            Button("Remove from Collector") { browser.uncollect(node) }
        }
        .help(browser.path(for: node))
    }
}
