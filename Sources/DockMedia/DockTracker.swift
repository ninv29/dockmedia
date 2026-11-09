import AppKit

/// Follows our slot inside the Dock every frame (auto-hide slide, magnification,
/// apps being added or removed), via Accessibility.
final class DockTracker {
    struct State: Equatable {
        /// Our slot as currently drawn, Cocoa global coords (bottom-left origin).
        var slot: CGRect
        /// Resting tile pitch / platter height.
        var restSlot: CGSize
        /// 0 = fully hidden, 1 = fully shown.
        var reveal: CGFloat
    }

    /// The platter floats this far above the screen edge when shown (macOS 26/27).
    static let bottomGap: CGFloat = 5

    private let ax = DockAX()
    private var timer: Timer?
    private var fast = true
    private var lastChange = Date()
    private var screenFrames: [CGRect] = NSScreen.screens.map(\.frame)
    private var primaryHeight: CGFloat = NSScreen.screens.first?.frame.height ?? 0

    private(set) var state: State?
    var onTick: ((State?) -> Void)?
    /// Set by the panel while the pointer is over the player, so hover stays smooth.
    var keepFast = false
    /// Look for our slot every few ms (it's about to appear after a Dock restart).
    var urgent: Bool {
        get { ax.urgent }
        set { ax.urgent = newValue }
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenFrames = NSScreen.screens.map(\.frame)
            self?.primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        }
    }

    func start() {
        schedule(fast: true)
        tick()
    }

    private func schedule(fast: Bool) {
        self.fast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 120.0 : 1.0 / 8.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = fast ? 0.001 : 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let s = currentState()
        if s != state { lastChange = Date() }
        state = s
        updateCadence(s)
        onTick?(s)
    }

    private func currentState() -> State? {
        guard let slot = ax.slot(expected: DockSlot.spacers) else { return nil }
        let f = slot.frame
        let reveal = Self.reveal(ofItemCG: f, screens: screenFrames, primaryHeight: primaryHeight)
        let cocoa = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        return State(slot: cocoa, restSlot: slot.restSlot, reveal: reveal)
    }

    /// How far the Dock is shown (0 hidden … 1 shown), from a resting-height tile's frame (CG coords).
    static func reveal(ofItemCG f: CGRect, screens: [CGRect] = NSScreen.screens.map(\.frame),
                       primaryHeight: CGFloat = NSScreen.screens.first?.frame.height ?? 0) -> CGFloat {
        let screen = screens.first { $0.minX <= f.midX && f.midX < $0.maxX } ?? screens.first ?? .zero
        let screenBottomCG = primaryHeight - screen.minY
        // Shown: top = bottom - gap - height. Hidden: top = bottom + gap. Measured from the
        // tile's bottom so magnified (taller) tiles read the same as resting ones.
        let shownBottom = screenBottomCG - Self.bottomGap
        let hiddenBottom = screenBottomCG + Self.bottomGap + f.height
        return max(0, min(1, (hiddenBottom - f.maxY) / max(1, hiddenBottom - shownBottom)))
    }

    private func updateCadence(_ s: State?) {
        let now = Date()
        let mouse = NSEvent.mouseLocation
        let bottom = screenFrames.first { $0.minX <= mouse.x && mouse.x < $0.maxX }?.minY ?? 0
        let nearDock = mouse.y < bottom + 120
        let animating = (s?.reveal ?? 0) > 0 && (s?.reveal ?? 0) < 1
        let wantFast = keepFast || nearDock || animating || now.timeIntervalSince(lastChange) < 0.8
        if wantFast != fast { schedule(fast: wantFast) }
    }
}
