import AppKit
import ApplicationServices

/// Reads the Dock's live layout through Accessibility. All rects are CG global
/// coordinates (top-left origin).
final class DockAX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    struct Slot {
        /// Union of our spacer tiles as currently drawn (moves with auto-hide, widens with magnification).
        var frame: CGRect
        /// A resting (unmagnified) tile's size: the Dock's slot pitch and platter height.
        var restSlot: CGSize
        /// The whole icon list.
        var list: CGRect
    }

    private var dockPid: pid_t = 0
    private var list: AXUIElement?
    private var first: AXUIElement?
    private var last: AXUIElement?
    private var restSlot = CGSize(width: 43, height: 55)
    private var lastRefresh = Date.distantPast
    private var lastTrustCheck = Date.distantPast
    private var trustedCached = false

    static func frame(of e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static func string(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return v as? String
    }

    /// Re-discovers the list and our spacer run (cheap enough twice a second).
    private func refresh(expected: Int) {
        lastRefresh = Date()
        first = nil; last = nil
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { list = nil; return }
        if dock.processIdentifier != dockPid || list == nil {
            dockPid = dock.processIdentifier
            let app = AXUIElementCreateApplication(dockPid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
                  let arr = children as? [AXUIElement] else { list = nil; return }
            list = arr.first { Self.string($0, kAXRoleAttribute) == kAXListRole as String }
            if let list { AXUIElementSetMessagingTimeout(list, 0.1) }
        }
        guard let list else { return }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { self.list = nil; return }
        let subs = items.map { Self.string($0, kAXSubroleAttribute) ?? "" }

        // Our run, right after a divider: `expected` spacers, then the half-width divider spacer.
        var i = 0
        while i < items.count {
            if subs[i] == "AXSeparatorDockItem" {
                var j = i + 1
                while j < items.count && subs[j] == "AXSpacerDockItem" { j += 1 }
                if j - (i + 1) >= expected + 1 {
                    first = items[i + 1]
                    last = items[i + expected + 1]
                    break
                }
            }
            i += 1
        }

        // Resting tile size: the smallest icon tile (magnification only grows tiles).
        let sizes = zip(items, subs).filter { $0.1 != "AXSeparatorDockItem" && $0.1 != "AXSpacerDockItem" }
            .compactMap { Self.frame(of: $0.0)?.size }
        if let w = sizes.map(\.width).min(), let h = sizes.map(\.height).min(), w > 0, h > 0 {
            restSlot = CGSize(width: w, height: h)
        }
    }

    static var dockPid: pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
    }

    struct Live {
        var pid: pid_t
        /// The icon list, and its first and last tiles (CG global coords).
        var list: CGRect
        var first: CGRect
        var last: CGRect
        /// Topmost point of any tile (magnified tiles rise above the platter).
        var top: CGFloat
        /// The tiles as drawn now. (The list's own frame doesn't follow auto-hide.)
        var tiles: CGRect { first.union(last) }
    }

    /// A fresh, uncached read of whatever Dock process is running now (for restarts).
    static func liveDock(measureTop: Bool = false) -> Live? {
        let pid = dockPid
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement],
              let list = arr.first(where: { string($0, kAXRoleAttribute) == kAXListRole as String }),
              let lf = frame(of: list) else { return nil }
        var items: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
              let tiles = items as? [AXUIElement], let f = tiles.first, let l = tiles.last,
              let ff = frame(of: f), let lff = frame(of: l) else { return nil }
        var top = min(ff.minY, lff.minY, lf.minY)
        if measureTop { for t in tiles { if let r = frame(of: t) { top = min(top, r.minY) } } }
        return Live(pid: pid, list: lf, first: ff, last: lff, top: top)
    }

    /// Re-look for our slot quickly while it's expected to appear (a Dock restart).
    var urgent = false

    /// Fast path, every display frame.
    func slot(expected: Int) -> Slot? {
        let now = Date()
        if now.timeIntervalSince(lastTrustCheck) > 2 { lastTrustCheck = now; trustedCached = DockAX.trusted }
        guard trustedCached else { return nil }
        if first == nil || now.timeIntervalSince(lastRefresh) > 0.5 {
            if first == nil && now.timeIntervalSince(lastRefresh) < (urgent ? 0.04 : 0.25) { return nil }
            refresh(expected: expected)
        }
        guard let first, let last, let list,
              let a = DockAX.frame(of: first), let b = DockAX.frame(of: last), let l = DockAX.frame(of: list) else {
            self.first = nil
            return nil
        }
        // Tiles grow upward when magnified; their bottoms stay on the platter's bottom.
        let bottom = max(a.maxY, b.maxY)
        let frame = CGRect(x: a.minX, y: bottom - restSlot.height, width: b.maxX - a.minX, height: restSlot.height)
        return Slot(frame: frame, restSlot: restSlot, list: l)
    }
}
