//
//  OnboardingView.swift
//  Broom
//

import SwiftUI

/// Shown at launch until Broom has Full Disk Access (or the user skips it). In the sandboxed build
/// there's a first step to give Broom access to the startup disk.
///
/// macOS has no way to ask for Full Disk Access from inside an app, so this walks the user through
/// System Settings. The model checks every second while this is up, so the steps tick off by
/// themselves.
struct OnboardingView: View {
    let model: AppModel

    private var isSandboxed: Bool { AppModel.isSandboxed }
    private var hasFullDiskAccess: Bool { model.fullDiskAccess == .granted }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 40)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                BroomLogo()
                    .frame(width: 76, height: 76)
                Text("Welcome to Broom")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text("To show where all your disk space goes, Broom needs to look inside every folder on your disk.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(.bottom, 30)

            VStack(spacing: 12) {
                if isSandboxed {
                    diskAccessStep
                }
                fullDiskAccessStep
            }
            .frame(maxWidth: 600)

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                PillButton(
                    title: hasFullDiskAccess ? "Continue" : "Continue Without Full Disk Access",
                    isProminent: hasFullDiskAccess
                ) {
                    model.finishOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                Text("You can come back to this anytime from Broom › Full Disk Access…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: model.fullDiskAccess)
        .animation(.easeInOut(duration: 0.25), value: model.hasStartupDiskAccess)
    }

    // MARK: - Steps

    private var diskAccessStep: some View {
        OnboardingStep(
            number: 1,
            title: "Give Broom access to your disk",
            detail: "Broom is sandboxed, so macOS asks you to choose the disk it may read. Select “Macintosh HD” and click Allow.",
            isDone: model.hasStartupDiskAccess
        ) {
            PillButton(title: "Choose Disk…", isProminent: true) {
                model.requestStartupDiskAccess()
            }
        }
    }

    private var fullDiskAccessStep: some View {
        OnboardingStep(
            number: isSandboxed ? 2 : 1,
            title: "Turn on Full Disk Access",
            detail: "macOS protects some folders, like Mail, Messages and other apps' data. Without Full Disk Access, Broom can't measure them and your scans come up short.",
            isDone: hasFullDiskAccess
        ) {
            PillButton(title: "Open System Settings", isProminent: !isSandboxed || model.hasStartupDiskAccess) {
                model.openFullDiskAccessSettings()
            }
        } footer: {
            if !hasFullDiskAccess {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        InstructionRow(number: 1, text: "Click Open System Settings.")
                        InstructionRow(number: 2, text: "Turn on Broom in the list. If it isn't there, click + and choose Broom.")
                        InstructionRow(number: 3, text: "If macOS asks, click Quit & Reopen.")
                    }
                    accessStatus
                }
            }
        }
    }

    @ViewBuilder
    private var accessStatus: some View {
        HStack(spacing: 7) {
            if isSandboxed && !model.hasStartupDiskAccess {
                Image(systemName: "info.circle")
                Text("Broom can check this once step 1 is done.")
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("Waiting for Full Disk Access…")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.tertiaryText)
    }
}

/// One numbered onboarding step. It shows a checkmark when done, its action button otherwise.
struct OnboardingStep<Action: View, Footer: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    let action: Action
    let footer: Footer

    init(
        number: Int, title: String, detail: String, isDone: Bool,
        @ViewBuilder action: () -> Action,
        @ViewBuilder footer: () -> Footer
    ) {
        self.number = number
        self.title = title
        self.detail = detail
        self.isDone = isDone
        self.action = action()
        self.footer = footer()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green.opacity(0.85) : Theme.panelStrong)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                footer
                    .padding(.top, 4)
            }

            Spacer(minLength: 12)

            if isDone {
                Text("Done")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.top, 5)
            } else {
                action
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(isDone ? Color.green.opacity(0.07) : Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isDone ? Color.green.opacity(0.35) : Theme.stroke)
        )
    }
}

extension OnboardingStep where Footer == EmptyView {
    init(
        number: Int, title: String, detail: String, isDone: Bool,
        @ViewBuilder action: () -> Action
    ) {
        self.init(number: number, title: title, detail: detail, isDone: isDone, action: action) {
            EmptyView()
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
