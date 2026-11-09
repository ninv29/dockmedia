import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: NowPlayingModel!
    var controller: PanelController!
    var statusItem: NSStatusItem?
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sending a command while the helper is being respawned writes to a closed pipe;
        // that must be a failed write, not the end of the app (and a stranded Dock slot).
        signal(SIGPIPE, SIG_IGN)
        model = NowPlayingModel()
        controller = PanelController(model: model)
        controller.start()
        AppSettings.shared.applyLoginDefault()
        updateStatusItem()
        // Clean up our Dock slot however we're asked to stop.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder/Spotlight) brings back the menu bar icon and peeks the player.
        if !AppSettings.shared.showMenuBarIcon {
            AppSettings.shared.showMenuBarIcon = true
            updateStatusItem()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
        model?.bridge.stop()
    }

    func updateStatusItem() {
        if AppSettings.shared.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let icon = Bundle.main.image(forResource: "MenuBarIconTemplate")
                    ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "DockMedia")
                icon?.isTemplate = true
                icon?.accessibilityDescription = "DockMedia"
                item.button?.image = icon
                item.menu = statusMenu()
                statusItem = item
            }
        } else if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
            statusItem = nil
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller!
        let s = AppSettings.shared
        if model.canControl {
            let np = NSMenuItem(title: model.title + (model.artist.isEmpty ? "" : " — \(model.artist)"), action: nil, keyEquivalent: "")
            np.isEnabled = false
            menu.addItem(np)
            menu.addItem(c.item(model.isPlaying ? "Pause" : "Play", #selector(PanelController.togglePlay)))
            menu.addItem(c.item("Next Track", #selector(PanelController.nextTrack)))
            menu.addItem(c.item("Previous Track", #selector(PanelController.prevTrack)))
            menu.addItem(.separator())
        } else {
            let np = NSMenuItem(title: "Nothing Playing", action: nil, keyEquivalent: "")
            np.isEnabled = false
            menu.addItem(np)
            menu.addItem(.separator())
        }
        let login = c.item("Open at Login", #selector(PanelController.toggleLogin)); login.state = s.launchAtLogin ? .on : .off
        menu.addItem(login)
        let mb = c.item("Show in Menu Bar", #selector(PanelController.toggleMenuBar)); mb.state = .on
        menu.addItem(mb)
        menu.addItem(.separator())
        menu.addItem(c.item("Quit DockMedia", #selector(PanelController.quit)))
    }
}

extension PanelController {
    @objc func togglePlay() { model.togglePlayPause() }
    @objc func nextTrack() { model.next() }
    @objc func prevTrack() { model.previous() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
