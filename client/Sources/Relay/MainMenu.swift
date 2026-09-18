// The menu bar. Built in code (no nib) with the standard menus a Mac app is
// expected to have: without them ⌘Q, ⌘W, ⌘H, ⌘M and the Edit shortcuts do
// nothing, and a text field cannot ⌘A/⌘C/⌘V — AppKit routes those through
// the Edit menu's items. Actions are nil-targeted so they reach whichever
// responder can act (the picker while its window is key, the app delegate
// otherwise) and disable themselves when nothing can; the picker validates
// the PC items per selection. While a session runs the kiosk window's
// StreamView swallows every ⌘-shortcut before the menu bar sees it, so
// nothing here steals a keystroke meant for the PC.

import AppKit

enum MainMenu {
    /// AppKit adds "Enter Full Screen" to any View menu unless this default
    /// says otherwise, and reads it when NSApplication is created — so this
    /// must run before `NSApplication.shared`, not when the menu is built.
    /// The picker window is not full-screen capable; the item would only
    /// ever be dimmed.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    }

    static func install() {
        let main = NSMenu()
        main.addItem(submenu(app()))
        main.addItem(submenu(pc()))
        main.addItem(submenu(edit()))
        main.addItem(submenu(view()))
        let window = window()
        main.addItem(submenu(window))
        let help = help()
        main.addItem(submenu(help))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    private static func app() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        item(menu, "About \(name)", #selector(AppDelegate.showAbout(_:)))
        menu.addItem(.separator())
        item(menu, "Settings…", #selector(HostPickerWindowController.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        item(menu, "Services", nil).submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        item(menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        item(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        item(menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    /// Relay has no documents, so File's slot is a PC menu: the same items as
    /// a row's context menu, for the selected row. Titles that depend on the
    /// selection ("Pair", the name to revert to) are set at validation.
    private static func pc() -> NSMenu {
        let menu = NSMenu(title: "PC")
        item(menu, "Connect", #selector(HostPickerWindowController.connectSelected(_:)), "\r", symbol: "display")
        menu.addItem(.separator())
        // Return is Connect, so Finder's rename key is not available.
        item(menu, "Rename", #selector(HostPickerWindowController.renameSelected(_:)), "r", symbol: "pencil")
        item(menu, "Revert Name", #selector(HostPickerWindowController.revertNameSelected(_:)), "r", [.command, .shift],
             symbol: "arrow.uturn.backward")
        menu.addItem(.separator())
        item(menu, "Forget", #selector(HostPickerWindowController.forgetSelected(_:)), "\u{8}", symbol: "xmark.circle")
        menu.addItem(.separator())
        // How the PC is used, not something done to one row: it lives here
        // rather than in View, which is about the picture.
        item(menu, "Native Keyboard and Pointer Control", #selector(HostPickerWindowController.toggleControl(_:)), "k",
             [.control, .option, .command], symbol: "keyboard")
        menu.addItem(.separator())
        // Not `performClose:`: AppKit pairs that with an automatic "Close All".
        item(menu, "Close Window", #selector(AppDelegate.closeKeyWindow(_:)), "w", symbol: "xmark")
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        item(menu, "Undo", Selector(("undo:")), "z")
        item(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        item(menu, "Cut", #selector(NSText.cut(_:)), "x")
        item(menu, "Copy", #selector(NSText.copy(_:)), "c")
        item(menu, "Paste", #selector(NSText.paste(_:)), "v")
        item(menu, "Delete", #selector(NSText.delete(_:)), "\u{8}", [])
        item(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    /// The stream mode, as the footer offers it: sizes, rates and bitrate
    /// as submenus of checkmarks. Titles and availability come from the
    /// picker's screen at validation; tags carry the scale index and the
    /// rate. Refresh Rate disappears altogether on a panel with one rate,
    /// as the footer's control does.
    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.delegate = viewDelegate
        let resolution = NSMenu(title: "Resolution")
        for i in StreamMode.scales.indices {
            item(resolution, "", #selector(HostPickerWindowController.selectResolution(_:))).tag = i
        }
        item(menu, "Resolution", nil, symbol: "arrow.up.left.and.arrow.down.right").submenu = resolution
        let refresh = NSMenu(title: "Refresh Rate")
        for hz in StreamMode.refreshCandidates {
            item(refresh, "\(hz) Hz", #selector(HostPickerWindowController.selectRefresh(_:))).tag = hz
        }
        let refreshItem = item(menu, "Refresh Rate", nil, symbol: "arrow.triangle.2.circlepath")
        refreshItem.submenu = refresh
        refreshItem.identifier = refreshRateIdentifier
        let bitrate = NSMenu(title: "Bitrate")
        bitrate.delegate = bitrateDelegate
        item(menu, "Bitrate", nil, symbol: "speedometer").submenu = bitrate
        menu.addItem(.separator())
        item(menu, "Show Latency Stats", #selector(HostPickerWindowController.toggleLatencyStats(_:)), "l",
             [.control, .option, .command], symbol: "chart.xyaxis.line")
        return menu
    }

    private static let bitrateDelegate = BitrateMenu()
    private static let viewDelegate = ViewMenu()
    private static let refreshRateIdentifier = NSUserInterfaceItemIdentifier("refreshRate")

    /// Hides Refresh Rate when the picker's screen offers a single rate.
    /// The picker is found through the responder chain; with none to ask
    /// (a session's kiosk window is key) the item stays, disabled like the rest.
    private final class ViewMenu: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let item = menu.items.first(where: { $0.identifier == refreshRateIdentifier }) else { return }
            let action = #selector(HostPickerWindowController.selectRefresh(_:))
            if let picker = NSApp.target(forAction: action) as? HostPickerWindowController {
                item.isHidden = picker.offeredRefreshRates.count < 2
            }
        }
    }

    /// Builds the Bitrate submenu each time it opens: the presets, plus the
    /// current value in its sorted place when the slider set something in
    /// between, so the checkmark is never missing. The current value comes
    /// from whichever picker would receive the action.
    private final class BitrateMenu: NSObject, NSMenuDelegate {
        static let presets = [20, 50, 80, 120, 200, 400, 800]

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let action = #selector(HostPickerWindowController.selectBitrate(_:))
            let current = (NSApp.target(forAction: action) as? HostPickerWindowController)?.prefs.bitrateMbps
            var values = Self.presets
            if let current, !values.contains(current) { values.append(current) }
            for mbps in values.sorted() {
                let item = NSMenuItem(title: "\(mbps) Mbps", action: action, keyEquivalent: "")
                item.tag = mbps
                item.state = mbps == current ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Custom…", action: #selector(HostPickerWindowController.showSettings(_:)), keyEquivalent: ""))
        }
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        item(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        item(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func help() -> NSMenu {
        let menu = NSMenu(title: "Help")
        item(menu, "\(ProcessInfo.processInfo.processName) Help", #selector(AppDelegate.openHelp(_:)), "?")
        return menu
    }
}
