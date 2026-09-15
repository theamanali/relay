// Entry point. No storyboard: the AppDelegate builds the single full-screen window.

import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
