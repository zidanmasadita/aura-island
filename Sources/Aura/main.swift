import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Menu-bar style app: no Dock icon, no main menu needed.
app.setActivationPolicy(.accessory)
app.run()
