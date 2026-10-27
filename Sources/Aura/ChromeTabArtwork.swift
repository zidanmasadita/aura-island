import AppKit
import Foundation

/// Fallback 1 for album artwork: the Chrome tab itself, no extension.
///
/// Proven background (Oct 2026): MediaRemote gives a third-party app
/// no artwork bytes by any tested path — JXA (Apple-signed osascript)
/// reads the metadata but the artwork value is unconvertible, and a
/// native helper is blocked outright (nil info while playing). The
/// tab that is actually playing still carries its own cover: the
/// YouTube Music watch URL's video ID maps to the video thumbnail
/// (i.ytimg.com), which is the same image YouTube Music shows.
///
/// Flow (once per track, only when the system artwork path yields
/// nothing): AppleScript lists Chrome's tabs (title + URL) -> pick
/// the YouTube watch tab whose title matches the playing song ->
/// video ID -> thumbnail (maxres, then hqdefault) -> NSImage.
///
/// Needs the Automation permission for Chrome (first run shows the
/// system dialog; the user grants it once). If Chrome is not running,
/// has no matching tab, or permission is denied, the AppleScript
/// fails and this returns nil — the placeholder stays, same as any
/// other artwork miss. No search, no API key: the image comes from
/// the playing tab's own video ID, never a web search.
enum ChromeTabArtwork {
    /// AppleScript listing every Chrome tab as "title|||url" lines.
    /// Kept in sync with the standalone Sources/Aura/chrome-tabs.applescript
    /// (run it directly with osascript to test the tab list by hand).
    private static let tabListScript = """
        tell application "Google Chrome"
            set outLines to {}
            repeat with w in every window
                repeat with t in every tab of w
                    set end of outLines to (title of t) & "|||" & (URL of t)
                end repeat
            end repeat
            set AppleScript's text item delimiters to "\\n"
            return outLines as text
        end tell
        """

    /// Runs off the main thread (osascript spawn + download); completion
    /// always on the main thread, like NowPlayingJXA.fetchArtwork.
    static func fetch(title: String, artist: String, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let image = fetchSync(title: title, artist: artist)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func fetchSync(title: String, artist: String) -> NSImage? {
        guard let videoID = matchingVideoID(title: title, artist: artist) else {
            return nil
        }
        // maxres is the full-size thumbnail; not every video has one,
        // so hqdefault (always present for public videos) is the fallback.
        for variant in ["maxresdefault", "hqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(variant).jpg"),
                  let data = download(url: url),
                  let image = NSImage(data: data) else {
                continue
            }
            return image
        }
        return nil
    }

    // MARK: - Tab list + match

    private static func matchingVideoID(title: String, artist: String) -> String? {
        guard let output = runTabListScript() else { return nil }
        let wantTitle = normalized(title)
        let wantArtist = normalized(artist)
        guard !wantTitle.isEmpty else { return nil }
        var fallbackID: String?
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 2 else { continue }
            let tabTitle = normalized(parts[0])
            let tabURL = parts[1]
            guard let videoID = videoID(from: tabURL) else { continue }
            let titleOK = tabTitle == wantTitle
                || tabTitle.contains(wantTitle) || wantTitle.contains(tabTitle)
            guard titleOK else { continue }
            // Prefer a tab whose title also carries the artist (a
            // lyrics page or video with the same song title is a
            // weaker match); otherwise the first title match wins.
            if !wantArtist.isEmpty
                && (tabTitle.contains(wantArtist) || wantArtist.contains(tabTitle)) {
                return videoID
            }
            if fallbackID == nil {
                fallbackID = videoID
            }
        }
        return fallbackID
    }

    private static func normalized(_ s: String) -> String {
        // Same lowercase + whitespace-collapse as the lyrics matcher,
        // plus: strip the YouTube tab suffix and punctuation separators
        // (•, –, |, -) that tab titles carry but song titles do not.
        var t = s.lowercased()
        for suffix in [" - youtube music", " - youtube"] {
            if t.hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count))
            }
        }
        let cleaned = t.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
        return cleaned.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Video ID from a YouTube watch URL (music.youtube.com or
    /// www.youtube.com) or a youtu.be short link. Returns nil for
    /// non-YouTube tabs (the tab filter itself).
    private static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host.hasSuffix("youtube.com") || host == "youtu.be" else {
            return nil
        }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        guard let query = url.query else { return nil }
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == "v" && !kv[1].isEmpty {
                return kv[1]
            }
        }
        return nil
    }

    private static func runTabListScript() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", tabListScript]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                proc.terminate()
            }
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            // Includes: Chrome not running, Automation permission
            // denied, and any AppleScript error. All are "no tab".
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Download

    private static func download(url: URL) -> Data? {
        var result: Data?
        var response: URLResponse?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, resp, _ in
            result = data
            response = resp
            sem.signal()
        }
        task.resume()
        // Cap the wait: URLSession's own timeout is 60s, far too long
        // for a once-per-track fallback running on a background queue.
        _ = sem.wait(timeout: .now() + 12)
        if task.state == .running {
            task.cancel()
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = result, !data.isEmpty else {
            return nil
        }
        return data
    }
}
