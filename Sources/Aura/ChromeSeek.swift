import Foundation

/// Seek in Chrome's YouTube Music tab via AppleScript (no extension:
/// the user refused a Chrome bridge). Finds the YTM tab — preferring
/// one whose title matches the playing track, else the first YTM
/// tab — then sets the playing media element's currentTime.
/// First use triggers macOS's Automation prompt ("Aura wants to
/// control Google Chrome"); without it the script fails with -1743
/// and the caller logs the permission hint.
enum ChromeSeek {
    static func seek(to seconds: Double, trackTitle: String,
                     completion: @escaping (Bool) -> Void) {
        let value = String(format: "%.3f", seconds)
        let title = trackTitle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Playing element first (a YTM page can hold other media
        // elements, e.g. hover previews); fall back to the first one.
        let js = "(function(){var els=document.querySelectorAll('video,audio');"
            + "var m=null;for(var i=0;i<els.length;i++){if(!els[i].paused){m=els[i];break;}}"
            + "if(!m)m=els[0];if(!m)return 'no-media';"
            + "m.currentTime=\(value);return 'ok';})()"
        let script = """
        tell application "Google Chrome"
            set ytmTab to missing value
            set anyTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if URL of t contains "music.youtube.com" then
                            if anyTab is missing value then set anyTab to t
                            if title of t contains "\(title)" then
                                set ytmTab to t
                                exit repeat
                            end if
                        end if
                    end try
                end repeat
                if ytmTab is not missing value then exit repeat
            end repeat
            if ytmTab is missing value then set ytmTab to anyTab
            if ytmTab is missing value then return "no-tab"
            tell ytmTab
                set jsResult to execute javascript "\(js)"
            end tell
            return jsResult
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            var ok = false
            var reason = "unknown"
            do {
                try proc.run()
                // Generous timeout: the first run shows the
                // Automation prompt and osascript waits for the
                // user's choice; a retry after allowing succeeds.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0, stdout == "ok" {
                    ok = true
                } else if stdout == "no-tab" {
                    reason = "no YouTube Music tab open"
                } else if stdout == "no-media" {
                    reason = "no playable media in the YouTube Music tab"
                } else if stderr.contains("1743") {
                    reason = "needs Automation permission: allow Aura to control Google Chrome in System Settings"
                } else if !stderr.isEmpty {
                    reason = stderr.components(separatedBy: "\n").first ?? "unknown"
                }
            } catch {
                reason = "osascript could not start"
            }
            if !ok {
                print("[Aura] seek failed: \(reason) (target \(value)s)")
            }
            let result = ok
            DispatchQueue.main.async { completion(result) }
        }
    }
}
