//
//  ResultsView.swift
//  Broom
//

import Foundation
import QuickLook
import SwiftUI

/// The main browsing screen: chart on the left, list on the right, collector below.
///
/// Keyboard: ↑/↓ select, → or Return opens a folder, ← or Delete goes up, Space toggles Quick
/// Look, ⌘[ and ⌘] move through history, ⌘⌫ adds the selection to the collector.
struct ResultsView: View {
    @Bindable var browser: BrowserModel
    let model: AppModel

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                browser: browser,
                onShowDisks: { model.showHome() },
                onRescan: { model.rescan() }
            )

            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    SunburstChart(browser: browser)
                        .padding(28)
                    if browser.unreadableCount > 0 {
                        UnreadableBanner(count: browser.unreadableCount) {
                            browser.openFullDiskAccessSettings()
                        }
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle().fill(Theme.stroke).frame(width: 1)

                ItemListView(browser: browser)
                    .frame(width: 340)
            }

            CollectorView(browser: browser)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: browser.current) { isFocused = true }
        .onKeyPress(.upArrow) {
            browser.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            browser.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            browser.openSelection()
            return .handled
        }
        .onKeyPress(.return) {
            browser.openSelection()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            browser.goUp()
            return .handled
        }
        .onKeyPress(.delete) {
            browser.goUp()
            return .handled
        }
        .onKeyPress(.space) {
            browser.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.escape) {
            if browser.quickLookURL != nil {
                browser.quickLookURL = nil
            } else {
                browser.selected = nil
            }
            return .handled
        }
        .quickLookPreview($browser.quickLookURL)
        .alert(
            "Some items couldn't be deleted",
            isPresented: Binding(
                get: { browser.deletionError != nil },
                set: { if !$0 { browser.deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.deletionError ?? "")
        }
    }
}

/// Shown when some folders couldn't be read, usually because Full Disk Access is off.
struct UnreadableBanner: View {
    let count: Int
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.orange)
            Text(count == 1 ? "1 folder couldn't be read." : "\(count.formatted()) folders couldn't be read.")
                .foregroundStyle(Theme.primaryText)
            Button("Allow Full Disk Access…") { onOpenSettings() }
                .buttonStyle(.link)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}
