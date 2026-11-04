//
//  AppModel.swift
//  Broom
//

import AppKit
import Foundation
import Observation

/// Top-level app state: which screen is showing, the mounted volumes, Full Disk Access, and the
/// scan in progress.
@Observable
final class AppModel {
    enum Screen: Equatable {
        /// Briefly, while checking Full Disk Access to pick the first screen.
        case launching
        case onboarding
        case home
        case scanning
        case results
    }

    private(set) var screen: Screen = .launching
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown
    /// Sandboxed builds only: the startup disk, once the user has given Broom access to it.
    private(set) var startupDiskAccess: URL? = nil
    private(set) var volumes: [VolumeInfo] = []
    private(set) var hasLoadedVolumes = false
    private(set) var scan: ScanSession? = nil
    private(set) var browser: BrowserModel? = nil
    var errorMessage: String? = nil

    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var progressTask: Task<Void, Never>? = nil
    @ObservationIgnored private var accessedURL: URL? = nil
    @ObservationIgnored private var accessCheckTask: Task<Void, Never>? = nil
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Sandboxed builds can only read folders the user picks, so scanning a disk asks first.
    /// The No Sandbox scheme builds without it (see Configurations/).
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static let onboardingDismissedKey = "FullDiskAccessOnboardingDismissed"

    init() {
        observeVolumeChanges()
        observeAppActivation()
        refreshVolumes()
        Task { await self.showFirstScreen() }
    }

    var hasStartupDiskAccess: Bool {
        startupDiskAccess.map { PathUtilities.path(of: $0) == "/" } ?? false
    }

    // MARK: - Onboarding and Full Disk Access

    /// Shows onboarding at launch unless Full Disk Access is already on, or the user skipped it.
    private func showFirstScreen() async {
        let status = await checkFullDiskAccess()
        fullDiskAccess = status
        let wasDismissed = UserDefaults.standard.bool(forKey: Self.onboardingDismissedKey)
        if status == .granted || wasDismissed {
            screen = .home
        } else {
            showOnboarding()
        }
    }

    func showOnboarding() {
        guard screen != .scanning else { return }
        screen = .onboarding
        // Keep checking while onboarding is up, so it updates as soon as access is switched on.
        accessCheckTask?.cancel()
        accessCheckTask = Task {
            while !Task.isCancelled {
                await self.updateFullDiskAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingDismissedKey)
        stopCheckingAccess()
        screen = .home
    }

    private func stopCheckingAccess() {
        accessCheckTask?.cancel()
        accessCheckTask = nil
    }

    func openFullDiskAccessSettings() {
        FullDiskAccess.openSettings()
    }

    /// Sandboxed builds: asks for access to the startup disk, so Broom can scan it and check
    /// Full Disk Access.
    func requestStartupDiskAccess() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/")
        panel.message = "Select your startup disk, then click Allow."
        configureFolderPanel(panel)
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard PathUtilities.path(of: url) == "/" else {
            errorMessage = "Choose your startup disk (usually “Macintosh HD”), not a folder inside it."
            return
        }
        startupDiskAccess = url
        refreshFullDiskAccess()
    }

    func refreshFullDiskAccess() {
        Task { await self.updateFullDiskAccess() }
    }

    private func updateFullDiskAccess() async {
        let status = await checkFullDiskAccess()
        if fullDiskAccess != status {
            fullDiskAccess = status
        }
    }

    private func checkFullDiskAccess() async -> FullDiskAccess.Status {
        let status = await FullDiskAccess.check()
        // Until the user grants the disk, the sandbox itself can refuse the check, so a refusal
        // doesn't mean Full Disk Access is off.
        if Self.isSandboxed && !hasStartupDiskAccess && status == .denied {
            return .unknown
        }
        return status
    }

    private func observeAppActivation() {
        // Coming back from System Settings: check again.
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFullDiskAccess()
            }
        }
        observers.append(token)
    }

    // MARK: - Volumes

    func refreshVolumes() {
        Task {
            let volumes = await VolumeInfo.loadMountedVolumes()
            self.volumes = volumes
            self.hasLoadedVolumes = true
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVolumes()
                }
            }
            observers.append(token)
        }
    }

    // MARK: - Choosing what to scan

    func scanVolume(_ volume: VolumeInfo) {
        guard Self.isSandboxed else {
            scan(ScanTarget(url: volume.url, volume: volume))
            return
        }
        // Access granted during onboarding (or an earlier scan) lasts until Broom quits.
        if let granted = startupDiskAccess, PathUtilities.path(of: granted) == PathUtilities.path(of: volume.url) {
            scan(ScanTarget(url: granted, volume: volume))
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = volume.url
        panel.message = "Broom needs your permission to read “\(volume.name)”. Click Scan to allow it."
        configureFolderPanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if PathUtilities.path(of: url) == "/" {
            startupDiskAccess = url
            refreshFullDiskAccess()
        }
        scan(ScanTarget(url: url, volume: matchingVolume(for: url)))
    }

    func chooseFolderToScan() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder or a disk to scan."
        configureFolderPanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(ScanTarget(url: url, volume: matchingVolume(for: url)))
    }

    func scanDroppedItem(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == true else {
            errorMessage = "Drop a folder or a disk to scan it."
            return
        }
        scan(ScanTarget(url: url, volume: matchingVolume(for: url)))
    }

    func rescan() {
        guard let target = browser?.target ?? scan?.target else { return }
        scan(target)
    }

    private func configureFolderPanel(_ panel: NSOpenPanel) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
    }

    private func matchingVolume(for url: URL) -> VolumeInfo? {
        let path = PathUtilities.path(of: url)
        return volumes.first { PathUtilities.path(of: $0.url) == path }
    }

    // MARK: - Scanning

    func scan(_ target: ScanTarget) {
        stopScanning()
        stopCheckingAccess()
        retire(browser)
        browser = nil
        beginAccess(to: target.url)

        let scanner = DiskScanner(rootPath: target.path, rootName: target.name)
        let session = ScanSession(target: target, scanner: scanner)
        scanGeneration += 1
        let generation = scanGeneration
        scan = session
        screen = .scanning

        // Poll the scanner's atomic counters a few times a second. The workers never touch the UI.
        progressTask = Task {
            while !Task.isCancelled {
                session.snapshot = scanner.progress.snapshot()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        Task {
            // Suspends this main-actor task without blocking it while the scanner threads work.
            let outcome = await scanner.run()
            guard generation == self.scanGeneration, !outcome.wasCancelled else {
                Self.releaseInBackground(outcome.root)
                return
            }
            self.progressTask?.cancel()
            self.progressTask = nil
            self.browser = BrowserModel(outcome: outcome, target: target)
            self.scan = nil
            self.screen = .results
        }
    }

    /// Stops the current scan and goes back to the disks.
    func cancelScan() {
        stopScanning()
        screen = browser == nil ? .home : .results
    }

    func showHome() {
        stopScanning()
        stopCheckingAccess()
        screen = .home
    }

    func showResults() {
        guard browser != nil else { return }
        stopCheckingAccess()
        screen = .results
    }

    private func stopScanning() {
        guard let session = scan else { return }
        scanGeneration += 1
        session.scanner.cancel()
        progressTask?.cancel()
        progressTask = nil
        scan = nil
    }

    private func beginAccess(to url: URL) {
        if accessedURL == url { return }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    // MARK: - Memory

    private func retire(_ browser: BrowserModel?) {
        guard let browser else { return }
        Self.releaseInBackground(browser.root)
    }

    /// Freeing millions of nodes takes a moment, so let a background task drop the last reference
    /// once the views showing the old tree are gone.
    private static func releaseInBackground(_ root: FileNode) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            withExtendedLifetime(root) {}
        }
    }
}

extension FullDiskAccess {
    /// Opens Privacy & Security › Full Disk Access in System Settings.
    @MainActor
    static func openSettings() {
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A scan in progress, as shown on the scanning screen.
@Observable
final class ScanSession {
    let target: ScanTarget
    let startDate = Date()
    fileprivate(set) var snapshot = ScanSnapshot()
    let scanner: DiskScanner

    init(target: ScanTarget, scanner: DiskScanner) {
        self.target = target
        self.scanner = scanner
    }
}

extension VolumeInfo {
    /// Loads the mounted volumes on a background thread.
    @concurrent
    nonisolated static func loadMountedVolumes() async -> [VolumeInfo] {
        mountedVolumes()
    }
}
