import Foundation
import CoreServices

/// Watches the macOS screenshot folder and reports every new
/// screenshot file. Detection uses the
/// `com.apple.metadata:kMDItemIsScreenCapture` extended attribute
/// that macOS stamps on screenshots — locale-independent (file
/// names are localized, e.g. "Cuplikan Layar" on Indonesian
/// systems), and it also covers screen recordings.
///
/// No special permission is needed: FSEvents on the user's own
/// screenshot folder (usually ~/Desktop) works sandbox-free.
///
/// Limitations: clipboard-only screenshots (Cmd+Ctrl+Shift+4)
/// never touch the disk, so they can't be seen here. If the user
/// changes the screenshot location mid-run, the watcher keeps the
/// old folder until the app restarts.
final class ScreenshotWatcher {
    /// Called on the main thread with each new screenshot file URL.
    var onScreenshot: ((URL) -> Void)?

    private var stream: FSEventStreamRef?
    private var pending: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.aura.screenshot-watcher")

    private static let xattrName = "com.apple.metadata:kMDItemIsScreenCapture"
    /// Settle delay: the file may still be writing when FSEvents
    /// fires, and create+modify arrive as an event pair.
    private static let settleDelay: TimeInterval = 0.8

    /// Where macOS currently saves screenshots
    /// (`defaults read com.apple.screencapture location`, else ~/Desktop).
    static func screenshotDirectory() -> URL {
        if let loc = CFPreferencesCopyAppValue("location" as CFString,
                                               "com.apple.screencapture" as CFString) as? String {
            let expanded = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    }

    func start() {
        stop()
        let dir = Self.screenshotDirectory()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            for i in 0..<numEvents {
                let flags = eventFlags[i]
                let created = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
                let isDir = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let removed = flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
                if created && !isDir && !removed {
                    watcher.handleNewFile(at: paths[i])
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context,
                                          [dir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        queue.sync { pending.removeAll() }
    }

    private func handleNewFile(at path: String) {
        pending[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending.removeValue(forKey: path)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  Self.isScreenshotFile(url) else { return }
            DispatchQueue.main.async { self.onScreenshot?(url) }
        }
        pending[path] = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// True when the file carries macOS's screen-capture marker.
    static func isScreenshotFile(_ url: URL) -> Bool {
        var flag: UInt8 = 0
        let res: Int = xattrName.withCString { namePtr in
            url.path.withCString { pathPtr in
                getxattr(pathPtr, namePtr, &flag, 1, 0, 0)
            }
        }
        return res >= 0
    }

    deinit { stop() }
}
