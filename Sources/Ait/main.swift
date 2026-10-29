import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // только значок в строке меню, без Dock
app.run()
