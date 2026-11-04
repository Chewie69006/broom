# Linux harness

Compiles and tests Broom's scanner and models on Linux, without Xcode. It's handy for CI or a
cloud machine. On a Mac, use the tests in Xcode (⌘U) instead: they run the same test file against
the real `getattrlistbulk`.

## Run it

You need Swift 6.2 or later on Linux. The official Docker image works:

```bash
docker run --rm -v "$PWD":/broom -w /broom/LinuxHarness swift:6.3-noble ./run.sh
```

Or, with Swift installed, from this folder:

```bash
./run.sh
```

The script runs four steps and stops at the first failure:

1. **Build and test in Swift 5 mode**, with the Xcode project's settings: `MainActor` default
   isolation, approachable concurrency and member import visibility. Runs `BroomTests`.
2. **Build and test in strict Swift 6 mode**, where any concurrency problem is an error.
3. **Benchmark cross-check**: runs `Benchmark/main.swift` (built as `Bench`) once and fails if
   any scanner setup's totals differ from `fts`'s. The timings mean little on Linux.
4. **Stress test under ThreadSanitizer** (`Stress/main.swift`):
   - Scans a folder (default `/usr/lib`, or pass one: `./run.sh /some/folder`) with 1, 4 and 24
     workers, with full-path opens and no entry counts, and with at most 3 open folders. Then
     `/usr` with 8 workers.
   - Compares every scan against a simple single-threaded walk, and checks every folder's size,
     sort order, parent links and item count.
   - Polls progress from another thread during scans, the way the UI does.
   - Cancels 60 scans at random moments.
   - Runs the collect-then-delete flow through `BrowserModel`.
   - Checks that entries the kernel reports as errors are skipped.

## What's covered

Only code that doesn't need SwiftUI or AppKit: everything in `Broom/Scanning`, plus
`SunburstLayout.swift`, `BrowserModel.swift`, `VolumeInfo.swift` and `FullDiskAccess.swift`. The
views, menus and AppKit code still need Xcode.

## How it works

- `Sources/Broom` and `Tests/BroomTests` hold **symlinks to the app's real files**, so there's
  nothing to keep in sync by hand. If you add a Linux-friendly source file to the app, add a symlink
  for it here.
- `Shims/DarwinShim` stands in for `Darwin`. It re-exports Glibc and implements `getattrlistbulk` on
  top of `readdir` and `fstatat`, packing entries in the macOS kernel's layout. Two details exercise
  the parser's harder paths: 64-bit fields land on unaligned offsets, and entries come back seven
  per call. Names starting with `zz_error_` come back as error entries. The app's `import Darwin`
  is pointed at the shim with `-module-alias Darwin=DarwinShim`.
- `Shims/CoreGraphics` re-exports Foundation, which provides the CG types on Linux.
- `Shims/CFTS` exposes `<fts.h>`, which Glibc's Swift module leaves out. The shim re-exports it,
  and provides Darwin's `RLIMIT_NOFILE` (an `Int32`; Glibc has an enum case). It also reports
  `ATTR_DIR_ENTRYCOUNT`, and starts a fresh listing for any descriptor still at offset 0. The
  kernel ties a listing to the open file, but the shim keys it by descriptor number, which gets
  reused.
- `Bench/` links the benchmark and the scanner sources into one module, as `Benchmark/run.sh`
  does on macOS.
- `Sources/Broom/_LinuxOnlyShims.swift` stubs two macOS-only Foundation APIs that Linux lacks
  (`FileManager.trashItem` and a disk-capacity key).
- `Sources/Broom/_TSanMutex.swift` is used only for the ThreadSanitizer build. On Linux, Swift's
  `Mutex` locks with raw futexes that TSan can't see, so it reports races that aren't real. This
  pthread-based stand-in has the same API and shadows the real one. (On macOS, `Mutex` uses
  `os_unfair_lock`, which TSan understands.)

The shim follows the layout documented in the `getattrlistbulk(2)` man page and XNU's source, so it
checks the parser against that understanding. It doesn't replace running the tests on a Mac.
