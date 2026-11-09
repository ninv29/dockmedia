import AppKit
import SwiftUI

/// A transparent, chrome-less window that sits exactly over our slot in the Dock.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: -200, width: 301, height: 55),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Just above the Dock's own window, so our content draws on its glass.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}

@MainActor
final class PanelController: NSObject, NSMenuDelegate {
    let model: NowPlayingModel
    let settings = AppSettings.shared
    let ui = PanelUIState()
    let tracker = DockTracker()
    let panel = DockPanel()
    let magnification = MagnificationGuard()
    let sampler = GlassSampler()
    let transition = DockTransition()
    private var hosting: PanelHostingView<PlayerView>!

    private var menuOpen = false
    private var lastTrackKey = ""

    // Visibility / slot lifecycle
    /// Paused media stays up this long (like the iPhone lock screen), then the player goes away.
    private let pausedKeep: TimeInterval = 5 * 60
    /// The slot outlives the player only long enough to ride out a momentary "no info" blip
    /// between tracks; after that the gap closes at once.
    private let slotGrace: TimeInterval = 0.3
    private let launchDate = Date()
    private var lastActiveDate = Date.distantPast
    private var lastDockRestart = Date.distantPast
    private var lastSlotCheck = Date.distantPast
    private var dockPidAtRestart: pid_t = 0
    /// While a covered slot change runs, this decides whether the player shows.
    private var showOverride: Bool?
    /// Our tiles were in the Dock at the last check.
    private var slotPresent = false

    init(model: NowPlayingModel) {
        self.model = model
        super.init()
        hosting = PanelHostingView(rootView: PlayerView(model: model, ui: ui))
        hosting.menuProvider = { [weak self] in self?.buildMenu() }
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.ignoresMouseEvents = true
        tracker.onTick = { [weak self] in self?.update($0) }
        sampler.onChange = { [weak self] in self?.ui.glassDark = $0 }
    }

    func start() {
        if !DockAX.trusted { DockAX.requestTrust() }
        tracker.start()
        panel.orderFrontRegardless()
    }

    /// Removes our slot from the Dock (on quit).
    func teardown() {
        magnification.restore()
        transition.autoHide.resume()
        DockSlot.uninstall()
    }

    // MARK: Per-frame (must stay cheap)

    /// There's something to show: playing, or paused recently.
    private var mediaActive: Bool {
        // A momentary gap (e.g. an album wrapping to its first track) isn't the end.
        guard model.hasMedia || model.inInfoGap() else { return false }
        if model.isPlaying { return true }
        return Date().timeIntervalSince(model.pausedSince ?? Date()) < pausedKeep
    }

    private func update(_ dock: DockTracker.State?) {
        let now = Date()
        let active = mediaActive
        if active { lastActiveDate = now }
        // A momentary "no info" between tracks shouldn't blink the player.
        let want = active || now.timeIntervalSince(lastActiveDate) < slotGrace
        manageSlot(dock, want: want)
        // Once media ends, a player in a showing Dock stays until the covered slot removal
        // (which needs a moment to start) takes over, so the user never sees an empty gap.
        let holdForRemoval = !want && slotPresent && (dock?.reveal ?? 0) > 0.01
        let show = showOverride ?? (want || holdForRemoval)
        if show != ui.showing {
            ui.showing = show
        }

        guard let dock else {
            magnification.restore()
            if ui.revealed { ui.revealed = false; panel.ignoresMouseEvents = true }
            return
        }

        var metrics = ui.metrics
        metrics.pitch = dock.restSlot.width
        metrics.platter = dock.restSlot.height
        if metrics != ui.metrics { ui.metrics = metrics }

        // Centre our fixed-width content in the slot (the slot widens while neighbours magnify).
        let w = metrics.width, h = metrics.platter
        var frame = NSRect(x: (dock.slot.midX - w / 2).rounded(), y: dock.slot.minY.rounded(), width: w, height: h)
        if !frame.origin.x.isFinite { frame.origin.x = 0 }
        if frame != panel.frame { panel.setFrame(frame, display: false) }

        let visible = dock.reveal > 0.01
        if dock.reveal > 0.99 {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let cg = CGRect(x: frame.minX, y: primaryH - frame.maxY, width: frame.width, height: frame.height)
            sampler.sampleIfNeeded(slotCG: cg, force: !ui.revealed)
        }
        if visible != ui.revealed {
            ui.revealed = visible
            if visible { panel.orderFrontRegardless() }
        }
        let interactive = visible && active && !transition.busy
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        let mouse = NSEvent.mouseLocation
        let local: CGPoint? = interactive && panel.frame.contains(mouse)
            ? CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
            : nil
        if local != ui.mouse { ui.mouse = local }
        tracker.keepFast = local != nil || ui.scrubbing || menuOpen || transition.busy || transition.autoHide.suspended

        // Don't let the Dock magnify around the player.
        if interactive && mouse.y <= panel.frame.maxY + 12 && mouse.y >= panel.frame.minY - 12 {
            magnification.update(distance: max(0, panel.frame.minX - mouse.x, mouse.x - panel.frame.maxX), pitch: metrics.pitch)
        } else if visible {
            // The pointer left the row (usually on its way off the Dock): hold the current
            // size while the Dock is still up. Restoring now would pop every icon still
            // under the Dock's own hover region to full size for a split second as the Dock
            // hides. Away from the row nothing is magnified, so holding is invisible; once
            // the Dock has hidden, restoring is too.
        } else {
            magnification.update(distance: nil, pitch: metrics.pitch)
        }

        let key = "\(model.title)|\(model.artist)"
        if key != lastTrackKey { lastTrackKey = key; ui.trackChangeDate = Date() }
    }

    /// Adds the slot as soon as there's media and removes it as soon as there isn't, whether
    /// or not the Dock is showing. Changing it restarts the Dock, which takes a moment to come
    /// back; until it has, we don't touch it again. When the Dock is showing, the restart is
    /// hidden behind a frozen picture of the Dock (see `DockTransition`).
    private func manageSlot(_ dock: DockTracker.State?, want: Bool) {
        transition.tick()
        tracker.urgent = transition.busy
        if transition.busy { return }
        let now = Date()
        guard now.timeIntervalSince(lastSlotCheck) > 0.1 else { return }
        lastSlotCheck = now
        guard DockAX.trusted else { return }
        // Until the media helper has reported, we don't know whether anything is playing.
        guard model.didReceiveState || now.timeIntervalSince(launchDate) > 6 else { return }
        // Let the restarted Dock finish relaunching (and settle its prefs) before checking again.
        if now.timeIntervalSince(lastDockRestart) < 1.0 { return }
        guard DockAX.dockPid != dockPidAtRestart else {
            if now.timeIntervalSince(lastDockRestart) < 5 { return }
            dockPidAtRestart = 0
            return
        }

        if want {
            let installed = DockSlot.isInstalled
            slotPresent = installed
            guard !installed else { return }
            changeSlot(install: true)
        } else {
            // Any leftover tile counts, not just a complete slot, or a partly rewritten one would stay as a gap.
            let present = DockSlot.isPresent
            slotPresent = present
            guard present else { DockSlot.confirmRemoved(); return }
            changeSlot(install: false)
        }
    }

    private func changeSlot(install: Bool) {
        let change: () -> Bool = { [weak self] in
            guard let self else { return false }
            let pid = DockAX.dockPid
            guard install ? DockSlot.install() : DockSlot.uninstall() else { return false }
            self.lastDockRestart = Date()
            self.dockPidAtRestart = pid
            return true
        }
        // Dock hidden: nobody sees the restart, just do it.
        guard let live = DockAX.liveDock(measureTop: true), DockTracker.reveal(ofItemCG: live.first) > 0.01 else {
            _ = change()
            return
        }
        // Freeze the whole width of the Dock's screen from its tallest tile down.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.map(\.frame).first { $0.minX <= live.list.midX && live.list.midX < $0.maxX } ?? NSScreen.screens.first?.frame ?? .zero
        let bottomCG = primaryH - screen.minY
        let top = max(primaryH - screen.maxY, live.top - 6)
        let rect = CGRect(x: screen.minX, y: top, width: screen.width, height: bottomCG - top)

        // Removing: the player stays in the picture. Installing: it fades in with the reveal.
        showOverride = !install
        transition.run(
            freeze: rect,
            willRestart: { [weak self] in self?.showOverride = false },
            restart: change,
            ready: { [weak self] in
                // Installing: wait until we're tracking the new slot, so the player is in place.
                !install || (self?.tracker.state?.reveal ?? 0) > 0.99
            },
            done: { [weak self] in
                guard let self else { return }
                self.showOverride = nil
                self.slotPresent = install
            })
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        if let name = model.appName {
            menu.addItem(item("Open \(name)", #selector(openApp)))
            menu.addItem(.separator())
        }
        let login = item("Open at Login", #selector(toggleLogin)); login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        let mb = item("Show in Menu Bar", #selector(toggleMenuBar)); mb.state = settings.showMenuBarIcon ? .on : .off
        menu.addItem(mb)
        menu.addItem(.separator())
        menu.addItem(item("Quit DockMedia", #selector(quit)))
        return menu
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func openApp() { model.openSourceApp() }
    @objc func toggleLogin() { settings.launchAtLogin.toggle() }
    @objc func toggleMenuBar() {
        settings.showMenuBarIcon.toggle()
        (NSApp.delegate as? AppDelegate)?.updateStatusItem()
    }
    @objc func quit() { NSApp.terminate(nil) }
}
