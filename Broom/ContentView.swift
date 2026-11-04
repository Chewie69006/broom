//
//  ContentView.swift
//  Broom
//
//  Created by David Rodrigues on 03/11/2026.
//

import SwiftUI

/// Switches between onboarding, the disks, the scanning screen and the results.
struct ContentView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Theme.background

            switch model.screen {
            case .launching:
                Color.clear
            case .onboarding:
                OnboardingView(model: model)
                    .transition(.opacity)
            case .home:
                HomeView(model: model)
                    .transition(.opacity)
            case .scanning:
                if let session = model.scan {
                    ScanningView(session: session) { model.cancelScan() }
                        .transition(.opacity)
                }
            case .results:
                if let browser = model.browser {
                    ResultsView(browser: browser, model: model)
                        .transition(.opacity)
                }
            }
        }
        // The title bar is hidden; our own top bar sits beside the window buttons.
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .alert(
            "Can't scan that",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView(model: AppModel())
        .frame(width: 1100, height: 720)
        .preferredColorScheme(.dark)
}
