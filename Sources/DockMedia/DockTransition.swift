import AppKit
import ScreenCaptureKit

/// Adding or removing our slot means restarting the Dock: it vanishes, and an auto-hiding
/// Dock comes back *hidden*, even with the pointer resting on it. Done naively, the user
/// sees the Dock close and reopen. When the Dock is showing at that moment, this hides
/// all of that:
///
/// 1. Freeze: a snapshot of the Dock as it is now goes up in a cover window just above it.
/// 2. Auto-hide is suspended in the Dock's prefs so the restarted Dock comes back shown.
/// 3. Restart behind the cover, then wait until the new Dock is laid out, fully shown and
///    has held still for a moment (and, when installing, our slot is tracked).
/// 4. Crossfade the cover away, revealing the new layout in place.
/// 5. Auto-hide comes back the moment the new Dock is up. While it's off, macOS reserves the
///    Dock's height and any window opened then is laid out above a gap, so it must not wait
///    for the pointer to leave: a Dock under the pointer stays open when it's re-enabled.
@MainActor
final class DockTransition {
    let autoHide = AutoHideSuspender()
    private let cover = CoverPanel()

    private(set) var busy = false
    private var restartedAt: Date?
    private var oldPid: pid_t = 0
    private var expectShown = true
    private var lastSignature: [CGRect] = []
    private var stableSince: Date?
    private var lastPoll = Date.distantPast
    private var ready: () -> Bool = { true }
    private var done: () -> Void = {}
    private var lastAutoHideCheck = Date.distantPast
    private var resumedEarly = false
    /// Auto-hide comes back by this time whatever the pointer is doing.
    private var autoHideDeadline = Date.distantPast

    /// How long the new Dock has to hold still before we reveal it (it lays out before it
    /// has drawn every icon).
    private let settle: TimeInterval = 0.16
    private let fade: TimeInterval = 0.32
    private let timeout: TimeInterval = 4

    /// `freeze`: the area to cover, CG global coords. `willRestart` runs once the cover is
    /// up; `restart` changes the slot (and restarts the Dock), returning whether it did.
    func run(freeze rect: CGRect,
             willRestart: @escaping () -> Void,
             restart: @escaping () -> Bool,
             ready: @escaping () -> Bool,
             done: @escaping () -> Void) {
        busy = true
        self.ready = ready
        self.done = done
        Task { @MainActor in
            let image = CGPreflightScreenCaptureAccess() ? try? await SCScreenshotManager.captureImage(in: rect) : nil
            if let image {
                self.cover.show(image, cgRect: rect)
                // Let the cover reach the screen before the Dock disappears under it.
                try? await Task.sleep(for: .milliseconds(34))
            }
            willRestart()
            let suspended = self.autoHide.suspendForRestart()
            self.expectShown = suspended || !self.autoHide.isEnabled
            self.oldPid = DockAX.dockPid
            guard restart() else {
                if suspended { self.autoHide.resume() }
                self.finish()
                return
            }
            self.restartedAt = Date()
            self.resumedEarly = false
            self.lastSignature = []
            self.stableSince = nil
        }
    }

    /// Called every tracker tick.
    func tick() {
        let now = Date()
        if busy, let restartedAt {
            if now.timeIntervalSince(restartedAt) > timeout {
                finish()
            } else if now.timeIntervalSince(lastPoll) >= 0.02 {
                lastPoll = now
                poll(now)
            }
        }
        // A safety net for when the Dock's restart didn't get as far as `poll` resuming it:
        // once the pointer is above the Dock, or the crossfade is over, auto-hide comes back.
        if !busy, autoHide.suspended, now.timeIntervalSince(lastAutoHideCheck) > 0.08 {
            lastAutoHideCheck = now
            let pointerAbove = DockAX.liveDock().map { pointerCG.y < $0.tiles.minY - 10 } ?? true
            if pointerAbove || now >= autoHideDeadline { autoHide.resume() }
        }
    }

    private var pointerCG: CGPoint {
        let mouse = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: primaryH - mouse.y)
    }

    private func poll(_ now: Date) {
        guard DockAX.dockPid != oldPid, let live = DockAX.liveDock(), live.list.width > 0 else {
            stableSince = nil; return
        }
        if expectShown && DockTracker.reveal(ofItemCG: live.first) < 0.995 {
            stableSince = nil
            // Auto-hide is already back, so the pointer has left and the Dock is hiding:
            // it won't show again, so there's nothing left to wait for.
            if resumedEarly { finish() }
            return
        }
        // The new Dock is up. With the pointer on it, re-enabling leaves it open, so don't
        // hold the screen space a moment longer. (With the pointer elsewhere it would start
        // hiding behind the cover, so that case waits for `finish`.)
        if autoHide.suspended, !resumedEarly, isPointerOnDock(live.tiles) {
            autoHide.resume()
            resumedEarly = true
        }
        let signature = [live.list, live.first, live.last]
        if signature != lastSignature || !ready() {
            lastSignature = signature
            stableSince = now
            return
        }
        if let s = stableSince, now.timeIntervalSince(s) >= settle {
            finish()
        }
    }

    /// The tiles, extended down to the bottom of the screen (the Dock's own hover area).
    private func isPointerOnDock(_ tiles: CGRect) -> Bool {
        let p = pointerCG
        return p.x >= tiles.minX && p.x <= tiles.maxX && p.y >= tiles.minY - 10
    }

    private func finish() {
        busy = false
        restartedAt = nil
        autoHideDeadline = Date().addingTimeInterval(fade)
        done()
        cover.fadeOut(duration: fade)
    }
}

/// Holds the frozen picture of the Dock during a restart.
private final class CoverPanel: NSPanel {
    private let imageLayer = CALayer()

    init() {
        super.init(contentRect: NSRect(x: 0, y: -400, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the Dock and above our player.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        v.layer?.addSublayer(imageLayer)
        contentView = v
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func show(_ image: CGImage, cgRect: CGRect) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: cgRect.minX, y: primaryH - cgRect.maxY, width: cgRect.width, height: cgRect.height)
        setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(origin: .zero, size: frame.size)
        imageLayer.contents = image
        CATransaction.commit()
        alphaValue = 1
        orderFrontRegardless()
        display()
        CATransaction.flush()
    }

    func fadeOut(duration: TimeInterval) {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.imageLayer.contents = nil
            }
        }
    }
}

/// Temporarily turns the Dock's auto-hide off across a restart, so the new Dock comes up
/// shown instead of hidden. The user's setting is restored live (CoreDock) as soon as the
/// new Dock is up, and on the next launch if DockMedia didn't exit cleanly.
final class AutoHideSuspender {
    private typealias GetB = @convention(c) () -> Bool
    private typealias SetB = @convention(c) (Bool) -> Void
    private let getF: GetB?
    private let setF: SetB?
    private let flagKey = "autoHideSuspended"
    private static let domain = "com.apple.dock" as CFString

    init() {
        let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        getF = h.flatMap { dlsym($0, "CoreDockGetAutoHideEnabled") }.map { unsafeBitCast($0, to: GetB.self) }
        setF = h.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }.map { unsafeBitCast($0, to: SetB.self) }
        if suspended { resume() }
    }

    var suspended: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    var isEnabled: Bool {
        if let getF { return getF() }
        CFPreferencesAppSynchronize(Self.domain)
        return CFPreferencesCopyAppValue("autohide" as CFString, Self.domain) as? Bool ?? false
    }

    /// Writes auto-hide off into the Dock's prefs (the restart that follows picks it up).
    /// Returns whether it did.
    func suspendForRestart() -> Bool {
        if suspended { return true }
        guard setF != nil, isEnabled else { return false }
        UserDefaults.standard.set(true, forKey: flagKey)
        CFPreferencesSetAppValue("autohide" as CFString, kCFBooleanFalse, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        return true
    }

    func resume() {
        guard suspended else { return }
        if let setF { setF(true) }
        CFPreferencesSetAppValue("autohide" as CFString, kCFBooleanTrue, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
