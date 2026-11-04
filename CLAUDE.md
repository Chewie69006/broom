# CLAUDE.md

Broom is a macOS disk space analyzer in the style of DaisyDisk: a parallel scanner feeds a
SwiftUI sunburst chart with a synced list, history navigation and a collector for deleting files.
See README.md for features and architecture.

## Commands

```bash
# Build and test (macOS, Xcode 27+). The "Broom (No Sandbox)" scheme builds without App Sandbox.
xcodebuild build -project Broom.xcodeproj -scheme Broom -destination 'platform=macOS'
xcodebuild test -project Broom.xcodeproj -scheme Broom -destination 'platform=macOS'
xcodebuild build -project Broom.xcodeproj -scheme "Broom (No Sandbox)" -destination 'platform=macOS'

# Scanner benchmark against fts (macOS, Terminal). Also flags any setup whose totals differ.
Benchmark/run.sh [--runs N] [folder ...]

# Linux, no Xcode (needs Swift 6.2+): builds the scanner and models in Swift 5 and strict
# Swift 6 modes, runs BroomTests, checks the benchmark's totals, then a ThreadSanitizer stress test.
LinuxHarness/run.sh
```

Run `LinuxHarness/run.sh` after changing anything in `Broom/Scanning/`,
`Broom/Sunburst/SunburstLayout.swift`, `Broom/Models/BrowserModel.swift`,
`Broom/Models/VolumeInfo.swift` or `Broom/Models/FullDiskAccess.swift`. The views and AppKit code can only be built in Xcode.

## Project setup

- Xcode 27 project in the new text format (`Broom.xcodeproj/project.xcproj`). `Broom/`,
  `BroomTests/` and `BroomUITests/` are synchronized folders: files added there join their target
  automatically, so don't edit the project file to add files, and never put non-app files under
  `Broom/`.
- Swift 5 language mode, with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- `MemberImportVisibility` is on: import every module whose members a file uses (`Foundation`,
  `AppKit`, `CoreGraphics`, `Synchronization`, `UniformTypeIdentifiers`…), even if another import
  seems to bring it in.
- Deployment target macOS 27.2.
- Two builds:

  | Scheme | Configurations | xcconfig | App Sandbox |
  | --- | --- | --- | --- |
  | `Broom` | Debug, Release | `Configurations/Sandboxed.xcconfig` | on, with read-write user-selected files |
  | `Broom (No Sandbox)` | Debug-NoSandbox, Release-NoSandbox | `Configurations/NoSandbox.xcconfig` | off |

  - The xcconfig files are attached to the Broom target via `specialized-configurations` in
    `project.xcproj`.
  - Keep sandbox settings in the xcconfig files only. Target build settings override them.
  - A new per-configuration setting (`SETTING[config=Debug]`) needs adding for all four
    configurations.
  - Code must work in both builds; branch on `AppModel.isSandboxed` at runtime.

## Concurrency rules

Everything is `@MainActor` unless declared otherwise. Thread safety is a core requirement for this
project, so keep these invariants.

- Code that runs off the main thread must be marked `nonisolated`: the type and each nested type
  (nested types don't inherit it). Otherwise their conformances (`Hashable`, `Sendable`…) are
  main-actor isolated and can't be used from other threads.
- A `nonisolated async` function runs on the caller's actor (`NonisolatedNonsendingByDefault`). To
  really leave the main actor for blocking work, use `@concurrent`. Examples:
  `FileRemover.remove`, `VolumeInfo.loadMountedVolumes`.
- Never do file-system work on the main actor. Long blocking syscalls don't belong on Swift's
  cooperative pool either; the scanner uses its own `Thread`s.
- For callbacks that arrive on arbitrary queues, make the closure `@Sendable` and hop back with
  `Task { @MainActor in … }`, or use `MainActor.assumeIsolated` when the queue is `.main`.
- File tree ownership:
  - **During a scan**, a `FileNode`'s `children`, `size` and `descendantCount` are written only by the
    worker that owns it. Finished folders are handed upward through `pendingSubfolders`
    (acquire/release). The UI reads only `ScanProgress` snapshots and never touches the tree.
  - **After the scan**, the tree belongs to the main actor. Change it only through `@MainActor`
    methods (`FileNode.removeChild`). After removing nodes, drop every reference into the removed
    subtree (see `BrowserModel.pruneDetachedReferences`). `parent` is `weak`.
- Free large trees off the main thread (`AppModel.releaseInBackground`).

## Where code goes

- Keep `Broom/Scanning/`, `SunburstLayout.swift`, `BrowserModel.swift`, `VolumeInfo.swift` and
  `FullDiskAccess.swift` free of SwiftUI and AppKit, so the Linux harness can build them. AppKit-backed `BrowserModel` actions
  go in `BrowserModel+Finder.swift`; chart drawing goes in `SunburstView.swift`.
- A new Linux-buildable source file needs a relative symlink in `LinuxHarness/Sources/Broom/`.
- Colors come from `Theme` and `SunburstPalette`, sizes are formatted with `Int64.byteString`, and
  icons come from `FileIcons` (cached). The chart palette leaves out red on purpose: red is kept
  for deleting, and a big red wedge reads as an error.
- Full Disk Access can't be requested, only detected (`FullDiskAccess.check()` tries to open
  protected items). Onboarding at launch walks the user through System Settings.
- Tests use Swift Testing. The test target isn't main-actor by default, so suites that touch app
  types are marked `@MainActor`.

## Scanner details to preserve

- `BulkDirectoryReader.swift` parses `getattrlistbulk` buffers:
  - Attributes are packed in bit order (common, then directory, then file), and only if they're set
    in the returned bitmap. Directory attributes come as entry count, then mount status.
  - `ATTR_CMN_ERROR` comes right after the returned bitmap.
  - 64-bit fields can be unaligned, so read them with `loadUnaligned`.

  To request a new attribute, add its parse step in bit order and mirror it in
  `LinuxHarness/Shims/DarwinShim/Darwin.swift`.
- Sizes are allocated bytes (`ATTR_FILE_ALLOCSIZE`). Hard links are counted once. Mount points and
  automount triggers are never opened. When scanning `/`, the Data volume is allowed but
  `/System/Volumes/Data` is skipped to avoid double counting.
- Folders are opened with `openat` relative to a `DirectoryHandle` for their parent. The handle
  closes its descriptor when the last subfolder holding it is done. `OpenFolderBudget` caps open
  handles; past the cap, or on `EMFILE`, folders are opened by full path. The scanner raises the
  descriptor limit at start.
- Entry counts end a folder's reading early. They're trusted only on APFS and HFS+
  (`Options.EntryCounts.automatic`), and only when the folder is on the same device as its
  parent: a firmlink like `/Users` reports the count of the wrong folder. An understated count
  would silently drop entries, so don't widen this without checking.
- `DiskScanner.Options` exists for the benchmark and tests; the app uses the defaults.

## Linux harness notes

- `LinuxHarness/Shims/DarwinShim` stands in for `Darwin` through `-module-alias`, and
  `Shims/CoreGraphics` re-exports Foundation. If a macOS-only API breaks the Linux build, stub it in
  `LinuxHarness/Sources/Broom/_LinuxOnlyShims.swift` rather than changing app code.
- On Linux, ThreadSanitizer reports false races inside `Synchronization.Mutex`, which uses raw
  futexes. The stress build swaps in `_TSanMutex.swift` for that reason. Any other TSan report is
  a real bug.
- Read `dirent` names with the shim's `direntName`, never by copying `d_name`: records are only as
  long as their name, and copying all 256 bytes can run off the end of the buffer and crash.
