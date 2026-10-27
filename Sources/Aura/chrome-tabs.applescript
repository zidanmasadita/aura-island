-- chrome-tabs.applescript — standalone manual-test version of the
-- tab-list script embedded in ChromeTabArtwork.swift (Fallback 1).
-- Run directly: osascript Sources/Aura/chrome-tabs.applescript
-- Prints one "title|||url" line per Chrome tab. Empty output means
-- Chrome is not running, has no windows, or Automation permission
-- was denied (check System Settings -> Privacy & Security ->
-- Automation, then allow the app that ran this script to control
-- Google Chrome).
tell application "Google Chrome"
	set outLines to {}
	repeat with w in every window
		repeat with t in every tab of w
			set end of outLines to (title of t) & "|||" & (URL of t)
		end repeat
	end repeat
	set AppleScript's text item delimiters to "\n"
	return outLines as text
end tell
