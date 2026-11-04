//
//  BrowserModel+Finder.swift
//  Broom
//

import AppKit
import Foundation

extension BrowserModel {
    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: node)])
    }

    func quickLook(_ node: FileNode) {
        selected = node
        quickLookURL = url(for: node)
    }

    /// Space bar: show or hide Quick Look for the selected (or hovered) item.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let node = selected ?? hovered {
            quickLookURL = url(for: node)
        }
    }

    func copyPath(_ node: FileNode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path(for: node), forType: .string)
    }

    /// Adds the selected (or hovered) item to the collector.
    func collectSelection() {
        if let node = selected ?? hovered {
            collect([node])
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccess.openSettings()
    }
}
