//
//  BroomApp.swift
//  Broom
//
//  Created by David Rodrigues on 03/11/2026.
//

import SwiftUI

@main
struct BroomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Broom", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1220, height: 800)
        .commands {
            BroomCommands(model: model)
        }
    }
}

/// Menu bar items. Their shortcuts work wherever keyboard focus is.
struct BroomCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.chooseFolderToScan() }
                .keyboardShortcut("o")
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.browser == nil)
            Divider()
            Button("Show Disks") { model.showHome() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            Button("Back") { model.browser?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(model.browser?.canGoBack ?? false) || model.screen != .results)
            Button("Forward") { model.browser?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(model.browser?.canGoForward ?? false) || model.screen != .results)
            Divider()
            Button("Enclosing Folder") { model.browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(model.browser?.canGoUp ?? false) || model.screen != .results)
            Button("Open Selection") { model.browser?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.browser?.selected == nil || model.screen != .results)
            Button("Top Level") { model.browser?.goToRoot() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(!(model.browser?.canGoUp ?? false) || model.screen != .results)
        }

        CommandMenu("Item") {
            Button("Quick Look") { model.browser?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model.browser?.selected == nil || model.screen != .results)
            Button("Reveal in Finder") {
                if let browser = model.browser, let node = browser.selected {
                    browser.revealInFinder(node)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.browser?.selected == nil || model.screen != .results)
            Divider()
            Button("Add to Collector") { model.browser?.collectSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.browser?.selected == nil || model.screen != .results)
        }
    }
}
